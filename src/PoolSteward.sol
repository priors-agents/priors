// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GuardianPause} from "./GuardianPause.sol";

/// @dev The owner side of CreditPoolV2 the steward wraps, with the pool's own `Params` layout (src/CreditPoolV2.sol
///      :114). Declared here so the steward does not compile the pool's source.
interface IStewardedPool {
    struct Params {
        uint256 minLoan;
        uint256 maxLoan;
        uint64 minTerm;
        uint64 maxTerm;
        uint64 grace;
        uint64 minScoreTerm;
        uint256 feeBps;
        uint256 sponsorFeeBps;
        uint256 protocolFeeBps;
        uint256 minStake;
        uint256 maxUtilizationBps;
        uint256 keeperBounty;
    }

    /// @notice The pool's owner (Ownable2Step).
    function owner() external view returns (address);
    /// @notice Ownable2Step: the pending owner accepts.
    function acceptOwnership() external;
    /// @notice Ownable2Step: name a pending owner.
    function transferOwnership(address newOwner) external;
    /// @notice The pool's twelve parameters.
    function getParams() external view returns (Params memory);
    /// @notice Replace all twelve parameters (owner only).
    function setParams(Params calldata p) external;
    /// @notice The protocol reserve, in USDG.
    function reserve() external view returns (uint256);
    /// @notice Principal of all open loans, in USDG.
    function totalPrincipalOut() external view returns (uint256);
    /// @notice Send reserve USDG (owner only).
    function withdrawReserve(uint256 amount, address to) external;
    /// @notice Move reserve into a root's stake (owner only).
    function reserveToStake(uint256 rootId, uint256 amount) external;
    /// @notice Mark a custodian (owner only).
    function setCustodian(address who, bool allowed) external;
    /// @notice Name the pool's guardian (owner only).
    function setGuardian(address g) external;
    /// @notice Stop new risk for 14 days (guardian or owner).
    function pause() external;
    /// @notice Lift the pause (guardian or owner).
    function unpause() external;
}

