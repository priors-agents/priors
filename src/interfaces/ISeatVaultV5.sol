// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISeatVaultV5Engine
/// @notice The part of SeatVaultV5 that BuyAndBack, PriorsLiquidity and the keeper helper call or read
///         (docs/PRIORS-UNDERWRITING-SPEC.md, 2A.1–2A.3, 2.8). Every price is a sqrtPriceX96 of the $PRIORS/USDG pool
///         (a higher value is a cheaper $PRIORS); every USDG amount is in raw units (6 decimals).
interface ISeatVaultV5Engine {
    // ---- writes BuyAndBack makes (each under V5's one reentrancy lock) ----

    /// @notice A back. For BuyAndBack it is a placement of C: no 1,000 $PRIORS minimum, allowed while `openBacking`
    ///         is off, refused unless the book meets the placement rule, and held to `placeRoom(id)`.
    function back(uint256 id, uint256 amount, bool autoAdd) external;

    /// @notice A leave; BuyAndBack's C leaves in mode 1 only. BuyAndBack never calls it: C moves to leaving only by
    ///         V5's rule-based moves (a late repayment, the owner's opt-out, a close, an owner change; 2A.2).
    function leave(uint256 id, uint256 amount, uint8 exitMode) external;

    /// @notice BuyAndBack only: serve the exit queue's head `entryId` by an internal fill priced at `sqrtFill`.
    ///         `taken` is the $PRIORS sent to BuyAndBack (at most `maxTokens` and V5's exit chunk), 0 when the head was
    ///         paid as $PRIORS or moved to the tail (its release rule or its leaver's floor failing). Never reverts on
    ///         the release rule or the floor. BuyAndBack then pays `holder` floor(taken × the fill price) in USDG.
    function fillExit(uint256 entryId, uint256 maxTokens, uint160 sqrtFill)
        external
        returns (uint256 taken, address holder);

    /// @notice BuyAndBack only, after a fill whose USDG payment failed: pays the entry's rest as $PRIORS if its release
    ///         rule holds, else moves it to the tail. Never reverts on the rule.
    function returnExit(uint256 entryId) external;

    // ---- reads ----

    /// @notice (t − EPOCH0) ÷ 7 days, EPOCH0 an immutable Monday 00:00 UTC. BuyAndBack never computes its own weeks.
    function epochOf(uint256 t) external view returns (uint256);

    /// @notice The agent's latest generation (0: never opened), the generation a placement joins.
    function latestGen(uint256 id) external view returns (uint32);

    /// @notice The exit queue's head: its id (0 when empty), holder, rest at the current burn factor, the stricter
    ///         P recorded at its leaves (sqrtPriceX96) and when it joined.
    function exitHead()
        external
        view
        returns (uint256 entryId, address holder, uint256 rest, uint160 sqrtPLeave, uint64 joinedAt);

    /// @notice Whether a fill may run now: V5 not paused, the breaker, the spot guard and the depth guard off, and the
    ///         price cache at most 45 min old.
    function exitServiceOpen() external view returns (bool);

    /// @notice The price cache `sync()` keeps: the 24h median, the SeatSizer `lastObsAt` stored with it, the week low
    ///         and the keeper's last observation. Under the depth guard's lasting state the median only moves toward a
    ///         lower P (2.8: a cache that cannot be pumped while depth is gone) while `obsAt` keeps the latest
    ///         observation's time: a capped median reads fresh. Intended: every reader that would act on it (a buy, a
    ///         fill, a raise, a new line) also stops under `depthGuard()`, which includes the lasting state.
    function priceCache()
        external
        view
        returns (uint160 sqrtMedian, uint64 obsAt, uint160 sqrtWeekLow, uint160 sqrtObservation);

    /// @notice The spot guard: `sync()`'s latch, or live spot at or under 0.80 × the cached median.
    function spotGuardOn() external view returns (bool);

    /// @notice The depth guard's lasting state, written only by `sync()`.
    function depthGuardOn() external view returns (bool);

    /// @notice 2.8's one predicate: `depthGuardOn`, the median-valued form or the live form.
    function depthGuard() external view returns (bool);

    function breakerTripped() external view returns (bool);
    function paused() external view returns (bool);

    /// @notice Engine 2's points of the agent's latest generation recorded in `epoch` (0 when erased or voided).
    function bookPoints(uint256 id, uint256 epoch) external view returns (uint256);

    /// @notice The global points recorded in `epoch` (0 once the slot holds another epoch).
    function globalPoints(uint256 epoch) external view returns (uint256);

    /// @notice What a placement into the agent's latest generation may add now (min(A/6 − C, A − B − C, A/8 a week),
    ///         B and C counted with pending and leaving stake), and whether the book meets the placement rule.
    function placeRoom(uint256 id) external view returns (uint256 tokens, bool eligible);

    /// @notice $PRIORS of C returned to BuyAndBack (releases and settled remainders).
    function cReturned() external view returns (uint256);

    function buyAndBack() external view returns (address);
    function timelock() external view returns (address);
    function swapLimiter() external view returns (address);
}
