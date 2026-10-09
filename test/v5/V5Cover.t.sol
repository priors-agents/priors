// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {IV5Lens} from "./IV5Lens.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {IV4SwapOnce} from "../../src/interfaces/IV5Deps.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {V5Auto} from "../../src/v5/V5Auto.sol";
import {V5Lens} from "../../src/v5/V5Lens.sol";

/// @dev The edges the scenario suites do not reach: every view's refusal reasons, the hooks' early returns, the
///      fail-closed reads, an unready root, a broken sizer or limiter, fee-on-transfer and burn failures, the tiers to
///      T5, and the rarer payout and queue paths (docs/V5-BUILD.md, "Coverage").
contract V5CoverTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
    }

    function _items(uint256 agent, address holder) internal pure returns (V5Auto.Item[] memory it) {
        it = new V5Auto.Item[](1);
        it[0] = V5Auto.Item(agent, holder);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    function _oneGen(uint32 g) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = g;
    }

    // ------------------------------------------------------------------
    // a root that is not ready, a cache that is not set
    // ------------------------------------------------------------------

    function test_unreadyRoot_openRefuses_flushClaimsNothing() public {
        SeatVaultV5 fresh = _deployV5();
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.RootNotReady.selector);
        fresh.open(id, 150_001 * T, false, c, sig);
        // flush before the root: nothing claimed, nothing owed
        vm.expectEmit(false, false, false, true, address(fresh));
        emit IV5Events.Flushed(0, 0, 0);
        fresh.flush();
        // compound with no price
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NoPrice.selector);
        fresh.compound(_items(id, _owner(id)), 0);
        // a keeper pass leaves the cache stale 46 minutes later
        sizer.set(_sqrtFor(P0), _sqrtFor(P0));
        fresh.sync();
        _skip(46 minutes);
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.StalePrice.selector);
        fresh.compound(_items(id, _owner(id)), 0);
        // views of an empty V5
        IV5Lens fl = IV5Lens(address(fresh));
        assertEq(fl.lineOf(id), 0);
        (bool open_, uint8 why) = fl.usdgPathOpen(5 * U);
        assertFalse(open_);
        assertEq(why, 1);
        V5Lens.Needed memory n = fl.needed(id, 0, true);
        assertEq(n.line, 0);
    }

    /// @dev A sizer that returns a zero median leaves the cache unset and latches the spot guard: stake refuses with
    ///      SpotGuardOn, `refresh` with NoPrice.
    function test_zeroMedian_failsClosed() public {
        _open(id, 75_001 * T);
        sizer.set(0, _sqrtFor(P0));
        v5.sync();
        assertTrue(lens.spotGuardOn());
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.SpotGuardOn.selector);
        v5.back(id, 10_000 * T, false);
        vm.expectRevert(IV5Errors.NoPrice.selector);
        v5.refresh(id);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function test_usdgPathOpen_eachReason() public {
        (bool ok, uint8 why) = lens.usdgPathOpen(5 * U);
        assertTrue(ok);
        assertEq(why, 0);
        limiter.setCap(1_000 * U, false);
        (ok, why) = lens.usdgPathOpen(5 * U);
        assertEq(why, 2);
        limiter.setCap(1_000 * U, true);
        (ok, why) = lens.usdgPathOpen(1_001 * U);
        assertEq(why, 3);
        _setSpot(P0 * 70 / 100);
        (ok, why) = lens.usdgPathOpen(5 * U);
        assertEq(why, 4);
        _setSpot(P0);
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        (ok, why) = lens.usdgPathOpen(5 * U);
        assertEq(why, 5);
        assertTrue(lens.depthGuard());
        _skip(46 minutes);
        (ok, why) = lens.usdgPathOpen(5 * U);
        assertEq(why, 1);
    }

    function test_placeRoom_eachRefusal() public {
        (uint256 t, bool eligible) = lens.placeRoom(id);
        assertFalse(eligible, "no book");
        _open(id, 150_001 * T);
        (t, eligible) = lens.placeRoom(id);
        assertFalse(eligible, "T1");
        _toT2(id);
        (t, eligible) = lens.placeRoom(id);
        assertTrue(eligible);
        assertGt(t, 0);
        // a listed loan past due
        uint256 l = _borrow(id, 10 * U, 1 days);
        _skipFresh(1 days + 1);
        (t, eligible) = lens.placeRoom(id);
        assertFalse(eligible, "a listed loan past due");
        _repay(l);
        (t, eligible) = lens.placeRoom(id);
        assertFalse(eligible, "a late repayment listed");
        v5.pokeFees(id);
        (t, eligible) = lens.placeRoom(id);
        assertFalse(eligible, "28 days after a late repayment");
    }

    function test_placeRoom_guardsAndDefault() public {
        _open(id, 150_001 * T);
        _toT2(id);
        vm.prank(guardian);
        v5.pause();
        (, bool eligible) = lens.placeRoom(id);
        assertFalse(eligible, "paused");
        vm.prank(guardian);
        v5.unpause();
        (, eligible) = lens.placeRoom(id);
        assertTrue(eligible);
        uint256 l = _borrow(id, 50 * U, 8 days);
        _skipFresh(11 days + 1);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "fail");
        pool.markDefault(l);
        vm.clearMockedCalls();
        (, eligible) = lens.placeRoom(id);
        assertFalse(eligible, "the agent defaulted");
    }

    function test_needed_asBacker_andGetters() public {
        _open(id, 150_001 * T);
        V5Lens.Needed memory n = lens.needed(id, 10_000 * T, false);
        assertEq(n.lineIfAdded, n.line, "a backer's tokens raise no line");
        assertEq(n.weekAfter, n.line);
        n = lens.needed(id, 10_000 * T, true);
        assertGe(n.lineIfAdded, n.line);
        (uint160 med, uint64 at, uint160 low, uint160 obs) = lens.priceCache();
        assertEq(med, _sqrtFor(P0));
        assertEq(at, block.timestamp);
        assertEq(low, med);
        assertEq(obs, med);
        assertEq(lens.cReturned(), 0);
        assertFalse(lens.depthGuard());
        S.Pending memory p = lens.pendingBucket(id, 1, C.OWNER, _today());
        assertEq(p.amount, 0);
        assertEq(lens.entry(1).id, 0);
        (address who, uint64 wat) = lens.delegateOf(id);
        assertEq(who, address(0));
        assertEq(wat, 0);
        assertEq(lens.targetPremiumBps(id), 0);
        assertEq(v5.poolKey().fee, key.fee);
        assertEq(v5.swapLimiter(), address(limiter));
        assertEq(v5.buyAndBack(), bb);
        assertEq(v5.timelock(), timelock);
    }

    /// @dev V5Exit matches V4SwapOnce's errors by these signatures.
    function test_swapperErrorSelectors() public pure {
        assertEq(bytes4(keccak256("TooLittleOut(uint256,uint256)")), IV4SwapOnce.TooLittleOut.selector);
        assertEq(bytes4(keccak256("Expired()")), IV4SwapOnce.Expired.selector);
    }

    function test_ceilings_eachTier() public pure {
        assertEq(C.ceiling(1), 50e6);
        assertEq(C.ceiling(2), 100e6);
        assertEq(C.ceiling(3), 175e6);
        assertEq(C.ceiling(4), 300e6);
        assertEq(C.ceiling(5), 500e6);
    }

    // ------------------------------------------------------------------
    // tiers to T5
    // ------------------------------------------------------------------

    /// @dev Three counted loans of at least half the ceiling, 14 days at a tier, one step an epoch: T1 → T5, then no
    ///      further.
    function test_promote_toT5_thenNotPromotable() public {
        _calmWeek();
        vm.prank(timelock);
        v5.setRooms(500 * U, 5_000 * U); // a week's stake share covers each step's raise
        _open(id, 75_100 * T);
        for (uint8 t = 1; t < 5; t++) {
            _toNext(id);
            assertEq(_gen(id).tier, t + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotPromotable.selector, 1));
        v5.promote(id);
    }

    /// @dev Promotion refusals under the breaker and the depth guard.
    function test_promote_refusedUnderBreakerAndDepth() public {
        _open(id, 150_001 * T);
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        vm.expectRevert(IV5Errors.DepthGuardOn.selector);
        v5.promote(id);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Three counted loans at the current tier (each half its ceiling, 8 days, repaid after 7), then 14 days at
    ///      the tier, then the promotion. Tops A up first so the line covers the loans.
    function _toNext(uint256 agent) internal {
        S.Gen memory g = _gen(agent);
        uint256 half = C.ceiling(g.tier) / 2;
        if (g.tier > 1) {
            // A for a line of at least half the ceiling at k 3 (the ring has gaps): 1.5 × ceiling at P0, plus margin
            uint256 lineNeed = (half + 5e6 - 1) / 5e6 * 5e6;
            uint256 need = lineNeed * 3 * 1e30 / P0 + 1_000 * T;
            if (g.counted[C.OWNER] + C.MIN_BACK < need) {
                vm.prank(_owner(agent));
                v5.back(agent, need - g.counted[C.OWNER], false);
                _skipFresh(1 days + 1);
                v5.pokeFees(agent);
            }
        }
        uint256 a = _borrow(agent, half, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        uint256 b = _borrow(agent, half, 8 days);
        _skipFresh(7 days + 1);
        _repay(b);
        uint256 c = _borrow(agent, half, 8 days);
        _skipFresh(7 days + 1);
        _repay(c);
        v5.promote(agent);
    }

    function _toT2(uint256 agent) internal {
        uint256 a = _borrow(agent, 25 * U, 8 days);
        uint256 b = _borrow(agent, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        uint256 c = _borrow(agent, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(c);
        v5.promote(agent);
        assertEq(_gen(agent).tier, 2);
    }
}

/// @dev The rarer paths of the hooks, the records, the closes and the payouts.
contract V5CoverPathsTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
        priors.mint(bb, 10_000_000 * T);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
    }

    function _starvedBorrow(uint256 agent, uint256 amount, uint64 term) internal returns (uint256 loanId) {
        vm.prank(_owner(agent));
        v5.refresh(agent);
        address o = _owner(agent);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onBorrow.selector), "fail");
        vm.prank(o);
        loanId = pool.borrow(agent, amount, term, o, type(uint256).max);
        vm.clearMockedCalls();
    }

    function _starvedDefault(uint256 loanId) internal {
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "fail");
        pool.markDefault(loanId);
        vm.clearMockedCalls();
    }

    /// @dev A loan V5 never saw (its onBorrow failed) that defaults with a failed onDefault: the book stays open, the
    ///      agent defaulted, the sponsorship gone.
    function _unseenDefault() internal returns (uint256 l) {
        _open(id, 150_001 * T);
        l = _starvedBorrow(id, 40 * U, 8 days);
        _skipFresh(11 days + 1);
        _starvedDefault(l);
        assertEq(_gen(id).status, C.OPEN);
        assertTrue(pool.getAgent(id).defaulted);
    }

    // ------------------------------------------------------------------
    // the hooks' early returns (only the pool calls them)
    // ------------------------------------------------------------------

    function test_hooks_earlyReturns() public {
        _open(id, 150_001 * T);
        uint256 nobody = agents[1];
        // not from the pool, or another root: nothing
        v5.onBorrow(ROOT, id, 1);
        vm.prank(address(pool));
        v5.onBorrow(OROOT, id, 1);
        // an agent with no generation
        vm.startPrank(address(pool));
        v5.onBorrow(ROOT, nobody, 77);
        assertFalse(lens.loanRecord(77).seen);
        v5.onRelease(ROOT, nobody, 0, 0);
        v5.onDefault(ROOT, nobody, 78, 1 * U, true);
        assertTrue(lens.loanRecord(78).breakerSeen, "recorded in the breaker, nothing else");
        // the book's own agent, still sponsored by V5's root: a partial release changes nothing
        v5.onRelease(ROOT, id, 0, 0);
        vm.stopPrank();
        assertEq(_gen(id).status, C.OPEN);
    }

    /// @dev onDefault for a loan issued before the generation opened (another root's loan of the agent's history):
    ///      recorded in the breaker, never settles the book.
    function test_onDefault_loanBeforeTheGeneration() public {
        _open(id, 150_001 * T);
        vm.prank(address(pool));
        v5.onDefault(ROOT, id, 1, 5 * U, true);
        assertFalse(lens.loanRecord(1).seen);
        assertEq(_gen(id).status, C.OPEN);
    }

    /// @dev onDefault of a loan V5 never listed (onBorrow failed): it reads the loan, records it with the generation
    ///      and settles.
    function test_onDefault_unseenLoanOfTheGeneration_settles() public {
        _open(id, 150_001 * T);
        uint256 l = _starvedBorrow(id, 40 * U, 8 days);
        assertFalse(lens.loanRecord(l).seen);
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        assertTrue(lens.loanRecord(l).seen);
        assertEq(_gen(id).status, C.SETTLED);
    }

    /// @dev A second default of a settled generation only records in the breaker.
    function test_onDefault_secondDefault_settledAlready() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 20 * U, 8 days);
        uint256 b = _borrow(id, 20 * U, 9 days);
        _skipFresh(11 days + 1);
        pool.markDefault(a);
        (,,,,, uint256 burned,) = lens.totals();
        _skipFresh(1 days);
        pool.markDefault(b);
        (,,,,, uint256 burned2, uint256 rec) = lens.totals();
        assertEq(burned2, burned, "burns once");
        assertEq(rec, 2);
    }

    /// @dev onRelease after an unseen default: the book waits for the settle (or sync(id)); with the default recorded
    ///      and the defaulted loan listed, it still waits.
    function test_onRelease_waitsForTheSettle() public {
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 40 * U, 8 days);
        _skipFresh(11 days + 1);
        _starvedDefault(l); // the residual release ran: the default was unseen, the book stays open
        assertEq(_gen(id).status, C.OPEN);
        v5.recordDefault(l); // seen already: the breaker records it
        vm.prank(address(pool));
        v5.onRelease(ROOT, id, 0, 0);
        assertEq(_gen(id).status, C.OPEN, "a listed Defaulted loan: the settle ends it");
        v5.pokeFees(id);
        assertEq(_gen(id).status, C.SETTLED);
    }

    // ------------------------------------------------------------------
    // recordLoan, settle, sync(id), close and expire around an unseen default
    // ------------------------------------------------------------------

    function test_unseenDefault_closeExpireBackRefuse_syncWaits_recordLoanSettles() public {
        uint256 l = _unseenDefault();
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.AgentDefaulted.selector);
        v5.close(id, 0);
        vm.expectRevert(IV5Errors.AgentDefaulted.selector);
        v5.expire(id);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.AgentDefaulted.selector);
        v5.back(id, 10_000 * T, false);
        vm.expectRevert(IV5Errors.DefaultUnseen.selector);
        v5.sync(id);
        // recordLoan of the defaulted loan: the breaker, the proof, then the settle in its first steps
        v5.recordLoan(l);
        assertEq(_gen(id).status, C.SETTLED);
        assertEq(_gen(id).defaultProof, l);
        // sync(id) on a settled generation does nothing
        v5.sync(id);
    }

    function test_settle_unseenLoan_recordsIt() public {
        uint256 l = _unseenDefault();
        v5.settle(id, 1, l);
        assertTrue(lens.loanRecord(l).seen);
        assertEq(_gen(id).status, C.SETTLED);
    }

    function test_recordLoan_beforeTheGeneration_notOurs() public {
        _open(id, 150_001 * T);
        uint256 l = _starvedBorrow(id, 10 * U, 1 days);
        _skipFresh(1 days);
        _repay(l);
        vm.prank(_owner(id));
        v5.close(id, 0);
        _skipFresh(31 days);
        v5.finishClose(id, 1);
        _open(id, 150_001 * T);
        vm.expectRevert(IV5Errors.NotOurLoan.selector);
        v5.recordLoan(l);
    }

    /// @dev A repaid loan V5 recorded through `recordLoan` (not through the hook) never counts.
    function test_recordLoan_open_thenRepaid_neverCounts() public {
        _open(id, 150_001 * T);
        uint256 l = _starvedBorrow(id, 25 * U, 8 days);
        v5.recordLoan(l);
        _skipFresh(7 days + 1);
        _repay(l);
        v5.pokeFees(id);
        assertEq(_gen(id).countedAtTier, 0);
        assertEq(_gen(id).listLen, 0);
    }

    /// @dev A closed generation with a listed loan still open blocks a reopen, 30 days on.
    function test_reopen_refusedWhileTheOldLoanIsOpen() public {
        _open(id, 150_001 * T);
        _borrow(id, 40 * U, 10 days);
        vm.prank(_owner(id));
        v5.close(id, 0);
        _skipFresh(31 days);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.LoanOpen.selector);
        v5.open(id, 150_001 * T, false, c, sig);
    }

    function test_expire_afterABorrowAndRepay() public {
        _open(id, 150_001 * T);
        _skipFresh(5 days);
        uint256 l = _borrow(id, 40 * U, 2 days);
        _skipFresh(1 days);
        _repay(l);
        _skipFresh(29 days);
        vm.expectRevert(IV5Errors.NotIdle.selector);
        v5.expire(id);
        _skipFresh(1 days + 1);
        v5.expire(id);
        assertEq(_gen(id).status, C.CLOSED);
    }

    // ------------------------------------------------------------------
    // the fee split, burns, refresh
    // ------------------------------------------------------------------

    /// @dev Fees that arrive after a settle (a second loan repaid) go to the buffer; a $PRIORS whose burn fails sends
    ///      the burn to the dead address.
    function test_feesAfterSettle_toTheBuffer_andBurnFallback() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 20 * U, 8 days);
        uint256 b = _borrow(id, 20 * U, 10 days);
        _skipFresh(11 days + 1);
        priors.setBurnBroken(true);
        uint256 dead0 = priors.balanceOf(C.DEAD);
        pool.markDefault(a);
        assertGt(priors.balanceOf(C.DEAD), dead0, "the burn went to the dead address");
        (, uint256 buf0,,,,,) = lens.totals();
        _repay(b);
        v5.pokeFees(id);
        (, uint256 buf1,,,,,) = lens.totals();
        assertGt(buf1, buf0, "the fee of a settled generation is all buffer");
    }

    /// @dev `refresh` of a book V5 no longer sponsors does nothing; within a thin fee headroom a raise is cut to it.
    function test_refresh_notSponsored_andHeadroomCut() public {
        _open(id, 150_001 * T);
        // take nearly all free backing out: the headroom admits only part of the line
        uint256 free = pool.freeBacking(ROOT);
        uint256 sh = pool.convertToShares(free - 20 * U);
        vm.prank(timelock);
        v5.retire(sh);
        vm.prank(_owner(id));
        v5.refresh(id);
        uint256 v = pool.getAgent(id).delegatedIn;
        assertLt(v, 50 * U, "cut to the headroom");
        assertGt(v, 0);
        // the agent leaves V5 in the pool: the book closes, refresh does nothing
        vm.prank(_owner(id));
        pool.leave(id);
        vm.prank(_owner(id));
        v5.refresh(id);
    }

    // ------------------------------------------------------------------
    // the breaker
    // ------------------------------------------------------------------

    function test_breaker_evalWhileTripped_andPromoteRefused() public {
        _open(id, 150_001 * T);
        vm.prank(address(pool));
        v5.onDefault(ROOT, agents[2], 999_999, 300 * U, true); // a recorded default of $300
        v5.sync();
        assertTrue(lens.breakerTripped());
        v5.sync(); // evaluates nothing more while tripped
        vm.expectRevert(IV5Errors.BreakerOn.selector);
        v5.promote(id);
    }
}

