// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";

/// @dev ERC-7201 location of {CurrencyRegistryStorage}:
///      keccak256(abi.encode(uint256(keccak256("fwss.storage.currencies")) - 1)) & ~bytes32(uint256(0xff))
bytes32 constant CURRENCY_REGISTRY_SLOT = 0xce14d13e508ebe613422ae6621b56280fb248a730a4c1776e0b3bd40cac71400;

/// @dev Root slot of FWSS's `dataSetInfo` mapping. Mirrors the generated
///      `FilecoinWarmStorageServiceLayout.DATA_SET_INFO_SLOT` (which Rails cannot import: the layout
///      generator compiles FWSS, which links Rails). Pinned by MultiCurrencyTest.
bytes32 constant DATA_SET_INFO_ROOT_SLOT = bytes32(uint256(7));

/// @dev Price-list constants are written at 18 decimals; a token with `d` decimals is charged
///      `amount18 / 10**(18 - d)`. Six decimals keeps the per-epoch dataset fee at one unit or more.
uint8 constant MIN_CURRENCY_DECIMALS = 6;
uint8 constant MAX_CURRENCY_DECIMALS = 18;

event CurrencyAdded(uint8 indexed currencyId, address indexed token, uint8 decimals);

event CurrencyEnabledSet(uint8 indexed currencyId, address indexed token, bool enabled);

/// @notice A whitelisted USD stablecoin. Packed into one slot.
struct Currency {
    address token;
    uint8 decimals;
    bool enabled; // false: no new data sets; existing data sets keep paying in it
}

/// @custom:storage-location erc7201:fwss.storage.currencies
struct CurrencyRegistryStorage {
    uint256 count; // ids 1..count are whitelisted; id 0 is the deployment's default token
    mapping(uint256 currencyId => Currency) currencies;
    mapping(address token => uint256 currencyId) ids;
}

/// @title CurrencyRegistry
/// @notice Owner-curated whitelist of USD stablecoins a data set may pay in (#618).
/// @dev Ids are append-only so the id stored per data set never changes meaning.
library CurrencyRegistry {
    function layout() internal pure returns (CurrencyRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := CURRENCY_REGISTRY_SLOT
        }
    }

    /// @notice Currency code of a whitelisted, enabled token: id | (18 - decimals) << 8.
    /// @dev The default token (id 0) is resolved by the caller. The code is stored as DataSetInfo.currency.
    function resolve(address token) internal view returns (uint16 code) {
        CurrencyRegistryStorage storage $ = layout();
        uint256 id = $.ids[token];
        Currency storage c = $.currencies[id];
        require(id != 0 && c.enabled, Errors.UnsupportedCurrency(token));
        return uint16(id) | (uint16(MAX_CURRENCY_DECIMALS - c.decimals) << 8);
    }

    /// @notice Divisor from the 18-decimal price list to the units of the currency with this code.
    function scale(uint256 currencyCode) internal pure returns (uint256) {
        return 10 ** (currencyCode >> 8);
    }
}
