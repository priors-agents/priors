// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardianPause
/// @notice The guardian's one power over the protocol's new contracts (docs/PRIORS-UNDERWRITING-SPEC.md section 8,
///         "Governance"): pause, for at most 14 days, and never again while paused or within 14 days after a pause
///         ends. There is no unpause and nothing else. Each contract decides which of its functions the pause stops
///         (`whenNotPaused`). The guardian (the Safe) and the timelock are immutable addresses: nothing to renounce
///         or transfer.
abstract contract GuardianPause {
    /// @notice The longest a single pause can last.
    uint64 public constant MAX_PAUSE = 14 days;
    /// @notice After a pause ends, the guardian cannot pause again for this long.
    uint64 public constant PAUSE_COOLDOWN = 14 days;

    /// @dev The Safe: pause only (read through `guardian()`).
    address internal immutable _guardian;
    /// @dev The 48 h TimelockController: every setting of the contract (read through `timelock()`).
    address internal immutable _timelock;

    /// @notice The end of the current (or the last) pause; 0 if never paused.
    uint64 public pausedUntil;

    /// @notice A pause until `until`.
    event PausedUntil(uint64 until);

    error NotGuardian(address caller);
    error NotTimelock(address caller);
    error IsPaused(uint64 until);
    error PauseRefused(uint64 nextAllowed);
    error BadPause(uint64 until);
    error ZeroAddress();

    /// @param guardian_ the Safe
    /// @param timelock_ the 48 h TimelockController
    constructor(address guardian_, address timelock_) {
        if (guardian_ == address(0) || timelock_ == address(0)) revert ZeroAddress();
        _guardian = guardian_;
        _timelock = timelock_;
    }

    modifier onlyTimelock() {
        if (msg.sender != _timelock) revert NotTimelock(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (block.timestamp < pausedUntil) revert IsPaused(pausedUntil);
        _;
    }

    /// @notice Pause until `until`: at most MAX_PAUSE ahead, refused while a pause runs or within PAUSE_COOLDOWN of
    ///         the end of the last one. A pause cannot be extended, shortened or lifted.
    /// @param until the timestamp the pause ends at, in (now, now + 14 days]
    function pause(uint64 until) external {
        if (msg.sender != _guardian) revert NotGuardian(msg.sender);
        uint64 last = pausedUntil;
        if (last != 0 && block.timestamp < uint256(last) + PAUSE_COOLDOWN) {
            revert PauseRefused(last + PAUSE_COOLDOWN);
        }
        if (until <= block.timestamp || until > block.timestamp + MAX_PAUSE) revert BadPause(until);
        pausedUntil = until;
        emit PausedUntil(until);
    }

    /// @notice The Safe: pause only.
    function guardian() public view virtual returns (address) {
        return _guardian;
    }

    /// @notice The 48 h TimelockController: every setting of the contract.
    function timelock() public view virtual returns (address) {
        return _timelock;
    }

    /// @notice True while a pause runs.
    function paused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }
}
