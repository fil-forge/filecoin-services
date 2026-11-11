// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @title DeterministicBeaconRandomness
/// @dev Mock FVM precompile that returns keccak256(abi.encode(epoch))
/// This provides deterministic but epoch-dependent randomness for local testing.
/// Both the Go mock RPC server and this contract use the same algorithm,
/// ensuring proof verification succeeds.
contract DeterministicBeaconRandomness {
    /// @dev Fallback function that implements the beacon randomness mock.
    /// Reads the epoch from calldata and returns keccak256(abi.encode(epoch))
    fallback() external {
        uint256 epoch;
        assembly ("memory-safe") {
            // Read epoch from calldata (first 32 bytes)
            epoch := calldataload(0)
            // Validate epoch is not greater than current block number
            if gt(epoch, number()) { invalid() }
        }

        // Calculate deterministic randomness: keccak256(abi.encode(epoch))
        uint256 randomness = uint256(keccak256(abi.encode(epoch)));

        assembly ("memory-safe") {
            // Store randomness at memory position 0 and return 32 bytes
            mstore(0, randomness)
            return(0, 32)
        }
    }
}
