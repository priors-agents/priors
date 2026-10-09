// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Events, IV5Errors} from "../../src/v5/V5Types.sol";
import {V5Auto} from "../../src/v5/V5Auto.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {MockV1Pool, MockRegistryV5} from "./V5Mocks.sol";

/// @dev Regressions for the internal audit's findings (docs/AUDIT-INTERNAL-2026-10.md, "Fixes"), in the V5 suite so
///      branch coverage counts them. The audit's own proofs of concept (test/audit/) now show each fix as well.

/// @dev M-01: auto-add spends only the credit the item's own positions produce in the call.
contract V5FixCompoundTest is V5Base {
    uint256 internal idA;
    uint256 internal idB;

    function _poolParams() internal pure override returns (ICreditPoolV2.Params memory p) {
        p = super._poolParams();
        p.feeBps = 500;
        p.sponsorFeeBps = 8500;
    }

    function setUp() public override {
        super.setUp();
        idA = agents[0];
        idB = agents[1];
        _open(idA, 140_000 * T);
        _open(idB, 140_000 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _back(backer1, idA, 139_000 * T);
        _back(backer1, idB, 139_000 * T);
        _skipFresh(1 days);
        v5.pokeFees(idA);
        v5.pokeFees(idB);
        // auto-add on book A only; both books pay fees
        vm.prank(backer1);
        v5.setAutoAdd(idA, true);
        for (uint256 i = 0; i < 26; i++) {
            uint256 la = _borrow(idA, 45 * U, 10 days);
            uint256 lb = _borrow(idB, 45 * U, 10 days);
            _skipFresh(10 days);
            _repay(la);
            _repay(lb);
            v5.pokeFees(idA);
            v5.pokeFees(idB);
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids, uint32[] memory gens) {
        ids = new uint256[](1);
        gens = new uint32[](1);
        ids[0] = id;
        gens[0] = 1;
    }

    /// @dev What `collect` would pay the backer for one book alone, measured in a snapshot and undone.
    function _creditOf(uint256 id) internal returns (uint256 amount) {
        uint256 snap = vm.snapshotState();
        (uint256[] memory ids, uint32[] memory gens) = _one(id);
        vm.prank(backer1);
        amount = v5.collect(ids, gens);
        vm.revertToState(snap);
    }

    function test_M01_mixedBatch_spendsOnlyTheOptedInBooksOwnCredit() public {
        uint256 feesA = _creditOf(idA);
        uint256 feesB = _creditOf(idB);
        assertGt(feesA, 5 * U, "book A's fees reach compound's minimum on their own");
        assertGt(feesB, 0);
        S.Pos memory pB0 = lens.position(idB, 1, C.OTHERS, backer1);

        // B (off) first, then A (on), then B again and A again: neither repeat adds anything
        V5Auto.Item[] memory items = new V5Auto.Item[](4);
        items[0] = V5Auto.Item(idB, backer1);
        items[1] = V5Auto.Item(idA, backer1);
        items[2] = V5Auto.Item(idB, backer1);
        items[3] = V5Auto.Item(idA, backer1);
        vm.recordLogs();
        vm.prank(keeper);
        v5.compound(items, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 usdIn;
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IV5Events.Backed.selector) {
                // L-03: a compound's stake is announced in the layer it enters
                assertEq(uint256(logs[i].topics[1]), idA);
                (uint8 layer,, uint256 u) = abi.decode(logs[i].data, (uint8, uint256, uint256));
                assertEq(layer, C.OTHERS);
                assertEq(u, 0, "the USDG is in Compounded");
            }
            if (logs[i].topics[0] == IV5Events.Compounded.selector) {
                assertEq(uint256(logs[i].topics[1]), idA, "only book A compounds");
                (uint256 u,) = abi.decode(logs[i].data, (uint256, uint256));
                usdIn += u;
                n++;
            }
        }
        assertEq(n, 1, "one item credited");
        assertEq(usdIn, feesA, "exactly book A's own credit is spent");
        S.Pos memory pB1 = lens.position(idB, 1, C.OTHERS, backer1);
        assertEq(pB1.checkpoint, pB0.checkpoint, "book B's position was not touched");
        assertEq(lens.claimable(backer1), 0, "nothing of B credited by the batch");

        // B's fees are still USDG, all of them
        (uint256[] memory ids, uint32[] memory gens) = _one(idB);
        vm.prank(backer1);
        assertEq(v5.collect(ids, gens), feesB, "book B's fees paid in USDG, whole");
        assertTrue(_solvent());
    }

    /// @dev A credit already in `claimable` (book A's own, moved there by an earlier touch) is not spent either: it
    ///      waits for `collect`.
    function test_M01_earlierCreditWaitsForCollect() public {
        uint256 feesA = _creditOf(idA);
        // a touch of A's position moves its credit into claimable (a 1,000 $PRIORS back by the backer)
        _back(backer1, idA, 1_000 * T);
        vm.prank(backer1);
        v5.setAutoAdd(idA, true);
        assertEq(lens.claimable(backer1), feesA);
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(idA, backer1);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.CompoundTooSmall.selector);
        v5.compound(items, 0);
        assertEq(lens.claimable(backer1), feesA, "kept as USDG");
    }
}

