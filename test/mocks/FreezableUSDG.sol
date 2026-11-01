// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {Reenter} from "./Reenter.sol";

/// @dev The test USDG (as ReentrantUSDG: MockUSDC whose transferFrom can call the market back first) with USDG's
///      freeze: a transfer from or to a frozen address reverts, as Paxos's USDG refuses one (the bids spec, 2.4). And
///      `burn`, gas each transferFrom spends before it moves anything (only one to `burnTo`, when set), so a test can
///      widen the window where a builder's transfer runs out of gas, or make the builder's alone far costlier than the
///      rest of a sale. Built on ReentrantUSDG's own two bases in the same order, so its storage is ReentrantUSDG's
///      with three slots after: vm.etch can put this code over a ReentrantUSDG already deployed, and every balance,
///      allowance and armed call stays.
contract FreezableUSDG is MockUSDC, Reenter {
    mapping(address => bool) public frozen;
    uint256 public burn;
    address public burnTo; // zero: every transferFrom spends `burn`

    error Frozen(address account);

    function setFrozen(address account, bool on) external {
        frozen[account] = on;
    }

    function setBurn(uint256 gasToBurn) external {
        burn = gasToBurn;
    }

    /// `burn` on a transfer to `to` only.
    function setBurnTo(address to, uint256 gasToBurn) external {
        (burnTo, burn) = (to, gasToBurn);
    }

    /// Calls the market back first when armed, as ReentrantUSDG; then spends `burn` gas, or runs out trying: never a
    /// cheap refusal when gas is short.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _fire();
        if (burnTo == address(0) || to == burnTo) {
            uint256 start = gasleft();
            while (start - gasleft() < burn) {}
        }
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert Frozen(from);
        if (frozen[to]) revert Frozen(to);
        super._update(from, to, value);
    }
}

/// @dev A token behind a proxy, as USDG is on chain: every call is a delegatecall to `impl` (a FreezableUSDG built
///      for it), so an out-of-gas inside the implementation comes back to the caller with the proxy's own 1/64 left.
///      The proxy holds the storage.
contract DelegatingUSDG {
    address public immutable impl;

    constructor(address impl_) {
        impl = impl_;
    }

    fallback() external {
        address target = impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
