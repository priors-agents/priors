// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {IV5Errors} from "../../src/v5/V5Types.sol";

/// @dev Triage of two private reports filed on 2026-10-10 against SeatVaultV5 (root #8641) by @SuperSmile0426,
///      GHSA-g626-94q6-4c84 and GHSA-8pxr-7299-3f6j. Each `test_GHSA_*` passes by demonstrating the reported
///      behaviour on the deployed source (no file in src/ changed); the `*_bound_*` and `*_mitigation_*` tests pass by
///      demonstrating what limits it.

interface IMarkDefault {
    function markDefault(uint256 loanId) external;
}

interface IRefresh {
    function refresh(uint256 id) external;
}

/// @dev One transaction: mark the defaults that reach the breaker's threshold, then raise a line this contract may
///      raise (the agent's pool delegate, recorded by V5 more than 24 h earlier). No keeper can put a sync() between.
contract G626AtomicRaiser {
    function run(address pool, address v5, uint256[] calldata loans, uint256 id) external {
        for (uint256 i; i < loans.length; ++i) {
            IMarkDefault(pool).markDefault(loans[i]);
        }
        IRefresh(v5).refresh(id);
    }
}

/// @dev GHSA-g626-94q6-4c84: `onDefault` records a default in the breaker's buckets without evaluating them (spec 2.8,
///      "hooks record; they never evaluate"), and `refresh`/`open` read the stored latch `tripped`. Between hook records
///      that reach the threshold and the next evaluation (`sync()`, or a recorder that newly records something), owners
///      still raise lines. Agents 0-4 default $50 each ($250, the floor); 5, 7 and 8 opened beforehand, unvouched.
contract V5ReportG626BreakerTest is V5Base {
    uint256[5] internal defaulted;
    G626AtomicRaiser internal raiser;

    function _agentCount() internal pure override returns (uint256) {
        return 9;
    }

    function setUp() public override {
        super.setUp();
        raiser = new G626AtomicRaiser();
        // book 8 names the raiser as its pool delegate before it opens: open records it, its 24 h run from there
        vm.prank(_owner(agents[8]));
        pool.setDelegate(agents[8], address(raiser));
        for (uint256 i; i < 5; ++i) {
            _open(agents[i], 150_000 * T);
            defaulted[i] = _borrow(agents[i], 50 * U, 1 days);
        }
        _open(agents[5], 150_000 * T);
        _open(agents[7], 150_000 * T);
        _open(agents[8], 150_000 * T);
        // a keeper pass: the five loans are past their grace, nothing is recorded yet, so this sync() trips nothing
        _skipFresh(4 days + 1);
    }

    function _markFive() internal {
        for (uint256 i; i < 5; ++i) {
            pool.markDefault(defaulted[i]);
        }
    }

    function test_GHSA_g626_hookRecordedThreshold_refreshRaisesUntilTheNextEvaluation() public {
        _markFive();
        (,,,,,, uint256 recorded) = lens.totals();
        assertEq(recorded, 5, "the five onDefault hooks recorded their defaults");
        assertFalse(lens.breakerTripped(), "$250 recorded (the floor) and nothing evaluated");

        // the permissionless recorders do not evaluate a default a hook already recorded
        vm.expectRevert(IV5Errors.AlreadySeen.selector);
        v5.recordDefault(defaulted[0]);
        v5.settle(agents[0], 1, defaulted[0]);
        v5.pokeFees(agents[1]);
        assertFalse(lens.breakerTripped(), "recordDefault, settle and reconciliation leave the latch stale");

        uint256 outBefore = pool.getAgent(ROOT).delegatedOut;
        // a book opened before the defaults: its owner's refresh raises on the stale latch
        vm.prank(_owner(agents[5]));
        v5.refresh(agents[5]);
        assertEq(pool.getAgent(agents[5]).delegatedIn, 50 * U, "a book opened earlier is raised to $50");
        // a book opened after the defaults: open reads the same latch, and its refresh raises too
        _open(agents[6], 150_000 * T);
        vm.prank(_owner(agents[6]));
        v5.refresh(agents[6]);
        assertEq(pool.getAgent(agents[6]).delegatedIn, 50 * U, "a book opened after the threshold is raised to $50");
        uint256 added = pool.getAgent(ROOT).delegatedOut - outBefore;
        assertEq(added, 100 * U, "$100 of new root vouches after the threshold was recorded");
        assertFalse(lens.breakerTripped());

        // the next sync() (the keeper's pass, or anyone's) evaluates the buckets and trips
        v5.sync();
        assertTrue(lens.breakerTripped(), "sync() trips at $250");
        vm.prank(_owner(agents[7]));
        v5.refresh(agents[7]);
        assertEq(pool.getAgent(agents[7]).delegatedIn, 0, "once tripped, a raise is refused");

        // lines vouched in the window are lines already vouched: loans within them still go through (as documented)
        _borrowRaw(agents[5], 50 * U, 1 days);
        assertEq(pool.getAgent(agents[5]).principalOut, 50 * U, "the line raised in the window draws after the trip");
        assertEq(pool.getAgent(ROOT).delegatedOut - outBefore, added, "the draw stays within the vouch");
        emit log_named_uint("root vouches added after the threshold, before evaluation (USDG raw)", added);
    }

    /// @dev Why no keeper cadence closes it entirely: whoever marks the threshold's defaults can raise in the same
    ///      transaction. The raiser here is book 8's pool delegate (an owner's own contract would do the same).
    function test_GHSA_g626_atomic_markTheThresholdAndRaiseInOneTransaction() public {
        uint256[] memory loans = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            loans[i] = defaulted[i];
        }
        raiser.run(address(pool), address(v5), loans, agents[8]);
        (,,,,,, uint256 recorded) = lens.totals();
        assertEq(recorded, 5);
        assertEq(pool.getAgent(agents[8]).delegatedIn, 50 * U, "raised in the transaction that recorded $250");
        assertFalse(lens.breakerTripped());
        v5.sync();
        assertTrue(lens.breakerTripped());
    }

    /// @dev The bound: a raise needs a price cache under 45 min old (`cacheFresh`), and the cache's only writer is
    ///      sync(), which evaluates the breaker in the same call. So the window ends at most 45 min after the
    ///      observation the last sync() before the defaults read, keeper or no keeper.
    function test_GHSA_g626_bound_theWindowClosesWithThePriceCache() public {
        _markFive();
        assertFalse(lens.breakerTripped());
        _skip(45 minutes + 1);
        vm.prank(_owner(agents[5]));
        v5.refresh(agents[5]);
        assertEq(pool.getAgent(agents[5]).delegatedIn, 0, "a cache over 45 min old raises nothing");
        // without a fresh SeatSizer observation sync() reverts and writes nothing ...
        vm.expectRevert(IV5Errors.StaleSizer.selector);
        v5.sync();
        // ... and the sync() that makes the cache fresh again is the one that trips the breaker
        _keeperPass(P0);
        assertTrue(lens.breakerTripped(), "the sync() that refreshes the cache trips the breaker");
        vm.prank(_owner(agents[5]));
        v5.refresh(agents[5]);
        assertEq(pool.getAgent(agents[5]).delegatedIn, 0);
    }

    /// @dev The operational mitigation: a sync() sent after the Defaulted events (while the SeatSizer observation is
    ///      under 45 min old) trips the breaker, and every later raise and open is refused.
    function test_GHSA_g626_mitigation_aSyncAfterTheDefaultsRefusesRaisesAndOpens() public {
        _markFive();
        v5.sync();
        assertTrue(lens.breakerTripped());
        vm.prank(_owner(agents[5]));
        v5.refresh(agents[5]);
        assertEq(pool.getAgent(agents[5]).delegatedIn, 0, "once evaluated, the raise is refused");
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(agents[6], ROOT, 0);
        vm.prank(_owner(agents[6]));
        vm.expectRevert(IV5Errors.BreakerOn.selector);
        v5.open(agents[6], 150_000 * T, false, c, sig);
    }
}