/// @dev L-01: points a hook voids (a settle inside `onDefault`, a close inside `onRelease`) are erased from the global
///      totals at the book's next first steps.
contract V5FixPointsTest is V5Base {
    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    /// @dev Two books with the same points in this epoch; returns the epoch and one book's points.
    function _earn(uint256 a, uint256 b) internal returns (uint256 e, uint256 pts) {
        _open(a, 150_001 * T);
        _open(b, 150_001 * T);
        uint256 la = _borrow(a, 25 * U, 8 days);
        uint256 lb = _borrow(b, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(la);
        _repay(lb);
        v5.pokeFees(a);
        v5.pokeFees(b);
        e = lens.epochOf(block.timestamp);
        pts = lens.bookPoints(a, e);
        assertGt(pts, 0);
        assertEq(lens.bookPoints(b, e), pts);
        assertEq(lens.globalPoints(e), 2 * pts);
    }

    function test_L01_onDefault_voidedPointsErasedAtNextSteps() public {
        (uint256 e, uint256 pts) = _earn(agents[0], agents[1]);
        uint256 l = _borrow(agents[1], 25 * U, 1 days);
        _skipFresh(4 days + 1);
        pool.markDefault(l); // settles inside onDefault
        assertTrue(_gen(agents[1]).pointsVoid);
        assertEq(lens.bookPoints(agents[1], e), 0, "void: reads 0 at once");
        assertEq(lens.globalPoints(e), 2 * pts, "only flagged inside the hook");
        v5.pokeFees(agents[1]);
        assertFalse(_gen(agents[1]).pointsVoid);
        assertEq(lens.globalPoints(e), pts, "erased at the next first steps");
        v5.pokeFees(agents[1]); // once only
        assertEq(lens.globalPoints(e), pts);
        assertEq(lens.bookPoints(agents[0], e), pts, "the other book's points untouched");
    }

    function test_L01_onRelease_voidedPointsErasedAtNextSteps() public {
        (uint256 e, uint256 pts) = _earn(agents[0], agents[1]);
        vm.prank(_owner(agents[1]));
        pool.leave(agents[1]); // onRelease closes the book inside the hook
        assertTrue(_gen(agents[1]).pointsVoid);
        assertEq(lens.globalPoints(e), 2 * pts);
        // any book call runs the first steps: here the owner's collect of the generation
        uint256[] memory ids = new uint256[](1);
        uint32[] memory gens = new uint32[](1);
        ids[0] = agents[1];
        gens[0] = 1;
        vm.prank(_owner(agents[1]));
        v5.collect(ids, gens);
        assertEq(lens.globalPoints(e), pts, "erased");
        assertEq(_gen(agents[1]).points[e % 5].points, 0);
    }
}

/// @dev L-02: a close inside `onRelease` records its time; the deferred move uses it for the bucket's day, the layer's
///      end and the 7-day release clock.
contract V5FixReleaseClockTest is V5Base {
    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function test_L02_deferredMove_joinsTheCloseDaysBucket_clockFromTheClose() public {
        uint256 id = agents[0];
        _open(id, 150_001 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _back(backer1, id, 50_000 * T);
        _back(backer2, id, 20_000 * T);
        _skipFresh(1 days);
        v5.pokeFees(id);
        // backer2 leaves first: today's bucket exists before the close
        vm.prank(backer2);
        v5.leave(id, 20_000 * T, 1);
        uint32 d = _today();
        uint64 leftAt = uint64(block.timestamp);
        _skip(1 hours);
        uint64 closedAt = uint64(block.timestamp);
        vm.prank(_owner(id));
        pool.leave(id);
        assertEq(_gen(id).movePendingAt, closedAt);
        assertEq(lens.leavingBucket(id, 1, C.OTHERS, d).latestLeave, leftAt);

        // three days later the first touch moves every layer as of the close
        _skipFresh(3 days);
        v5.pokeFees(id);
        S.Gen memory g = _gen(id);
        assertFalse(g.movePending);
        for (uint8 layer = 0; layer < 3; layer++) {
            assertEq(g.layerEnd[layer], closedAt, "each layer ended at the close");
        }
        S.Leaving memory b = lens.leavingBucket(id, 1, C.OTHERS, d);
        assertEq(b.latestLeave, closedAt, "the close's day's bucket, its latest leave the close");
        assertEq(b.counted, 70_000 * T, "backer2's leave and backer1's forced move in one bucket");
        assertEq(lens.leavingBucket(id, 1, C.OWNER, d).latestLeave, closedAt);
        assertEq(lens.leavingBucket(id, 1, C.OTHERS, _today()).exists, false, "no bucket on the touch's day");

        // releasable 7 days after the close, not 7 after the touch
        _skip(uint256(closedAt) + 7 days - block.timestamp - 1);
        _keeperPass(P0);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.releaseFor(id, 1, backer1, d);
        _skipFresh(1);
        v5.releaseFor(id, 1, backer1, d);
        v5.releaseFor(id, 1, backer2, d);
        v5.finishClose(id, 1);
        assertEq(lens.leavingBucket(id, 1, C.OTHERS, d).releasableAt, closedAt + 7 days);
    }
}

/// @dev Found re-running the audit's invariant campaign: `claimSettled` of BuyAndBack's live C position on a settled
///      generation lowered C's units but not C's live part, breaking `cUnits >= cLive` (AuditInvariant's structure).
contract V5FixCLiveTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        priors.mint(bb, 10_000_000 * T);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 25 * U, 8 days);
        uint256 b = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        uint256 c = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(c);
        v5.promote(id);
    }

    function test_claimSettled_liveC_lowersCLive() public {
        vm.prank(bb);
        v5.back(id, 10_000 * T, false);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        assertEq(_gen(id).cLive, 10_000 * T);
        uint256 l = _borrow(id, 50 * U, 8 days);
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        assertEq(_gen(id).status, C.SETTLED);
        v5.claimSettled(id, 1, bb);
        S.Gen memory g = _gen(id);
        assertEq(g.cUnits, 0, "C paid");
        assertEq(g.cLive, 0, "and out of C's live part");
        assertEq(lens.cReturned(), 5_000 * T, "half of C burned, half back to BuyAndBack");
    }

    /// @dev L-03: C's opt-out moves its one position: `LayerMoved` with BuyAndBack as the holder.
    function test_L03_optOut_emitsLayerMovedForC() public {
        vm.prank(bb);
        v5.back(id, 10_000 * T, false);
        vm.recordLogs();
        vm.prank(_owner(id));
        v5.setProtocolBacking(id, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IV5Events.LayerMoved.selector) continue;
            (uint8 layer, address holder, uint32 day, uint64 at, uint256 cnt, uint256 unc) =
                abi.decode(logs[i].data, (uint8, address, uint32, uint64, uint256, uint256));
            assertEq(layer, C.OWN);
            assertEq(holder, bb);
            assertEq(day, _today());
            assertEq(at, block.timestamp);
            assertEq(cnt, 0);
            assertEq(unc, 10_000 * T, "pending C, uncounted");
            n++;
        }
        assertEq(n, 1);
    }
}

