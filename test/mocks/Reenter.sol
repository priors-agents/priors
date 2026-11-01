// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev A token's transfer that calls back once into a target (armed by the test): the reentrancy hook of the private
///      repository's test/mocks/AgentMarketMocks.sol, alone, for the mocks published here.
abstract contract Reenter {
    address public hookTarget;
    bytes public hookData;
    bool public hookFired;
    bool public hookOk;
    bytes public hookReturn;

    function arm(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        hookFired = false;
        hookOk = false;
        delete hookReturn;
    }

    function _fire() internal {
        address target = hookTarget;
        if (target == address(0)) return;
        hookTarget = address(0); // once
        hookFired = true;
        (hookOk, hookReturn) = target.call(hookData);
    }
}
