// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {V5Lens} from "../../src/v5/V5Lens.sol";
import {V5Math as M} from "../../src/v5/V5Math.sol";

/// @dev `open` and `openWithUsdg` (2.5, 2A.1): the entry gate, the guards, the consent, the split of the owner's
///      stake, the line, the handoff, and every revert path.
contract V5OpenTest is V5Base {
    function _openAs(uint256 id, uint256 tokens, ICreditPoolV2.Consent memory c, bytes memory sig) internal {
        vm.prank(_owner(id));
        v5.open(id, tokens, false, c, sig);
    }

    function test_open_countsAtOnce_andRecordsTheLine() public {
        uint256 id = agents[0];
        vm.expectEmit(true, true, true, true, address(v5));
        emit IV5Events.BookOpened(id, 1, _owner(id), 121_000 * T, 40 * U);
        _open(id, 121_000 * T);
        S.Gen memory g = _gen(id);
        assertEq(g.counted[C.OWNER], 121_000 * T, "counted at once");
        assertEq(g.divisor, 121_000 * T);
        assertEq(g.openLine, 40 * U, "value 120 / k 3 = 40");
        assertEq(g.roomLine, 40 * U);
        assertEq(g.tier, 1);
        assertEq(pool.getAgent(id).sponsor, ROOT, "handoff from the old sponsor");
        assertEq(pool.getAgent(id).delegatedIn, 0, "question 40: nothing vouched at the open");
        assertEq(lens.lineOf(id), 40 * U);
        (uint256 l,) = _ledger();
        assertEq(l, 121_000 * T);
        assertEq(priors.balanceOf(address(v5)), 121_000 * T);
    }

    function test_open_minimumLine_25() public {
        uint256 id = agents[0];
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        assertEq(n.k, C.K_WILD, "fail-safe: k reads 3 at launch");
        // minA opens exactly $25 (the inverse of value()'s floors)
        _open(id, n.minA);
        assertEq(_gen(id).openLine, 25 * U);
    }

    function test_open_revert_lineTooSmall() public {
        uint256 id = agents[0];
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.LineTooSmall.selector, 20 * U));
        _openAs(id, n.minA - 1, c, sig);
    }

    function test_open_aboveThreeCeilings_goesToOwnBacking_andSixCeilingsReverts() public {
        uint256 id = agents[0];
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        uint256 capA = n.capA; // 3 × $50 at P
        _open(id, capA + 50_000 * T);
        S.Gen memory g = _gen(id);
        assertEq(g.counted[C.OWNER], capA);
        assertEq(g.counted[C.OWN], 50_000 * T);
        assertEq(lens.position(id, 1, C.OWN, _owner(id)).counted, 50_000 * T);

        uint256 id2 = agents[1];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id2, ROOT, 0);
        vm.expectRevert(IV5Errors.TooMuchStake.selector);
        _openAs(id2, 2 * capA + 1, c, sig);
    }

    function _specEntryRule() internal {
        vm.prank(timelock);
        v5.setEntryRule(3, 14);
    }

    function test_open_stakeOnlyEntry_freshAgentAtT1() public {
        (uint8 loans, uint32 days_) = lens.entryRule();
        assertEq(loans, 0);
        assertEq(days_, 0);
        uint256 id = _newAgent(0xF2E5);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        _openAs(id, 150_001 * T, c, sig);
        S.Gen memory g = _gen(id);
        assertEq(g.tier, 1);
        assertEq(g.openLine, 50 * U, "the stake buys T1's $50");
        uint256 l = _borrow(id, 50 * U, 8 days);
        assertGt(l, 0);
        // the ladder still needs the record: no promotion without 3 counted loans and 14 days
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotPromotable.selector, 2));
        v5.promote(id);
    }

    function test_setEntryRule_bounds() public {
        vm.expectRevert(IV5Errors.NotTimelock.selector);
        v5.setEntryRule(3, 14);
        vm.startPrank(timelock);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setEntryRule(4, 14);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setEntryRule(3, 15);
        v5.setEntryRule(1, 7);
        vm.stopPrank();
        (uint8 loans, uint32 days_) = lens.entryRule();
        assertEq(loans, 1);
        assertEq(days_, 7);
    }

    function test_open_entryGate() public {
        _specEntryRule();
        // a fresh agent: no record
        uint256 id = _newAgent(0xBEEF);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 3));
        _openAs(id, 150_000 * T, c, sig);
    }

    function test_open_entryGate_tooYoung() public {
        _specEntryRule();
        uint256 id = _newAgent(0xBEEF);
        (ICreditPoolV2.Consent memory c0, bytes memory s0) = _consent(id, OROOT, 0);
        vm.prank(otherRootOwner);
        pool.vouchWithConsent(OROOT, id, 100 * U, 0, c0, s0);
        uint256[3] memory ls;
        for (uint256 j = 0; j < 3; j++) {
            ls[j] = _borrowRaw(id, 5 * U, 7 days);
        }
        _skipFresh(7 days);
        for (uint256 j = 0; j < 3; j++) {
            _repay(ls[j]);
        }
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 4));
        _openAs(id, 150_000 * T, c, sig);
        _skipFresh(7 days);
        (c, sig) = _consent(id, ROOT, 0);
        _openAs(id, 150_000 * T, c, sig);
    }

    function test_open_entryGate_ownerDefaulted() public {
        // owner of agents[0] defaults on another agent it owns, under OROOT
        uint256 id = agents[0];
        uint256 other = _newAgentOwnedBy(pkOf[id]);
        (ICreditPoolV2.Consent memory c0, bytes memory s0) = _consent(other, OROOT, 0);
        vm.prank(otherRootOwner);
        pool.vouchWithConsent(OROOT, other, 10 * U, 0, c0, s0);
        uint256 loanId = _borrowRaw(other, 5 * U, 1 days);
        _skipFresh(5 days);
        pool.markDefault(loanId);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 5));
        _openAs(id, 150_000 * T, c, sig);
    }

    function test_open_entryGate_defaultedAgent_andRoot() public {
        uint256 id = agents[0];
        // default it under OROOT
        uint256 loanId = _borrowRaw(id, 5 * U, 1 days);
        _skipFresh(5 days);
        pool.markDefault(loanId);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 1));
        _openAs(id, 150_000 * T, c, sig);
        // a root cannot be an agent
        (c, sig) = _consentFor(OROOT, otherRootOwner, ROOT);
        vm.prank(otherRootOwner);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 2));
        v5.open(OROOT, 150_000 * T, false, c, sig);
    }

    function test_open_revert_loanOpen() public {
        uint256 id = agents[0];
        _borrowRaw(id, 5 * U, 7 days);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(IV5Errors.LoanOpen.selector);
        _openAs(id, 150_000 * T, c, sig);
    }

    function test_open_revert_notOwner_registryRead_premium() public {
        uint256 id = agents[0];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotOwner.selector);
        v5.open(id, 150_000 * T, false, c, sig);

        reg.setMode(1);
        vm.expectRevert(IV5Errors.RegistryRead.selector);
        _openAs(id, 150_000 * T, c, sig);
        reg.setMode(0);

        (c, sig) = _consent(id, ROOT, 1);
        vm.expectRevert(IV5Errors.PremiumCap.selector);
        _openAs(id, 150_000 * T, c, sig);

        // a target premium the consent does not reach
        vm.prank(timelock);
        v5.setPremiumCap(100);
        vm.prank(timelock);
        v5.setPremium(id, 50);
        (c, sig) = _consent(id, ROOT, 40);
        vm.expectRevert(IV5Errors.PremiumCap.selector);
        _openAs(id, 150_000 * T, c, sig);
        (c, sig) = _consent(id, ROOT, 50);
        _openAs(id, 150_000 * T, c, sig);
        assertEq(pool.getAgent(id).premiumBps, 50, "V5 forwards its own target premium");
    }

    function test_open_revert_guards() public {
        uint256 id = agents[0];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(guardian);
        v5.pause();
        vm.expectRevert(IV5Errors.Paused.selector);
        _openAs(id, 150_000 * T, c, sig);
        vm.prank(guardian);
        v5.unpause();

        limiter.setDepthTerm(400e6, 5_000e6, 60, true); // the live form
        vm.expectRevert(IV5Errors.DepthGuardOn.selector);
        _openAs(id, 150_000 * T, c, sig);
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);

        _setSpot(P0 * 79 / 100); // live spot at 0.79 × median
        vm.expectRevert(IV5Errors.SpotGuardOn.selector);
        _openAs(id, 150_000 * T, c, sig);
        _setSpot(P0);
    }

    function test_open_revert_noPrice() public {
        uint256 id = agents[0];
        _clearMedian();
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(IV5Errors.NoPrice.selector);
        _openAs(id, 150_000 * T, c, sig);
    }

    function test_open_reopenBan_andOnePerOwnerAWeek() public {
        uint256 id = agents[0];
        uint256 id2 = _newAgentOwnedBy(pkOf[id]);
        _qualify(id2);
        _open(id, 150_000 * T);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.expectRevert(IV5Errors.OpenTooSoon.selector);
        _openAs(id, 150_000 * T, c, sig);
        _skipFresh(7 days);
        (c, sig) = _consent(id, ROOT, 0);
        vm.expectRevert(IV5Errors.BookOpen.selector);
        _openAs(id, 150_000 * T, c, sig);
        // a book that borrowed, closed: 30-day ban
        uint256 loanId = _borrow(id, 25 * U, 8 days);
        _skipFresh(8 days);
        _repay(loanId);
        vm.prank(_owner(id));
        v5.close(id, 1);
        (c, sig) = _consent(id, ROOT, 0);
        vm.expectRevert(IV5Errors.ReopenBan.selector);
        _openAs(id, 150_000 * T, c, sig);
        _skipFresh(30 days);
        (c, sig) = _consent(id, ROOT, 0);
        _openAs(id, 150_000 * T, c, sig);
        assertEq(lens.latestGen(id), 2, "a new generation");

        // one open per owner address in any 7 days
        (c, sig) = _consent(id2, ROOT, 0);
        vm.expectRevert(IV5Errors.OpenTooSoon.selector);
        _openAs(id2, 150_000 * T, c, sig);
    }

    function test_open_idleCloseOfABookThatNeverBorrowed_noBan() public {
        uint256 id = agents[0];
        _open(id, 150_000 * T);
        _skipFresh(30 days);
        v5.expire(id);
        assertEq(lens.reopenAt(id), 0);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        _openAs(id, 150_000 * T, c, sig);
        assertEq(lens.latestGen(id), 2);
    }

    function test_openWithUsdg_mixedPay_valuesAtSpotBeforeTheSwap() public {
        uint256 id = agents[0];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        uint256 usdgBefore = usdg.balanceOf(_owner(id));
        vm.prank(_owner(id));
        v5.openWithUsdg(id, 50_000 * T, 100 * U, 90_000 * T, block.timestamp + 300, true, c, sig);
        S.Gen memory g = _gen(id);
        // 100 USDG at $0.001 less the hook's 3% = 97,000 $PRIORS
        assertApproxEqAbs(g.counted[C.OWNER], 147_000 * T, 1e9);
        assertEq(usdgBefore - usdg.balanceOf(_owner(id)), 100 * U);
        assertEq(usdg.allowance(address(v5), address(swapper)), 0, "allowance reset");
        assertTrue(lens.position(id, 1, C.OWNER, _owner(id)).autoAdd);
    }

    function test_openWithUsdg_refundsUnspent_andRevertsShort() public {
        uint256 id = agents[0];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        swapper.setPayPart(9_000); // the swap consumes 90%
        uint256 before = usdg.balanceOf(_owner(id));
        vm.prank(_owner(id));
        v5.openWithUsdg(id, 0, 200 * U, 1, block.timestamp + 300, false, c, sig);
        assertEq(before - usdg.balanceOf(_owner(id)), 180 * U, "unspent USDG refunded");
        assertEq(usdg.balanceOf(address(v5)), 0);
    }

    function test_openWithUsdg_reverts() public {
        uint256 id = agents[0];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        // the swapper's own bound
        vm.prank(_owner(id));
        vm.expectRevert();
        v5.openWithUsdg(id, 0, 200 * U, 1_000_000 * T, block.timestamp + 300, false, c, sig);
        // over maxSwapUsdg
        vm.prank(_owner(id));
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.SplitNeeded.selector, 2_000 * U, 1_900 * U));
        v5.openWithUsdg(id, 0, 2_000 * U, 1, block.timestamp + 300, false, c, sig);
        // a stale cache closes the USDG path
        _skip(46 minutes);
        vm.prank(_owner(id));
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 1));
        v5.openWithUsdg(id, 0, 200 * U, 1, block.timestamp + 300, false, c, sig);
        _keeperPass(P0);
        // no readable cap
        limiter.setCap(0, false);
        vm.prank(_owner(id));
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.UsdgPathClosed.selector, 2));
        v5.openWithUsdg(id, 0, 200 * U, 1, block.timestamp + 300, false, c, sig);
        limiter.setCap(2_169e6, true);
        // nothing posted
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.ZeroAmount.selector);
        v5.openWithUsdg(id, 0, 0, 0, block.timestamp + 300, false, c, sig);
    }

    function test_open_staleCache_sizesAtK3() public {
        uint256 id = agents[0];
        _calmWeek();
        assertEq(lens.kEff(), C.K_CALM);
        _skip(46 minutes);
        assertEq(lens.kEff(), C.K_WILD, "a cache over 45 min reads k 3");
        _open(id, 121_000 * T);
        assertEq(_gen(id).openLine, 40 * U);
    }

    function test_open_calmWeek_k15() public {
        uint256 id = agents[0];
        _calmWeek();
        _open(id, 60_100 * T); // $60.1 at P / 1.5 = $40.07, floored to $40
        assertEq(_gen(id).openLine, 40 * U);
    }

    function test_open_pokesThePreviousGeneration_feesStayThere() public {
        uint256 id = agents[0];
        _open(id, 150_000 * T);
        uint256 loanId = _borrow(id, 50 * U, 8 days);
        _skipFresh(8 days);
        _repay(loanId);
        vm.prank(_owner(id));
        v5.close(id, 1);
        _skipFresh(30 days);
        uint256 idx1 = lens.getGen(id, 1).index;
        _open(id, 150_000 * T);
        assertGt(lens.getGen(id, 1).index, idx1 - 1);
        assertEq(lens.getGen(id, 2).index, 0, "the new generation starts at 0");
    }

    function test_open_recordsTheDelegate() public {
        uint256 id = agents[0];
        address d = makeAddr("delegate");
        vm.prank(_owner(id));
        pool.setDelegate(id, d);
        _open(id, 150_000 * T);
        (address who, uint64 at) = lens.delegateOf(id);
        assertEq(who, d);
        assertEq(at, block.timestamp);
    }

    // helpers

    function _newAgentOwnedBy(uint256 pk) internal returns (uint256 id) {
        vm.prank(vm.addr(pk));
        id = reg.register("agent-2");
        pkOf[id] = pk;
    }

    function _qualify(uint256 id) internal {
        (ICreditPoolV2.Consent memory c0, bytes memory s0) = _consent(id, OROOT, 0);
        vm.prank(otherRootOwner);
        pool.vouchWithConsent(OROOT, id, 100 * U, 0, c0, s0);
        uint256[3] memory ls;
        for (uint256 j = 0; j < 3; j++) {
            ls[j] = _borrowRaw(id, 5 * U, 7 days);
        }
        _skip(7 days);
        for (uint256 j = 0; j < 3; j++) {
            _repay(ls[j]);
        }
        _skip(7 days + 1);
        _keeperPass(P0);
    }

    function _consentFor(uint256 id, address o, uint256 sponsor)
        internal
        view
        returns (ICreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = ICreditPoolV2.Consent({
            agentId: id,
            sponsorId: sponsor,
            owner: o,
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: block.timestamp
        });
        sig = "";
    }

    function _clearMedian() internal {
        // Price layout: slot0 rawMedian|rawObsAt, slot1 median, ...: zero `median` in the namespaced storage
        bytes32 base = 0xcdde73c5677481b13a9fd0c58a089a0307b78e5c27d24daeaaa5854a73c18400;
        uint256 priceSlot0 = uint256(base) + _priceOffset();
        vm.store(address(v5), bytes32(priceSlot0 + 1), bytes32(0));
        assertEq(lens.price().median, 0);
    }

    /// @dev the word offset of Layout.price: keeper|openBacking|premiumCheck|minDrawK|premiumCheckFrom (1),
    ///      premiumCap, maxSwapUsdg, openRoom, raiseRoom, vouchCap (5), pausedUntil|pauseEnd|rootReady (1),
    ///      childBase, recordedDefaults (2) = 9
    function _priceOffset() internal pure returns (uint256) {
        return 9;
    }
}