/// @dev L-03: events that match state.
contract V5FixEventsTest is V5Base {
    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public override {
        super.setUp();
        vm.prank(timelock);
        v5.setOpenBacking(true);
    }

    struct Bk {
        uint8 layer;
        uint256 tokens;
        uint256 usdgIn;
    }

    function _backed(Vm.Log[] memory logs) internal pure returns (Bk[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IV5Events.Backed.selector) n++;
        }
        out = new Bk[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IV5Events.Backed.selector) continue;
            (out[n].layer, out[n].tokens, out[n].usdgIn) = abi.decode(logs[i].data, (uint8, uint256, uint256));
            n++;
        }
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) n++;
        }
    }

    /// @dev The owner's top-up: all into A, split over A and its own backing, all into its own backing; one event per
    ///      layer credited, each matching the state, the call's USDG on the first.
    function test_L03_ownerTopUp_backedPerLayer() public {
        uint256 id = agents[0];
        _open(id, 100_000 * T); // A = 100,000; capA at T1 = 150,000 at P0
        address o = _owner(id);

        vm.recordLogs();
        vm.prank(o);
        v5.back(id, 20_000 * T, false);
        Bk[] memory b = _backed(vm.getRecordedLogs());
        assertEq(b.length, 1);
        assertEq(b[0].layer, C.OWNER, "into A");
        assertEq(b[0].tokens, 20_000 * T);
        assertEq(_gen(id).pendingTok[C.OWNER], 20_000 * T);

        // 40,000 more with 5 USDG swapped in: A takes 30,000 (up to 150,000), its own backing the rest
        uint256 ownBefore = _gen(id).pendingTok[C.OWN];
        vm.recordLogs();
        vm.prank(o);
        v5.backWithUsdg(id, 40_000 * T, 5 * U, 0, block.timestamp, false);
        b = _backed(vm.getRecordedLogs());
        S.Gen memory g = _gen(id);
        assertEq(b.length, 2);
        assertEq(b[0].layer, C.OWNER);
        assertApproxEqAbs(b[0].tokens, 30_000 * T, 1 * T);
        assertEq(b[0].usdgIn, 5 * U, "the call's USDG on the first event");
        assertEq(b[1].layer, C.OWN);
        assertEq(b[1].usdgIn, 0);
        assertEq(g.pendingTok[C.OWNER], 20_000 * T + b[0].tokens, "A's pending matches the OWNER events");
        assertEq(g.pendingTok[C.OWN] - ownBefore, b[1].tokens, "its own backing matches the OWN event");

        // A at its cap: everything into its own backing, the USDG on that one event
        vm.recordLogs();
        vm.prank(o);
        v5.backWithUsdg(id, 1_000 * T, 2 * U, 0, block.timestamp, false);
        b = _backed(vm.getRecordedLogs());
        assertEq(b.length, 1);
        assertEq(b[0].layer, C.OWN);
        assertEq(b[0].usdgIn, 2 * U);
        assertEq(_gen(id).pendingTok[C.OWNER], g.pendingTok[C.OWNER], "A unchanged");
    }

    /// @dev Every forced move of a whole layer announces itself: an owner's close (three layers) and an owner change
    ///      (the two backing layers), each with its bucket's day, its time and its stake.
    function test_L03_forcedMoves_emitLayerMoved() public {
        uint256 id = agents[0];
        _open(id, 150_001 * T);
        _back(backer1, id, 40_000 * T);
        _skipFresh(1 days);
        v5.pokeFees(id);
        _back(backer2, id, 5_000 * T); // pending at the move: uncounted

        // an owner change: OTHERS and OWN move
        address o = _owner(id);
        vm.prank(o);
        reg.transferFrom(o, makeAddr("buyer"), id);
        vm.recordLogs();
        v5.pokeFees(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, IV5Events.LayerMoved.selector), 2);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IV5Events.LayerMoved.selector) continue;
            (uint8 layer, address holder, uint32 day, uint64 at, uint256 cnt, uint256 unc) =
                abi.decode(logs[i].data, (uint8, address, uint32, uint64, uint256, uint256));
            assertEq(holder, address(0), "a whole layer");
            assertEq(day, _today());
            assertEq(at, block.timestamp);
            if (layer == C.OTHERS) {
                assertEq(cnt, 40_000 * T);
                assertEq(unc, 5_000 * T);
                assertEq(lens.leavingBucket(id, 1, C.OTHERS, day).counted, cnt, "matches the bucket");
            } else {
                assertEq(layer, C.OWN);
            }
        }

        // the close (by anyone, after the owner change): the owner layer moves now
        vm.recordLogs();
        vm.prank(anyone);
        v5.close(id, 1);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, IV5Events.LayerMoved.selector), 1, "only A was still live");
    }

    /// @dev `BreakerRecorded` fires only for a default the breaker enters in its buckets.
    function test_L03_breakerRecorded_onlyForCountedDefaults() public {
        uint256 id = agents[0];
        _open(id, 150_001 * T);
        // a default in the second of a clear(): seen, counted in recordedDefaults, not in the buckets, no event
        uint256 l = _borrow(id, 25 * U, 1 days);
        _skipFresh(4 days + 1);
        vm.prank(guardian);
        v5.clear();
        vm.recordLogs();
        pool.markDefault(l);
        assertEq(_count(vm.getRecordedLogs(), IV5Events.BreakerRecorded.selector), 0, "not counted: no event");
        assertTrue(lens.loanRecord(l).breakerSeen);

        // a default the breaker counts: announced
        uint256 id2 = agents[1];
        _skipFresh(1);
        _open(id2, 150_001 * T);
        uint256 l2 = _borrow(id2, 25 * U, 1 days);
        _skipFresh(4 days + 1);
        vm.recordLogs();
        pool.markDefault(l2);
        assertEq(_count(vm.getRecordedLogs(), IV5Events.BreakerRecorded.selector), 1, "counted: one event");
    }

    /// @dev Through `recordDefault` (the hook failed): a default older than the last clear() is seen, not counted, and
    ///      not announced; a later one is.
    function test_L03_recordDefault_breakerRecordedOnlyWhenCounted() public {
        uint256 id = agents[0];
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 25 * U, 1 days);
        _skipFresh(4 days + 1);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "fail");
        pool.markDefault(l);
        vm.clearMockedCalls();
        _skipFresh(1);
        vm.prank(guardian);
        v5.clear();
        vm.recordLogs();
        v5.recordDefault(l);
        assertEq(_count(vm.getRecordedLogs(), IV5Events.BreakerRecorded.selector), 0, "before the clear: no event");
        assertTrue(lens.loanRecord(l).breakerSeen);
    }
}

