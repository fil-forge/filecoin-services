// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";

/// @dev ERC-7201 location of {CurrencyRegistryStorage}:
///      keccak256(abi.encode(uint256(keccak256("fwss.storage.currencies")) - 1)) & ~bytes32(uint256(0xff))
bytes32 constant CURRENCY_REGISTRY_SLOT = 0xce14d13e508ebe613422ae6621b56280fb248a730a4c1776e0b3bd40cac71400;

/// @dev Price-list constants are written at 18 decimals; a token with `d` decimals is charged
///      `amount18 / 10**(18 - d)`. Six decimals keeps the per-epoch dataset fee at one unit or more.
uint8 constant MIN_CURRENCY_DECIMALS = 6;
uint8 constant MAX_CURRENCY_DECIMALS = 18;

event CurrencyAdded(uint8 indexed currencyId, address indexed token, uint8 decimals);

event CurrencyEnabledSet(uint8 indexed currencyId, address indexed token, bool enabled);

/// @notice A whitelisted USD stablecoin. Packed into one slot.
struct Currency {
    address token;
    uint64 scale; // 10 ** (18 - decimals)
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

    /// @notice Divisor applied to the 18-decimal price list for a data set's currency.
    function scaleOf(uint8 currencyId) internal view returns (uint256) {
        if (currencyId == 0) return 1;
        return layout().currencies[currencyId].scale;
    }

    /// @notice Resolves a client-requested token to its id and scale.
    /// @dev address(0) and the default token resolve to id 0. Others must be whitelisted and enabled.
    function resolve(address token, address defaultToken) internal view returns (uint8 currencyId, uint256 scale) {
        if (token == address(0) || token == defaultToken) return (0, 1);
        CurrencyRegistryStorage storage $ = layout();
        currencyId = uint8($.ids[token]);
        Currency storage c = $.currencies[currencyId];
        require(currencyId != 0 && c.enabled, Errors.UnsupportedCurrency(token));
        return (currencyId, c.scale);
    }
}