/// @dev Protocol backing (C) through its life, the payouts' rarer branches, the exit queue's links, the keeper's sell
///      refusals, `sync()` under the depth guard, the fail-closed reads.
contract V5CoverExitTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
        priors.mint(bb, 10_000_000 * T);
        usdg.mint(bb, 10_000 * U);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
        _open(id, 150_001 * T);
    }

    function _toT2() internal {
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

    function _place(uint256 tokens) internal {
        vm.prank(bb);
        v5.back(id, tokens, false);
    }

    function _leaveMode(address who, uint256 tokens, uint8 mode) internal returns (uint32 d) {
        vm.prank(who);
        v5.leave(id, tokens, mode);
        d = _today();
    }

    // ------------------------------------------------------------------
    // C
    // ------------------------------------------------------------------

    /// @dev C earns fees (to `protocolFeesOwed`, flushed to BuyAndBack), leaves in mode 1 only, and its release pays
    ///      BuyAndBack (`cReturned`).
    function test_C_fees_flush_leave_release() public {
        _toT2();
        _place(10_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        uint256 l = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l);
        // C's credit moves when its position is touched: its own leave
        vm.prank(bb);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.leave(id, 10_000 * T, 0);
        uint32 d = _leaveMode(bb, 10_000 * T, 1);
        (,, uint256 pf,,,,) = lens.totals();
        assertGt(pf, 0, "C's fees owed to BuyAndBack");
        uint256 u0 = usdg.balanceOf(bb);
        v5.flush();
        assertEq(usdg.balanceOf(bb) - u0, pf, "flushed to BuyAndBack");
        _skipFresh(8 days);
        v5.releaseFor(id, 1, bb, d);
        assertEq(lens.cReturned(), 10_000 * T);
    }

    /// @dev A flush whose transfer to BuyAndBack fails (USDG frozen for it) keeps C's fees owed.
    function test_flush_transferToBuyAndBackFails_keepsOwed() public {
        _toT2();
        _place(10_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        uint256 l = _borrow(id, 45 * U, 10 days);
        _skipFresh(10 days);
        _repay(l);
        vm.prank(bb);
        v5.leave(id, 10_000 * T, 1);
        (,, uint256 pf,,,,) = lens.totals();
        usdg.freeze(bb, true);
        v5.flush();
        (,, uint256 pf2,,,,) = lens.totals();
        assertEq(pf2, pf);
    }

    /// @dev C pending on two days moves to leaving at the owner's opt-out (both slots debited); after an owner change
    ///      C's layer has already moved and the opt-out moves nothing more.
    function test_C_optOut_movesBothPendingSlots_andAfterOwnerChange() public {
        _toT2();
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 22 hours);
        _keeperPass(P0);
        _place(5_000 * T);
        _skipFresh(4 hours); // the next UTC day
        _place(5_000 * T);
        S.Pos memory p = lens.position(id, 1, C.OWN, bb);
        assertTrue(p.d0 != 0 && p.d1 != 0, "both slots");
        vm.prank(_owner(id));
        v5.setProtocolBacking(id, false);
        assertEq(_gen(id).pendingTok[C.OWN], 0);
        // an owner change, then the opt-out again: the layer has moved
        address o = _owner(id);
        vm.prank(o);
        reg.transferFrom(o, makeAddr("buyer"), id);
        v5.pokeFees(id);
        vm.prank(o);
        v5.setProtocolBacking(id, false);
    }

    /// @dev A settled generation's C, left the same day (its bucket not yet retired): claimed at once to BuyAndBack.
    function test_C_settledSameDay_claimedToBuyAndBack() public {
        _toT2();
        _place(10_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        uint256 l = _borrow(id, 50 * U, 8 days);
        _skipFresh(11 days + 1);
        vm.prank(_owner(id));
        v5.setProtocolBacking(id, false); // C to leaving today
        uint32 d = _today();
        pool.markDefault(l);
        v5.claimSettled(id, 1, bb, C.OWN, d);
        assertEq(lens.cReturned(), 5_000 * T, "half of C burned, half back");
    }

    /// @dev BuyAndBack places nothing after a late repayment for 28 days (a T3 book demoted to T2).
    function test_C_placeRefused_afterALateRepayment() public {
        vm.prank(timelock);
        v5.setRooms(500 * U, 5_000 * U);
        _toT2();
        // to T3: a line of 50 at T2 needs A worth $150 at k 3 (the ring has gaps)
        for (uint256 i = 0; i < 3; i++) {
            uint256 x = _borrow(id, 50 * U, 8 days);
            _skipFresh(7 days + 1);
            _repay(x);
        }
        v5.promote(id);
        assertEq(_gen(id).tier, 3);
        uint256 l = _borrow(id, 10 * U, 1 days);
        _skipFresh(2 days);
        _repay(l);
        v5.pokeFees(id);
        assertEq(_gen(id).tier, 2);
        vm.prank(bb);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 7));
        v5.back(id, 1_000 * T, false);
        (, bool eligible) = lens.placeRoom(id);
        assertFalse(eligible);
    }

    // ------------------------------------------------------------------
    // payouts
    // ------------------------------------------------------------------

    /// @dev An open loan V5 never listed (its onBorrow failed) holds every payout of the generation.
    function test_release_waitsForAnUnlistedOpenLoan() public {
        _back(backer1, id, 10_000 * T);
        uint32 d = _leaveMode(backer1, 10_000 * T, 0);
        vm.prank(_owner(id));
        v5.refresh(id);
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onBorrow.selector), "fail");
        vm.prank(_owner(id));
        pool.borrow(id, 10 * U, 8 days, _owner(id), type(uint256).max);
        vm.clearMockedCalls();
        _skipFresh(7 days + 1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.release(id, 1, d, 0, 0);
    }

    /// @dev A queued record: its holder's own release unlinks it; `releaseFor` waits for the 3-day window.
    function test_queued_releaseUnlinks_releaseForWaitsTheWindow() public {
        _back(backer1, id, 40_000 * T);
        _back(backer2, id, 40_000 * T);
        uint32 d = _leaveMode(backer1, 40_000 * T, 2);
        _leaveMode(backer2, 40_000 * T, 2);
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer2, C.OTHERS, d);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.releaseFor(id, 1, backer2, d);
        // the tail's own release: its entry unlinks (prev != 0)
        vm.prank(backer2);
        v5.release(id, 1, d, 0, 0);
        (uint256 head,,,,) = lens.exitHead();
        assertEq(lens.entry(head).holder, backer1);
        _skipFresh(3 days);
        v5.releaseFor(id, 1, backer1, d);
        (head,,,,) = lens.exitHead();
        assertEq(head, 0);
    }

    /// @dev `finishClose`: no generation, a mode-2 closing record before its window, then paid, then nothing left.
    function test_finishClose_mode2Window_andNothingLeft() public {
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.finishClose(agents[1], 1);
        vm.prank(_owner(id));
        v5.close(id, 2);
        _skipFresh(8 days);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.finishClose(id, 1);
        _skipFresh(3 days);
        v5.finishClose(id, 1);
        vm.expectRevert(IV5Errors.NoRecord.selector);
        v5.finishClose(id, 1);
    }

    /// @dev A queued closing record: `finishClose` waits for its window.
    function test_finishClose_queuedClosingRecord_waitsTheWindow() public {
        vm.prank(_owner(id));
        v5.close(id, 2);
        uint32 d = _today();
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, _owner(id), C.OWNER, d);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.finishClose(id, 1);
        _skipFresh(3 days);
        v5.finishClose(id, 1);
    }

    /// @dev Settled after an owner change: a backer's position had moved to a record (claimed from it), the owner has
    ///      none in that layer; a queued record leaves the queue when claimed.
    function test_claimSettled_afterAForcedMove_andAQueuedRecord() public {
        _back(backer1, id, 40_000 * T);
        _back(backer2, id, 40_000 * T);
        uint32 d = _leaveMode(backer2, 40_000 * T, 2);
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer2, C.OTHERS, d);
        uint256 l = _borrow(id, 40 * U, 8 days);
        address o = _owner(id);
        vm.prank(o);
        reg.transferFrom(o, makeAddr("buyer"), id);
        v5.pokeFees(id); // backer1's position moves to leaving
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        uint256 b0 = priors.balanceOf(backer1);
        v5.claimSettled(id, 1, backer1);
        assertEq(priors.balanceOf(backer1) - b0, 20_000 * T);
        v5.claimSettled(id, 1, o);
        uint256 c0 = priors.balanceOf(backer2);
        v5.claimSettled(id, 1, backer2, C.OTHERS, d);
        assertEq(priors.balanceOf(backer2) - c0, 20_000 * T);
        (uint256 head,,,,) = lens.exitHead();
        assertEq(head, 0, "unlinked");
    }

    function test_claimSettledRecord_notSettled() public {
        vm.expectRevert(IV5Errors.NotSettled.selector);
        v5.claimSettled(id, 1, backer1, C.OTHERS, _today());
    }

    /// @dev A settled position with pending stake on both slots.
    function test_claimSettled_pendingOnBothDays() public {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 22 hours);
        _keeperPass(P0);
        uint256 l = _borrow(id, 40 * U, 1 days);
        _back(backer1, id, 5_000 * T);
        _skipFresh(4 hours);
        _back(backer1, id, 5_000 * T);
        S.Pos memory p = lens.position(id, 1, C.OTHERS, backer1);
        assertTrue(p.d0 != 0 && p.d1 != 0, "both slots");
        _skipFresh(4 days + 1);
        pool.markDefault(l); // the hook settles with no poke: both pending slots stay unmerged
        assertEq(_gen(id).status, C.SETTLED);
        uint256 b0 = priors.balanceOf(backer1);
        v5.claimSettled(id, 1, backer1);
        assertEq(priors.balanceOf(backer1) - b0, 5_000 * T);
    }

    /// @dev A position's record when the same day holds its own leave and its layer's forced move (the cheaper of
    ///      the two prices is kept).
    function test_forcedMove_intoAnExistingRecord_keepsTheLowerFloor() public {
        _back(backer1, id, 40_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        _setSpot(P0 * 95 / 100); // a cheaper spot: P at the leave is spot
        uint32 d = _leaveMode(backer1, 10_000 * T, 0);
        uint160 atLeave = lens.record(id, 1, C.OTHERS, d, backer1).sqrtLeave;
        _setSpot(P0);
        vm.prank(_owner(id));
        v5.setOthersBacking(id, false); // the rest moves the same day, at min(median, week low)
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        vm.prank(backer1);
        v5.collect(ids, gens); // touches the position: it resolves into the same record
        S.Rec memory r = lens.record(id, 1, C.OTHERS, d, backer1);
        assertEq(r.counted + r.uncounted, 40_000 * T);
        assertLt(r.sqrtLeave, atLeave, "the dearer floor of the two");
    }
}