/// @dev L-04: `queueExit` is the record's holder's or V5's keeper's, and values question 43's $25 floor at
///      min(cached median, week low), never at live spot.
contract V5FixQueueExitTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _open(id, 150_001 * T);
    }

    function _usdgLeave(address who, uint256 tokens) internal returns (uint32 d) {
        _back(who, id, tokens);
        _skipFresh(1 days);
        vm.prank(who);
        v5.leave(id, tokens, 2);
        d = _today();
        _skipFresh(8 days);
    }

    function test_L04_onlyTheHolderOrTheKeeper() public {
        uint32 d = _usdgLeave(backer1, 30_000 * T);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        vm.prank(backer2);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        vm.prank(guardian);
        v5.stopKeeper(); // a stopped keeper is address(0): nobody calls as it
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        vm.prank(backer1);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        assertGt(lens.record(id, 1, C.OTHERS, d, backer1).entry, 0);
    }

    function test_L04_keeperQueues_atADumpedSpot_floorAtTheMedian() public {
        uint32 d = _usdgLeave(backer1, 30_000 * T); // $30 at the median
        _setSpot(P0 * 75 / 100); // live spot 25% under
        vm.prank(keeper);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        S.Rec memory r = lens.record(id, 1, C.OTHERS, d, backer1);
        assertEq(r.mode, 2);
        assertGt(r.entry, 0, "joins: the floor ignores live spot");
    }

    function test_L04_pumpedSpotCannotLiftADustRecord() public {
        uint32 d = _usdgLeave(backer1, 20_000 * T); // $20 at the median
        _setSpot(P0 * 2); // live spot doubled: $40 at spot
        vm.prank(backer1);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        S.Rec memory r = lens.record(id, 1, C.OTHERS, d, backer1);
        assertEq(r.mode, 1, "under $25 at the median: set to mode 1");
        assertEq(r.entry, 0);
    }
}

