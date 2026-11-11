// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BURN_ACTOR_ID, BURN_ADDRESS} from "@fvm-solidity/FVMActors.sol";
import {EMPTY_CODEC} from "@fvm-solidity/FVMCodec.sol";
import {EXIT_SUCCESS, INSUFFICIENT_FUNDS} from "@fvm-solidity/FVMErrors.sol";
import {SEND} from "@fvm-solidity/FVMMethod.sol";

/// @dev Sends its value to `to` without running `to`'s code, as an FVM SEND does
contract SendForwarder {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @dev Shared by the call-actor mocks. fvm-solidity's own mocks move value with forge's `vm.deal`
/// cheatcode, which a live Anvil chain does not have; these move it with SendForwarder.
abstract contract LocalFVMSend {
    function _send(address to, uint256 value) internal {
        bytes memory response = address(this).balance >= value
            ? abi.encode(EXIT_SUCCESS, EMPTY_CODEC, bytes(""))
            : abi.encode(INSUFFICIENT_FUNDS, EMPTY_CODEC, bytes(""));
        if (address(this).balance >= value && value != 0) {
            new SendForwarder{value: value}(payable(to));
        }
        assembly ("memory-safe") {
            return(add(response, 0x20), mload(response))
        }
    }
}

/// @title LocalFVMCallActorByAddress
/// @dev Mock CallActorByAddress precompile for Anvil. Supports SEND to f410 addresses, which FVMPay.pay uses.
contract LocalFVMCallActorByAddress is LocalFVMSend {
    fallback() external payable {
        (uint64 method, uint256 value,,,, bytes memory filAddress) =
            abi.decode(msg.data, (uint64, uint256, uint64, uint64, bytes, bytes));
        require(method == SEND, "LocalFVMCallActorByAddress: only SEND supported");
        require(
            filAddress.length == 22 && filAddress[0] == 0x04 && filAddress[1] == 0x0a,
            "LocalFVMCallActorByAddress: only f410 addresses supported"
        );

        address recipient;
        assembly ("memory-safe") {
            recipient := mload(add(22, filAddress))
        }
        _send(recipient, value);
    }
}

/// @title LocalFVMCallActorById
/// @dev Mock CallActorById precompile for Anvil. Supports SEND to the burn actor, which FVMPay.burn uses.
contract LocalFVMCallActorById is LocalFVMSend {
    fallback() external payable {
        (uint64 method, uint256 value,,,, uint64 actorId) =
            abi.decode(msg.data, (uint64, uint256, uint64, uint64, bytes, uint64));
        require(method == SEND, "LocalFVMCallActorById: only SEND supported");
        require(actorId == BURN_ACTOR_ID, "LocalFVMCallActorById: only the burn actor supported");
        _send(BURN_ADDRESS, value);
    }
}
