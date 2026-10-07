// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "./PriceListUSDFC.sol";
import {ServiceProviderRegistry} from "../ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../ServiceProviderRegistryStorage.sol";

/// @dev ERC-7201 location of {PaymentTermsStorage.FWSSCurrencyStorage}:
///      keccak256(abi.encode(uint256(keccak256("filecoin.storage.FWSSCurrency")) - 1)) & ~bytes32(uint256(0xff))
bytes32 constant FWSS_CURRENCY_STORAGE_SLOT = 0x2be83150facef7aa3ae5922e809766ad94dac519fdf44800de563f85c625d500;

/// @dev ERC-7201 location of {PaymentTermsStorage.FWSSDataSetPricingStorage}:
///      keccak256(abi.encode(uint256(keccak256("filecoin.storage.FWSSDataSetPricing")) - 1)) & ~bytes32(uint256(0xff))
bytes32 constant FWSS_DATA_SET_PRICING_STORAGE_SLOT =
    0x44ed9206e2d77446bd06f9698aeef56e4b0ec8004fef8f3eb108175dad5b9600;

/// @dev Prices and fees are 18-decimal USD (the price list). A token with `d` decimals is charged
///      ceil(amount / 10**(PRICE_DECIMALS - d)).
uint256 constant PRICE_DECIMALS = 18;
uint8 constant MIN_CURRENCY_DECIMALS = 6;

/// @dev ServiceProviderRegistry PDP capability through which a provider opts in to non-default currencies:
///      the accepted token addresses, packed 20 bytes each (at most six in a 128-byte value). The deployment's
///      default token needs no entry.
string constant PAYMENT_TOKENS_CAPABILITY_KEY = "paymentTokens";

event CurrencyAdded(uint8 indexed currencyId, address indexed token, uint8 decimals);

event CurrencyEnabledSet(uint8 indexed currencyId, address indexed token, bool enabled);

/// @notice The client-agreed storage price of a data set was set at creation or changed by mutual consent.
/// @param dataSetId The data set ID
/// @param storagePricePerTibPerMonth Agreed price in 18-decimal USD; 0 means the posted price
event DataSetStoragePriceSet(uint256 indexed dataSetId, uint256 storagePricePerTibPerMonth);

/// @notice The payer invalidated every outstanding UpdateStoragePrice signature for a data set.
/// @param dataSetId The data set ID
/// @param nonce The data set's new price-update nonce; the next UpdateStoragePrice signature signs this value
event StoragePriceOffersCancelled(uint256 indexed dataSetId, uint256 nonce);

/// @title PaymentTermsStorage
/// @notice Declares the namespaced state of the payment-currency (#618) and per-data-set price (#619) extensions.
/// @dev Holds no state of its own: FWSS inherits it so its ERC-7201 namespaces sit in the inheritance chain, and
///      the libraries that run in FWSS's context reach them through {PaymentTerms}. Nothing is added to the
///      frozen root slots 0-23 or to `DataSetInfo`.
abstract contract PaymentTermsStorage {
    /// @notice A whitelisted USD stablecoin. Packed into one slot.
    struct Currency {
        address token;
        uint8 decimals;
        bool enabled; // false: no new data sets; existing data sets keep paying in it
    }

    /// @custom:storage-location erc7201:filecoin.storage.FWSSCurrency
    struct FWSSCurrencyStorage {
        uint256 count; // ids 1..count are whitelisted; id 0 is the deployment's default token
        mapping(uint256 currencyId => Currency) currencies;
        mapping(address token => uint256 currencyId) ids;
    }

    /// @notice Payment terms of one data set, packed into one slot. All zero (every legacy data set) means the
    ///         default currency at the posted price.
    struct DataSetPricing {
        uint128 storagePricePerTibPerMonth; // 18-decimal USD; 0 means the posted price
        uint64 nonce; // accepted UpdateStoragePrice operations
        uint8 currencyId; // 0 = the deployment's default token
    }

    /// @custom:storage-location erc7201:filecoin.storage.FWSSDataSetPricing
    struct FWSSDataSetPricingStorage {
        mapping(uint256 dataSetId => DataSetPricing) dataSets;
    }
}