/// @dev `sync()` under the depth guard, the fail-closed reads (starved gas, a dirty registry word, a short transfer,
///      a lying swapper, a failing fee view) and `canBorrow` over an unreconciled repayment.
contract V5CoverReadsTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
    }

    function _guardOn() internal {
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        v5.sync();
        assertTrue(lens.depthGuardOn());
    }

    /// @dev Under the guard a cheaper median lowers the guard's low to it.
    function test_sync_guard_cheaperMedianLowersTheGuardLow() public {
        _calmWeek();
        _guardOn();
        uint160 low0 = lens.price().guardLow;
        _skip(1 days);
        _keeperPass(P0 * 80 / 100);
        assertGt(lens.price().guardLow, low0);
    }

    /// @dev Under the guard a new day's entry is at least as cheap as the week low the guard came on at.
    function test_sync_guard_newDayAtLeastTheGuardLow() public {
        _calmWeek();
        _skip(1 days);
        _keeperPass(P0 * 70 / 100);
        _skip(1 days);
        _keeperPass(P0);
        _guardOn();
        uint160 low = lens.price().guardLow;
        assertEq(low, _sqrtFor(P0 * 70 / 100));
        _skip(1 days);
        _keeperPass(P0);
        assertEq(lens.price().ringMax, low);
    }

    /// @dev Under the guard k_base never falls, even once the wide day has left the ring.
    function test_sync_guard_holdsKBase() public {
        _calmWeek();
        _skip(1 days);
        _keeperPass(P0 * 10 / 26);
        assertEq(lens.price().kBase, C.K_WILD);
        _guardOn();
        for (uint256 i = 0; i < 8; i++) {
            _skip(1 days);
            _keeperPass(P0);
        }
        assertEq(lens.price().kBase, C.K_WILD);
    }

    /// @dev A failing fee view reverts the whole sync() and writes nothing (deep audit H-01, L-07: a starved or failed
    ///      read is never recorded); the hook's own failed read (the view's ok false) is recorded as `feeOk` false.
    function test_sync_feeViewReverts_syncReverts_feeOkFalseOnlyFromTheView() public {
        _skipFresh(1 minutes);
        assertTrue(lens.price().feeOk);
        uint64 obsAt = lens.price().rawObsAt;
        limiter.setFeeReverts(true);
        _skip(1 minutes);
        sizer.set(_sqrtFor(P0), _sqrtFor(P0));
        vm.expectRevert(bytes("fee view down"));
        v5.sync();
        assertTrue(lens.price().feeOk, "unchanged");
        assertEq(lens.price().rawObsAt, obsAt, "nothing written");
        limiter.setFeeReverts(false);
        limiter.setFee(0, false);
        v5.sync();
        assertFalse(lens.price().feeOk, "the view's own ok false");
    }

    /// @dev A call with too little gas for the registry's bounded read reverts ReadStarved (never a silent failed
    ///      read); one with too little for the fixed-gas claim too.
    function test_readStarved_registryRead_andClaim() public {
        _open(id, 150_001 * T);
        bool sawRead;
        for (uint256 g = 60_000; g < 200_000 && !sawRead; g += 1_000) {
            (bool ok, bytes memory r) = address(v5).call{gas: g}(abi.encodeCall(v5.pokeFees, (id)));
            if (!ok && r.length == 4 && bytes4(r) == IV5Errors.ReadStarved.selector) sawRead = true;
        }
        assertTrue(sawRead, "ReadStarved on the registry read");
        bool sawClaim;
        for (uint256 g = 200_000; g < 420_000 && !sawClaim; g += 2_000) {
            (bool ok, bytes memory r) = address(v5).call{gas: g}(abi.encodeCall(v5.flush, ()));
            if (!ok && r.length == 4 && bytes4(r) == IV5Errors.ReadStarved.selector) sawClaim = true;
        }
        assertTrue(sawClaim, "ReadStarved on the claim");
    }

    function test_registryDirtyWord_failsTheRead() public {
        reg.setMode(5);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.RegistryRead.selector);
        v5.open(id, 150_001 * T, false, c, sig);
    }

    function test_pull_shortTransfer_reverts() public {
        _open(id, 150_001 * T);
        priors.setSkimFrom(backer1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.BadTransfer.selector);
        v5.back(id, 10_000 * T, false);
    }

    function test_zap_swapperDeliversLess_reverts() public {
        _open(id, 150_001 * T);
        swapper.setDeliver(9_000);
        vm.prank(backer1);
        vm.expectPartialRevert(IV5Errors.SwapShort.selector);
        v5.backWithUsdg(id, 0, 20 * U, 18_000 * T, block.timestamp + 300, false);
    }

    /// @dev A listed loan repaid on time and not yet reconciled does not block `canBorrow`.
    function test_canBorrow_listedRepaidLoan_notReconciled() public {
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 20 * U, 8 days);
        _skipFresh(1 days);
        _repay(l);
        assertEq(_gen(id).listLen, 1);
        assertTrue(v5.canBorrow(ROOT, id, 20 * U, 8 days, 1, _owner(id), _owner(id), _owner(id)));
    }
}