/// @title PoolSteward
/// @notice CreditPoolV2's owner, between the 48 h timelock and the pool (docs/PRIORS-UNDERWRITING-SPEC.md 2A.4,
///         section 8, section 12 PS-FLOOR and PS-SWEEP). Not upgradeable and ownerless: the timelock's address is an
///         immutable, so there is nothing to renounce and no way to strand the pool behind it.
///
///         - `execute(data)` (timelock only) forwards the pool's owner calls, every one of them still behind 48 h:
///           `setParams`, `withdrawReserve`, `reserveToStake`, `setCustodian`, `setGuardian`, `pause`, `unpause` and
///           `transferOwnership` (the handback, to the timelock only). It decodes three first and reverts outside
///           the policy: `setParams` only with sponsor <= 2,500 bps, feeBps <= 200, lenders (10,000 - sponsor -
///           protocol) >= 3,500, protocol <= 4,000, keeperBounty 0 and the eight loan fields equal to `getParams()`
///           at execution; `withdrawReserve` and `reserveToStake` only if the reserve stays at or above
///           `hardFloor()`. Any other selector reverts.
///         - `setLoanParams(p)` (timelock only) changes the loan fields, keeping the fee split and the bounty equal to
///           `getParams()`: one operation changes the fee split or the loan fields, never both; `minTerm` stays at
///           least 1 day (AutoRepay's 6-hour window depends on it).
///         - `sweep()` (anyone, once per 24 h, paused by the guardian) sends the router everything above `target()`,
///           or, with the reserve at or under it, half of what reached the reserve since the last sweep, never taking
///           it under `hardFloor()`, and nothing under 25 USDG. The destination is fixed.
///
///         What the decode does not bind: a batch that first hands the pool back
///         (`execute(transferOwnership(timelock))`, then the timelock's `acceptOwnership`) escapes it, 48 h after it
///         is scheduled; and a split that comes out too low. Both are the spec's stated limits (2A.4).
contract PoolSteward is GuardianPause {
    // ------------------------------------------------------------------
    // Policy
    // ------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 200;
    /// @notice `setLoanParams` never sets the pool's `minTerm` under this (AutoRepay's window, deep audit AR-I3).
    uint64 public constant MIN_MIN_TERM = 1 days;
    uint256 public constant MAX_SPONSOR_BPS = 2_500;
    uint256 public constant MAX_PROTOCOL_BPS = 4_000;
    uint256 public constant MIN_LENDER_BPS = 3_500;

    /// @notice `hardFloor()`'s absolute term never goes under the seed money it keeps (question 17).
    uint256 public constant MIN_FLOOR_ABS = 190e6;
    uint256 public constant MIN_FLOOR_BPS = 100;
    uint256 public constant MAX_FLOOR_BPS = 2_000;
    /// @notice A sanity bound on `target()`'s share of principal out (the spec sets none; see PROTOCOL-BUILD.md).
    uint256 public constant MAX_TARGET_BPS = BPS;

    uint256 public constant SWEEP_INTERVAL = 24 hours;
    uint256 public constant MIN_SWEEP = 25e6;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    /// @notice CreditPoolV2.
    IStewardedPool public immutable pool;
    /// @notice The RevenueRouter: the one destination of `sweep()`.
    address public immutable router;

    uint256 public floorAbs;
    uint256 public floorBps;
    uint256 public targetAbs;
    uint256 public targetBps;

    /// @notice The reserve when the steward accepted the pool, then after every sweep and every forwarded reserve
    ///         move. Under the target, a sweep takes half of `reserve() - mark`.
    uint256 public mark;
    uint64 public lastSweepAt;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    /// @notice A sweep sent `amount` to the router; `mark` is the reserve after it.
    event Swept(uint256 amount, uint256 mark);
    /// @notice A pool owner call forwarded through the timelock.
    event Executed(bytes4 indexed selector);
    /// @notice The steward became the pool's owner; the mark starts at the reserve then.
    event PoolAccepted(uint256 mark);
    /// @notice A forwarded reserve move reset the mark to the reserve after it.
    event MarkSet(uint256 mark);
    /// @notice The hard floor's terms changed.
    event FloorSet(uint256 floorAbs, uint256 floorBps);
    /// @notice The target's terms changed.
    event TargetSet(uint256 targetAbs, uint256 targetBps);

    error UnknownCall(bytes4 selector);
    error HandbackOnlyToTimelock(address to);
    error BadLength(bytes4 selector, uint256 length);
    error FeeAbovePolicy(uint256 feeBps);
    error SponsorAbovePolicy(uint256 sponsorFeeBps);
    error ProtocolAbovePolicy(uint256 protocolFeeBps);
    error LendersBelowPolicy(uint256 sponsorFeeBps, uint256 protocolFeeBps);
    error BountyNotZero(uint256 keeperBounty);
    error LoanFieldChanged();
    error FeeFieldChanged();
    error BelowFloor(uint256 reserve, uint256 amount, uint256 floor);
    error TooSoon(uint64 next);
    error BadFloor(uint256 floorAbs, uint256 floorBps);
    error BadTarget(uint256 targetBps);
    error TermTooShort(uint64 minTerm);

    /// @param pool_ CreditPoolV2
    /// @param router_ the RevenueRouter
    /// @param timelock_ the 48 h TimelockController
    /// @param guardian_ the Safe (pause of `sweep` only)
    constructor(IStewardedPool pool_, address router_, address timelock_, address guardian_)
        GuardianPause(guardian_, timelock_)
    {
        if (address(pool_) == address(0) || router_ == address(0)) revert ZeroAddress();
        pool = pool_;
        router = router_;
        floorAbs = MIN_FLOOR_ABS;
        floorBps = 200;
        targetAbs = MIN_FLOOR_ABS;
        targetBps = 1_000;
        emit FloorSet(MIN_FLOOR_ABS, 200);
        emit TargetSet(MIN_FLOOR_ABS, 1_000);
    }

    // ------------------------------------------------------------------
    // The timelock
    // ------------------------------------------------------------------

    /// @notice Complete the pool's two-step handover to the steward (adoption step 2, in one timelock batch after
    ///         the pool's `transferOwnership(steward)`), and set the mark to the reserve now.
    function acceptPoolOwnership() external onlyTimelock {
        uint256 r = pool.reserve(); // acceptOwnership moves no reserve
        mark = r;
        pool.acceptOwnership();
        emit PoolAccepted(r);
    }

    /// @notice Forward one owner call to the pool, decoding `setParams`, `withdrawReserve` and `reserveToStake`
    ///         against the policy first. Any other selector than the pool's owner calls reverts.
    /// @param data the pool call: selector and ABI-encoded arguments, exact length
    /// @return ret the pool's return data
    function execute(bytes calldata data) external onlyTimelock returns (bytes memory ret) {
        if (data.length < 4) revert UnknownCall(bytes4(0));
        bytes4 sel = bytes4(data[:4]);
        bool reserveMove;
        uint256 newMark;
        if (sel == IStewardedPool.setParams.selector) {
            _len(sel, data.length, 12);
            IStewardedPool.Params memory p = abi.decode(data[4:], (IStewardedPool.Params));
            _checkSplit(p);
            if (!_sameLoanFields(p, pool.getParams())) revert LoanFieldChanged();
        } else if (sel == IStewardedPool.withdrawReserve.selector) {
            _len(sel, data.length, 2);
            (uint256 amount,) = abi.decode(data[4:], (uint256, address));
            newMark = _checkFloor(amount);
            reserveMove = true;
        } else if (sel == IStewardedPool.reserveToStake.selector) {
            _len(sel, data.length, 2);
            (, uint256 amount) = abi.decode(data[4:], (uint256, uint256));
            newMark = _checkFloor(amount);
            reserveMove = true;
        } else if (sel == IStewardedPool.setCustodian.selector) {
            _len(sel, data.length, 2);
        } else if (sel == IStewardedPool.setGuardian.selector) {
            _len(sel, data.length, 1);
        } else if (sel == IStewardedPool.transferOwnership.selector) {
            // the handback goes back to the timelock only (2A.4: "transferOwnership back")
            _len(sel, data.length, 1);
            address to = abi.decode(data[4:], (address));
            if (to != _timelock) revert HandbackOnlyToTimelock(to);
        } else if (sel == IStewardedPool.pause.selector || sel == IStewardedPool.unpause.selector) {
            _len(sel, data.length, 0);
        } else {
            revert UnknownCall(sel);
        }
        // both reserve moves take exactly `amount` off the reserve, so the mark is known before the call
        if (reserveMove) mark = newMark;
        bool ok;
        (ok, ret) = address(pool).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (reserveMove) emit MarkSet(newMark);
        emit Executed(sel);
    }

    /// @notice Change the eight loan fields; the fee split and the bounty must equal `getParams()` at execution.
    function setLoanParams(IStewardedPool.Params calldata p) external onlyTimelock {
        IStewardedPool.Params memory cur = pool.getParams();
        if (
            p.feeBps != cur.feeBps || p.sponsorFeeBps != cur.sponsorFeeBps || p.protocolFeeBps != cur.protocolFeeBps
                || p.keeperBounty != cur.keeperBounty
        ) revert FeeFieldChanged();
        // AutoRepay's window (6 h before `dueAt`) and its T2 bound assume a loan term of at least a day: the one loan
        // field it depends on is bounded here (deep audit AR-I3)
        if (p.minTerm < MIN_MIN_TERM) revert TermTooShort(p.minTerm);
        pool.setParams(p);
        emit Executed(IStewardedPool.setParams.selector);
    }

    /// @notice The hard floor's terms: absolute at least 190 USDG, share of principal out 100-2,000 bps.
    function setFloor(uint256 abs_, uint256 bps_) external onlyTimelock {
        if (abs_ < MIN_FLOOR_ABS || bps_ < MIN_FLOOR_BPS || bps_ > MAX_FLOOR_BPS) revert BadFloor(abs_, bps_);
        floorAbs = abs_;
        floorBps = bps_;
        emit FloorSet(abs_, bps_);
    }

    /// @notice The target's terms (question 8: 190 USDG and 10% of principal out at launch).
    function setTarget(uint256 abs_, uint256 bps_) external onlyTimelock {
        if (bps_ > MAX_TARGET_BPS) revert BadTarget(bps_);
        targetAbs = abs_;
        targetBps = bps_;
        emit TargetSet(abs_, bps_);
    }

    // ------------------------------------------------------------------
    // The sweep
    // ------------------------------------------------------------------

    /// @notice Send the router what the reserve rule allows, at most once per 24 h. Under 25 USDG it sends nothing
    ///         and changes nothing, so arrivals add up.
    /// @return amount the USDG sent to the router
    function sweep() external whenNotPaused returns (uint256 amount) {
        uint64 last = lastSweepAt;
        if (last != 0 && block.timestamp < uint256(last) + SWEEP_INTERVAL) {
            // safe cast: a constant
            // forge-lint: disable-next-line(unsafe-typecast)
            revert TooSoon(last + uint64(SWEEP_INTERVAL));
        }
        uint256 r;
        (amount, r) = _sweepable();
        if (amount < MIN_SWEEP) return 0;
        lastSweepAt = uint64(block.timestamp);
        mark = r - amount; // withdrawReserve takes exactly `amount` off the reserve
        pool.withdrawReserve(amount, router);
        emit Swept(amount, r - amount);
    }

    /// @notice What a sweep would send now (before the 25 USDG minimum and the 24 h interval): above the target, the
    ///         excess; at or under it, half of what arrived since the mark; in both cases never below the floor.
    function sweepable() external view returns (uint256 amount) {
        (amount,) = _sweepable();
    }

    /// @dev The reserve rule of 2A.4: what a sweep sends, and the reserve it read.
    function _sweepable() internal view returns (uint256 amount, uint256 r) {
        r = pool.reserve();
        uint256 p = pool.totalPrincipalOut();
        uint256 floor_ = _hardFloor(p);
        if (r <= floor_) return (0, r);
        uint256 t = _target(p);
        if (r > t) amount = r - t;
        else amount = r > mark ? (r - mark) / 2 : 0;
        uint256 room = r - floor_;
        if (amount > room) amount = room;
    }

    /// @notice max(floorAbs, floorBps of principal out), rounded up.
    function hardFloor() public view returns (uint256) {
        return _hardFloor(pool.totalPrincipalOut());
    }

    /// @notice max(targetAbs, targetBps of principal out), rounded up, read at the sweep (question 8).
    function target() public view returns (uint256) {
        return _target(pool.totalPrincipalOut());
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev max(floorAbs, floorBps of `principalOut`), rounded up.
    function _hardFloor(uint256 principalOut) internal view returns (uint256) {
        uint256 f = Math.mulDiv(principalOut, floorBps, BPS, Math.Rounding.Ceil);
        return f > floorAbs ? f : floorAbs;
    }

    /// @dev max(targetAbs, targetBps of `principalOut`), rounded up.
    function _target(uint256 principalOut) internal view returns (uint256) {
        uint256 t = Math.mulDiv(principalOut, targetBps, BPS, Math.Rounding.Ceil);
        return t > targetAbs ? t : targetAbs;
    }

    /// @dev Reverts unless the reserve stays at or above the hard floor; returns the reserve after the move.
    function _checkFloor(uint256 amount) internal view returns (uint256 after_) {
        uint256 r = pool.reserve();
        uint256 f = hardFloor();
        if (amount > r || r - amount < f) revert BelowFloor(r, amount, f);
        after_ = r - amount;
    }

    /// @dev The fee policy of 2A.4: every row of the staged table passes, a swapped or inflated split does not.
    function _checkSplit(IStewardedPool.Params memory p) internal pure {
        if (p.feeBps > MAX_FEE_BPS) revert FeeAbovePolicy(p.feeBps);
        if (p.sponsorFeeBps > MAX_SPONSOR_BPS) revert SponsorAbovePolicy(p.sponsorFeeBps);
        // lenders get 10,000 - sponsor - protocol; sponsor <= 2,500 here, so the subtraction cannot underflow
        if (p.protocolFeeBps > BPS - MIN_LENDER_BPS - p.sponsorFeeBps) {
            revert LendersBelowPolicy(p.sponsorFeeBps, p.protocolFeeBps);
        }
        if (p.protocolFeeBps > MAX_PROTOCOL_BPS) revert ProtocolAbovePolicy(p.protocolFeeBps);
        if (p.keeperBounty != 0) revert BountyNotZero(p.keeperBounty);
    }

    /// @dev True when the eight loan fields of `a` and `b` are equal.
    function _sameLoanFields(IStewardedPool.Params memory a, IStewardedPool.Params memory b)
        internal
        pure
        returns (bool)
    {
        return a.minLoan == b.minLoan && a.maxLoan == b.maxLoan && a.minTerm == b.minTerm && a.maxTerm == b.maxTerm
            && a.grace == b.grace && a.minScoreTerm == b.minScoreTerm && a.minStake == b.minStake
            && a.maxUtilizationBps == b.maxUtilizationBps;
    }

    /// @dev Calldata must be exactly the selector and `words` static ABI words: what the steward decodes is then
    ///      exactly what the pool decodes.
    function _len(bytes4 sel, uint256 length, uint256 words) internal pure {
        if (length != 4 + 32 * words) revert BadLength(sel, length);
    }
}