/// @title PaymentTerms
/// @notice Accessors and conversions for {PaymentTermsStorage}. Internal only: compiled into the external libraries
///         (Rails, SignatureVerificationLib) that run by DELEGATECALL in the FWSS proxy.
library PaymentTerms {
    function currencies() internal pure returns (PaymentTermsStorage.FWSSCurrencyStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FWSS_CURRENCY_STORAGE_SLOT
        }
    }

    function pricing(uint256 dataSetId) internal view returns (PaymentTermsStorage.DataSetPricing storage) {
        PaymentTermsStorage.FWSSDataSetPricingStorage storage $;
        assembly ("memory-safe") {
            $.slot := FWSS_DATA_SET_PRICING_STORAGE_SLOT
        }
        return $.dataSets[dataSetId];
    }

    /// @notice Divisor from 18-decimal USD to the units of a data set's token.
    function scale(uint256 dataSetId) internal view returns (uint256) {
        uint256 currencyId = pricing(dataSetId).currencyId;
        if (currencyId == 0) return 10 ** (PRICE_DECIMALS - TOKEN_DECIMALS);
        return 10 ** (PRICE_DECIMALS - currencies().currencies[currencyId].decimals);
    }

    /// @notice Price used for the size-proportional rate, in 18-decimal USD: max(agreed, posted).
    function effectiveStoragePrice(uint256 dataSetId) internal view returns (uint256 price) {
        price = pricing(dataSetId).storagePricePerTibPerMonth;
        if (price < STORAGE_PRICE_PER_TIB_PER_MONTH) price = STORAGE_PRICE_PER_TIB_PER_MONTH;
    }

    /// @notice Records the price signed at creation. Does not consume a nonce.
    function setPrice(uint256 dataSetId, uint256 storagePricePerTibPerMonth) internal {
        _store(pricing(dataSetId), dataSetId, storagePricePerTibPerMonth);
    }

    /// @notice Records a mutually agreed price change, consuming `nonce`.
    function updatePrice(uint256 dataSetId, uint256 storagePricePerTibPerMonth, uint256 nonce) internal {
        PaymentTermsStorage.DataSetPricing storage p = pricing(dataSetId);
        uint64 current = p.nonce;
        if (nonce != current) revert Errors.InvalidStoragePriceNonce(dataSetId, current, nonce);
        p.nonce = current + 1;
        _store(p, dataSetId, storagePricePerTibPerMonth);
    }

    /// @notice Invalidates every outstanding UpdateStoragePrice signature by consuming the current nonce.
    function cancelOffers(uint256 dataSetId) internal {
        PaymentTermsStorage.DataSetPricing storage p = pricing(dataSetId);
        uint64 next = p.nonce + 1;
        p.nonce = next;
        emit StoragePriceOffersCancelled(dataSetId, next);
    }

    /// @notice Clears a deleted data set's payment terms.
    function clear(uint256 dataSetId) internal {
        PaymentTermsStorage.FWSSDataSetPricingStorage storage $;
        assembly ("memory-safe") {
            $.slot := FWSS_DATA_SET_PRICING_STORAGE_SLOT
        }
        delete $.dataSets[dataSetId];
    }

    /// @notice Whitelist id of an enabled, non-default token that the provider lists in its `paymentTokens`
    ///         registry capability (20-byte addresses, packed).
    function resolveCurrency(address token, uint256 providerId, ServiceProviderRegistry registry)
        internal
        view
        returns (uint256 currencyId)
    {
        PaymentTermsStorage.FWSSCurrencyStorage storage $ = currencies();
        currencyId = $.ids[token];
        require(currencyId != 0 && $.currencies[currencyId].enabled, Errors.UnsupportedCurrency(token));

        string[] memory capabilityKeys = new string[](1);
        capabilityKeys[0] = PAYMENT_TOKENS_CAPABILITY_KEY;
        bytes memory accepted = registry.getProductCapabilities(
            providerId, ServiceProviderRegistryStorage.ProductType.PDP, capabilityKeys
        )[0];
        for (uint256 i = 0; i + 20 <= accepted.length; i += 20) {
            address listed;
            assembly ("memory-safe") {
                listed := shr(96, mload(add(add(accepted, 0x20), i)))
            }
            if (listed == token) return currencyId;
        }
        revert Errors.CurrencyNotAcceptedByProvider(providerId, token);
    }

    function _store(PaymentTermsStorage.DataSetPricing storage p, uint256 dataSetId, uint256 price) private {
        // Width of the stored field, not a pricing policy
        if (price > type(uint128).max) revert Errors.InvalidStoragePrice(price);
        p.storagePricePerTibPerMonth = uint128(price);
        emit DataSetStoragePriceSet(dataSetId, price);
    }
}