/// @dev I-01: V5's first `fund()` imports its root's v1 history before reading `childBase`, and refuses a root whose
///      import could still come later; after it, `importFromV1(root)` can never change the root's count.
contract V5FixImportV1Test is V5Base {
    MockV1Pool internal v1;

    function _v1() internal override returns (address) {
        v1 = new MockV1Pool();
        return address(v1);
    }

    /// @dev A fresh V5 on a fresh root identity, the root handed to it, not yet funded.
    function _freshV5() internal returns (SeatVaultV5 fresh, uint256 root) {
        root = reg.register("another-v5-root");
        SeatVaultV5.Init memory i = _baseInit();
        i.rootId = root;
        fresh = new SeatVaultV5(i);
        reg.safeTransferFrom(address(this), address(fresh), root);
        usdg.mint(address(this), 1_000 * U);
        usdg.approve(address(fresh), type(uint256).max);
    }

    function _childBase(SeatVaultV5 x) internal view returns (uint256) {
        return uint256(vm.load(address(x), bytes32(uint256(S.SLOT) + 7)));
    }

    function test_I01_noV1Record_fundsAndImportStaysImpossible() public {
        // setUp's V5 funded with a v1 that has no record of its root: InvalidAgent, accepted
        vm.expectRevert(abi.encodeWithSignature("InvalidAgent(uint256)", ROOT));
        pool.importFromV1(ROOT);
    }

    function test_I01_v1History_importedAtTheFirstFund_beforeChildBase() public {
        (SeatVaultV5 fresh, uint256 root) = _freshV5();
        v1.set(root, uint64(block.timestamp - 30 days), 0, 4, 2); // a v1 history with 2 children defaulted
        fresh.fund(100 * U);
        assertTrue(pool.getAgent(root).importedFromV1, "imported by the first fund");
        assertEq(pool.getAgent(root).childrenDefaulted, 2);
        assertEq(_childBase(fresh), 2, "childBase counts from after the import");
        vm.expectRevert(abi.encodeWithSignature("AlreadyImported(uint256)", root));
        pool.importFromV1(root); // nobody can add v1's defaults later
    }

    function test_I01_alreadyImportedBeforeFund_accepted() public {
        (SeatVaultV5 fresh, uint256 root) = _freshV5();
        v1.set(root, uint64(block.timestamp - 30 days), 0, 4, 1);
        pool.importFromV1(root); // anyone, before V5's first fund
        fresh.fund(100 * U);
        assertEq(_childBase(fresh), 1);
    }

    function test_I01_v1Busy_refusesTheFund() public {
        (SeatVaultV5 fresh, uint256 root) = _freshV5();
        v1.set(root, uint64(block.timestamp - 30 days), 1, 4, 2); // a v1 loan open: import refused for now
        vm.expectRevert(IV5Errors.RootNotReady.selector);
        fresh.fund(100 * U);
        v1.set(root, uint64(block.timestamp - 30 days), 0, 4, 2); // once v1 is clear, the fund goes through
        fresh.fund(100 * U);
        assertEq(_childBase(fresh), 2);
    }
}

