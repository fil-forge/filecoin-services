// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH} from "./PriceListUSDFC.sol";

/// @dev ERC-7201 slot for per-data-set pricing state:
///      keccak256(abi.encode(uint256(keccak256("filecoin-warm-storage-service.DataSetPricing")) - 1))
///        & ~bytes32(uint256(0xff))
///      Namespaced so it never collides with the root slots 0-23 that FWSSStorage freezes.
bytes32 constant DATA_SET_PRICING_STORAGE_SLOT = 0xe60d4b8c9786d4bff16c61a200159c92875861d64c13f886bd854066b070bc00;

/// @notice The client-agreed storage price of a data set was set at creation or changed by mutual consent.
/// @param dataSetId The data set ID
/// @param storagePricePerTibPerMonth Agreed price in the data set's token units; 0 means the posted price
event DataSetStoragePriceSet(uint256 indexed dataSetId, uint256 storagePricePerTibPerMonth);

/// @title DataSetPricing
/// @notice Client-agreed storage price per data set (FilOzone/filecoin-services#619).
/// @dev Internal functions only: they compile into the external libraries that call them
///      (SignatureVerificationLib at creation, Rails on update and on every rate computation), which run
///      by DELEGATECALL in the FWSS proxy's storage. Nothing here adds bytecode to the FWSS core.
library DataSetPricing {
    /// @notice Agreed storage price for one data set, packed into one slot.
    /// @dev storagePricePerTibPerMonth is in the data set's token units; 0 means the posted price.
    ///      nonce counts accepted price updates and is the replay guard for UpdateStoragePrice.
    struct Price {
        uint128 storagePricePerTibPerMonth;
        uint64 nonce;
    }

    /// @custom:storage-location erc7201:filecoin-warm-storage-service.DataSetPricing
    struct Layout {
        mapping(uint256 dataSetId => Price) prices;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = DATA_SET_PRICING_STORAGE_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    /// @notice Price used for the size-proportional rate: the agreed price, never below the posted price.
    function effectiveStoragePrice(uint256 dataSetId) internal view returns (uint256 price) {
        price = layout().prices[dataSetId].storagePricePerTibPerMonth;
        if (price < STORAGE_PRICE_PER_TIB_PER_MONTH) {
            price = STORAGE_PRICE_PER_TIB_PER_MONTH;
        }
    }

    /// @notice Records the price signed at creation. Does not consume a nonce.
    function setPrice(uint256 dataSetId, uint256 storagePricePerTibPerMonth) internal {
        _store(layout().prices[dataSetId], dataSetId, storagePricePerTibPerMonth);
    }

    /// @notice Records a mutually agreed price change, consuming `nonce`.
    function updatePrice(uint256 dataSetId, uint256 storagePricePerTibPerMonth, uint256 nonce) internal {
        Price storage p = layout().prices[dataSetId];
        uint64 current = p.nonce;
        if (nonce != current) revert Errors.InvalidStoragePriceNonce(dataSetId, current, nonce);
        p.nonce = current + 1;
        _store(p, dataSetId, storagePricePerTibPerMonth);
    }

    function _store(Price storage p, uint256 dataSetId, uint256 storagePricePerTibPerMonth) private {
        if (
            storagePricePerTibPerMonth != 0
                && (storagePricePerTibPerMonth < STORAGE_PRICE_PER_TIB_PER_MONTH
                    || storagePricePerTibPerMonth > type(uint128).max)
        ) {
            revert Errors.InvalidStoragePrice(storagePricePerTibPerMonth);
        }
        p.storagePricePerTibPerMonth = uint128(storagePricePerTibPerMonth);
        emit DataSetStoragePriceSet(dataSetId, storagePricePerTibPerMonth);
    }
}