/// @dev GHSA-8pxr-7299-3f6j: V5 keeps its own record of the agent's pool delegate (`open` and `noteDelegate` write it)
///      and `refresh`'s `_mayRaise` accepts that record once 24 h old, without comparing it with the pool's current
///      `delegateOf`. An owner's `setDelegate(id, 0)` at the pool does not reach V5 until someone calls `noteDelegate`.
contract V5Report8pxrDelegateTest is V5Base {
    uint256 internal id;
    address internal formerKey = makeAddr("formerKey");

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(_owner(id));
        pool.setDelegate(id, formerKey);
        _open(id, 150_000 * T); // open records the pool delegate and the time (V5Book._noteDelegate)
        _skipFresh(1 days); // DELEGATE_WAIT has run
        vm.prank(_owner(id));
        pool.setDelegate(id, address(0)); // the owner revokes the key at the pool; nothing tells V5
    }

    function test_GHSA_8pxr_revokedPoolDelegateStillRaisesTheV5Line() public {
        assertEq(pool.delegateOf(id), address(0), "the pool has no delegate");
        (address who, uint64 at) = lens.delegateOf(id);
        assertEq(who, formerKey, "V5 still records the revoked key");
        assertLe(uint256(at) + 1 days, block.timestamp, "and its 24 h have run");

        // what the owner's own refresh would vouch (measured and undone)
        uint256 snap = vm.snapshotState();
        vm.prank(_owner(id));
        v5.refresh(id);
        uint256 ownersLine = pool.getAgent(id).delegatedIn;
        vm.revertToState(snap);

        uint256 freeBefore = pool.freeBacking(ROOT);
        vm.prank(formerKey);
        v5.refresh(id);
        assertEq(pool.getAgent(id).delegatedIn, 50 * U, "the revoked key raised the owner's line to $50");
        assertEq(pool.getAgent(id).delegatedIn, ownersLine, "exactly the line the owner's stake and consent support");
        assertEq(freeBefore - pool.freeBacking(ROOT), 50 * U, "and reserved $50 of the root's free backing");

        // V5's view still names the key; the pool's own controller check refuses its borrow
        assertTrue(v5.canBorrow(ROOT, id, 5 * U, 1 days, 0, formerKey, _owner(id), formerKey), "misleading view");
        vm.expectRevert(abi.encodeWithSignature("NotController(uint256,address)", id, formerKey));
        vm.prank(formerKey);
        pool.borrow(id, 5 * U, 1 days, formerKey, type(uint256).max);
    }

    /// @dev The bound, and the no-contract-change fix: `noteDelegate` is open to anyone and records the cleared
    ///      delegate at once, after which the revoked key raises nothing.
    function test_GHSA_8pxr_bound_anyoneEndsTheStaleKeyWithNoteDelegate() public {
        vm.prank(anyone);
        v5.noteDelegate(id);
        (address who,) = lens.delegateOf(id);
        assertEq(who, address(0), "V5 now records no delegate");
        vm.prank(formerKey);
        v5.refresh(id);
        assertEq(pool.getAgent(id).delegatedIn, 0, "once noted, the revoked key raises nothing");
        assertFalse(v5.canBorrow(ROOT, id, 5 * U, 1 days, 0, formerKey, _owner(id), formerKey));
    }

    /// @dev The bound on the reserved backing: a raise nobody draws can be lowered by anyone's refresh to
    ///      max(principal out, $5) once RAISE_HOLD (1 h) has passed (question 40).
    function test_GHSA_8pxr_bound_anUndrawnRaiseIsLoweredByAnyoneAfterAnHour() public {
        vm.prank(formerKey);
        v5.refresh(id);
        assertEq(pool.getAgent(id).delegatedIn, 50 * U);
        _skipFresh(1 hours);
        vm.prank(anyone);
        v5.refresh(id);
        assertEq(pool.getAgent(id).delegatedIn, 5 * U, "anyone lowers the undrawn vouch to $5 after the hold");
    }
}