/// @dev I-02: V5 accepts by safe transfer only its own root identity from the registry.
contract V5FixErc721Test is V5Base {
    function _agentCount() internal pure override returns (uint256) {
        return 1;
    }

    function test_I02_refusesAnyOtherToken_acceptsItsRoot() public {
        uint256 id = agents[0];
        address o = _owner(id);
        vm.prank(o);
        vm.expectRevert(IV5Errors.BadTransfer.selector);
        reg.safeTransferFrom(o, address(v5), id);
        assertEq(reg.ownerOf(id), o);

        // another ERC-721 contract, even with the root's token id
        MockRegistryV5 other = new MockRegistryV5();
        uint256 tid;
        while (tid != ROOT) tid = other.register("x");
        vm.expectRevert(IV5Errors.BadTransfer.selector);
        other.safeTransferFrom(address(this), address(v5), ROOT);

        // the root itself, from the registry: accepted (a fresh V5 on a fresh root, as setUp did for this one)
        uint256 root = reg.register("root-2");
        SeatVaultV5.Init memory i = _baseInit();
        i.rootId = root;
        SeatVaultV5 fresh = new SeatVaultV5(i);
        reg.safeTransferFrom(address(this), address(fresh), root);
        assertEq(reg.ownerOf(root), address(fresh));
        vm.expectRevert(IV5Errors.BadTransfer.selector); // a direct call is not the registry
        fresh.onERC721Received(address(0), address(0), root, "");
    }
}
