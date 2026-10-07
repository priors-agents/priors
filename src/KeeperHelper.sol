// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice SeatSizerV4's keeper calls (src/SeatSizer.sol:106, :123).
interface IKeptSizer {
    /// @notice Record the pool's price (keeper or owner, at most once per 29 minutes).
    function poke() external;
    /// @notice Resize SeatVaultV4's seat from the median.
    function resize() external returns (uint256);
}

/// @notice SwapLimiter's keeper call.
interface IKeptLimiter {
    /// @notice Record the pool's depth snapshot.
    function snapDepth() external;
}

/// @title KeeperHelper
/// @notice The keeper of both SeatSizerV4 and the SwapLimiter, called by the keeper's key alone
///         (docs/PRIORS-UNDERWRITING-SPEC.md 2A.5, 2A.6, section 8, section 12 KH-SCOPE). It exists so the depth
///         snapshot lands in the same transaction as the price observation: `pokeAndSnap()` sends SeatSizer `poke`
///         then SwapLimiter `snapDepth()`, all or nothing. It also forwards the keeper's further `snapDepth()` at a
///         random moment between passes, and `resize()`, the SeatSizer's other keeper call.
///
///         It forwards nothing else, has no setter, no owner and no payable function, and holds no tokens. The key is
///         immutable: replacing it is a new helper, named keeper by the Safe on the sizer (`setKeeper`, at once) and
///         by the timelock on the limiter (48 h; the Safe can `snapDepth()` itself meanwhile).
contract KeeperHelper {
    /// @notice SeatSizerV4.
    IKeptSizer public immutable sizer;
    /// @notice The SwapLimiter.
    IKeptLimiter public immutable limiter;
    /// @notice The keeper's key, the only caller.
    address public immutable key;

    error NotKey(address caller);
    error ZeroAddress();

    /// @param sizer_ SeatSizerV4
    /// @param limiter_ the SwapLimiter
    /// @param key_ the keeper's key
    constructor(IKeptSizer sizer_, IKeptLimiter limiter_, address key_) {
        if (address(sizer_) == address(0) || address(limiter_) == address(0) || key_ == address(0)) {
            revert ZeroAddress();
        }
        sizer = sizer_;
        limiter = limiter_;
        key = key_;
    }

    modifier onlyKey() {
        if (msg.sender != key) revert NotKey(msg.sender);
        _;
    }

    /// @notice The pass's first step: the SeatSizer's observation and the depth snapshot in one transaction.
    function pokeAndSnap() external onlyKey {
        sizer.poke();
        limiter.snapDepth();
    }

    /// @notice The extra snapshot taken at a random moment between passes.
    function snapDepth() external onlyKey {
        limiter.snapDepth();
    }

    /// @notice SeatSizerV4's resize (SeatVaultV4's seat size and its collapse guard).
    /// @return next the new seat size
    function resize() external onlyKey returns (uint256 next) {
        return sizer.resize();
    }
}
