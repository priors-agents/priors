// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {MockSwapper} from "./V5Mocks.sol";

/// @dev The release rule and every payout path that is not the exit queue (2.5, 2.6, 2.7, 2.4's closes).
contract V5ExitsTest is V5Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = agents[0];
        _open(id, 140_000 * T); // under 3 × the ceiling at P: all of it is A
        vm.prank(timelock);
        v5.setOpenBacking(true);
    }

    function _leaveAll(address who, uint8 mode) internal returns (uint32 d) {
        S.Pos memory p = lens.position(id, lens.latestGen(id), C.OTHERS, who);
        vm.prank(who);
        v5.leave(id, p.counted + p.a0 + p.a1, mode);
        d = _today();
    }

    // ------------------------------------------------------------------
    // the release rule (2.5)
    // ------------------------------------------------------------------

    function test_release_sevenDaysFromTheBucketsLatestLeave_afterTheDayEnds() public {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1 hours);
        _keeperPass(P0);
        _back(backer1, id, 10_000 * T);
        _back(backer2, id, 10_000 * T);
        uint32 d = _leaveAll(backer1, 0);
        _skip(5 hours);
        _leaveAll(backer2, 0); // the same bucket: its latest leave moves
        _skipFresh(7 days - 5 hours);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.release(id, 1, d, 0, 0);
        _skipFresh(5 hours);
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0);
        assertEq(
            lens.leavingBucket(id, 1, C.OTHERS, d).releasableAt,
            lens.leavingBucket(id, 1, C.OTHERS, d).latestLeave + 7 days
        );
    }

    function test_release_waitsForLoansUpToTheBucketsCount_andPaysAfterTheirClose() public {
        _back(backer1, id, 10_000 * T);
        uint256 l = _borrow(id, 40 * U, 10 days);
        uint32 d = _leaveAll(backer1, 0);
        _skipFresh(8 days);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.release(id, 1, d, 0, 0);
        _skipFresh(1 days);
        _repay(l);
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0);
        assertEq(lens.leavingBucket(id, 1, C.OTHERS, d).releasableAt, pool.getLoan(l).closedAt);
    }

    function test_release_marksAnOverdueLoanFirst_andBurnsTheLeaver() public {
        _back(backer1, id, 10_000 * T);
        uint32 d = _leaveAll(backer1, 0);
        // a loan taken after the leave still reaches the leaving stake (A-F11)
        uint256 l = _borrow(id, 40 * U, 1 days);
        _skipFresh(8 days);
        uint256 b0 = priors.balanceOf(backer1);
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0);
        assertEq(uint8(pool.getLoan(l).status), uint8(ICreditPoolV2.LoanStatus.Defaulted));
        assertEq(_gen(id).status, C.SETTLED);
        assertEq(priors.balanceOf(backer1) - b0, 5_000 * T, "half burned");
    }

    function test_release_hookStarvedRevertsTheWholeRelease() public {
        _back(backer1, id, 10_000 * T);
        uint32 d = _leaveAll(backer1, 0);
        _borrow(id, 40 * U, 1 days);
        _skipFresh(8 days);
        // markDefault reverting HookStarved (as PoolV2Lib does when its caller starves a hook)
        vm.mockCallRevert(
            address(pool), abi.encodeWithSignature("markDefault(uint256)"), abi.encodeWithSignature("HookStarved()")
        );
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSignature("HookStarved()"));
        v5.release(id, 1, d, 0, 0);
        // any other failure only delays the release
        vm.mockCallRevert(address(pool), abi.encodeWithSignature("markDefault(uint256)"), "nope");
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.release(id, 1, d, 0, 0);
        vm.clearMockedCalls();
    }

    function test_release_supersededGenerationNeedsOnlySevenDays() public {
        _back(backer1, id, 10_000 * T);
        _skipFresh(1 days);
        uint32 d = _leaveAll(backer1, 0);
        // idle close of a book that never borrowed, reopen at once, borrow on the new generation
        _skipFresh(30 days);
        v5.expire(id);
        _open(id, 150_000 * T);
        uint256 l = _borrow(id, 40 * U, 10 days);
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0); // gen 1 can never burn: paid while gen 2's loan is open
        assertEq(priors.balanceOf(backer1), 100_000_000 * T);
        // and gen 2's default reaches nothing of gen 1
        _skipFresh(14 days);
        pool.markDefault(l);
        assertEq(lens.getGen(id, 1).status, C.CLOSED);
    }

    // ------------------------------------------------------------------
    // release with USDG (2.5)
    // ------------------------------------------------------------------

    function _leftRecord() internal returns (uint32 d) {
        _back(backer1, id, 10_000 * T);
        d = _leaveAll(backer1, 0);
        _skipFresh(8 days);
    }

    function test_release_usdg_soldToTheHolder() public {
        uint32 d = _leftRecord();
        uint256 u0 = usdg.balanceOf(backer1);
        vm.prank(backer1);
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        assertApproxEqAbs(usdg.balanceOf(backer1) - u0, 9_700_000, 1, "$10 less the hook's 3%");
        assertEq(priors.allowance(address(v5), address(swapper)), 0);
    }

    function test_release_usdg_frozenHolderTakesPriors() public {
        uint32 d = _leftRecord();
        usdg.freeze(backer1, true);
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(backer1);
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        assertEq(priors.balanceOf(backer1) - p0, 10_000 * T);
    }

    function test_release_usdg_namedErrors() public {
        uint32 d = _leftRecord();
        // isFrozen read fails
        usdg.setFrozenMode(1);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 3));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        usdg.setFrozenMode(3);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 3));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        usdg.setFrozenMode(0);
        // depth guard
        limiter.setDepthTerm(400e6, 5_000e6, 60, true);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 4));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        // stale cache
        _skip(46 minutes);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 1));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        _keeperPass(P0);
        // above the live cap
        limiter.setCap(5 * U, true);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.SplitNeeded.selector, 9_999_999, 5 * U));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        limiter.setCap(2_169e6, true);
        // the swapper's own errors pass through
        vm.prank(backer1);
        vm.expectPartialRevert(MockSwapper.TooLittleOut.selector);
        v5.release(id, 1, d, 10 * U, block.timestamp + 60);
        vm.prank(backer1);
        vm.expectRevert(MockSwapper.Expired.selector);
        v5.release(id, 1, d, 9 * U, block.timestamp - 1);
        // any other failure is UsdgPathClosed(5)
        swapper.setBroken(true);
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 5));
        v5.release(id, 1, d, 9 * U, block.timestamp + 60);
        swapper.setBroken(false);
        // the stake stayed releasable through all of it
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0);
    }

    function test_release_reverts_noRecord() public {
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.release(id, 1, _today(), 0, 0);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.release(agents[1], 1, _today(), 0, 0);
    }

    // ------------------------------------------------------------------
    // releaseFor (anyone)
    // ------------------------------------------------------------------

    function test_releaseFor_modeOne_onceReleasable() public {
        _back(backer1, id, 10_000 * T);
        uint32 d = _leaveAll(backer1, 1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.releaseFor(id, 1, backer1, d);
        _skipFresh(8 days);
        vm.prank(anyone);
        v5.releaseFor(id, 1, backer1, d);
        assertEq(priors.balanceOf(backer1), 100_000_000 * T);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.releaseFor(id, 1, backer1, d);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.releaseFor(agents[1], 1, backer1, d);
    }

    function test_releaseFor_parkedStake_threeDaysAfterReleasable() public {
        _back(backer1, id, 10_000 * T);
        uint32 d = _leaveAll(backer1, 0);
        _skipFresh(8 days);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.releaseFor(id, 1, backer1, d);
        _skipFresh(3 days);
        v5.releaseFor(id, 1, backer1, d);
        assertEq(priors.balanceOf(backer1), 100_000_000 * T);
    }

    // ------------------------------------------------------------------
    // close, expire, sync(id), onRelease
    // ------------------------------------------------------------------

    function test_close_byOwner_finishClose_returnsA() public {
        _back(backer1, id, 10_000 * T);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.close(id, 1);
        vm.prank(_owner(id));
        v5.close(id, 0);
        S.Gen memory g = _gen(id);
        assertEq(g.status, C.CLOSED);
        assertEq(g.counted[C.OWNER], 0);
        assertEq(g.leavingLive[C.OWNER], 140_000 * T);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.finishClose(id, 1);
        _skipFresh(8 days);
        uint256 p0 = priors.balanceOf(_owner(id));
        v5.finishClose(id, 1);
        assertEq(priors.balanceOf(_owner(id)) - p0, 140_000 * T);
        // the backer's position resolves into its forced-move record (mode 1)
        v5.releaseFor(id, 1, backer1, uint32(g.layerEnd[C.OTHERS] / 1 days));
        assertEq(priors.balanceOf(backer1), 100_000_000 * T);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        vm.prank(_owner(id));
        v5.close(id, 0);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        vm.prank(_owner(id));
        v5.close(id, 3);
    }

    function test_close_withLoanOpen_finishCloseWaits() public {
        uint256 l = _borrow(id, 40 * U, 10 days);
        vm.prank(_owner(id));
        v5.close(id, 1);
        assertFalse(v5.canBorrow(ROOT, id, 5 * U, 1 days, 1, _owner(id), _owner(id), _owner(id)));
        _skipFresh(8 days);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.finishClose(id, 1);
        _skipFresh(1 days);
        _repay(l);
        v5.finishClose(id, 1);
    }

    function test_close_byAnyoneAfterOwnerChange_modeOne() public {
        vm.prank(_owner(id));
        reg.transferFrom(_owner(id), makeAddr("buyer"), id);
        vm.prank(anyone);
        v5.close(id, 2);
        S.Gen memory g = _gen(id);
        assertTrue(g.ownerChanged);
        S.Rec memory r = lens.record(id, 1, C.OWNER, uint32(g.layerEnd[C.OWNER] / 1 days), g.owner);
        assertEq(r.counted, 0, "lazy: resolved at its next touch");
        _skipFresh(8 days);
        address poster = g.owner;
        uint256 p0 = priors.balanceOf(poster);
        v5.finishClose(id, 1);
        assertEq(priors.balanceOf(poster) - p0, 140_000 * T, "back to the address that posted A");
    }

    function test_close_refusesADefaultedAgent() public {
        uint256 l = _borrow(id, 40 * U, 1 days);
        _skipFresh(5 days);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "fail");
        pool.markDefault(l);
        vm.clearMockedCalls();
        // the first steps settle the generation (its listed loan is Defaulted): the book is no longer open
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.close(id, 1);
    }

    function test_expire_idleThirtyDays() public {
        uint256 l = _borrow(id, 40 * U, 8 days);
        vm.expectRevert(IV5Errors.NotIdle.selector);
        v5.expire(id);
        _skipFresh(8 days);
        _repay(l);
        _skipFresh(29 days);
        vm.expectRevert(IV5Errors.NotIdle.selector);
        v5.expire(id);
        _skipFresh(1 days);
        v5.expire(id);
        assertEq(_gen(id).status, C.CLOSED);
        assertEq(lens.reopenAt(id), block.timestamp + 30 days, "it borrowed: the ban applies");
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.expire(id);
    }

    function test_onRelease_agentLeavesInThePool_closesWithNoBurn() public {
        _back(backer1, id, 10_000 * T);
        vm.prank(_owner(id));
        v5.refresh(id);
        vm.prank(_owner(id));
        pool.leave(id);
        S.Gen memory g = _gen(id);
        assertEq(g.status, C.CLOSED);
        assertTrue(g.pointsVoid);
        assertEq(lens.reopenAt(id), block.timestamp + 30 days);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.sync(id);
    }

    function test_syncId_closesWhenTheHookFailed() public {
        vm.prank(_owner(id));
        v5.refresh(id);
        vm.expectRevert(IV5Errors.StillSponsored.selector);
        v5.sync(id);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onRelease.selector), "fail");
        vm.prank(_owner(id));
        pool.leave(id);
        vm.clearMockedCalls();
        assertEq(_gen(id).status, C.OPEN, "the hook failed");
        v5.sync(id);
        assertEq(_gen(id).status, C.CLOSED);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.sync(agents[1]);
    }

    // ------------------------------------------------------------------
    // claimSettled (2.6)
    // ------------------------------------------------------------------

    function test_claimSettled_positionsAndRecords_once() public {
        _back(backer1, id, 10_000 * T);
        _back(backer2, id, 20_000 * T);
        _skipFresh(1 days);
        uint32 d = _leaveAll(backer2, 2);
        uint256 l = _borrow(id, 45 * U, 1 days);
        vm.expectRevert(IV5Errors.NotSettled.selector);
        v5.claimSettled(id, 1, backer1);
        _skipFresh(5 days);
        pool.markDefault(l);
        v5.claimSettled(id, 1, backer1);
        assertEq(priors.balanceOf(backer1), 100_000_000 * T - 5_000 * T);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.claimSettled(id, 1, backer1);
        v5.claimSettled(id, 1, backer2, C.OTHERS, d);
        assertEq(priors.balanceOf(backer2), 100_000_000 * T - 10_000 * T);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.claimSettled(id, 1, backer2, C.OTHERS, d);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.claimSettled(id, 1, backer2, 3, d);
        // the owner's 25%
        uint256 p0 = priors.balanceOf(_owner(id));
        v5.claimSettled(id, 1, _owner(id));
        S.Gen memory g = _gen(id);
        assertApproxEqAbs(priors.balanceOf(_owner(id)) - p0, 140_000 * T / 4, 1e12);
        g;
        (uint256 led,) = _ledger();
        assertEq(priors.balanceOf(address(v5)), led, "only accounted dust left");
        assertLt(led, 10, "dust");
    }

    // ------------------------------------------------------------------
    // fees out (2.7)
    // ------------------------------------------------------------------

    function test_collect_paysTheFeesCredited_afterTheStakeCounted() public {
        _back(backer1, id, 50_000 * T);
        uint256 l1 = _borrow(id, 45 * U, 10 days);
        _skipFresh(1 days);
        v5.pokeFees(id); // the keeper's poke: the stake merges before the fee arrives
        _skipFresh(9 days);
        _repay(l1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        uint256 u0 = usdg.balanceOf(backer1);
        vm.prank(backer1);
        uint256 paid = v5.collect(ids, gens);
        assertEq(usdg.balanceOf(backer1) - u0, paid);
        // fee 1% × 45 × 10/30 = 150,000 → sponsor cut 37,500 → book 28,125 → backer1's 50k of 190k = 7,401
        assertApproxEqAbs(paid, 7_401, 1);
        assertTrue(_solvent());
        vm.prank(backer1);
        assertEq(v5.collect(ids, gens), 0);
        uint32[] memory bad = new uint32[](2);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.collect(ids, bad);
    }

    function test_collect_revertsWhenV5CannotCover_creditsKept() public {
        uint256 l1 = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l1);
        v5.pokeFees(id);
        reg.setMode(1); // the claim fails (the pool's ownerOf for V5's root)
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.ClaimShort.selector);
        v5.collect(ids, gens);
        reg.setMode(0);
        vm.prank(_owner(id));
        assertGt(v5.collect(ids, gens), 0);
    }

    function test_flush_bufferToTheRoot_cToBuyAndBack_onlyWhenCovered() public {
        uint256 l1 = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l1);
        v5.pokeFees(id);
        (uint256 h, uint256 buf,,,,,) = lens.totals();
        assertGt(buf, 0);
        uint256 shares0 = pool.rootShares(ROOT);
        v5.flush();
        (, uint256 buf2,,,,,) = lens.totals();
        assertEq(buf2, 0);
        assertGt(pool.rootShares(ROOT), shares0);
        assertTrue(_solvent());
        h;
        // a pool pause holds back only the buffer
        uint256 l2 = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l2);
        v5.pokeFees(id);
        vm.prank(guardian);
        pool.pause();
        v5.flush();
        (, buf2,,,,,) = lens.totals();
        assertGt(buf2, 0);
    }
}
