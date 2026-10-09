// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {V5Auto} from "../../src/v5/V5Auto.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";

/// @dev The exit queue (2A.1): `queueExit`, BuyAndBack's internal fills, the keeper's sells, `returnExit`; and
///      auto-add (`compound`).
contract V5QueueTest is V5Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = agents[0];
        _open(id, 140_000 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        priors.mint(bb, 10_000_000 * T);
        usdg.mint(bb, 10_000 * U);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
    }

    /// @dev backer leaves `tokens` in mode 2, the rule holds 8 days later, then it joins the queue.
    function _queued(address who, uint256 tokens) internal returns (uint64 eid, uint32 d) {
        _back(who, id, tokens);
        vm.prank(who);
        v5.leave(id, tokens, 2);
        d = _today();
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, who, C.OTHERS, d);
        (uint256 head,,,,) = lens.exitHead();
        eid = uint64(lens.record(id, 1, C.OTHERS, d, who).entry);
        head;
    }

    function _rest(uint32 d) internal view returns (uint256) {
        S.Rec memory r = lens.record(id, 1, C.OTHERS, d, backer1);
        return r.counted + r.uncounted;
    }

    // ------------------------------------------------------------------
    // queueExit
    // ------------------------------------------------------------------

    function test_queueExit_joinsOnceTheRuleHolds() public {
        _back(backer1, id, 50_000 * T);
        vm.prank(backer1);
        v5.leave(id, 50_000 * T, 2);
        uint32 d = _today();
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        _skipFresh(8 days);
        vm.expectEmit(true, true, true, true, address(v5));
        emit IV5Events.ExitQueued(1, id, 1, backer1, 50_000 * T);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        (uint256 eid, address h, uint256 rest,, uint64 joinedAt) = lens.exitHead();
        assertEq(eid, 1);
        assertEq(h, backer1);
        assertEq(rest, 50_000 * T);
        assertEq(joinedAt, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.AlreadyQueued.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
    }

    function test_queueExit_dustUnder25_setsModeOne() public {
        _back(backer1, id, 20_000 * T); // $20 at P
        vm.prank(backer1);
        v5.leave(id, 20_000 * T, 2);
        uint32 d = _today();
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        assertEq(lens.record(id, 1, C.OTHERS, d, backer1).mode, 1);
        (uint256 eid,,,,) = lens.exitHead();
        assertEq(eid, 0);
        v5.releaseFor(id, 1, backer1, d);
    }

    function test_queueExit_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.queueExit(agents[1], 1, backer1, C.OTHERS, _today());
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.queueExit(id, 1, backer1, 3, _today());
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.queueExit(id, 1, backer1, C.OWNER, _today()); // not the owner
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.queueExit(id, 1, backer1, C.OWN, _today()); // not its layer
        _back(backer1, id, 50_000 * T);
        vm.prank(backer1);
        v5.leave(id, 50_000 * T, 1);
        uint32 d = _today();
        _skipFresh(8 days);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.queueExit(id, 1, backer1, C.OTHERS, d); // mode 1
    }

    function test_queueExit_closingRecordOfTheOwner() public {
        vm.prank(_owner(id));
        v5.close(id, 2);
        uint32 d = _today();
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, _owner(id), C.OWNER, d);
        (uint256 eid,,,,) = lens.exitHead();
        assertEq(eid, 1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.finishClose(id, 1);
        _skipFresh(3 days);
        v5.finishClose(id, 1);
        (eid,,,,) = lens.exitHead();
        assertEq(eid, 0, "unlinked");
    }

    // ------------------------------------------------------------------
    // fills (BuyAndBack)
    // ------------------------------------------------------------------

    function test_fill_servesTheHeadByOneChunk_thenTail() public {
        limiter.setDepth(20_000e6, true); // V5's exit chunk: min($250, 0.35% of $20,000) = $70
        (uint64 e1,) = _queued(backer1, 130_000 * T); // $130 at P
        uint160 fillPrice = _sqrtFor(P0);
        vm.prank(bb);
        (uint256 taken, address h) = v5.fillExit(e1, type(uint256).max, fillPrice);
        assertEq(h, backer1);
        assertApproxEqAbs(taken, 70_000 * T, 1e18);
        assertEq(priors.balanceOf(bb), 10_000_000 * T + taken);
        (uint256 head,, uint256 rest,,) = lens.exitHead();
        assertEq(head, e1, "alone: still the head (moved to the tail of a queue of one)");
        assertApproxEqAbs(rest, 60_000 * T, 1e18);
        vm.prank(bb);
        v5.fillExit(e1, type(uint256).max, fillPrice);
        (head,,,,) = lens.exitHead();
        assertEq(head, 0);
    }

    function test_fill_roundRobin_andNotHead() public {
        limiter.setDepth(20_000e6, true);
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        (uint64 e2,) = _queued(backer2, 30_000 * T);
        vm.prank(bb);
        vm.expectRevert(IV5Errors.NotHead.selector);
        v5.fillExit(e2, 1, _sqrtFor(P0));
        vm.prank(bb);
        v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        (uint256 head,,,,) = lens.exitHead();
        assertEq(head, e2, "e1 moved to the tail");
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotBuyAndBack.selector);
        v5.fillExit(e2, 1, _sqrtFor(P0));
    }

    function test_fill_floorAtTheFillPrice_movesToTail() public {
        _back(backer1, id, 60_000 * T);
        _back(backer2, id, 60_000 * T);
        vm.prank(backer1);
        v5.leave(id, 60_000 * T, 2);
        vm.prank(backer2);
        v5.leave(id, 60_000 * T, 2);
        uint32 d = _today();
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer2, C.OTHERS, d);
        uint64 e1 = uint64(lens.record(id, 1, C.OTHERS, d, backer1).entry);
        uint64 e2 = uint64(lens.record(id, 1, C.OTHERS, d, backer2).entry);
        // a fill price under 90% of P at the leave
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0 * 89 / 100));
        assertEq(taken, 0);
        (uint256 head,,,,) = lens.exitHead();
        assertEq(head, e2);
    }

    function test_fill_skipsWritingNothing_whenServiceClosed() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        vm.prank(guardian);
        v5.pause();
        assertFalse(lens.exitServiceOpen());
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        assertEq(_rest(uint32(_today() - 8)), 100_000 * T);
    }

    function test_fill_windowEnded_paysPriors() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        _skipFresh(3 days);
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        assertEq(priors.balanceOf(backer1) - p0, 100_000 * T);
    }

    function test_fill_dustUnder5_paysPriors() public {
        (uint64 e1,) = _queued(backer1, 30_000 * T);
        vm.prank(bb);
        v5.fillExit(e1, 26_000 * T, _sqrtFor(P0));
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        assertEq(priors.balanceOf(backer1) - p0, 4_000 * T);
    }

    function test_fill_ruleFailsAgain_tail_thenReturnExit() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        uint256 l = _borrow(id, 40 * U, 1 days);
        _skipFresh(5 days);
        // the overdue loan cannot be marked (its markDefault fails): the rule fails again
        vm.mockCallRevert(address(pool), abi.encodeWithSignature("markDefault(uint256)"), "nope");
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        vm.prank(bb);
        v5.returnExit(e1);
        assertEq(lens.record(id, 1, C.OTHERS, uint32(_today() - 13), backer1).entry, e1, "still queued");
        vm.clearMockedCalls();
        // marked now: the generation settles, the entry is paid its remainder as $PRIORS
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(bb);
        v5.returnExit(e1);
        assertEq(priors.balanceOf(backer1) - p0, 50_000 * T);
        l;
        vm.prank(bb);
        vm.expectRevert(IV5Errors.NotQueued.selector);
        v5.returnExit(e1);
    }

    // ------------------------------------------------------------------
    // keeper sells
    // ------------------------------------------------------------------

    function test_keeperSell_oneChunk_paidStraightToTheLeaver() public {
        limiter.setDepth(20_000e6, true); // chunk $70, day budget $200
        (uint64 e1,) = _queued(backer1, 130_000 * T);
        uint256 u0 = usdg.balanceOf(backer1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        uint256 got = usdg.balanceOf(backer1) - u0;
        assertGt(got, 67 * U);
        assertLt(got, 70 * U);
        assertEq(limiter.consumeCount(), 1);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotKeeper.selector);
        v5.releaseFor(e1, type(uint256).max);
    }

    function test_keeperSell_skips() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        uint32 d = uint32(_today() - 8);
        // the limiter would refuse: a swap already in this L2 block
        limiter.setSwapped(true);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(_rest(d), 100_000 * T);
        limiter.setSwapped(false);
        // f_live above the ceiling
        limiter.setFee(401, true);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        limiter.setFee(300, true);
        // under $5 of the hour's budget
        limiter.setHourLeft(4 * U);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        limiter.setHourLeft(2_000 * U);
        // spot under the week low
        _setSpot(P0 * 95 / 100);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        _setSpot(P0);
        // a frozen-read failure
        usdg.setFrozenMode(1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        usdg.setFrozenMode(0);
        // a hook failure in the swap: undone, skipped
        swapper.setBroken(true);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        swapper.setBroken(false);
        assertEq(_rest(d), 100_000 * T, "nothing written");
        assertEq(limiter.consumeCount(), 0, "the leg's consume was undone with it");
    }

    function test_keeperSell_frozenLeaver_paidPriors() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        usdg.freeze(backer1, true);
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(priors.balanceOf(backer1) - p0, 100_000 * T);
    }

    function test_keeperSell_floorMissedInsideTheSwap_paidPriors() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        swapper.setFee(2_000); // the swap pays 20% to the hook: under the size-aware floor
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(priors.balanceOf(backer1) - p0, 100_000 * T);
    }

    function test_keeperSell_leaversFloor_tail() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        // the price fell 20%: a sale would pay under 90% of P at the leave
        _keeperPass(P0 * 80 / 100);
        _setSpot(P0 * 80 / 100);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(_rest(uint32(_today() - 8)), 100_000 * T);
    }

    // ------------------------------------------------------------------
    // the rarer queue paths
    // ------------------------------------------------------------------

    function test_fill_zeroMaxTokens_takesNothing() public {
        (uint64 e1, uint32 d) = _queued(backer1, 100_000 * T);
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, 0, _sqrtFor(P0));
        assertEq(taken, 0);
        assertEq(_rest(d), 100_000 * T);
    }

    function test_fill_serviceClosed_underTheSpotAndDepthGuards() public {
        (uint64 e1, uint32 d) = _queued(backer1, 100_000 * T);
        _setSpot(P0 * 70 / 100);
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        _setSpot(P0);
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        vm.prank(bb);
        (taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0));
        assertEq(taken, 0);
        assertEq(_rest(d), 100_000 * T);
    }

    function test_fill_belowTheLeaversFloor_tail() public {
        (uint64 e1, uint32 d) = _queued(backer1, 100_000 * T);
        vm.prank(bb);
        (uint256 taken,) = v5.fillExit(e1, type(uint256).max, _sqrtFor(P0 * 80 / 100));
        assertEq(taken, 0);
        assertEq(_rest(d), 100_000 * T);
    }

    function test_keeperSell_refusals() public {
        (uint64 e1, uint32 d) = _queued(backer1, 100_000 * T);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NotHead.selector);
        v5.releaseFor(e1 + 1, type(uint256).max);
        // paused; the spot guard; D unreadable
        vm.prank(guardian);
        v5.pause();
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        vm.prank(guardian);
        v5.unpause();
        _setSpot(P0 * 70 / 100);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        _setSpot(P0);
        limiter.setDepth(77_911e6, false);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        // the day's sell budget under $5 (D of $400: 1% is $4)
        limiter.setDepth(400e6, true);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        // a turn worth under $5 (one token)
        limiter.setDepth(77_911e6, true);
        vm.prank(keeper);
        v5.releaseFor(e1, 1 * T);
        assertEq(_rest(d), 100_000 * T, "nothing written");
    }

    function test_keeperSell_windowEnded_paysPriors() public {
        (uint64 e1,) = _queued(backer1, 100_000 * T);
        _skipFresh(3 days);
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(priors.balanceOf(backer1) - p0, 100_000 * T);
    }

    function test_keeperSell_wholeRest_unlinks() public {
        (uint64 e1,) = _queued(backer1, 30_000 * T); // $30 at P: under one chunk
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        (uint256 head,,,,) = lens.exitHead();
        assertEq(head, 0);
    }

    function test_keeperSell_dustRest_paidPriors() public {
        (uint64 e1, uint32 d) = _queued(backer1, 30_000 * T);
        // a fill takes all but $4 of it
        vm.prank(bb);
        v5.fillExit(e1, 26_000 * T, _sqrtFor(P0));
        assertEq(_rest(d), 4_000 * T);
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(keeper);
        v5.releaseFor(e1, type(uint256).max);
        assertEq(priors.balanceOf(backer1) - p0, 4_000 * T);
    }

    // ------------------------------------------------------------------
    // compound (auto-add)
    // ------------------------------------------------------------------

    function _earnFees() internal {
        uint256 l = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l);
        v5.pokeFees(id);
    }

    function test_compound_ownerFees_backAsPendingA() public {
        vm.prank(_owner(id));
        v5.setAutoAdd(id, true);
        for (uint256 i = 0; i < 20; i++) {
            _earnFees();
        }
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(id, _owner(id));
        uint256 c0 = lens.claimable(_owner(id));
        // (claimable is credited at the position's touch inside compound)
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.CompoundTooSmall.selector);
        v5.compound(items, 0);
        c0;
    }

    function test_compound_access_andLimits() public {
        V5Auto.Item[] memory items = new V5Auto.Item[](51);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotKeeper.selector);
        v5.compound(items, 0);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.TooManyItems.selector);
        v5.compound(items, 0);
        _skip(46 minutes);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.StalePrice.selector);
        v5.compound(new V5Auto.Item[](0), 0);
    }
}

