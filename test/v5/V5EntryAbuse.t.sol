// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors} from "../../src/v5/V5Types.sol";
import {V5Math as M} from "../../src/v5/V5Math.sol";

/// @dev Stake-only entry at T1 (the owner's addition: "you can already start a bigger line if you back with $PRIORS";
///      docs/V5-BUILD.md, decision E1). An agent with no record opens T1 on its owner's stake alone. These tests show
///      the abuse does not pay: a fresh book that draws and defaults burns more than its line at every k, stays
///      unprofitable up to section 3.3's walk-away thresholds exactly as an aged T1 book does, and many fresh agents
///      draw no more than one line each, inside the week's open room and the breaker.
contract V5EntryAbuseTest is V5Base {
    uint256 internal constant LINE = 50 * U;

    function _agentCount() internal pure override returns (uint256) {
        return 1;
    }

    /// @dev Sets the week up for doubled k `kx2` and returns P (18-decimal USDG per $PRIORS) the line is sized at.
    function _regime(uint8 kx2) internal returns (uint256 pE18) {
        if (kx2 == C.K_WILD) return P0; // the fail-safe: under 7 observed days
        _calmWeek();
        if (kx2 == C.K_CALM) return P0;
        // two days at 0.6 × P0: the range 1.67 reads normal once the undercut's step-up has passed
        _skip(1 days);
        _keeperPass(P0 * 60 / 100);
        _skip(1 days);
        _keeperPass(P0 * 60 / 100);
        return P0 * 60 / 100;
    }

    /// @dev The smallest whole-token stake whose value at P buys the $50 T1 line at `kx2` (a token over k × line).
    function _minStake(uint8 kx2, uint256 pE18) internal pure returns (uint256) {
        return (LINE * kx2 / 2) * 1e12 * 1e18 / pE18 + 1e18;
    }

    /// @dev A fresh agent (no loans, enrolled this block) opens on its stake alone, draws the full line, defaults.
    ///      Returns the stake, what burned and what the owner got back.
    function _freshDefault(uint8 kx2)
        internal
        returns (uint256 a, uint256 own, uint256 burned, uint256 back, uint256 pE18)
    {
        pE18 = _regime(kx2);
        assertEq(lens.kEff(), kx2, "the regime");
        uint256 id = _newAgent(0xF00D + kx2);
        a = _minStake(kx2, pE18);
        _open(id, a);
        S.Gen memory g = _gen(id);
        assertEq(g.tier, 1, "T1");
        assertEq(g.openLine, LINE, "the whole T1 line on the stake alone");
        own = g.counted[C.OWN];
        a = g.counted[C.OWNER];
        uint256 l = _borrow(id, LINE, 8 days);
        (,,,,, uint256 b0,) = lens.totals();
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        assertEq(_gen(id).status, C.SETTLED);
        (,,,,, uint256 b1,) = lens.totals();
        burned = b1 - b0;
        uint256 p0 = priors.balanceOf(_owner(id));
        v5.claimSettled(id, 1, _owner(id));
        back = priors.balanceOf(_owner(id)) - p0;
    }

    function _usd(uint256 tokens, uint256 pE18) internal pure returns (uint256) {
        return tokens * pE18 / 1e30;
    }

    function _check(uint8 kx2) internal {
        (uint256 a, uint256 own, uint256 burned, uint256 back, uint256 p) = _freshDefault(kx2);
        assertEq(burned, M.burnOf(a, C.OWNER_BURN_BPS) + M.burnOf(own, C.BACK_BURN_BPS), "75% of A, 50% of own");
        assertEq(back + burned, a + own, "the rest comes back, nothing more");
        uint256 burnedUsd = _usd(burned, p);
        // 0.75 × k lines: 1.125 / 1.5 / 2.25 at k 1.5 / 2 / 3
        assertGe(burnedUsd * 2, LINE * 3 * kx2 / 4 * 2 / 2, "burns 0.75 k lines at P");
        assertGt(burnedUsd, LINE, "burns more than the line at every k");
        // section 3.3: walking away pays only past a fall of 1 − d ÷ (0.75 k) (d = 1, fully drawn). One basis point
        // short of it, the burned stake is still worth the line drawn.
        uint256 thresholdBps = 10_000 - 10_000 * 4 * 2 / (3 * kx2); // 1111 / 3333 / 5555 bps
        uint256 fallen = p * (10_000 - thresholdBps + 1) / 10_000;
        assertGe(_usd(burned, fallen), LINE - 1, "unprofitable up to the 3.3 threshold");
    }

    function test_stakeOnly_default_burnsMoreThanTheLine_kCalm() public {
        _check(C.K_CALM);
    }

    function test_stakeOnly_default_burnsMoreThanTheLine_kNormal() public {
        _check(C.K_NORMAL);
    }

    function test_stakeOnly_default_burnsMoreThanTheLine_kWild() public {
        _check(C.K_WILD);
    }

    /// @dev Stake-only entry changes nothing in 3.3: a fresh book and an aged T1 book on the same stake get the same
    ///      line and burn the same tokens, so their walk-away thresholds are the same.
    function test_stakeOnly_sameTermsAsAnAgedT1Book() public {
        uint256 aged = agents[0];
        uint256 fresh = _newAgent(0xF2E5);
        _open(aged, 150_001 * T);
        _open(fresh, 150_001 * T);
        S.Gen memory ga = _gen(aged);
        S.Gen memory gf = _gen(fresh);
        assertEq(gf.tier, ga.tier);
        assertEq(gf.openLine, ga.openLine);
        assertEq(gf.counted[C.OWNER], ga.counted[C.OWNER]);
        assertEq(lens.lineOf(fresh), lens.lineOf(aged));
    }

    /// @dev The stake must cover the line: a fresh owner short of k × $25 at P cannot open at all, and the line never
    ///      exceeds T1's ceiling however large the stake.
    function test_stakeOnly_coverRuleUnchanged() public {
        uint256 id = _newAgent(0xF2E6);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.LineTooSmall.selector, 20 * U));
        v5.open(id, 74_000 * T, false, c, sig); // $74 at k 3: a $24.67 line
        uint256 id2 = _newAgent(0xF2E7);
        _open(id2, 290_000 * T);
        assertEq(_gen(id2).openLine, LINE, "T1's ceiling");
        assertApproxEqAbs(
            _gen(id2).counted[C.OWNER], 150_000 * T, 1e15, "3x the ceiling into A, the rest is own backing"
        );
    }

    /// @dev Sybil: many fresh agents, each with its own owner address. Each opens at most one $50 line; together they
    ///      draw no more than the week's open room; past $250 of defaults the breaker stops new books; and every
    ///      defaulted book burns more than it drew.
    uint256[] internal sIds;
    uint256[] internal sLoans;

    function _canFirst(uint256 id, uint256 amount) internal view returns (bool) {
        address o = _owner(id);
        return v5.canBorrow(ROOT, id, amount, 8 days, 1, o, o, o);
    }

    function _sybilBorrow(uint256 n) internal returns (uint256 books) {
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _newAgent(0x5B11 + i);
            sIds.push(id);
            _open(id, 150_001 * T);
            assertEq(_gen(id).openLine, LINE, "one T1 line per agent, whatever the count");
            vm.prank(_owner(id));
            v5.refresh(id);
            if (_canFirst(id, LINE)) {
                sLoans.push(_borrowRaw(id, LINE, 8 days));
                books++;
            }
        }
    }

    function test_stakeOnly_sybil_boundedByRoomsAndBreaker() public {
        uint256 books = _sybilBorrow(12);
        uint256 drawn = books * LINE;
        (,,, uint256 openRoom,,,,,) = lens.settings();
        assertEq(books, openRoom / LINE, "the week's open room admits 10 first loans of $50");
        assertEq(sLoans.length, books, "and they are the first 10");
        // the rest wait for next week's room, no matter how many agents
        for (uint256 i = books; i < sIds.length; i++) {
            assertFalse(_canFirst(sIds[i], 5 * U), "a first loan past the open room");
        }
        // all default: the breaker trips at $250, and every book burned more than its line
        (,,,,, uint256 b0,) = lens.totals();
        _skipFresh(11 days + 1);
        for (uint256 i = 0; i < books; i++) {
            pool.markDefault(sLoans[i]);
        }
        v5.sync();
        assertTrue(lens.breakerTripped(), "the breaker trips");
        (,,,,, uint256 b1,) = lens.totals();
        assertGt(_usd(b1 - b0, P0), drawn, "the attacker burns more than it drew");
        S.Gen memory g0 = _gen(sIds[0]);
        assertEq(
            b1 - b0,
            books * (M.burnOf(g0.counted[C.OWNER], C.OWNER_BURN_BPS) + M.burnOf(g0.counted[C.OWN], C.BACK_BURN_BPS))
        );
        // no new book while tripped, even with a fresh agent and a fresh address
        uint256 late = _newAgent(0x5B99);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(late, ROOT, 0);
        vm.prank(_owner(late));
        vm.expectRevert(IV5Errors.BreakerOn.selector);
        v5.open(late, 150_001 * T, false, c, sig);
    }

    /// @dev The ladder above T1 still needs the record: a stake-only book with a larger stake still cannot promote
    ///      without three counted loans and 14 days at T1.
    function test_stakeOnly_noClimbWithoutTheRecord() public {
        uint256 id = _newAgent(0xF2E8);
        _open(id, 290_000 * T);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotPromotable.selector, 2));
        v5.promote(id);
        _skipFresh(15 days);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotPromotable.selector, 3));
        v5.promote(id);
    }

    /// @dev With the spec's entry rule restored by the timelock, a fresh agent is refused again.
    function test_entryRule_specRestored_refusesFresh() public {
        vm.prank(timelock);
        v5.setEntryRule(3, 14);
        uint256 id = _newAgent(0xF2E9);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 3));
        v5.open(id, 150_001 * T, false, c, sig);
    }
}
