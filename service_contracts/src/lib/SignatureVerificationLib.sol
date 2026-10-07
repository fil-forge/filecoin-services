// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {Errors} from "../Errors.sol";
import {IDataSetAuthorizer} from "../interfaces/IDataSetAuthorizer.sol";
import {DataSetPricing} from "./DataSetPricing.sol";
import {CurrencyRegistry} from "./CurrencyRegistry.sol";

/// @dev ABI offset of `keys` in the CreateDataSetWithPayment extraData variant
///      abi.encode(payer, clientDataSetId, keys, values, signature, token, storagePricePerTibPerMonth):
///      a seven-word head. Standard encoders put `keys` of the legacy five-field encoding at 0xa0. A
///      non-standard encoding that lands on 0xe0 is verified against the CreateDataSetWithPayment type hash,
///      so it fails without a signature over that type.
uint256 constant CREATE_DATA_SET_WITH_PAYMENT_KEYS_OFFSET = 0xe0;

/// @title SignatureVerificationLib
/// @notice Library for EIP-712 signature verification and metadata hashing
/// @dev This is an external library (deployed separately) to reduce main contract size.
///      Functions are marked public/external so they use DELEGATECALL rather than being inlined.
library SignatureVerificationLib {
    // ============================================================================
    // EIP-712 Type hashes
    // ============================================================================

    bytes32 internal constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    bytes32 internal constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)MetadataEntry(string key,string value)"
    );

    bytes32 internal constant CID_TYPEHASH = keccak256("Cid(bytes data)");

    bytes32 internal constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");

    bytes32 internal constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );

    bytes32 internal constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    bytes32 internal constant TERMINATE_SERVICE_TYPEHASH = keccak256("TerminateService(uint256 dataSetId)");

    /// @dev CreateDataSet plus payment terms (#618 token, #619 storage price). Carried by the extraData
    ///      variant whose head has seven words. token == address(0) means the deployment's default token;
    ///      storagePricePerTibPerMonth == 0 means the posted price.
    bytes32 internal constant CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH = keccak256(
        "CreateDataSetWithPayment(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token,"
        "uint256 storagePricePerTibPerMonth)" "MetadataEntry(string key,string value)"
    );

    bytes32 internal constant UPDATE_STORAGE_PRICE_TYPEHASH =
        keccak256("UpdateStoragePrice(uint256 dataSetId,uint256 nonce,uint256 storagePricePerTibPerMonth)");

    // ============================================================================
    // Metadata Hashing Functions
    // ============================================================================

    /**
     * @notice Hashes a single metadata entry for EIP-712 signing
     * @param key The metadata key
     * @param value The metadata value
     * @return Hash of the metadata entry struct
     */
    function hashMetadataEntry(string calldata key, string calldata value) internal pure returns (bytes32) {
        return keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(key)), keccak256(bytes(value))));
    }

    /**
     * @notice Hashes an array of metadata entries
     * @param keys Array of metadata keys
     * @param values Array of metadata values
     * @return Hash of all metadata entries
     */
    function hashMetadataEntries(string[] calldata keys, string[] calldata values) internal pure returns (bytes32) {
        require(keys.length == values.length, Errors.MetadataKeyAndValueLengthMismatch(keys.length, values.length));

        bytes32[] memory entryHashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entryHashes[i] = hashMetadataEntry(keys[i], values[i]);
        }
        return keccak256(abi.encodePacked(entryHashes));
    }

    function createDataSetStructHash(
        uint256 clientDataSetId,
        address payee,
        string[] calldata keys,
        string[] calldata values
    ) public pure returns (bytes32 structHash) {
        return keccak256(
            abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, hashMetadataEntries(keys, values))
        );
    }

    function hashAllCids(Cids.Cid[] calldata pieceDataArray) internal pure returns (bytes32 cidHashesHash) {
        bytes32[] memory cidHashes = new bytes32[](pieceDataArray.length);
        for (uint256 i = 0; i < pieceDataArray.length; i++) {
            cidHashes[i] = keccak256(abi.encode(CID_TYPEHASH, keccak256(pieceDataArray[i].data)));
        }
        return keccak256(abi.encodePacked(cidHashes));
    }

    function addPiecesStructHash(
        uint256 clientDataSetId,
        uint256 nonce,
        Cids.Cid[] calldata pieceDataArray,
        string[][] calldata allKeys,
        string[][] calldata allValues
    ) public pure returns (bytes32 structHash) {
        return keccak256(
            abi.encode(
                ADD_PIECES_TYPEHASH,
                clientDataSetId,
                nonce,
                hashAllCids(pieceDataArray),
                hashAllPieceMetadata(allKeys, allValues)
            )
        );
    }

    /**
     * @notice Hashes piece metadata for a specific piece index
     * @param pieceIndex The index of the piece
     * @param keys Array of metadata keys for this piece
     * @param values Array of metadata values for this piece
     * @return Hash of the piece metadata struct
     */
    function hashPieceMetadata(uint256 pieceIndex, string[] calldata keys, string[] calldata values)
        internal
        pure
        returns (bytes32)
    {
        bytes32 metadataHash = hashMetadataEntries(keys, values);
        return keccak256(abi.encode(PIECE_METADATA_TYPEHASH, pieceIndex, metadataHash));
    }

    /**
     * @notice Hashes all piece metadata for multiple pieces
     * @param allKeys 2D array where allKeys[i] contains keys for piece i
     * @param allValues 2D array where allValues[i] contains values for piece i
     * @return Hash of all piece metadata
     */
    function hashAllPieceMetadata(string[][] calldata allKeys, string[][] calldata allValues)
        public
        pure
        returns (bytes32)
    {
        require(allKeys.length == allValues.length, "Keys/values array length mismatch");

        bytes32[] memory pieceHashes = new bytes32[](allKeys.length);
        for (uint256 i = 0; i < allKeys.length; i++) {
            pieceHashes[i] = hashPieceMetadata(i, allKeys[i], allValues[i]);
        }
        return keccak256(abi.encodePacked(pieceHashes));
    }

    // ============================================================================
    // Signature Recovery
    // ============================================================================

    /**
     * @notice Recover the signer address from a signature
     * @param messageHash The signed message hash
     * @param signature The signature bytes (v, r, s)
     * @return The address that signed the message
     */
    function recoverSigner(bytes32 messageHash, bytes calldata signature) public pure returns (address) {
        require(signature.length == 65, Errors.InvalidSignatureLength(65, signature.length));

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from the signature
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        uint8 originalV = v;

        // If v is not 27 or 28, adjust it (for some wallets)
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, Errors.UnsupportedSignatureV(originalV));

        // Recover and return the address
        return ecrecover(messageHash, v, r, s);
    }

    // ============================================================================
    // Signature Verification Functions
    // ============================================================================

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @dev The digest parameter already contains the EIP-712 wrapped struct hash computed by the caller
     * @param payer The address of the payer who should have signed
     * @param signature The signature bytes
     * @param digest The EIP-712 digest to verify
     * @param sessionKeyRegistry The session key registry contract
     */
    function verifyCreateDataSetSignature(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        SessionKeyRegistry sessionKeyRegistry
    ) public view {
        // The digest is already computed by the calling contract
        // Just use it directly for signature verification

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, CREATE_DATA_SET_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }

    /// @notice Verifies and authorizes an AddPieces operation.
    function verifyAddPiecesAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        uint256 clientDataSetId,
        Cids.Cid[] calldata pieceDataArray,
        uint256 nonce,
        string[][] calldata allKeys,
        string[][] calldata allValues,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public {
        bytes32 digest = _toTypedDataHash(
            domainSeparator, addPiecesStructHash(clientDataSetId, nonce, pieceDataArray, allKeys, allValues)
        );

        if (authorizer == address(0)) {
            _verifySignature(payer, signature, digest, ADD_PIECES_TYPEHASH, sessionKeyRegistry);
            return;
        }

        _verifyAuthorizer(
            payer,
            signature,
            digest,
            ADD_PIECES_TYPEHASH,
            dataSetId,
            authorizer,
            abi.encode(clientDataSetId, nonce, pieceDataArray, allKeys, allValues)
        );
    }

    /// @notice Verifies and authorizes a SchedulePieceRemovals operation.
    function verifySchedulePieceRemovalsAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        uint256 clientDataSetId,
        uint256[] calldata pieceIds,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public {
        bytes32 digest = _toTypedDataHash(
            domainSeparator,
            keccak256(
                abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, clientDataSetId, keccak256(abi.encodePacked(pieceIds)))
            )
        );

        if (authorizer == address(0)) {
            _verifySignature(payer, signature, digest, SCHEDULE_PIECE_REMOVALS_TYPEHASH, sessionKeyRegistry);
            return;
        }

        _verifyAuthorizer(
            payer,
            signature,
            digest,
            SCHEDULE_PIECE_REMOVALS_TYPEHASH,
            dataSetId,
            authorizer,
            abi.encode(clientDataSetId, pieceIds)
        );
    }

    /// @notice Verifies and authorizes a TerminateService operation.
    function verifyTerminateServiceAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public returns (address) {
        bytes32 digest = _toTypedDataHash(domainSeparator, keccak256(abi.encode(TERMINATE_SERVICE_TYPEHASH, dataSetId)));

        if (authorizer == address(0)) {
            return _verifySignature(payer, signature, digest, TERMINATE_SERVICE_TYPEHASH, sessionKeyRegistry);
        }

        return _verifyAuthorizer(payer, signature, digest, TERMINATE_SERVICE_TYPEHASH, dataSetId, authorizer, bytes(""));
    }

    /// @notice Verifies the payer's signature over data set creation extraData, in either variant, resolves
    ///         the payment currency (#618) and records the agreed storage price (#619).
    /// @dev Legacy variant: CreateDataSet(clientDataSetId, payee, metadata), unchanged, pays in the default
    ///      token. New variant (keys at offset 0xe0): CreateDataSetWithPayment(clientDataSetId, payee, metadata,
    ///      token, storagePricePerTibPerMonth). token 0 or `defaultToken` is the default currency; any other
    ///      token must be whitelisted and enabled. The price is in that token's units; 0 means the posted price.
    ///      Session keys: choosing a currency at the posted price needs only the CreateDataSet permission
    ///      (FilecoinPay operator approvals are per token); signing a price needs CreateDataSetWithPayment.
    /// @return token The rail token
    /// @return currencyCode Value for DataSetInfo.currency: whitelist id | (18 - decimals) << 8
    function verifyCreateDataSet(
        bytes calldata extraData,
        uint256 dataSetId,
        address payee,
        address defaultToken,
        uint16 defaultCurrencyCode,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public returns (address token, uint16 currencyCode) {
        (address payer, uint256 clientDataSetId, string[] memory keys, string[] memory values,) =
            abi.decode(extraData, (address, uint256, string[], string[], bytes));
        bytes32 metadataHash = _hashMetadataEntriesMemory(keys, values);
        // The signature as a calldata slice, for recoverSigner.
        uint256 sigOffset = uint256(bytes32(extraData[128:160]));
        uint256 sigLength = uint256(bytes32(extraData[sigOffset:sigOffset + 32]));
        bytes calldata signature = extraData[sigOffset + 32:sigOffset + 32 + sigLength];

        if (uint256(bytes32(extraData[64:96])) != CREATE_DATA_SET_WITH_PAYMENT_KEYS_OFFSET) {
            _verifySignature(
                payer,
                signature,
                _toTypedDataHash(
                    domainSeparator,
                    keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, metadataHash))
                ),
                CREATE_DATA_SET_TYPEHASH,
                sessionKeyRegistry
            );
            return (defaultToken, defaultCurrencyCode);
        }

        uint256 storagePricePerTibPerMonth;
        (token, storagePricePerTibPerMonth) = abi.decode(extraData[160:224], (address, uint256));
        _verifySignature(
            payer,
            signature,
            _toTypedDataHash(
                domainSeparator,
                keccak256(
                    abi.encode(
                        CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH,
                        clientDataSetId,
                        payee,
                        metadataHash,
                        token,
                        storagePricePerTibPerMonth
                    )
                )
            ),
            storagePricePerTibPerMonth == 0 ? CREATE_DATA_SET_TYPEHASH : CREATE_DATA_SET_WITH_PAYMENT_TYPEHASH,
            sessionKeyRegistry
        );
        if (token == address(0) || token == defaultToken) {
            token = defaultToken;
            currencyCode = defaultCurrencyCode;
        } else {
            currencyCode = CurrencyRegistry.resolve(token);
        }
        DataSetPricing.setPrice(dataSetId, storagePricePerTibPerMonth, CurrencyRegistry.scale(currencyCode));
    }

    function _hashMetadataEntriesMemory(string[] memory keys, string[] memory values) private pure returns (bytes32) {
        require(keys.length == values.length, Errors.MetadataKeyAndValueLengthMismatch(keys.length, values.length));
        bytes32[] memory entryHashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entryHashes[i] =
                keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(keys[i])), keccak256(bytes(values[i]))));
        }
        return keccak256(abi.encodePacked(entryHashes));
    }

    /// @notice Verifies and authorizes an UpdateStoragePrice operation.
    /// @dev Internal: compiled into Rails.updateStoragePrice, which runs in the FWSS proxy's context, so the
    ///      authorizer reentrancy latch below shares the proxy's transient slot as for the other operations.
    function verifyUpdateStoragePriceAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        uint256 nonce,
        uint256 storagePricePerTibPerMonth,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) internal {
        bytes32 digest = _toTypedDataHash(
            domainSeparator,
            keccak256(abi.encode(UPDATE_STORAGE_PRICE_TYPEHASH, dataSetId, nonce, storagePricePerTibPerMonth))
        );

        if (authorizer == address(0)) {
            _verifySignature(payer, signature, digest, UPDATE_STORAGE_PRICE_TYPEHASH, sessionKeyRegistry);
            return;
        }

        _verifyAuthorizer(
            payer,
            signature,
            digest,
            UPDATE_STORAGE_PRICE_TYPEHASH,
            dataSetId,
            authorizer,
            abi.encode(nonce, storagePricePerTibPerMonth)
        );
    }

    /// @notice Gas ceiling for the authorizer subcall.
    /// @dev Bounds what an untrusted authorizer can burn on the caller's behalf. EIP-150 forwards at
    ///      most 63/64 of the remaining gas, so this only binds when the caller supplies more.
    uint256 internal constant AUTHORIZER_GAS_LIMIT = 150_000_000;

    /// @dev Transient-storage slot for the authorizer reentrancy latch. This library is DELEGATECALL'd,
    ///      so the slot lives in the calling contract's (FWSS's) transient storage and the latch therefore
    ///      spans the whole FWSS call frame, not just this library invocation.
    bytes32 internal constant AUTHORIZER_REENTRANCY_SLOT =
        keccak256("filecoin-warm-storage-service.authorizer.reentrancy.guard");

    /// @dev Reentrancy latch for the authorizer subcall. `_lockAuthorizer` takes the latch before the body;
    ///      it clears after `_;` (a `return` in the body still runs post-`_;` code) and, on any revert, via
    ///      transient-storage rollback — so a second legitimate authorization in the same transaction is not
    ///      blocked. The pre-`_;` check-and-set is hoisted so the modifier body stays call-only
    ///      (forge-lint `unwrapped-modifier-logic`).
    modifier nonReentrantAuthorizer() {
        _lockAuthorizer();
        _;
        _setAuthorizerLock(false);
    }

    function _verifyAuthorizer(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        bytes32 operation,
        uint256 dataSetId,
        address authorizer,
        bytes memory operationData
    ) private nonReentrantAuthorizer returns (address) {
        require(
            IDataSetAuthorizer(authorizer).isAuthorized{gas: AUTHORIZER_GAS_LIMIT}(
                dataSetId, payer, operation, digest, signature, operationData
            ),
            Errors.Unauthorized(payer, operation, digest, signature)
        );
        return payer;
    }

    function _verifySignature(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        bytes32 operation,
        SessionKeyRegistry sessionKeyRegistry
    ) private view returns (address recoveredSigner) {
        recoveredSigner = recoverSigner(digest, signature);
        if (payer != recoveredSigner) {
            require(
                sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, operation) >= block.timestamp,
                Errors.InvalidSignature(payer, recoveredSigner)
            );
        }
    }

    function _toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _authorizerLocked() private view returns (bool locked) {
        bytes32 slot = AUTHORIZER_REENTRANCY_SLOT;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
    }

    function _setAuthorizerLock(bool value) private {
        bytes32 slot = AUTHORIZER_REENTRANCY_SLOT;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @dev Pre-`_;` half of `nonReentrantAuthorizer`, split out to keep the modifier body call-only.
    function _lockAuthorizer() private {
        require(!_authorizerLocked(), Errors.AuthorizerReentrancy());
        _setAuthorizerLock(true);
    }
}
