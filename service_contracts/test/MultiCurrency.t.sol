// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Cids} from "@pdp/Cids.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FilecoinWarmStorageServiceTest} from "./FilecoinWarmStorageService.t.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {Errors} from "../src/Errors.sol";
import {PriceList} from "../src/lib/PriceList.sol";
import {DATA_SET_INFO_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {CURRENCY_REGISTRY_SLOT, CurrencyAdded, CurrencyEnabledSet} from "../src/lib/CurrencyRegistry.sol";
import {
    calculateStorageRate,
    TIB_IN_BYTES,
    EPOCHS_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    CREATE_DATA_SET_FEE
} from "../src/lib/PriceListUSDFC.sol";

/// @dev Stablecoin mock with configurable decimals (axlUSDC-like at 6, USDFC-like at 18).
contract MockStablecoin is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Multi-currency support (FilOzone/filecoin-services#618): a data set picks a whitelisted
///         USD stablecoin at creation; every amount FWSS charges is the USD price list scaled to the
///         token's decimals.
contract MultiCurrencyTest is FilecoinWarmStorageServiceTest {
    bytes32 constant CREATE_DATA_SET_TYPEHASH_V1 = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    bytes32 constant CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH = keccak256(
        "CreateDataSetWithCurrency(uint256 clientDataSetId,address payee,address currency,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    bytes32 constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    // Native 6-decimal values of the USD price list (what a single-token axlUSDC deployment charges)
    uint256 constant SIX_RESERVE = 500_000; // $0.50
    uint256 constant SIX_CREATE_FEE = 25_000; // $0.025
    uint256 constant SIX_ADD_BASE_FEE = 8_000; // $0.008
    uint256 constant SIX_ADD_PER_PIECE_FEE = 3_000; // $0.003
    uint256 constant SIX_REMOVALS_FEE = 7_000; // $0.007
    uint256 constant SIX_DATASET_FEE_PER_EPOCH = 1; // 120_000 / 86_400 truncated
    uint256 constant SIX_STORAGE_PER_TIB_MONTH = 2_500_000; // $2.50
    uint256 constant SIX_REQUIRED_LOCKUP = 620_000; // dataset fee month + reserve
    uint256 constant SIX_CDN_LOCKUP = 700_000;
    uint256 constant SIX_CACHE_MISS_LOCKUP = 300_000;

    MockStablecoin axl; // 6 decimals
    MockStablecoin usd18; // second 18-decimal stablecoin

    uint256 clientKey = 0xC11E47;
    address signingClient;

    /// @dev The base setUp is not virtual; each test deploys the extra tokens through this modifier.
    modifier withTokens() {
        _deployTokens();
        _;
    }

    function _deployTokens() internal {
        axl = new MockStablecoin("axlUSDC", 6);
        usd18 = new MockStablecoin("USD18", 18);
        signingClient = vm.addr(clientKey);
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? client : signingClient;
            axl.mint(who, 1_000_000e6);
            usd18.mint(who, 1_000_000e18);
            mockUSDFC.transfer(who, 1000e18);
        }
    }

    // ---------------------------------------------------------------------
    // helpers

    function _fund(address payer, IERC20 token, uint256 depositAmount) internal {
        uint256 unit = 10 ** IERC20Metadata(address(token)).decimals();
        vm.startPrank(payer);
        payments.setOperatorApproval(token, address(pdpServiceWithPayments), true, 1000 * unit, 1000 * unit, 365 days);
        token.approve(address(payments), depositAmount);
        payments.deposit(token, payer, depositAmount);
        vm.stopPrank();
    }

    function _metadata(bool withCDN) internal pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](withCDN ? 2 : 1);
        values = new string[](keys.length);
        keys[0] = "label";
        values[0] = "multi-currency";
        if (withCDN) {
            keys[1] = "withCDN";
            values[1] = "true";
        }
    }

    /// @dev The #618 variant: the legacy tuple with `address currency` appended. The first dynamic
    ///      field (`keys`) then sits at offset 0xc0 instead of 0xa0.
    function _extraDataV2(address payer, uint256 clientDataSetId, bool withCDN, bytes memory sig, address currency)
        internal
        pure
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _metadata(withCDN);
        return abi.encode(payer, clientDataSetId, keys, values, sig, currency);
    }

    function _extraDataV1(address payer, uint256 clientDataSetId, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _metadata(false);
        return abi.encode(payer, clientDataSetId, keys, values, sig);
    }

    function _createV2(address currency, bool withCDN) internal returns (uint256 dataSetId) {
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, nextClientDataSetId++, withCDN, FAKE_SIGNATURE, currency)
        );
    }

    function _metadataHash(bool withCDN) internal pure returns (bytes32) {
        (string[] memory keys, string[] memory values) = _metadata(withCDN);
        bytes32[] memory entries = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entries[i] =
                keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(keys[i])), keccak256(bytes(values[i]))));
        }
        return keccak256(abi.encodePacked(entries));
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(clientKey, _eip712Digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _addPieces(uint256 dataSetId, uint256 count) internal {
        Cids.Cid[] memory pieces = new Cids.Cid[](count);
        for (uint256 i = 0; i < count; i++) {
            pieces[i] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked(dataSetId, i, "mc")));
        }
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            dataSetId,
            0,
            pieces,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    function _pending(uint256 dataSetId) internal view returns (uint256) {
        return viewContract.getDataSet(dataSetId).pendingOneTimePayments;
    }

    function _reserve(uint256 dataSetId) internal view returns (uint256) {
        return viewContract.getDataSet(dataSetId).lifecycleReserveBalance;
    }

    function _pdpRail(uint256 dataSetId) internal view returns (FilecoinPayV1.RailView memory) {
        return payments.getRail(viewContract.getDataSet(dataSetId).pdpRailId);
    }

    // ---------------------------------------------------------------------
    // whitelist administration

    function testAddCurrency_AssignsSequentialIdsAndEmits() public withTokens {
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyAdded(1, address(axl), 6);
        pdpServiceWithPayments.addCurrency(axl);

        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyAdded(2, address(usd18), 18);
        pdpServiceWithPayments.addCurrency(usd18);

        assertEq(viewContract.getCurrencyCount(), 2);
        assertEq(viewContract.getCurrencyId(address(axl)), 1);
        assertEq(viewContract.getCurrencyId(address(usd18)), 2);
        (address token, uint8 decimals, bool enabled) = viewContract.getCurrency(1);
        assertEq(token, address(axl));
        assertEq(decimals, 6);
        assertTrue(enabled);
        // id 0 is always the deployment's default token (USDFC)
        (token, decimals, enabled) = viewContract.getCurrency(0);
        assertEq(token, address(mockUSDFC));
        assertEq(decimals, 18);
        assertTrue(enabled);
    }

    function testAddCurrency_OnlyOwner() public withTokens {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        pdpServiceWithPayments.addCurrency(axl);

        pdpServiceWithPayments.addCurrency(axl);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        pdpServiceWithPayments.setCurrencyEnabled(address(axl), false);
    }

    function testAddCurrency_RejectsDuplicatesDefaultAndBadDecimals() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyAlreadyAdded.selector, address(axl)));
        pdpServiceWithPayments.addCurrency(axl);

        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyAlreadyAdded.selector, address(mockUSDFC)));
        pdpServiceWithPayments.addCurrency(IERC20Metadata(address(mockUSDFC)));

        MockStablecoin five = new MockStablecoin("FIVE", 5);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCurrencyDecimals.selector, address(five), uint8(5)));
        pdpServiceWithPayments.addCurrency(five);

        MockStablecoin nineteen = new MockStablecoin("NINETEEN", 19);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidCurrencyDecimals.selector, address(nineteen), uint8(19))
        );
        pdpServiceWithPayments.addCurrency(nineteen);
    }

    function testSetCurrencyEnabled_EmitsAndRejectsUnknown() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyEnabledSet(1, address(axl), false);
        pdpServiceWithPayments.setCurrencyEnabled(address(axl), false);
        (,, bool enabled) = viewContract.getCurrency(1);
        assertFalse(enabled);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedCurrency.selector, address(usd18)));
        pdpServiceWithPayments.setCurrencyEnabled(address(usd18), true);
    }

    // ---------------------------------------------------------------------
    // backwards compatibility

    function testLegacyExtraDataStillUsesDefaultToken() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, mockUSDFC, 100e18);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(pdpServiceWithPayments, _extraDataV1(client, 7, FAKE_SIGNATURE));

        assertEq(address(_pdpRail(dataSetId).token), address(mockUSDFC));
        assertEq(_reserve(dataSetId), LIFECYCLE_RESERVE_TARGET);
        assertEq(_pending(dataSetId), CREATE_DATA_SET_FEE);
        (address token, uint8 decimals) = viewContract.getDataSetCurrency(dataSetId);
        assertEq(token, address(mockUSDFC));
        assertEq(decimals, 18);
    }

    function testV2WithDefaultTokenBehavesLikeLegacy() public withTokens {
        _fund(client, mockUSDFC, 100e18);
        uint256 dataSetId = _createV2(address(mockUSDFC), false);
        assertEq(address(_pdpRail(dataSetId).token), address(mockUSDFC));
        assertEq(_reserve(dataSetId), LIFECYCLE_RESERVE_TARGET);
    }

    function testLegacySignatureStillVerifies() public withTokens {
        _fund(signingClient, mockUSDFC, 100e18);
        bytes32 structHash =
            keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH_V1, uint256(11), serviceProvider, _metadataHash(false)));
        bytes memory extra = _extraDataV1(signingClient, 11, _sign(structHash));
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extra);
        assertEq(viewContract.getDataSet(dataSetId).payer, signingClient);
    }

    // ---------------------------------------------------------------------
    // the currency is client-signed

    function testV2SignatureBindsCurrency() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        pdpServiceWithPayments.addCurrency(usd18);
        _fund(signingClient, axl, 100e6);
        _fund(signingClient, usd18, 100e18);

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH, uint256(12), serviceProvider, address(axl), _metadataHash(false)
            )
        );
        bytes memory sig = _sign(structHash);

        // The SP cannot swap the payer's chosen token for another one the payer has approved
        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(signingClient, 12, false, sig, address(usd18))
        );

        // ...nor strip the currency to fall back to the default token
        _fund(signingClient, mockUSDFC, 100e18);
        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, _extraDataV1(signingClient, 12, sig));

        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(signingClient, 12, false, sig, address(axl))
        );
        assertEq(address(_pdpRail(dataSetId).token), address(axl));
    }

    function testSessionKeyWithCreateDataSetPermissionCanSignV2() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 100e6);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH_V1;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp + 1 days, permissions, "mc");

        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 21, false, FAKE_SIGNATURE, address(axl))
        );
        assertEq(viewContract.getDataSet(dataSetId).payer, client);
    }

    // ---------------------------------------------------------------------
    // currency selection

    function testUnknownCurrencyReverts() public withTokens {
        _fund(client, axl, 100e6);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedCurrency.selector, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 31, false, FAKE_SIGNATURE, address(axl))
        );
    }

    function testDisabledCurrencyBlocksNewDataSetsOnly() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 1000e6);
        uint256 existing = _createV2(address(axl), false);

        pdpServiceWithPayments.setCurrencyEnabled(address(axl), false);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedCurrency.selector, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 32, false, FAKE_SIGNATURE, address(axl))
        );

        // The existing data set keeps paying in its token at its token's scale
        _addPieces(existing, 2);
        (address token,) = viewContract.getDataSetCurrency(existing);
        assertEq(token, address(axl));
        assertEq(_reserve(existing), SIX_RESERVE - SIX_CREATE_FEE - SIX_ADD_BASE_FEE - 2 * SIX_ADD_PER_PIECE_FEE);

        pdpServiceWithPayments.setCurrencyEnabled(address(axl), true);
        _createV2(address(axl), false);
    }

    // ---------------------------------------------------------------------
    // amounts scale to the token's decimals

    function testSixDecimalDataSetCreationAmounts() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), false);

        FilecoinPayV1.RailView memory rail = _pdpRail(dataSetId);
        assertEq(address(rail.token), address(axl));
        assertEq(rail.lockupFixed, SIX_RESERVE);
        assertEq(_reserve(dataSetId), SIX_RESERVE);
        assertEq(_pending(dataSetId), SIX_CREATE_FEE);
        (address token, uint8 decimals) = viewContract.getDataSetCurrency(dataSetId);
        assertEq(token, address(axl));
        assertEq(decimals, 6);
    }

    function testSixDecimalFundsCheckUsesScaledRequirement() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, SIX_REQUIRED_LOCKUP - 1);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientLockupFunds.selector, client, SIX_REQUIRED_LOCKUP, SIX_REQUIRED_LOCKUP - 1
            )
        );
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 41, false, FAKE_SIGNATURE, address(axl))
        );

        vm.startPrank(client);
        axl.approve(address(payments), 1);
        payments.deposit(axl, client, 1);
        vm.stopPrank();
        _createV2(address(axl), false);
    }

    function testSixDecimalCDNLockups() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), true);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory cdn = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMiss = payments.getRail(info.cacheMissRailId);
        assertEq(address(cdn.token), address(axl));
        assertEq(address(cacheMiss.token), address(axl));
        assertEq(cdn.lockupFixed, SIX_CDN_LOCKUP);
        assertEq(cacheMiss.lockupFixed, SIX_CACHE_MISS_LOCKUP);
    }

    function testSixDecimalOperationFees() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), false);

        _addPieces(dataSetId, 3);
        // create + add fees flushed to the SP out of the reserve
        assertEq(_pending(dataSetId), 0);
        assertEq(_reserve(dataSetId), SIX_RESERVE - SIX_CREATE_FEE - SIX_ADD_BASE_FEE - 3 * SIX_ADD_PER_PIECE_FEE);

        uint256[] memory pieceIds = new uint256[](1);
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
        assertEq(_pending(dataSetId), SIX_REMOVALS_FEE);
    }

    function testSixDecimalStorageRateMatchesNativeSixDecimalPriceList() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2(address(axl), false);

        // ~100 GiB so the size-proportional term is non-zero at 6 decimals
        uint256 baseLeaves = (100 * 1024 * 1024 * 1024) / 32;
        mockPDPVerifier.setDataSetLeafCount(dataSetId, baseLeaves);
        _addPieces(dataSetId, 1);
        uint256 leafCount = mockPDPVerifier.getDataSetLeafCount(dataSetId);

        uint256 rawBytes = Cids.leafCountToRawSize(leafCount);
        uint256 expected =
            (rawBytes * SIX_STORAGE_PER_TIB_MONTH) / (TIB_IN_BYTES * EPOCHS_PER_MONTH) + SIX_DATASET_FEE_PER_EPOCH;
        assertGt(expected, SIX_DATASET_FEE_PER_EPOCH, "size term must be non-zero for this check");
        assertEq(_pdpRail(dataSetId).paymentRate, expected);
    }

    function testSecondEighteenDecimalCurrencyChargesSameAsUSDFC() public withTokens {
        pdpServiceWithPayments.addCurrency(usd18);
        _fund(client, usd18, 1000e18);
        _fund(client, mockUSDFC, 900e18);

        uint256 a = _createV2(address(usd18), false);
        uint256 b = _createV2(address(mockUSDFC), false);
        uint256 baseLeaves = (100 * 1024 * 1024 * 1024) / 32;
        mockPDPVerifier.setDataSetLeafCount(a, baseLeaves);
        mockPDPVerifier.setDataSetLeafCount(b, baseLeaves);
        _addPieces(a, 1);
        _addPieces(b, 1);

        assertEq(address(_pdpRail(a).token), address(usd18));
        assertEq(_pdpRail(a).paymentRate, _pdpRail(b).paymentRate);
        assertEq(_pdpRail(a).paymentRate, calculateStorageRate(mockPDPVerifier.getDataSetLeafCount(a)));
        assertEq(_reserve(a), _reserve(b));
    }

    // ---------------------------------------------------------------------
    // views

    function testPriceListForCurrencyIsScaled() public withTokens {
        pdpServiceWithPayments.addCurrency(axl);
        PriceList memory list = viewContract.getPriceListForCurrency(address(axl));
        assertEq(address(list.token), address(axl));
        assertEq(list.rates.storagePerTibPerMonth, SIX_STORAGE_PER_TIB_MONTH);
        assertEq(list.rates.datasetFeePerMonth, 120_000);
        assertEq(list.fees.createDataSetFee, SIX_CREATE_FEE);
        assertEq(list.fees.addPiecesPerPieceFee, SIX_ADD_PER_PIECE_FEE);
        assertEq(list.lockups.lifecycleReserveTarget, SIX_RESERVE);
        assertEq(list.lockups.defaultLockupPeriod, EPOCHS_PER_MONTH);

        PriceList memory def = viewContract.getPriceListForCurrency(address(mockUSDFC));
        PriceList memory legacy = viewContract.getPriceList();
        assertEq(keccak256(abi.encode(def)), keccak256(abi.encode(legacy)));

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedCurrency.selector, address(usd18)));
        viewContract.getPriceListForCurrency(address(usd18));
    }

    // ---------------------------------------------------------------------
    // storage layout

    function testCurrencyIdPackedIntoDataSetInfoAndRegistryNamespaced() public withTokens {
        assertEq(
            CURRENCY_REGISTRY_SLOT,
            keccak256(abi.encode(uint256(keccak256("fwss.storage.currencies")) - 1)) & ~bytes32(uint256(0xff))
        );
        pdpServiceWithPayments.addCurrency(usd18);
        pdpServiceWithPayments.addCurrency(axl);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), false);

        bytes32 word10 = vm.load(
            address(pdpServiceWithPayments), bytes32(uint256(keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT))) + 10)
        );
        assertEq(uint8(uint256(word10) >> 192), 2, "currency id in DataSetInfo bits 192-199");
        assertEq(uint96(uint256(word10)), SIX_CREATE_FEE, "pending unchanged at bits 0-95");
        assertEq(uint256(vm.load(address(pdpServiceWithPayments), CURRENCY_REGISTRY_SLOT)), 2, "currency count");
    }
}
