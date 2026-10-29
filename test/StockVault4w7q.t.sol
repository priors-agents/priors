// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StockVault3vg6.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// GHSA-4w7q-8vph-j5mr (hey-research-lab): a price tape that had fallen behind resumed at the round after its last,
/// whatever the gap. PtLinearDiscountFeed (PT-USDG's feed) serves only its last 1,024 rounds, so once a tape is 1,025
/// rounds behind (35.6 days at the fastest push, about 43 at the live pace) every round from the one after its last is
/// one the feed has dropped: each was recorded as unreadable on the day it was recorded (SV-19's rule), and that day's
/// lowest answer of 0 held new PT credit for the 14-day window from it (about 15 days) with nothing moved. A PT default
/// waiting on the tape (SV-19's TapeBehind) can settle only after that record, under the hold, and seized every token
/// instead of what is owed plus 20%. The fix: a tape resumes after its last round only while that round can still be
/// read and was published within TAPE_FROM (20 days); otherwise it begins again where a new tape begins.
///
/// The report's two cases, then both sides of the rule. StockVault3vg6Test's 7 cases (SV-20) run here too, inherited.
contract StockVault4w7qTest is StockVault3vg6Test {
    /// The report's default: a $200 loan on 500 PT at the live pace (the keeper recording), then 1,100 rounds (46 days)
    /// with nobody recording the tape. The default waits for the tape (TapeBehind); once anyone records it, the seizure
    /// takes what is owed plus 20% at the feed's price and gives the rest back (SV-11).
    function test_resumedTapePastTheRing_defaultSeizesOwedPlusBuffer() public {
        _push(400, 1 hours, 12);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vault.open(AGENT, address(pt), 500 * PT_UNIT, c, sig);
        uint256 loanId = _borrow(agentOp, AGENT, 200 * USDC);
        assertEq(vault.lendStatus(address(pt)), 0);
        (uint80 last,) = vault.holds().tapes(address(feed));

        _push(1100, 1 hours, 0);
        vm.expectRevert(abi.encodeWithSelector(PtLinearDiscountFeed.NoRound.selector, last + 1));
        feed.getRoundData(last + 1); // the round after the tape's last: dropped from the ring
        uint256 b0 = pt.balanceOf(agentOp);
        vm.prank(anyone);
        pool.markDefault(loanId); // the hook reverts TapeBehind: the position waits
        assertEq(uint256(vault.getPosition(AGENT).status), uint256(StockVault.Status.Open), "waiting");
        vm.expectRevert(abi.encodeWithSelector(StockVault.TapeBehind.selector, address(feed)));
        vault.settle(AGENT, 0);

        _record(address(feed)); // the only way to let the waiting default settle
        (uint80 through,) = vault.holds().tapes(address(feed));
        assertEq(through, feed.latestRound(), "the tape is current again");
        CreditPoolV2.Loan memory l = pool.getLoan(loanId);
        uint256 owed = l.principal + l.fee;
        (, int256 answer,,,) = feed.latestRoundData();
        // PT 6 decimals, the feed 18: owed + 20% in PT base units at the feed's price, rounded up
        uint256 fair = Math.mulDiv(owed * 12_000, 1e18, 10_000 * uint256(answer), Math.Rounding.Ceil);
        vm.prank(anyone);
        vault.settle(AGENT, 0);
        uint256 seized = pt.balanceOf(treasury);
        emit log_named_uint("owed (USDG base units)", owed);
        emit log_named_uint("owed + 20% in PT at the feed's price", fair);
        emit log_named_uint("seized PT", seized);
        emit log_named_uint("returned PT", pt.balanceOf(agentOp) - b0);
        assertEq(seized, fair, "SV-11: owed + 20% at the price");
        assertEq(pt.balanceOf(agentOp) - b0, 500 * PT_UNIT - seized, "the rest back to the depositor");
        assertEq(vault.lendStatus(address(pt)), 0, "no hold: the price is linear");
    }

    /// The report's second case, with no default: 20 days at the live pace after that record, the tape recorded every
    /// hour, PT credit is never held (the price is linear throughout).
    function test_resumedTapePastTheRing_holdsNothing() public {
        _push(400, 1 hours, 12);
        _push(1100, 1 hours, 0);
        _record(address(feed));
        uint256 heldHours;
        for (uint256 i; i < 24 * 20; ++i) {
            vm.warp(_now() + 1 hours);
            feed.push();
            _record(address(feed));
            if (vault.lendStatus(address(pt)) != 0) heldHours++;
        }
        emit log_named_uint("hours PT credit was held, price linear throughout", heldHours);
        assertEq(heldHours, 0, "nothing moved: no hold");
    }

    /// Where it begins: a tape whose last round the ring dropped begins again at the first round of the last 20 days
    /// (read from the feed by the test), as a new tape does, not at the round after its last.
    function test_resumedTapePastTheRing_beginsAgainAtTheCut() public {
        _push(400, 1 hours, 12);
        _push(1100, 1 hours, 0);
        uint256 first = _firstAfter(address(feed), _now() - 20 days);
        assertEq(first, 1501 - 20 * 24 + 1, "the last 20 days: 480 hourly rounds");
        assertEq(_recordNew(address(feed)), first, "the tape begins again at the first round of the last 20 days");
        assertEq(_phaseBegan(address(feed)), 0, "a feed 62 days old is not a phase begun now");
        assertEq(vault.lendStatus(address(pt)), 0, "nothing moved: no hold");
    }

    /// Unchanged: a tape behind by less than the ring and less than 20 days (300 hourly rounds, 12.5 days) resumes at
    /// the round after its last, and lends.
    function test_tapeBehindWithinTheRingAndTheWindow_resumesAfterItsLastRound() public {
        _push(400, 1 hours, 12);
        (uint80 last,) = vault.holds().tapes(address(feed));
        _push(300, 1 hours, 0);
        assertEq(_recordNew(address(feed)), uint256(last) + 1, "the tape resumes after its last round");
        assertEq(vault.lendStatus(address(pt)), 0);
    }

    /// The rule's other side, on a feed that serves every round (as the 35 stock feeds do): a tape whose last round was
    /// published more than 20 days ago begins again at the first round of the last 20 days, skipping only rounds no
    /// window reads, as a new tape does; nothing moved, so it lends.
    function test_tapeLastRoundOlderThanTwentyDays_beginsAgainAtTheCut() public {
        MockStock tok = new MockStock("OLD");
        MockFeed f = new MockFeed(8, 40e8);
        vm.warp(_now() + 40 days);
        for (uint256 h = 35 * 24; h > 0; h -= 3) {
            f.set(40e8, _now() - h * 1 hours);
        }
        f.set(40e8, _now());
        vm.prank(owner);
        vault.setAsset(address(tok), address(f), 4 days, true, 2500, uint128(500 * USDC));
        _record(address(f));
        (uint80 last,) = vault.holds().tapes(address(f));
        assertEq(last, f.rounds(), "the tape is current");

        uint256 t0 = _now();
        vm.warp(t0 + 30 days); // nobody records for 30 days; the feed publishes every 3 hours
        for (uint256 t = t0 + 3 hours; t <= _now(); t += 3 hours) {
            f.set(40e8, t);
        }
        uint256 first = _firstAfter(address(f), _now() - 20 days);
        assertGt(first, uint256(last) + 1);
        assertEq(_recordNew(address(f)), first, "the tape begins again at the first round of the last 20 days");
        assertEq(vault.lendStatus(address(tok)), 0, "nothing moved: no hold");
    }
}
