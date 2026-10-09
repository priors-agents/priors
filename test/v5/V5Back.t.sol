// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {V5Lens} from "../../src/v5/V5Lens.sol";

/// @dev `back`, `backWithUsdg`, the warm-up and the merges, `leave`, and the bound owner's switches (2.2, 2.5, 2.7).
contract V5BackTest is V5Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = agents[0];
        _open(id, 150_000 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
    }

    // ------------------------------------------------------------------
    // back
    // ------------------------------------------------------------------

    function test_back_others_pendingThenMerged() public {
        vm.expectEmit(true, true, true, true, address(v5));
        emit IV5Events.Backed(id, 1, backer1, C.OTHERS, 10_000 * T, 0);
        _back(backer1, id, 10_000 * T);
        S.Gen memory g = _gen(id);
        assertEq(g.pendingTok[C.OTHERS], 10_000 * T);
        assertEq(g.counted[C.OTHERS], 0);
        S.Pos memory p = lens.position(id, 1, C.OTHERS, backer1);
        // the slot of today's parity (UTC day + 1)
        bool even = (_today() + 1) % 2 == 0;
        assertEq(even ? p.a0 : p.a1, 10_000 * T);
        assertEq(even ? p.d0 : p.d1, _today() + 1);
        // 23 h later a poke merges nothing
        _skipFresh(23 hours);
        v5.pokeFees(id);
        assertEq(_gen(id).counted[C.OTHERS], 0);
        _skipFresh(1 hours);
        v5.pokeFees(id);
        g = _gen(id);
        assertEq(g.counted[C.OTHERS], 10_000 * T);
        assertEq(g.pendingTok[C.OTHERS], 0);
        assertEq(g.divisor, g.counted[C.OWNER] + g.counted[C.OWN] + 10_000 * T);
    }

    function test_back_laterDepositSameDay_delaysTheWholeBucket() public {
        // land the first deposit at 00:30 UTC of a day, the second at 20:00 the same day
        uint256 dayStart = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(dayStart + 30 minutes);
        _keeperPass(P0);
        _back(backer1, id, 10_000 * T);
        vm.warp(dayStart + 20 hours);
        _keeperPass(P0);
        _back(backer2, id, 10_000 * T);
        vm.warp(dayStart + 1 days + 1 hours); // 24.5 h after the first, 5 h after the second
        _keeperPass(P0);
        v5.pokeFees(id);
        assertEq(_gen(id).counted[C.OTHERS], 0, "the later deposit holds the bucket");
        vm.warp(dayStart + 1 days + 20 hours);
        _keeperPass(P0);
        v5.pokeFees(id);
        assertEq(_gen(id).counted[C.OTHERS], 20_000 * T);
    }

    function test_back_ownerTopUp_intoA_untilThreeCeilings_restOwnBacking() public {
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        uint256 aNow = _gen(id).counted[C.OWNER];
        uint256 roomA = n.capA - aNow;
        _back(_owner(id), id, roomA + 20_000 * T);
        S.Gen memory g = _gen(id);
        assertEq(g.pendingTok[C.OWNER], roomA);
        assertEq(g.pendingTok[C.OWN], 20_000 * T);
        // the A part waits for its warm-up to count for the line
        assertEq(lens.lineOf(id), 50 * U);
    }

    /// @dev The top-up line ("Your agent's line: now → after") values A as it will count: the counted stake, an earlier
    ///      top-up still pending, and this one (docs/V5-LAUNCH.md, open items). It used to leave the pending part out.
    function test_needed_topUp_countsTheOwnersPendingStake() public {
        uint256 id2 = agents[1];
        _open(id2, 90_001 * T); // a $30 line at k 3
        _back(_owner(id2), id2, 30_000 * T); // counts tomorrow
        V5Lens.Needed memory n = lens.needed(id2, 15_000 * T, true);
        assertEq(n.line, 30 * U, "now: the counted stake");
        assertEq(n.lineIfAdded, 45 * U, "after: 135,001 $PRIORS at $0.001 and k 3");
        _back(_owner(id2), id2, 15_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id2);
        assertEq(lens.lineOf(id2), n.lineIfAdded, "the line V5 values once both top-ups count");
    }

    function test_back_ownerTopUp_ownBackingNeedsRoom() public {
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        uint256 aNow = _gen(id).counted[C.OWNER];
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.NoRoom.selector);
        v5.back(id, n.capA - aNow + aNow + 1, false);
    }

    function test_back_room_BplusC_atMostA() public {
        uint256 a = _gen(id).counted[C.OWNER];
        _back(backer1, id, a - 1_000 * T);
        vm.prank(backer2);
        vm.expectRevert(IV5Errors.NoRoom.selector);
        v5.back(id, 2_000 * T, false);
        // leaving stake still holds its room until releasableAt
        _skipFresh(1 days);
        vm.prank(backer1);
        v5.leave(id, 10_000 * T, 0);
        vm.prank(backer2);
        vm.expectRevert(IV5Errors.NoRoom.selector);
        v5.back(id, 2_000 * T, false);
        _skipFresh(8 days);
        v5.pokeFees(id);
        _back(backer2, id, 2_000 * T);
    }

    function test_back_reverts() public {
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.TooSmall.selector);
        v5.back(id, 999 * T, false);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ZeroAmount.selector);
        v5.back(id, 0, false);
        // no book
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.back(agents[1], 10_000 * T, false);
        // openBacking off
        vm.prank(timelock);
        v5.setOpenBacking(false);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BackingClosed.selector);
        v5.back(id, 10_000 * T, false);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        // registry down: refuses what adds stake
        reg.setMode(3);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.RegistryRead.selector);
        v5.back(id, 10_000 * T, false);
        reg.setMode(0);
        // guards
        vm.prank(guardian);
        v5.pause();
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.Paused.selector);
        v5.back(id, 10_000 * T, false);
    }

    function test_back_refusedUnderBreaker_andDepthMedianForm_andSpotLatch() public {
        // the median-valued form alone
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.DepthGuardOn.selector);
        v5.back(id, 10_000 * T, false);
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        // a stale snapshot counts as on
        limiter.setDepthTerm(5_000e6, 5_000e6, 2 hours + 1, true);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.DepthGuardOn.selector);
        v5.back(id, 10_000 * T, false);
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        // a view that reverts reverts the call: never read as "on", never latched (deep audit H-01)
        limiter.setViewReverts(true);
        vm.prank(backer1);
        vm.expectRevert(bytes("view down"));
        v5.back(id, 10_000 * T, false);
        limiter.setViewReverts(false);
        // the spot latch from the keeper's observation
        sizer.set(_sqrtFor(P0), _sqrtFor(P0 * 79 / 100));
        v5.sync();
        assertTrue(lens.spotGuardOn());
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.SpotGuardOn.selector);
        v5.back(id, 10_000 * T, false);
        // off at ≥ 0.90 × median
        sizer.set(_sqrtFor(P0), _sqrtFor(P0 * 89 / 100));
        v5.sync();
        assertTrue(lens.spotGuardOn(), "hysteresis: still on at 0.89");
        sizer.set(_sqrtFor(P0), _sqrtFor(P0 * 91 / 100));
        v5.sync();
        assertFalse(lens.spotGuardOn());
    }

    function test_back_refusedAfterOwnerChange_andForDefaultedAgent() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(_owner(id));
        reg.transferFrom(_owner(id), newOwner, id);
        // a reverting call writes no latch; any call that succeeds does
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.OwnerChangedLatch.selector);
        v5.back(id, 10_000 * T, false);
        assertFalse(_gen(id).ownerChanged);
        v5.pokeFees(id);
        assertTrue(_gen(id).ownerChanged);
        // back to the bound owner: the latch is never cleared
        vm.prank(newOwner);
        reg.transferFrom(newOwner, _owner(id), id);
        v5.pokeFees(id);
        assertTrue(_gen(id).ownerChanged);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.OwnerChangedLatch.selector);
        v5.back(id, 10_000 * T, false);
    }

    function test_back_lateGuard() public {
        uint256 loanId = _borrow(id, 25 * U, 8 days);
        _skipFresh(8 days + 1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.LateGuard.selector);
        v5.back(id, 10_000 * T, false);
        loanId;
    }

    function test_backWithUsdg_others() public {
        vm.prank(backer1);
        v5.backWithUsdg(id, 0, 10 * U, 9_000 * T, block.timestamp + 300, true);
        S.Gen memory g = _gen(id);
        assertApproxEqAbs(g.pendingTok[C.OTHERS], 9_700 * T, 1e9);
        assertTrue(lens.position(id, 1, C.OTHERS, backer1).autoAdd);
    }

    function test_backWithUsdg_txSumAtMostTheLiveCap() public {
        limiter.setCap(150 * U, true);
        // two zaps in one transaction: the second takes the sum over the cap
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(v5.backWithUsdg, (id, 0, 60 * U, 1, block.timestamp + 300, false));
        calls[1] = abi.encodeCall(v5.backWithUsdg, (id, 0, 100 * U, 1, block.timestamp + 300, false));
        vm.prank(backer1);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.SplitNeeded.selector, 160 * U, 150 * U));
        v5.multicall(calls);
        // one at a time, each its own transaction, both pass
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(v5.backWithUsdg, (id, 0, 60 * U, 1, block.timestamp + 300, false));
        vm.prank(backer1);
        v5.multicall(calls);
    }

    // ------------------------------------------------------------------
    // BuyAndBack's placement (2A.2)
    // ------------------------------------------------------------------

    function test_place_refusedUnderT2_thenCapped() public {
        priors.mint(bb, 10_000_000 * T);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
        vm.prank(bb);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 6));
        v5.back(id, 1 * T, false);
        _promoteToT2();
        uint256 a = _gen(id).counted[C.OWNER];
        (uint256 room, bool ok) = lens.placeRoom(id);
        assertTrue(ok);
        assertEq(room, a / 8, "A/8 a week binds first");
        vm.prank(bb);
        vm.expectRevert(IV5Errors.NoRoom.selector);
        v5.back(id, a / 8 + 1, false);
        vm.prank(bb);
        v5.back(id, a / 8, false); // no 1,000 $PRIORS minimum, no openBacking needed
        (room,) = lens.placeRoom(id);
        assertEq(room, 0);
        // next week: A/6 binds
        _skipFresh(7 days);
        (room,) = lens.placeRoom(id);
        assertEq(room, a / 6 - a / 8);
    }

    // ------------------------------------------------------------------
    // leave
    // ------------------------------------------------------------------

    function test_leave_countedFirst_thenPending_andRecord() public {
        _back(backer1, id, 10_000 * T);
        _skipFresh(1 days);
        v5.pokeFees(id);
        _back(backer1, id, 5_000 * T);
        vm.prank(backer1);
        v5.leave(id, 12_000 * T, 2);
        uint32 d = _today();
        S.Rec memory r = lens.record(id, 1, C.OTHERS, d, backer1);
        assertEq(r.counted, 10_000 * T);
        assertEq(r.uncounted, 2_000 * T);
        assertEq(r.mode, 2);
        S.Leaving memory b = lens.leavingBucket(id, 1, C.OTHERS, d);
        assertEq(b.counted, 10_000 * T);
        assertEq(b.uncounted, 2_000 * T);
        assertEq(b.loanCount, pool.loanCount());
        S.Pos memory p = lens.position(id, 1, C.OTHERS, backer1);
        assertEq(p.counted + p.a0 + p.a1, 3_000 * T);
    }

    function test_leave_wholePositionWhenUnder1000Stays() public {
        _back(backer1, id, 10_000 * T);
        vm.prank(backer1);
        v5.leave(id, 9_500 * T, 1);
        S.Pos memory p = lens.position(id, 1, C.OTHERS, backer1);
        assertEq(p.counted + p.a0 + p.a1, 0);
    }

    function test_leave_reverts() public {
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.leave(id, 1, 3);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.NothingToLeave.selector);
        v5.leave(id, 1_000 * T, 1);
        _back(backer1, id, 10_000 * T);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.TooSmall.selector);
        v5.leave(id, 500 * T, 1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.leave(agents[1], 1_000 * T, 1);
        vm.prank(bb);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.leave(id, 1_000 * T, 2);
        // after an owner change the backing layers already moved
        vm.prank(_owner(id));
        reg.transferFrom(_owner(id), anyone, id);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.NothingToLeave.selector);
        v5.leave(id, 1_000 * T, 1);
    }

    // ------------------------------------------------------------------
    // switches
    // ------------------------------------------------------------------

    function test_setAutoAdd() public {
        _back(backer1, id, 10_000 * T);
        vm.prank(backer1);
        v5.setAutoAdd(id, true);
        assertTrue(lens.position(id, 1, C.OTHERS, backer1).autoAdd);
        vm.prank(_owner(id));
        v5.setAutoAdd(id, true);
        assertTrue(lens.position(id, 1, C.OWNER, _owner(id)).autoAdd);
        reg.setMode(1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.OwnerChangedLatch.selector);
        v5.setAutoAdd(id, true);
        vm.prank(backer1);
        v5.setAutoAdd(id, false);
        reg.setMode(0);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.setAutoAdd(agents[1], true);
    }

    function test_setProtocolBacking_offMovesC() public {
        _promoteToT2();
        priors.mint(bb, 10_000_000 * T);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
        (uint256 room,) = lens.placeRoom(id);
        vm.prank(bb);
        v5.back(id, room, false);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.setProtocolBacking(id, false);
        vm.prank(_owner(id));
        v5.setProtocolBacking(id, false);
        S.Rec memory r = lens.record(id, 1, C.OWN, _today(), bb);
        assertEq(r.uncounted, room);
        assertEq(r.mode, 1);
        (, bool ok) = lens.placeRoom(id);
        assertFalse(ok);
        vm.prank(bb);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 6));
        v5.back(id, 1 * T, false);
        vm.prank(_owner(id));
        v5.setProtocolBacking(id, true);
        (, ok) = lens.placeRoom(id);
        assertTrue(ok);
        // on refuses after an owner change
        vm.prank(_owner(id));
        reg.transferFrom(_owner(id), anyone, id);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.OwnerChangedLatch.selector);
        v5.setProtocolBacking(id, true);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.setProtocolBacking(agents[1], true);
    }

    function test_setOthersBacking() public {
        _back(backer1, id, 10_000 * T);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.setOthersBacking(id, false);
        vm.prank(_owner(id));
        v5.setOthersBacking(id, false);
        S.Gen memory g = _gen(id);
        assertTrue(g.othersOff);
        assertGt(g.layerEnd[C.OTHERS], 0);
        assertEq(g.leavingLive[C.OTHERS], 10_000 * T);
        vm.prank(backer2);
        vm.expectRevert(IV5Errors.BackingClosed.selector);
        v5.back(id, 10_000 * T, false);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.BackingClosed.selector);
        v5.setOthersBacking(id, true);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.setOthersBacking(agents[1], true);
    }

    function test_setOthersBacking_onAgain_beforeAnyMove() public {
        vm.prank(_owner(id));
        v5.setOthersBacking(id, true);
        assertFalse(_gen(id).othersOff);
    }

    function test_reconsent() public {
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.reconsent(id, c, sig);
        (c, sig) = _consent(id, ROOT, 5);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.PremiumCap.selector);
        v5.reconsent(id, c, sig);
        vm.prank(timelock);
        v5.setPremiumCap(200);
        vm.prank(timelock);
        v5.setPremium(id, 0);
        (c, sig) = _consent(id, ROOT, 150);
        vm.prank(_owner(id));
        v5.reconsent(id, c, sig);
        assertEq(pool.getAgent(id).premiumCap, 150);
        vm.prank(timelock);
        v5.setPremium(id, 100);
        assertEq(pool.getAgent(id).premiumBps, 100);
        // a reconsent forwards V5's target, never 0
        (c, sig) = _consent(id, ROOT, 150);
        vm.prank(_owner(id));
        v5.reconsent(id, c, sig);
        assertEq(pool.getAgent(id).premiumBps, 100);
        reg.setMode(1);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.OwnerChangedLatch.selector);
        v5.reconsent(id, c, sig);
        reg.setMode(0);
        vm.expectRevert(IV5Errors.BookNotOpen.selector);
        v5.reconsent(agents[1], c, sig);
    }

    function test_noteDelegate_keepsAnUnchangedClock() public {
        address d = makeAddr("d");
        vm.prank(_owner(id));
        pool.setDelegate(id, d);
        v5.noteDelegate(id);
        (address who, uint64 at) = lens.delegateOf(id);
        assertEq(who, d);
        _skipFresh(1 hours);
        v5.noteDelegate(id);
        (, uint64 at2) = lens.delegateOf(id);
        assertEq(at2, at);
    }

    // ------------------------------------------------------------------

    /// @dev Three counted loans at T1 (8-day terms, $25 each, repaid after 7 days), then 14 days, then promote.
    function _promoteToT2() internal {
        uint256 a = _borrow(id, 25 * U, 8 days);
        uint256 b = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        uint256 c = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(c);
        v5.promote(id);
        assertEq(_gen(id).tier, 2);
    }
}
