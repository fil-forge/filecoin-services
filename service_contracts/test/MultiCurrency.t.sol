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
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {
    FWSS_CURRENCY_STORAGE_SLOT,
    FWSS_DATA_SET_PRICING_STORAGE_SLOT,
    PAYMENT_TOKENS_CAPABILITY_KEY,
    CurrencyAdded,
    CurrencyEnabledSet
} from "../src/lib/PaymentTermsStorage.sol";
import {
    calculateStorageRate,
    DATASET_FEE_PER_EPOCH,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TIB_IN_BYTES,
    EPOCHS_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    CREATE_DATA_SET_FEE
} from "../src/lib/PriceListUSDFC.sol";
import {console} from "forge-std/Test.sol";

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
///         USD stablecoin at creation; every amount FWSS charges is computed in 18-decimal USD as on main
///         and converted to the token's units with ceiling division. A non-default currency needs the
///         provider's opt-in through its `paymentTokens` registry capability.
contract MultiCurrencyTest is FilecoinWarmStorageServiceTest {
    bytes32 constant CREATE_DATA_SET_TYPEHASH_V1 = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    // #618 variant (keys at 0xc0): the legacy tuple plus `address token`
    bytes32 constant CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH = keccak256(
        "CreateDataSetWithCurrency(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token)"
        "MetadataEntry(string key,string value)"
    );
    // #619 variant (keys at 0xe0): the legacy tuple plus `address token, uint256 storagePricePerTibPerMonth`
    bytes32 constant CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH = keccak256(
        "CreateDataSetWithPayment(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token,"
        "uint256 storagePricePerTibPerMonth)" "MetadataEntry(string key,string value)"
    );
    bytes32 constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    // Native 6-decimal values of the USD price list (what a single-token axlUSDC deployment charges)
    uint256 constant SIX_RESERVE = 500_000; // $0.50
    uint256 constant SIX_CREATE_FEE = 25_000; // $0.025
    uint256 constant SIX_ADD_BASE_FEE = 8_000; // $0.008
    uint256 constant SIX_ADD_PER_PIECE_FEE = 3_000; // $0.003
    uint256 constant SIX_REMOVALS_FEE = 7_000; // $0.007
    uint256 constant SIX_TERMINATE_FEE = 6_000; // $0.006
    uint256 constant SIX_DATASET_FEE_PER_EPOCH = 2; // ceil(1_388_888_888_888 / 10**12)
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
            require(mockUSDFC.transfer(who, 1000e18));
        }
        // serviceProvider accepts both extra currencies; sp1 advertises none (default currency only)
        address[] memory accepted = new address[](2);
        accepted[0] = address(axl);
        accepted[1] = address(usd18);
        _acceptCurrencies(serviceProvider, accepted);
    }

    /// @dev Sets the provider's `paymentTokens` PDP capability: the token addresses, packed 20 bytes each.
    function _acceptCurrencies(address sp, address[] memory tokens) internal {
        uint256 providerId = serviceProviderRegistry.getProviderIdByAddress(sp);
        (, string[] memory keys, bytes[] memory values) = serviceProviderRegistry.getAllProductCapabilities(
            providerId, ServiceProviderRegistryStorage.ProductType.PDP
        );
        bytes memory packed;
        for (uint256 i = 0; i < tokens.length; i++) {
            packed = abi.encodePacked(packed, tokens[i]);
        }
        string[] memory newKeys = new string[](keys.length + 1);
        bytes[] memory newValues = new bytes[](keys.length + 1);
        uint256 n = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(PAYMENT_TOKENS_CAPABILITY_KEY))) continue;
            newKeys[n] = keys[i];
            newValues[n] = values[i];
            n++;
        }
        newKeys[n] = PAYMENT_TOKENS_CAPABILITY_KEY;
        newValues[n] = packed;
        n++;
        assembly ("memory-safe") {
            mstore(newKeys, n)
            mstore(newValues, n)
        }
        vm.prank(sp);
        serviceProviderRegistry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, newKeys, newValues);
    }

    function _ceil(uint256 amount, uint256 scale) internal pure returns (uint256) {
        return amount == 0 ? 0 : (amount - 1) / scale + 1;
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

    /// @dev The #618 variant: the legacy tuple with `address token` appended. The first dynamic field (`keys`)
    ///      then sits at offset 0xc0 instead of 0xa0.
    function _extraDataV2(address payer, uint256 clientDataSetId, bool withCDN, bytes memory sig, address currency)
        internal
        pure
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _metadata(withCDN);
        return abi.encode(payer, clientDataSetId, keys, values, sig, currency);
    }

    /// @dev The #619 variant: the legacy tuple with `address token, uint256 storagePricePerTibPerMonth` appended
    ///      (`keys` at 0xe0). The price is 18-decimal USD per TiB per month; 0 means the posted price.
    function _extraDataV2Priced(
        address payer,
        uint256 clientDataSetId,
        bool withCDN,
        bytes memory sig,
        address currency,
        uint256 price
    ) internal pure returns (bytes memory) {
        (string[] memory keys, string[] memory values) = _metadata(withCDN);
        return abi.encode(payer, clientDataSetId, keys, values, sig, currency, price);
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
        pdpServiceWithPayments.setCurrency(address(axl), true);

        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyAdded(2, address(usd18), 18);
        pdpServiceWithPayments.setCurrency(address(usd18), true);

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
        pdpServiceWithPayments.setCurrency(address(axl), true);

        pdpServiceWithPayments.setCurrency(address(axl), true);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        pdpServiceWithPayments.setCurrency(address(axl), false);
    }

    function testAddCurrency_RejectsDefaultAndBadDecimals() public withTokens {
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyAlreadyAdded.selector, address(mockUSDFC)));
        pdpServiceWithPayments.setCurrency(address(mockUSDFC), true);

        MockStablecoin five = new MockStablecoin("FIVE", 5);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCurrencyDecimals.selector, address(five), uint8(5)));
        pdpServiceWithPayments.setCurrency(address(five), true);

        MockStablecoin nineteen = new MockStablecoin("NINETEEN", 19);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCurrencyDecimals.selector, address(nineteen), uint8(19)));
        pdpServiceWithPayments.setCurrency(address(nineteen), true);
    }

    function testSetCurrency_TogglesEnabledAndCanAddDisabled() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyEnabledSet(1, address(axl), false);
        pdpServiceWithPayments.setCurrency(address(axl), false);
        (,, bool enabled) = viewContract.getCurrency(1);
        assertFalse(enabled);
        assertEq(viewContract.getCurrencyCount(), 1, "toggling does not add an entry");

        // An unknown token is added under the next id, here disabled from the start
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit CurrencyAdded(2, address(usd18), 18);
        pdpServiceWithPayments.setCurrency(address(usd18), false);
        (address token,, bool enabled2) = viewContract.getCurrency(2);
        assertEq(token, address(usd18));
        assertFalse(enabled2);
    }

    // ---------------------------------------------------------------------
    // backwards compatibility

    function testLegacyExtraDataStillUsesDefaultToken() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
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
        pdpServiceWithPayments.setCurrency(address(axl), true);
        pdpServiceWithPayments.setCurrency(address(usd18), true);
        _fund(signingClient, axl, 100e6);
        _fund(signingClient, usd18, 100e18);

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH, uint256(12), serviceProvider, _metadataHash(false), address(axl)
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

    /// The 0xc0 variant has its own session-key permission (its type hash); CreateDataSet does not cover it.
    function testSessionKeyNeedsCreateDataSetWithCurrencyPermission() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 100e6);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH_V1;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp + 1 days, permissions, "mc");

        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 21, false, FAKE_SIGNATURE, address(axl))
        );

        permissions[0] = CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp + 1 days, permissions, "mc");
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
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 existing = _createV2(address(axl), false);

        pdpServiceWithPayments.setCurrency(address(axl), false);
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

        pdpServiceWithPayments.setCurrency(address(axl), true);
        _createV2(address(axl), false);
    }

    // ---------------------------------------------------------------------
    // amounts scale to the token's decimals

    function testSixDecimalDataSetCreationAmounts() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
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
        pdpServiceWithPayments.setCurrency(address(axl), true);
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

    /// FilBeam settles in default-token units, so withCDN is rejected for any other currency.
    function testNonDefaultCurrencyRejectsCDN() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        pdpServiceWithPayments.setCurrency(address(usd18), true);
        _fund(client, axl, 100e6);
        _fund(client, usd18, 100e18);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNNotSupportedForCurrency.selector, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 42, true, FAKE_SIGNATURE, address(axl))
        );
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNNotSupportedForCurrency.selector, address(usd18)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 43, true, FAKE_SIGNATURE, address(usd18))
        );

        // The default token named explicitly keeps CDN
        _fund(client, mockUSDFC, 100e18);
        uint256 dataSetId = _createV2(address(mockUSDFC), true);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(payments.getRail(info.cdnRailId).lockupFixed, SIX_CDN_LOCKUP * 1e12);
        assertEq(payments.getRail(info.cacheMissRailId).lockupFixed, SIX_CACHE_MISS_LOCKUP * 1e12);
    }

    function testSixDecimalOperationFees() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
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

    function testSixDecimalTerminateFeePaidInToken() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), false);
        _addPieces(dataSetId, 1);

        (, uint256 spBefore,,) = payments.getAccountInfoIfSettled(axl, serviceProvider);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));
        (, uint256 spAfter,,) = payments.getAccountInfoIfSettled(axl, serviceProvider);

        uint256 networkFee =
            (SIX_TERMINATE_FEE * payments.NETWORK_FEE_NUMERATOR() + payments.NETWORK_FEE_DENOMINATOR() - 1)
                / payments.NETWORK_FEE_DENOMINATOR();
        assertEq(spAfter - spBefore, SIX_TERMINATE_FEE - networkFee, "SP receives the 6-decimal terminate fee");
        assertEq(_pdpRail(dataSetId).lockupFixed, 0);
    }

    /// Each per-epoch term is computed at 18 decimals as on main, then rounded up to whole token units.
    function testSixDecimalStorageRateRoundsUp() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2(address(axl), false);

        // ~100 GiB so the size-proportional term is non-zero at 6 decimals
        uint256 baseLeaves = (100 * 1024 * 1024 * 1024) / 32;
        mockPDPVerifier.setDataSetLeafCount(dataSetId, baseLeaves);
        _addPieces(dataSetId, 1);
        uint256 leafCount = mockPDPVerifier.getDataSetLeafCount(dataSetId);

        uint256 rawBytes = Cids.leafCountToRawSize(leafCount);
        uint256 sizeTerm18 = (rawBytes * STORAGE_PRICE_PER_TIB_PER_MONTH) / (TIB_IN_BYTES * EPOCHS_PER_MONTH);
        uint256 expected = _ceil(sizeTerm18, 1e12) + _ceil(DATASET_FEE_PER_EPOCH, 1e12);
        assertGt(sizeTerm18 % 1e12, 0, "size term must not be a whole number of units for this check");
        assertEq(_pdpRail(dataSetId).paymentRate, expected);
        assertEq(expected, sizeTerm18 / 1e12 + 1 + SIX_DATASET_FEE_PER_EPOCH);
    }

    function testSecondEighteenDecimalCurrencyChargesSameAsUSDFC() public withTokens {
        pdpServiceWithPayments.setCurrency(address(usd18), true);
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
        pdpServiceWithPayments.setCurrency(address(axl), true);
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
    // the default currency is the deployment's 18-decimal USDFC

    function testDefaultTokenMustHaveTokenDecimals() public withTokens {
        vm.expectRevert();
        new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            axl,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
    }

    // ---------------------------------------------------------------------
    // #619 agreed prices in a non-default currency (combined 618 + 619)

    function _createV2Priced(address currency, uint256 price) internal returns (uint256 dataSetId) {
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments,
            _extraDataV2Priced(client, nextClientDataSetId++, false, FAKE_SIGNATURE, currency, price)
        );
    }

    /// @dev Rate of a 6-decimal data set at an 18-decimal USD price: each 18-decimal term rounded up.
    function _sixDecimalRate(uint256 leafCount, uint256 price) internal pure returns (uint256) {
        return _ceil((Cids.leafCountToRawSize(leafCount) * price) / (TIB_IN_BYTES * EPOCHS_PER_MONTH), 1e12)
            + SIX_DATASET_FEE_PER_EPOCH;
    }

    function _grow(uint256 dataSetId) internal returns (uint256 leafCount) {
        mockPDPVerifier.setDataSetLeafCount(dataSetId, (100 * 1024 * 1024 * 1024) / 32); // ~100 GiB
        _addPieces(dataSetId, 1);
        leafCount = mockPDPVerifier.getDataSetLeafCount(dataSetId);
    }

    /// The agreed price is 18-decimal USD in every currency: $5.00 per TiB-month is 5e18 for axlUSDC too.
    function testSixDecimalAgreedPriceSetsRailRate() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 price = 5e18;
        uint256 dataSetId = _createV2Priced(address(axl), price);
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, price);

        uint256 leafCount = _grow(dataSetId);
        assertEq(_pdpRail(dataSetId).paymentRate, _sixDecimalRate(leafCount, price));
        assertGt(_sixDecimalRate(leafCount, price), _sixDecimalRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));
        assertEq(address(_pdpRail(dataSetId).token), address(axl));
    }

    /// No floor check: a price below the posted price is stored, and the effective price is the posted one.
    function testSixDecimalPriceBelowPostedPaysPosted() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2Priced(address(axl), STORAGE_PRICE_PER_TIB_PER_MONTH - 1);
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, STORAGE_PRICE_PER_TIB_PER_MONTH - 1);
        uint256 leafCount = _grow(dataSetId);
        assertEq(_pdpRail(dataSetId).paymentRate, _sixDecimalRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));
    }

    /// A zero price in a 6-decimal currency pays the 6-decimal posted price.
    function testSixDecimalZeroPricePaysScaledPostedPrice() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2Priced(address(axl), 0);
        uint256 leafCount = _grow(dataSetId);
        assertEq(_pdpRail(dataSetId).paymentRate, _sixDecimalRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));
    }

    /// updateStoragePrice on a 6-decimal data set takes an 18-decimal price and re-prices at once.
    function testSixDecimalUpdateStoragePrice() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2Priced(address(axl), 0);
        uint256 leafCount = _grow(dataSetId);

        makeSignaturePass(client);
        uint256 newPrice = 4e18;
        vm.prank(serviceProvider);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, block.number, FAKE_SIGNATURE);
        assertEq(_pdpRail(dataSetId).paymentRate, _sixDecimalRate(leafCount, newPrice));
        (uint256 stored, uint256 nonce) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, newPrice);
        assertEq(nonce, 1);
    }

    /// The 0xe0 variant needs the CreateDataSetWithPayment permission; CreateDataSet does not cover it.
    function testSessionKeyCreateDataSetPermissionCannotSignPrice() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH_V1;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp + 1 days, permissions, "mc");

        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2Priced(client, 61, false, FAKE_SIGNATURE, address(axl), 5e18)
        );

        permissions[0] = CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp + 1 days, permissions, "mc");
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2Priced(client, 61, false, FAKE_SIGNATURE, address(axl), 5e18)
        );
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, 5e18);
    }

    // ---------------------------------------------------------------------
    // extraData variants

    /// A signature for one variant never verifies for another: each has its own EIP-712 type.
    function testCurrencyAndPaymentVariantsAreDistinct() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(signingClient, axl, 100e6);

        bytes memory currencySig = _sign(
            keccak256(
                abi.encode(
                    CREATE_DATA_SET_WITH_CURRENCY_TYPEHASH,
                    uint256(70),
                    serviceProvider,
                    _metadataHash(false),
                    address(axl)
                )
            )
        );
        bytes memory paymentSig = _sign(
            keccak256(
                abi.encode(
                    CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH,
                    uint256(70),
                    serviceProvider,
                    _metadataHash(false),
                    address(axl),
                    uint256(0)
                )
            )
        );

        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2Priced(signingClient, 70, false, currencySig, address(axl), 0)
        );

        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(signingClient, 70, false, paymentSig, address(axl))
        );

        vm.prank(serviceProvider);
        uint256 a = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(signingClient, 70, false, currencySig, address(axl))
        );
        assertEq(address(_pdpRail(a).token), address(axl));
    }

    function testUnknownKeysOffsetReverts() public withTokens {
        (string[] memory keys, string[] memory values) = _metadata(false);
        bytes memory extra =
            abi.encode(client, uint256(71), keys, values, FAKE_SIGNATURE, address(0), uint256(0), uint256(0));
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedExtraDataVariant.selector, uint256(0x100)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extra);
    }

    // ---------------------------------------------------------------------
    // provider opt-in

    function testProviderMustAdvertiseCurrency() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 sp1Id = serviceProviderRegistry.getProviderIdByAddress(sp1);

        makeSignaturePass(client);
        vm.prank(sp1);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyNotAcceptedByProvider.selector, sp1Id, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 72, false, FAKE_SIGNATURE, address(axl))
        );
        vm.prank(sp1);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyNotAcceptedByProvider.selector, sp1Id, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2Priced(client, 72, false, FAKE_SIGNATURE, address(axl), 5e18)
        );

        // Advertising another token is not enough
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd18);
        _acceptCurrencies(sp1, tokens);
        vm.prank(sp1);
        vm.expectRevert(abi.encodeWithSelector(Errors.CurrencyNotAcceptedByProvider.selector, sp1Id, address(axl)));
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 72, false, FAKE_SIGNATURE, address(axl))
        );

        tokens = new address[](2);
        tokens[0] = address(usd18);
        tokens[1] = address(axl);
        _acceptCurrencies(sp1, tokens);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 72, false, FAKE_SIGNATURE, address(axl))
        );
        assertEq(address(_pdpRail(dataSetId).token), address(axl));
    }

    function testDefaultCurrencyNeedsNoProviderOptIn() public withTokens {
        _fund(client, mockUSDFC, 100e18);
        makeSignaturePass(client);
        vm.prank(sp1);
        uint256 a = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 73, false, FAKE_SIGNATURE, address(mockUSDFC))
        );
        vm.prank(sp1);
        uint256 b = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2Priced(client, 74, false, FAKE_SIGNATURE, address(0), 0)
        );
        assertEq(address(_pdpRail(a).token), address(mockUSDFC));
        assertEq(address(_pdpRail(b).token), address(mockUSDFC));
    }

    // ---------------------------------------------------------------------
    // rounding

    /// A small 6-decimal data set pays at least one unit for the size term and two for the dataset fee.
    function testSixDecimalSmallDataSetRoundsUpEachTerm() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 100e6);
        uint256 dataSetId = _createV2(address(axl), false);
        _addPieces(dataSetId, 1);
        uint256 leafCount = mockPDPVerifier.getDataSetLeafCount(dataSetId);
        uint256 sizeTerm18 =
            (Cids.leafCountToRawSize(leafCount) * STORAGE_PRICE_PER_TIB_PER_MONTH) / (TIB_IN_BYTES * EPOCHS_PER_MONTH);
        assertGt(sizeTerm18, 0);
        assertLt(sizeTerm18, 1e12);
        assertEq(_pdpRail(dataSetId).paymentRate, 1 + SIX_DATASET_FEE_PER_EPOCH);
    }

    // ---------------------------------------------------------------------
    // storage layout

    function testPaymentTermsLiveInNamespaces() public withTokens {
        assertEq(
            FWSS_CURRENCY_STORAGE_SLOT,
            keccak256(abi.encode(uint256(keccak256("filecoin.storage.FWSSCurrency")) - 1)) & ~bytes32(uint256(0xff))
        );
        assertEq(
            FWSS_DATA_SET_PRICING_STORAGE_SLOT,
            keccak256(abi.encode(uint256(keccak256("filecoin.storage.FWSSDataSetPricing")) - 1))
                & ~bytes32(uint256(0xff))
        );
        pdpServiceWithPayments.setCurrency(address(usd18), true);
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, axl, 1000e6);
        uint256 dataSetId = _createV2Priced(address(axl), 5e18);

        bytes32 word10 = vm.load(
            address(pdpServiceWithPayments), bytes32(uint256(keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT))) + 10)
        );
        assertEq(uint256(word10) >> 192, 0, "nothing new in DataSetInfo");
        assertEq(uint96(uint256(word10)), CREATE_DATA_SET_FEE, "pending fees held in 18-decimal USD");
        assertEq(_pending(dataSetId), SIX_CREATE_FEE, "views report pending fees in token units");

        uint256 terms = uint256(
            vm.load(
                address(pdpServiceWithPayments), keccak256(abi.encode(dataSetId, FWSS_DATA_SET_PRICING_STORAGE_SLOT))
            )
        );
        assertEq(uint128(terms), 5e18, "price, bits 0-127");
        assertEq(uint64(terms >> 128), 0, "nonce, bits 128-191");
        assertEq(uint8(terms >> 192), 2, "currency id, bits 192-199");
        assertEq(uint256(vm.load(address(pdpServiceWithPayments), FWSS_CURRENCY_STORAGE_SLOT)), 2, "currency count");
    }

    // ---------------------------------------------------------------------
    // gas (logged; signatures mocked; accounts and storage cooled before each measured call so each
    // reads like the first call of a transaction; includes MockPDPVerifier.createDataSet overhead)

    function _cool() internal {
        vm.cool(address(pdpServiceWithPayments));
        vm.cool(address(payments));
        vm.cool(address(mockUSDFC));
        vm.cool(address(axl));
        vm.cool(address(serviceProviderRegistry));
        vm.cool(address(sessionKeyRegistry));
        vm.cool(address(mockPDPVerifier));
    }

    function _measureCreate(string memory label, bytes memory extra) internal returns (uint256 dataSetId) {
        _cool();
        vm.prank(serviceProvider);
        uint256 g = gasleft();
        dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extra);
        console.log(label, g - gasleft());
    }

    function testGas_CreateDataSetVariants() public withTokens {
        pdpServiceWithPayments.setCurrency(address(axl), true);
        _fund(client, mockUSDFC, 100e18);
        _fund(client, axl, 100e6);
        makeSignaturePass(client);
        // Warm-up creates (not measured) so first-use writes for this payer in each token are paid up front
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, _extraDataV1(client, 78, FAKE_SIGNATURE));
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _extraDataV2(client, 79, false, FAKE_SIGNATURE, address(axl))
        );

        _measureCreate("gas createDataSet legacy 0xa0 (USDFC)", _extraDataV1(client, 80, FAKE_SIGNATURE));
        _measureCreate(
            "gas createDataSet 0xc0 (USDFC)", _extraDataV2(client, 81, false, FAKE_SIGNATURE, address(mockUSDFC))
        );
        _measureCreate(
            "gas createDataSet 0xc0 (axlUSDC)", _extraDataV2(client, 82, false, FAKE_SIGNATURE, address(axl))
        );
        _measureCreate(
            "gas createDataSet 0xe0 (USDFC, priced)",
            _extraDataV2Priced(client, 83, false, FAKE_SIGNATURE, address(0), 5e18)
        );
        uint256 dataSetId = _measureCreate(
            "gas createDataSet 0xe0 (axlUSDC, priced)",
            _extraDataV2Priced(client, 84, false, FAKE_SIGNATURE, address(axl), 5e18)
        );

        _grow(dataSetId);
        _cool();
        vm.prank(serviceProvider);
        uint256 g = gasleft();
        pdpServiceWithPayments.updateStoragePrice(dataSetId, 6e18, 0, block.number, FAKE_SIGNATURE);
        console.log("gas updateStoragePrice (axlUSDC, ~100 GiB)", g - gasleft());
    }
}