/// @dev Auto-add on a pool whose fees are large enough to reach `compound`'s 5 USDG in a few loans.
contract V5CompoundTest is V5Base {
    uint256 internal id;

    function _poolParams() internal pure override returns (ICreditPoolV2.Params memory p) {
        p = super._poolParams();
        p.feeBps = 500;
        p.sponsorFeeBps = 8500;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        _open(id, 140_000 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _back(backer1, id, 60_000 * T);
        _skipFresh(1 days);
        v5.pokeFees(id);
        vm.prank(_owner(id));
        v5.setAutoAdd(id, true);
        vm.prank(backer1);
        v5.setAutoAdd(id, true);
        for (uint256 i = 0; i < 16; i++) {
            uint256 l = _borrow(id, 45 * U, 10 days);
            _skipFresh(10 days);
            _repay(l);
            v5.pokeFees(id);
        }
    }

    function test_compound_bothHolders_pendingStake_carryAndSolvency() public {
        V5Auto.Item[] memory items = new V5Auto.Item[](3);
        items[0] = V5Auto.Item(id, _owner(id));
        items[1] = V5Auto.Item(id, backer1);
        items[2] = V5Auto.Item(id, bb); // C never auto-adds: skipped
        uint256 a0 = _gen(id).pendingTok[C.OWNER];
        vm.prank(keeper);
        v5.compound(items, 0);
        S.Gen memory g = _gen(id);
        assertGt(g.pendingTok[C.OWNER], a0, "the owner's fees back in A, pending");
        assertGt(g.pendingTok[C.OTHERS], 0, "the backer's back in its backing");
        assertEq(lens.claimable(_owner(id)), 0);
        assertEq(limiter.consumeCount(), 1, "one swap through the limiter");
        (uint256 l, uint256 carry) = _ledger();
        assertEq(priors.balanceOf(address(v5)), l + carry);
        assertTrue(_solvent());
    }

    function test_compound_skipsUnderGuards_andWithAutoAddOff() public {
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(id, backer1);
        vm.prank(backer1);
        v5.setAutoAdd(id, false);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.CompoundTooSmall.selector);
        v5.compound(items, 0);
        vm.prank(backer1);
        v5.setAutoAdd(id, true);
        vm.prank(guardian);
        v5.pause();
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.CompoundTooSmall.selector);
        v5.compound(items, 0);
    }

    function test_compound_overflowReturned_whenNoRoom() public {
        // fill the backing room: B + C = A
        uint256 a = _gen(id).counted[C.OWNER];
        V5Auto.Item[] memory items = new V5Auto.Item[](2);
        items[0] = V5Auto.Item(id, _owner(id));
        items[1] = V5Auto.Item(id, backer1);
        _back(backer2, id, a - 60_000 * T - 1_000 * T);
        // room is 1,000 tokens: the pre-check passes; the credit is cut to the room, the rest returned
        uint256 p0 = priors.balanceOf(backer1);
        vm.prank(keeper);
        v5.compound(items, 0);
        assertGt(priors.balanceOf(backer1), p0, "ExtraReturned");
        assertEq(_gen(id).pendingTok[C.OTHERS], a - 60_000 * T - 1_000 * T + 1_000 * T);
    }

    function test_compound_payBand_andCap() public {
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(id, _owner(id));
        swapper.setFee(600); // pays 6%: under the pay band at f_live 3%
        vm.prank(keeper);
        vm.expectRevert();
        v5.compound(items, 0);
        swapper.setFee(300);
        limiter.setCap(1 * U, true);
        vm.prank(keeper);
        vm.expectPartialRevert(IV5Errors.SplitNeeded.selector);
        v5.compound(items, 0);
        limiter.setCap(2_169e6, false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 2));
        v5.compound(items, 0);
    }

    // ------------------------------------------------------------------
    // the items compound skips, and its fail-closed reads
    // ------------------------------------------------------------------

    function _pair(uint256 agent, address holder) internal view returns (V5Auto.Item[] memory items) {
        items = new V5Auto.Item[](2);
        items[0] = V5Auto.Item(id, _owner(id));
        items[1] = V5Auto.Item(agent, holder);
    }

    /// @dev More of the owner's fees, for another batch.
    function _again() internal {
        for (uint256 i = 0; i < 16; i++) {
            uint256 l = _borrow(id, 45 * U, 10 days);
            _skipFresh(10 days);
            _repay(l);
        }
        v5.pokeFees(id);
    }

    /// @dev One item that runs (the owner's) and one that is skipped, its credit untouched.
    function _skipped(uint256 agent, address holder) internal {
        uint256 c0 = lens.claimable(holder);
        vm.prank(keeper);
        v5.compound(_pair(agent, holder), 0);
        assertGe(lens.claimable(holder), c0, "skipped: its credit is not taken");
    }

    function test_compound_skips_noBook() public {
        _skipped(agents[1], backer2);
    }

    function test_compound_skips_closedBook_andLateGuard() public {
        uint256 other = agents[1];
        _open(other, 150_001 * T);
        _borrow(other, 10 * U, 1 days);
        _skipFresh(2 days);
        vm.prank(_owner(other));
        v5.setAutoAdd(other, true);
        _skipped(other, _owner(other)); // a listed loan past due
        _again();
        vm.prank(_owner(other));
        v5.close(other, 0);
        _skipped(other, _owner(other)); // a closed book
    }

    function test_compound_skips_endedLayer() public {
        vm.prank(_owner(id));
        v5.setOthersBacking(id, false);
        uint256 c0 = lens.claimable(backer1);
        vm.prank(keeper);
        v5.compound(_pair(id, backer1), 0);
        assertGe(lens.claimable(backer1), c0, "backer1's layer moved to leaving: skipped");
    }

    function test_compound_skips_dustCredit_andNoRoom() public {
        _back(backer2, id, 1_000 * T);
        vm.prank(backer2);
        v5.setAutoAdd(id, true);
        _skipped(id, backer2); // under 0.50 USDG of credit
        _again();
        // B + C = A: a backer's item has no room
        uint256 a = _gen(id).counted[C.OWNER];
        _back(anyone, id, a - 61_000 * T);
        _skipped(id, backer1);
    }

    function test_compound_ownerAtTheCap_intoOwnBacking() public {
        // A at 3 × the ceiling at P: the owner's fees go to its own backing
        vm.prank(_owner(id));
        v5.back(id, 20_000 * T, true);
        // the back's touch moved the fees so far into claimable, where they wait for `collect` (audit M-01: a batch
        // spends only the credit its items produce): earn more for the batch
        _again();
        uint256 own0 = _gen(id).pendingTok[C.OWN];
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(id, _owner(id));
        vm.prank(keeper);
        v5.compound(items, 0);
        assertGt(_gen(id).pendingTok[C.OWN], own0);
    }

    function test_compound_failClosed_payBandAndDepth() public {
        V5Auto.Item[] memory items = new V5Auto.Item[](1);
        items[0] = V5Auto.Item(id, _owner(id));
        swapper.setDeliver(9_000); // the swap reports more than it delivers
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.PayBand.selector);
        v5.compound(items, 0);
        swapper.setDeliver(10_000);
        limiter.setDepth(77_911e6, false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 2));
        v5.compound(items, 0);
    }
}
