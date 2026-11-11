// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDFC
 * @dev A simple ERC20 mock for the USDFC token used in local development.
 *      Allows unrestricted minting for testing purposes.
 */
contract MockUSDFC is ERC20 {
    uint8 private _decimals;

    constructor() ERC20("Mock USDFC", "USDFC") {
        _decimals = 18; // USDFC uses 18 decimals
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Mint tokens to any address. Unrestricted for testing.
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Convenience function to mint tokens to the caller
     * @param amount The amount of tokens to mint
     */
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
