// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FilecoinWarmStorageServiceTest, TestDataSetAuthorizer} from "./FilecoinWarmStorageService.t.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {Errors} from "../src/Errors.sol";
import {DATA_SET_PRICING_STORAGE_SLOT, DataSetStoragePriceSet} from "../src/lib/DataSetPricing.sol";
import {
    DATASET_FEE_PER_EPOCH,
    EPOCHS_PER_MONTH,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TIB_IN_BYTES
} from "../src/lib/PriceListUSDFC.sol";

/// @notice Adjustable storage price per data set (FilOzone/filecoin-services#619).
/// @dev The client signs an absolute storage price per TiB per month in a new CreateDataSetWithPayment
///      message carried by a new extraData variant (shared with #618's token field). The provider consents
///      by submitting the transaction. Zero means the posted price; prices below the posted price are
///      rejected. A mutual-consent update (provider submits, payer signs) changes the price of an existing
///      data set and re-prices its rail immediately. Signatures here are real ECDSA signatures over the
///      live EIP-712 domain, so the type strings are checked end to end.
contract AdjustableStoragePriceTest is FilecoinWarmStorageServiceTest {
    bytes32 private constant METADATA_ENTRY_TYPEHASH_ = keccak256("MetadataEntry(string key,string value)");
    bytes32 private constant CREATE_DATA_SET_TYPEHASH_ = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    bytes32 private constant CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH = keccak256(
        "CreateDataSetWithPayment(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token,"
        "uint256 storagePricePerTibPerMonth)" "MetadataEntry(string key,string value)"
    );
    bytes32 private constant UPDATE_STORAGE_PRICE_TYPEHASH =
        keccak256("UpdateStoragePrice(uint256 dataSetId,uint256 nonce,uint256 storagePricePerTibPerMonth)");

    uint8 private constant PIECE_HEIGHT = 30; // 2^30 leaves = 32 GiB padded

    address private payer;
    uint256 private payerKey;
    address private sessionSigner;
    uint256 private sessionSignerKey;

    uint256 private clientDataSetIdCounter = 1000;

    // The base suite's setUp is not virtual, so each test funds its payer through this modifier.
    modifier payerReady() {
        _initPayer();
        _;
    }

    function _initPayer() private {
        (payer, payerKey) = makeAddrAndKey("fil1276-payer");
        (sessionSigner, sessionSignerKey) = makeAddrAndKey("fil1276-session-key");
        mockUSDFC.transfer(payer, 1000e18);
        vm.startPrank(payer);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 1000e18);
        payments.deposit(mockUSDFC, payer, 1000e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _metadataHash(string[] memory keys, string[] memory values) private pure returns (bytes32) {
        bytes32[] memory entries = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entries[i] =
                keccak256(abi.encode(METADATA_ENTRY_TYPEHASH_, keccak256(bytes(keys[i])), keccak256(bytes(values[i]))));
        }
        return keccak256(abi.encodePacked(entries));
    }

    function _label() private pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](1);
        values = new string[](1);
        keys[0] = "label";
        values[0] = "fil1276";
    }

    function _sign(uint256 key, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _eip712Digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _signCreateWithPayment(uint256 key, uint256 clientDataSetId, address payee, address token, uint256 price)
        private
        view
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _label();
        return _sign(
            key,
            keccak256(
                abi.encode(
                    CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH,
                    clientDataSetId,
                    payee,
                    _metadataHash(keys, values),
                    token,
                    price
                )
            )
        );
    }

    function _signCreateLegacy(uint256 key, uint256 clientDataSetId, address payee)
        private
        view
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _label();
        return _sign(
            key, keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH_, clientDataSetId, payee, _metadataHash(keys, values)))
        );
    }

    function _signUpdate(uint256 key, uint256 dataSetId, uint256 nonce, uint256 price)
        private
        view
        returns (bytes memory)
    {
        return _sign(key, keccak256(abi.encode(UPDATE_STORAGE_PRICE_TYPEHASH, dataSetId, nonce, price)));
    }

    function _withPaymentExtraData(uint256 clientDataSetId, address token, uint256 price, bytes memory signature)
        private
        view
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _label();
        return abi.encode(payer, clientDataSetId, keys, values, signature, token, price);
    }

    function _legacyExtraData(uint256 clientDataSetId, bytes memory signature) private view returns (bytes memory) {
        (string[] memory keys, string[] memory values) = _label();
        return abi.encode(payer, clientDataSetId, keys, values, signature);
    }

    /// Creates a data set with sp1 at `price` (0 = posted) using a real payer signature.
    function _createWithPrice(uint256 price) private returns (uint256 dataSetId) {
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), price);
        vm.prank(sp1);
        dataSetId =
            mockPDPVerifier.createDataSet(pdpServiceWithPayments, _withPaymentExtraData(cdsId, address(0), price, sig));
    }

    function _addPiece(uint256 dataSetId) private returns (uint256 leafCount) {
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, PIECE_HEIGHT, keccak256(abi.encode("fil1276", dataSetId)));
        string[] memory none = new string[](0);
        makeSignaturePass(payer); // AddPieces signing is not under test here
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, 0, pieces, clientDataSetIdCounter++, FAKE_SIGNATURE, none, none
        );
        vm.clearMockedCalls();
        leafCount = mockPDPVerifier.getDataSetLeafCount(dataSetId);
    }

    function _expectedRate(uint256 leafCount, uint256 price) private pure returns (uint256) {
        return Cids.leafCountToRawSize(leafCount) * price / (TIB_IN_BYTES * EPOCHS_PER_MONTH) + DATASET_FEE_PER_EPOCH;
    }

    function _railRate(uint256 dataSetId) private view returns (uint256) {
        return payments.getRail(viewContract.getDataSet(dataSetId).pdpRailId).paymentRate;
    }

    // ------------------------------------------------------------------
    // Creation
    // ------------------------------------------------------------------

    function test_legacyExtraData_paysPostedPrice() public payerReady {
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateLegacy(payerKey, cdsId, sp1);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, _legacyExtraData(cdsId, sig));

        (uint256 price, uint256 nonce) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(price, 0, "no custom price");
        assertEq(nonce, 0, "no updates");

        uint256 leafCount = _addPiece(dataSetId);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH), "posted rate");
    }

    function test_withPayment_customPrice_setsRailRate() public payerReady {
        uint256 price = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), price);

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit DataSetStoragePriceSet(1, price);
        vm.prank(sp1);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(pdpServiceWithPayments, _withPaymentExtraData(cdsId, address(0), price, sig));
        assertEq(dataSetId, 1);

        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, price, "stored price");

        uint256 leafCount = _addPiece(dataSetId);
        uint256 rate = _railRate(dataSetId);
        assertEq(rate, _expectedRate(leafCount, price), "custom price on rail, dataset fee unchanged");
        assertGt(rate, _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH), "above posted");
    }

    function test_withPayment_zeroPrice_paysPosted() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 leafCount = _addPiece(dataSetId);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));
    }

    function test_withPayment_postedPriceExactly_accepted() public payerReady {
        uint256 dataSetId = _createWithPrice(STORAGE_PRICE_PER_TIB_PER_MONTH);
        uint256 leafCount = _addPiece(dataSetId);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));
    }

    function test_withPayment_belowPosted_reverts() public payerReady {
        uint256 price = STORAGE_PRICE_PER_TIB_PER_MONTH - 1;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), price);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), price, sig);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStoragePrice.selector, price));
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function test_withPayment_priceAboveUint128_reverts() public payerReady {
        uint256 price = uint256(type(uint128).max) + 1;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), price);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), price, sig);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStoragePrice.selector, price));
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function test_withPayment_deploymentToken_accepted() public payerReady {
        uint256 price = 3 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(mockUSDFC), price);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            pdpServiceWithPayments, _withPaymentExtraData(cdsId, address(mockUSDFC), price, sig)
        );
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, price);
    }

    function test_withPayment_otherToken_reverts() public payerReady {
        address other = address(0xBEEF);
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, other, 0);
        bytes memory extraData = _withPaymentExtraData(cdsId, other, 0, sig);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedPaymentToken.selector, other));
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function test_withPayment_providerCannotChangeSignedPrice() public payerReady {
        uint256 signedPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), signedPrice);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), 10 * signedPrice, sig);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function test_withPayment_signatureBindsPayee() public payerReady {
        uint256 price = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(payerKey, cdsId, sp1, address(0), price);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), price, sig);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp2); // a different provider cannot reuse sp1's negotiated price
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    /// A provider holding a legacy CreateDataSet signature cannot re-encode it into the new variant
    /// and attach a price: the variant is verified against its own type hash.
    function test_legacySignature_reencodedWithPrice_rejected() public payerReady {
        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory legacySig = _signCreateLegacy(payerKey, cdsId, sp1);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), 0, legacySig);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
    }

    function test_withPayment_sessionKeyNeedsNewPermission() public payerReady {
        uint256 price = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;

        // A session key allowed only CreateDataSet cannot sign a priced creation.
        bytes32[] memory legacyPermission = new bytes32[](1);
        legacyPermission[0] = CREATE_DATA_SET_TYPEHASH_;
        vm.prank(payer);
        sessionKeyRegistry.login(sessionSigner, block.timestamp + 1 days, legacyPermission, "fil1276");

        uint256 cdsId = clientDataSetIdCounter++;
        bytes memory sig = _signCreateWithPayment(sessionSignerKey, cdsId, sp1, address(0), price);
        bytes memory extraData = _withPaymentExtraData(cdsId, address(0), price, sig);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, payer, sessionSigner));
        vm.prank(sp1);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);

        // Granting the new type hash enables it.
        bytes32[] memory newPermission = new bytes32[](1);
        newPermission[0] = CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH;
        vm.prank(payer);
        sessionKeyRegistry.login(sessionSigner, block.timestamp + 1 days, newPermission, "fil1276");
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, price);
    }

    // ------------------------------------------------------------------
    // Mutual-consent update
    // ------------------------------------------------------------------

    function test_update_repricesIdleDataSetImmediately() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 leafCount = _addPiece(dataSetId);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH));

        vm.roll(block.number + 100);
        uint256 newPrice = 4 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, newPrice);

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit DataSetStoragePriceSet(dataSetId, newPrice);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);

        assertEq(_railRate(dataSetId), _expectedRate(leafCount, newPrice), "rail re-priced without a piece change");
        (uint256 stored, uint256 nonce) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, newPrice);
        assertEq(nonce, 1, "nonce consumed");
    }

    function test_update_lowerToPosted_byConsent() public payerReady {
        uint256 dataSetId = _createWithPrice(3 * STORAGE_PRICE_PER_TIB_PER_MONTH);
        uint256 leafCount = _addPiece(dataSetId);
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, 0);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, 0, 0, sig);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH), "back to posted");
    }

    function test_update_beforeAnyPiece_appliesOnFirstAdd() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, newPrice);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);
        assertEq(_railRate(dataSetId), 0, "empty data set streams nothing");

        uint256 leafCount = _addPiece(dataSetId);
        assertEq(_railRate(dataSetId), _expectedRate(leafCount, newPrice));
    }

    function test_update_onlyServiceProvider() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, newPrice);
        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotServiceProvider.selector, dataSetId, sp1, payer));
        vm.prank(payer);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);
    }

    function test_update_requiresPayerSignature() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        bytes memory sig = _signUpdate(strangerKey, dataSetId, 0, newPrice);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);
    }

    function test_update_providerCannotChangeSignedPrice() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, 2 * STORAGE_PRICE_PER_TIB_PER_MONTH);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, 9 * STORAGE_PRICE_PER_TIB_PER_MONTH, 0, sig);
    }

    function test_update_replayRejected() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 high = 3 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory toHigh = _signUpdate(payerKey, dataSetId, 0, high);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, high, 0, toHigh);

        bytes memory toPosted = _signUpdate(payerKey, dataSetId, 1, 0);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, 0, 1, toPosted);

        // Replaying the first signature (nonce 0) fails even though the price is back where it started.
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStoragePriceNonce.selector, dataSetId, 2, 0));
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, high, 0, toHigh);
    }

    function test_update_signatureBoundToDataSet() public payerReady {
        uint256 a = _createWithPrice(0);
        uint256 b = _createWithPrice(0);
        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sigForA = _signUpdate(payerKey, a, 0, newPrice);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(b, newPrice, 0, sigForA);
    }

    function test_update_belowPosted_reverts() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 price = STORAGE_PRICE_PER_TIB_PER_MONTH / 2;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, price);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStoragePrice.selector, price));
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, price, 0, sig);
    }

    function test_update_terminated_reverts() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        _addPiece(dataSetId);
        vm.prank(payer);
        pdpServiceWithPayments.terminateService(dataSetId);

        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, newPrice);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);
    }

    function test_update_unknownDataSet_reverts() public payerReady {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, 999));
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(999, 0, 0, "");
    }

    function test_update_rateIncreaseNeedsPayerRateAllowance() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        uint256 leafCount = _addPiece(dataSetId);
        uint256 postedRate = _expectedRate(leafCount, STORAGE_PRICE_PER_TIB_PER_MONTH);

        // Payer caps FWSS at the current usage: any increase must fail inside FilecoinPay.
        vm.prank(payer);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, postedRate, 1000e18, 365 days);

        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(payerKey, dataSetId, 0, newPrice);
        vm.expectRevert();
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);

        (uint256 stored, uint256 nonce) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, 0, "atomic: price unchanged");
        assertEq(nonce, 0, "atomic: nonce unchanged");
        assertEq(_railRate(dataSetId), postedRate);
    }

    function test_update_sessionKeyWithPermission() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        bytes32[] memory permission = new bytes32[](1);
        permission[0] = UPDATE_STORAGE_PRICE_TYPEHASH;
        vm.prank(payer);
        sessionKeyRegistry.login(sessionSigner, block.timestamp + 1 days, permission, "fil1276");

        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        bytes memory sig = _signUpdate(sessionSignerKey, dataSetId, 0, newPrice);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, sig);
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, newPrice);
    }

    function test_update_usesDataSetAuthorizer() public payerReady {
        uint256 dataSetId = _createWithPrice(0);
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        (address delegate, uint256 delegateKey) = makeAddrAndKey("fil1276-delegate");
        authorizer.allow(dataSetId, delegate);
        vm.prank(payer);
        pdpServiceWithPayments.setDataSetAuthorizer(dataSetId, address(authorizer));

        uint256 newPrice = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        // With an authorizer attached, the authorizer decides; the payer's own key is not consulted.
        bytes memory payerSig = _signUpdate(payerKey, dataSetId, 0, newPrice);
        vm.expectPartialRevert(Errors.Unauthorized.selector);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, payerSig);

        bytes memory delegateSig = _signUpdate(delegateKey, dataSetId, 0, newPrice);
        vm.prank(sp1);
        pdpServiceWithPayments.updateStoragePrice(dataSetId, newPrice, 0, delegateSig);
        (uint256 stored,) = viewContract.getDataSetStoragePrice(dataSetId);
        assertEq(stored, newPrice);
    }

    // ------------------------------------------------------------------
    // Storage layout
    // ------------------------------------------------------------------

    function test_pricingNamespace_slotPinned() public payerReady {
        // keccak256(abi.encode(uint256(keccak256("filecoin-warm-storage-service.DataSetPricing")) - 1))
        //   & ~bytes32(uint256(0xff))
        assertEq(
            DATA_SET_PRICING_STORAGE_SLOT,
            0xe60d4b8c9786d4bff16c61a200159c92875861d64c13f886bd854066b070bc00,
            "ERC-7201 slot"
        );
        uint256 price = 2 * STORAGE_PRICE_PER_TIB_PER_MONTH;
        uint256 dataSetId = _createWithPrice(price);
        bytes32 slot = keccak256(abi.encode(dataSetId, DATA_SET_PRICING_STORAGE_SLOT));
        uint256 word = uint256(pdpServiceWithPayments.extsload(slot));
        assertEq(uint128(word), price, "price in low 128 bits");
        assertEq(word >> 128, 0, "nonce in the next 64 bits");
    }
}