/// @dev Two paths that need a particular day: a leave across both pending slots, and a queued record that a forced
///      move joined the same day, settled later.
contract V5CoverDaysTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 1;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _open(id, 150_001 * T);
    }

    function test_leave_takesBothPendingSlots_olderFirst() public {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 22 hours);
        _keeperPass(P0);
        _back(backer1, id, 5_000 * T);
        _skipFresh(4 hours);
        _back(backer1, id, 5_000 * T);
        vm.prank(backer1);
        v5.leave(id, 8_000 * T, 0);
        S.Pos memory p = lens.position(id, 1, C.OTHERS, backer1);
        assertEq(p.a0 + p.a1, 2_000 * T, "2,000 left pending, on the newer day");
        assertEq(_gen(id).pendingTok[C.OTHERS], 2_000 * T);
    }

    function test_claimSettled_queuedRecordOfAForcedMove_unlinks() public {
        _back(backer1, id, 60_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
        vm.prank(backer1);
        v5.leave(id, 30_000 * T, 2);
        uint32 d = _today();
        vm.prank(_owner(id));
        v5.setOthersBacking(id, false); // the rest joins the same record, which keeps its mode
        _skipFresh(8 days);
        vm.prank(keeper); // the keeper's pass (2A.6)
        v5.queueExit(id, 1, backer1, C.OTHERS, d);
        uint256 l = _borrow(id, 40 * U, 8 days); // after the bucket's count: it does not hold the record
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        assertGt(lens.record(id, 1, C.OTHERS, d, backer1).entry, 0, "still queued");
        assertEq(_gen(id).layerEnd[C.OTHERS] / 1 days, d);
        uint256 b0 = priors.balanceOf(backer1);
        v5.claimSettled(id, 1, backer1);
        assertEq(priors.balanceOf(backer1) - b0, 30_000 * T);
        (uint256 head,,,,) = lens.exitHead();
        assertEq(head, 0);
    }
}
