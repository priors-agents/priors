// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolV2} from "./IPoolV2.sol";
import {IncomeBase, AssetOnly, ReenteringHook, ReenteringToken} from "./IncomeBase.sol";
import {IncomeRouter, IncomeBox, IIncomeRouterPool} from "../../src/IncomeRouter.sol";
import {AutoRepayV2, IAutoRepayV2Pool, IAutoRepayV2Savings} from "../../src/AutoRepayV2.sol";

contract Junk is ERC20 {
    constructor() ERC20("Junk", "JNK") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev The IncomeRouter's unit suite: section 5's forge "Unit" list of
///      docs/proposals/2026-11-01-income-repay-and-inference-on-credit.md, one group per item, on the real pool
///      (deployed from its artifact) and a USDG stand-in with the issuer's freezes, pause and seizure.
contract IncomeRouterTest is IncomeBase {
    uint256 constant ALL = 10_000;
    uint256 constant CAP = 60 * U;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructor_readsThePoolAndChecksItsArguments() public {
        assertEq(address(router.pool()), address(pool));
        assertEq(address(router.usdg()), address(usdg));
        assertEq(address(router.registry()), address(reg));
        assertEq(router.PAUSER(), safe);
        assertEq(router.WINDOW(), WIN);
        assertEq(router.BOX_CODE_HASH(), keccak256(type(IncomeBox).creationCode));
        assertEq(router.VERSION(), 1);
        IIncomeRouterPool p = IIncomeRouterPool(address(pool));
        vm.expectRevert(IncomeRouter.ZeroAddress.selector);
        new IncomeRouter(IIncomeRouterPool(address(0)), safe, WIN);
        vm.expectRevert(IncomeRouter.ZeroAddress.selector);
        new IncomeRouter(p, address(0), WIN);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadWindow.selector, uint64(2 hours - 1)));
        new IncomeRouter(p, safe, 2 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadWindow.selector, uint64(24 hours + 1)));
        new IncomeRouter(p, safe, 24 hours + 1);
        new IncomeRouter(p, safe, 2 hours);
        new IncomeRouter(p, safe, 24 hours);
    }

    // ------------------------------------------------------------------
    // The box's address before and after its deploy; only the router moves its money
    // ------------------------------------------------------------------

    function test_box_addressKnownBeforeDeploy_sameAfter() public {
        address box = router.incomeAddressOf(AGENT);
        assertEq(
            box, vm.computeCreate2Address(bytes32(AGENT), keccak256(type(IncomeBox).creationCode), address(router))
        );
        assertEq(box.code.length, 0, "not deployed yet");
        _pay(AGENT, 7 * U); // money lands before the box exists
        assertEq(_bal(box), 7 * U);
        IncomeRouter.Summary memory v = router.check(AGENT);
        assertEq(v.box, box);
        assertFalse(v.deployed);
        assertEq(v.unswept, 7 * U);

        _enroll(owner, AGENT, ALL, payout, CAP, false);
        uint256[] memory none = new uint256[](0);
        vm.expectEmit(address(router));
        emit IncomeRouter.BoxDeployed(AGENT, box);
        router.sweep(AGENT, none);
        assertGt(box.code.length, 0);
        assertEq(IncomeBox(box).router(), address(router));
        assertTrue(router.isBox(box));
        assertEq(router.incomeAddressOf(AGENT), box, "the same address after the deploy");
        assertEq(_bal(payout), 7 * U, "no loan: everything forwarded");

        // the second sweep deploys nothing
        _pay(AGENT, 1 * U);
        vm.recordLogs();
        _sweep(AGENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IncomeRouter.BoxDeployed.selector, "deployed once");
        }
    }

    function test_box_addressDiffersPerAgentAndPerRouter() public {
        uint256 other = _newAgent(buyer, BUYER_PK, address(0), ROOT);
        IncomeRouter r2 = new IncomeRouter(IIncomeRouterPool(address(pool)), safe, WIN);
        assertTrue(router.incomeAddressOf(AGENT) != router.incomeAddressOf(other));
        assertTrue(router.incomeAddressOf(AGENT) != r2.incomeAddressOf(AGENT));
    }

    function test_box_onlyTheRouterMovesItsMoney() public {
        _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 10 * U);
        _sweep(AGENT); // deploys; sets the 10 aside
        address box = _box(AGENT);
        _pay(AGENT, 5 * U);
        address[4] memory callers = [owner, key, anyone, safe];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IncomeBox.NotRouter.selector, callers[i]));
            IncomeBox(box).move(IERC20(address(usdg)), callers[i], 1);
        }
        // no allowance either: the box never approves anything
        assertEq(usdg.allowance(box, owner), 0);
        assertEq(usdg.allowance(box, address(router)), 0);
        assertEq(_bal(box), 15 * U);
    }

    /// I13: the box has no key and answers no signature check, so no EIP-3009 or permit signature can move its USDG
    /// (a token that takes contract signatures asks ERC-1271, and the box has no such function and no fallback).
    function test_box_answersNoSignatureCheck_andTakesNoEther() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _sweep(AGENT);
        address box = _box(AGENT);
        (bool ok,) = box.staticcall(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok, "no ERC-1271");
        (ok,) = box.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner");
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (ok,) = box.call{value: 1}("");
        assertFalse(ok, "no receive");
    }

    // ------------------------------------------------------------------
    // Plans
    // ------------------------------------------------------------------

    function test_enroll_onlyTheRegistryOwner() public {
        vm.prank(key); // the agent's own key, its declared wallet and pool delegate
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NotOwner.selector, AGENT, key));
        router.enroll(AGENT, ALL, payout, CAP, false);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NotOwner.selector, AGENT, anyone));
        router.enroll(AGENT, ALL, payout, CAP, false);

        vm.expectEmit(address(router));
        emit IncomeRouter.Synced(AGENT, owner, 1);
        vm.expectEmit(address(router));
        emit IncomeRouter.Enrolled(AGENT, owner, 2500, payout, CAP, true, 1);
        _enroll(owner, AGENT, 2500, payout, CAP, true);
        (address to, uint16 share, uint32 cap, uint32 epoch, bool on, bool early) = router.planOf(AGENT, owner);
        assertEq(to, payout);
        assertEq(share, 2500);
        assertEq(cap, CAP);
        assertEq(epoch, 1);
        assertTrue(on);
        assertTrue(early);

        // set again: replaced
        _enroll(owner, AGENT, ALL, payout2, 25 * U, false);
        (to, share, cap, epoch, on, early) = router.planOf(AGENT, owner);
        assertEq(to, payout2);
        assertEq(share, ALL);
        assertEq(cap, 25 * U);
        assertFalse(early);
    }

    function test_enroll_refusesBadShareCapAndPayout() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadShare.selector, 10_001));
        router.enroll(AGENT, 10_001, payout, CAP, false);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadCap.selector, 0));
        router.enroll(AGENT, ALL, payout, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadCap.selector, 2_000e6 + 1));
        router.enroll(AGENT, ALL, payout, 2_000e6 + 1, false);
        router.enroll(AGENT, 0, payout, 2_000e6, false); // the bounds themselves are fine
        vm.stopPrank();

        // never nothing, the router, the pool, USDG, the agent's own box (deployed or not), or another deployed box
        uint256 other = _newAgent(buyer, BUYER_PK, address(0), ROOT);
        _enroll(buyer, other, 0, payout, CAP, false);
        _sweep(other); // deploys the other agent's box
        address[6] memory bad = [address(0), address(router), address(pool), address(usdg), _box(AGENT), _box(other)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadPayout.selector, bad[i]));
            router.enroll(AGENT, ALL, bad[i], CAP, false);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadPayout.selector, bad[i]));
            router.setPayout(AGENT, bad[i]);
        }
        // the agent's own declared wallet, the owner itself, or any other address are fine
        _enroll(owner, AGENT, ALL, key, CAP, false);
        _enroll(owner, AGENT, ALL, owner, CAP, false);
    }

    function test_enroll_revertsWhenTheRegistryDoesNotAnswer() public {
        reg.setOwnerBroken(true);
        vm.prank(owner);
        vm.expectRevert("registry down");
        router.enroll(AGENT, ALL, payout, CAP, false);
    }

    function test_sync_emitsOnlyOnChange() public {
        vm.recordLogs();
        assertEq(router.sync(AGENT), 1);
        assertEq(router.sync(AGENT), 1);
        assertEq(vm.getRecordedLogs().length, 1, "one Synced: the first sight");
        (address o, uint32 e) = router.seen(AGENT);
        assertEq(o, owner);
        assertEq(e, 1);
        vm.prank(owner);
        reg.transferFrom(owner, buyer, AGENT);
        assertEq(router.sync(AGENT), 2);
    }

    // ------------------------------------------------------------------
    // The split: fuzzed share and amounts, rounding up for the loan; never above the need
    // ------------------------------------------------------------------

    function testFuzz_split(uint256 share, uint256 amount, uint256 principal, uint256 already) public {
        share = bound(share, 0, ALL);
        amount = bound(amount, 0, 10_000 * U);
        principal = bound(principal, 5 * U, 400 * U);
        uint256 loanId = _borrowAs(key, AGENT, principal, 14 days);
        uint256 due = _due(loanId);
        // something may already be set aside from an earlier sweep
        _enroll(owner, AGENT, ALL, payout, 2_000e6, false);
        already = bound(already, 0, due);
        _pay(AGENT, already);
        _sweep(AGENT);
        assertEq(router.setAsideOf(AGENT, owner), already);

        _enroll(owner, AGENT, share, payout, 2_000e6, false);
        uint256 before = _bal(payout);
        _pay(AGENT, amount);
        (uint256 arrived, uint256 put, uint256 forwarded, uint256 released) = _sweep(AGENT);
        uint256 need = due - already;
        uint256 shareUp = (amount * share + ALL - 1) / ALL;
        assertEq(arrived, amount, "arrived: what came in since the last sweep");
        assertEq(put, shareUp < need ? shareUp : need, "the share rounded up, at most the need");
        assertEq(put + forwarded, arrived, "every unit split once");
        assertEq(released, 0);
        assertLe(router.setAsideOf(AGENT, owner), due, "never above the need");
        assertEq(_bal(payout) - before, forwarded);
        assertEq(_bal(_box(AGENT)), router.setAsideTotal(AGENT), "the box holds exactly the set-asides");
        // rounding favours the loan: the payout gets at most one unit less than its exact share
        if (put < need) assertLe(amount * (ALL - share), forwarded * ALL + ALL);
    }

    function test_split_roundsUpForTheLoan() public {
        _borrow(14 days);
        _enroll(owner, AGENT, 3333, payout, CAP, false);
        _pay(AGENT, 1);
        (, uint256 put, uint256 fwd,) = _sweep(AGENT);
        assertEq(put, 1, "a third of one unit, rounded up");
        assertEq(fwd, 0);
        _pay(AGENT, 10);
        (, put, fwd,) = _sweep(AGENT);
        assertEq(put, 4, "3.333 rounded up");
        assertEq(fwd, 6);
    }

    function test_split_everythingUntilCovered_thenForwardsAll() public {
        uint256 loanId = _borrow(14 days);
        uint256 due = _due(loanId);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 20 * U);
        (, uint256 put, uint256 fwd,) = _sweep(AGENT);
        assertEq(put, 20 * U);
        assertEq(fwd, 0);
        _pay(AGENT, due); // more than the rest of the need
        (, put, fwd,) = _sweep(AGENT);
        assertEq(put, due - 20 * U, "only what the loan still needs");
        assertEq(fwd, 20 * U);
        assertEq(router.setAsideOf(AGENT, owner), due);
        _pay(AGENT, 3 * U);
        (, put, fwd,) = _sweep(AGENT);
        assertEq(put, 0, "covered: everything goes on");
        assertEq(fwd, 3 * U);
        assertEq(_bal(payout), 23 * U);
    }

    function test_split_zeroShareIsAForwarder() public {
        _borrow(14 days);
        _enroll(owner, AGENT, 0, payout, CAP, false);
        _pay(AGENT, 30 * U);
        (uint256 arrived, uint256 put, uint256 fwd,) = _sweep(AGENT);
        assertEq(arrived, 30 * U);
        assertEq(put, 0);
        assertEq(fwd, 30 * U);
        assertEq(_bal(payout), 30 * U);
    }

    /// 2.6: with no loan open the need is zero, so everything goes to the payout, and nothing is kept for a loan taken
    /// later.
    function test_noLoan_forwardsEverything_nothingKeptForALaterLoan() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 40 * U);
        uint256[] memory none = new uint256[](0);
        vm.expectEmit(address(router));
        emit IncomeRouter.Swept(AGENT, owner, 40 * U, 0, 40 * U, 0, payout);
        router.sweep(AGENT, none);
        assertEq(_bal(payout), 40 * U);
        _borrow(14 days);
        (uint256 arrived,,,) = _sweep(AGENT);
        assertEq(arrived, 0, "what was forwarded before the borrow is not set aside for it");
        assertEq(router.setAsideOf(AGENT, owner), 0);
    }

    function test_sweep_withNothingNew_movesNothing() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        (uint256 a, uint256 p, uint256 f, uint256 r) = _sweep(AGENT);
        assertEq(a + p + f + r, 0);
    }

    function test_sweep_needsAPlanOfTheCurrentOwner() public {
        _pay(AGENT, 5 * U);
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        assertEq(_bal(_box(AGENT)), 5 * U, "the money waits in the box");
    }

    function test_sweep_revertsWhenTheRegistryDoesNotAnswer() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        reg.setOwnerBroken(true);
        uint256[] memory none = new uint256[](0);
        vm.expectRevert("registry down");
        router.sweep(AGENT, none);
    }

    /// The cap: the largest due the plan repays. A loan above it is not in the need and is never repaid from income;
    /// lowering the cap under an open loan's due releases its set-aside at the next sweep.
    function test_cap_excludesLargerLoans_andLoweringItReleases() public {
        uint256 small = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 big = _borrowAs(key, AGENT, 100 * U, 14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 200 * U);
        (, uint256 put,,) = _sweep(AGENT);
        assertEq(put, _due(small), "the big loan is over the cap: not in the need");
        vm.warp(_opens(big));
        _repayReverts(big, abi.encodeWithSelector(IncomeRouter.OverCap.selector, big, _due(big), CAP));
        assertEq(uint8(_status(big)), uint8(IncomeRouter.Status.OverCap));

        _enroll(owner, AGENT, ALL, payout, 10 * U, false); // under the small loan's due too
        uint256 before = _bal(payout);
        (,,, uint256 released) = _sweep(AGENT);
        assertEq(released, _due(small));
        assertEq(_bal(payout) - before, _due(small));
        assertEq(router.setAsideOf(AGENT, owner), 0);
    }

    // ------------------------------------------------------------------
    // The open-loan list: short, long, repeated, foreign or closed ids refused
    // ------------------------------------------------------------------

    function test_list_refusesShortLongRepeatedForeignClosedAndUnknown() public {
        _enroll(owner, AGENT, ALL, payout, 2_000e6, false);
        uint256 a = _borrowAs(key, AGENT, 10 * U, 14 days);
        uint256 b = _borrowAs(key, AGENT, 10 * U, 14 days);
        uint256 other = _newAgent(buyer, BUYER_PK, address(0), ROOT);
        uint256 foreign = _borrowAs(buyer, other, 10 * U, 14 days);

        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.WrongLoanCount.selector, AGENT, 1, 2));
        router.sweep(AGENT, _list(a)); // short: hides b
        uint256[] memory three = new uint256[](3);
        (three[0], three[1], three[2]) = (a, b, b + 100);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.WrongLoanCount.selector, AGENT, 3, 2));
        router.sweep(AGENT, three); // long
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, a));
        router.sweep(AGENT, _list(a, a)); // repeated
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, a));
        router.sweep(AGENT, _list(b, a)); // not rising
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, foreign));
        router.sweep(AGENT, _list(a, foreign)); // another agent's
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, 0));
        router.sweep(AGENT, _list(0, a)); // the pool's sentinel
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, 999));
        router.sweep(AGENT, _list(a, 999)); // no such loan

        // closed: a repaid by hand, then listed in place of b
        _repayByHand(owner, a);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, a));
        router.sweep(AGENT, _list(a));
        router.sweep(AGENT, _list(b)); // the exact list
        // release checks the list the same way
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, a));
        router.release(AGENT, owner, _list(a));
    }

    /// More open loans than one call checks: sweeps, releases and repayments revert and the money waits (known limit
    /// (c)); once a loan closes another way, all of them work again.
    function test_moreOpenLoansThanOneCallChecks() public {
        _enroll(owner, AGENT, ALL, payout, 2_000e6, false);
        uint256 first = _borrowAs(key, AGENT, 5 * U, 14 days);
        _pay(AGENT, _due(first));
        _sweep(AGENT); // first loan covered
        for (uint256 i = 0; i < 32; i++) {
            _borrowAs(key, AGENT, 5 * U, 14 days);
        }
        assertEq(pool.getAgent(AGENT).activeLoans, 33);
        _pay(AGENT, 10 * U);
        uint256[] memory list = _open(AGENT);
        uint256[] memory firstThirtyTwo = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            firstThirtyTwo[i] = list[i];
        }
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.TooManyLoans.selector, AGENT, 33));
        router.sweep(AGENT, list);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.TooManyLoans.selector, AGENT, 33));
        router.sweep(AGENT, firstThirtyTwo);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.TooManyLoans.selector, AGENT, 33));
        router.release(AGENT, owner, list);
        vm.warp(_opens(first));
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.TooManyLoans.selector, AGENT, 33));
        router.repay(first, list);
        assertEq(router.check(AGENT).unswept, 10 * U, "the money waits");

        _repayByHand(owner, list[32]); // one closes another way
        assertEq(pool.getAgent(AGENT).activeLoans, 32);
        _repay(first);
        (uint256 arrived, uint256 put,,) = _sweep(AGENT);
        assertEq(arrived, 10 * U);
        assertEq(put, 10 * U);
    }

    // ------------------------------------------------------------------
    // The window (AutoRepayV2's opensAt vectors), early, the grace period
    // ------------------------------------------------------------------

    function _windowCase(uint64 term, uint64 opensAfter) internal returns (uint256 loanId) {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        loanId = _borrow(term);
        IPoolV2.Loan memory l = _loan(loanId);
        _pay(AGENT, _due(loanId));
        _sweep(AGENT);
        uint64 opens = l.issuedAt + opensAfter;
        assertEq(_opens(loanId), opens);
        vm.warp(opens - 1);
        assertEq(uint8(_status(loanId)), uint8(IncomeRouter.Status.TooEarly));
        _repayReverts(loanId, abi.encodeWithSelector(IncomeRouter.TooEarly.selector, loanId, opens));
        vm.warp(opens);
        assertEq(uint8(_status(loanId)), uint8(IncomeRouter.Status.Ready));
        uint256 due = _due(loanId);
        assertEq(_repayAs(keeper, loanId), due);
        assertEq(uint8(_loan(loanId).status), uint8(IPoolV2.LoanStatus.Repaid));
    }

    function test_window_1day_last6h() public {
        _windowCase(1 days, 1 days - 6 hours);
    }

    function test_window_6days_last6h() public {
        _windowCase(6 days, 6 days - 6 hours);
    }

    function test_window_7days_last6h_noWeekLongCredit() public {
        _windowCase(7 days, 7 days - 6 hours);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 0, "a 7-day loan repaid in its window holds under 7 days");
    }

    function test_window_7daysPlus1h_last2h() public {
        _windowCase(7 days + 1 hours, 7 days - 1 hours);
    }

    function test_window_7daysPlus2h_fromDay7() public {
        _windowCase(7 days + 2 hours, 7 days);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 1, "week-long credit kept");
    }

    function test_window_7daysPlus6h_fromDay7() public {
        _windowCase(7 days + 6 hours, 7 days);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 1);
    }

    function test_window_14days_last6h_keepsWeekLong() public {
        _windowCase(14 days, 14 days - 6 hours);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 1);
    }

    function test_window_30days_last6h() public {
        _windowCase(30 days, 30 days - 6 hours);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 1);
    }

    function test_opensAt_neverInTheFirstHour() public view {
        assertEq(router.opensAt(1000, 1000 + 3 hours), 1000 + 1 hours, "the term after its first hour");
        assertEq(router.opensAt(1000, 1000 + 30 minutes), 1000 + 1 hours);
    }

    /// The router's window is AutoRepayV2's, exactly: the same function of (issuedAt, dueAt) for the same WINDOW.
    function testFuzz_opensAt_sameAsAutoRepayV2(uint64 issuedAt, uint64 term, uint64 window) public {
        window = uint64(bound(window, 2 hours, 24 hours));
        issuedAt = uint64(bound(issuedAt, 0, type(uint64).max / 2));
        term = uint64(bound(term, 0, 365 days));
        AutoRepayV2 ar = new AutoRepayV2(
            IAutoRepayV2Pool(address(pool)), IAutoRepayV2Savings(address(new AssetOnly(address(usdg)))), safe, window
        );
        IncomeRouter r = new IncomeRouter(IIncomeRouterPool(address(pool)), safe, window);
        assertEq(r.opensAt(issuedAt, issuedAt + term), ar.opensAt(issuedAt, issuedAt + term));
    }

    /// AR-WINDOW over every issue time and term (AutoRepayV2's own fuzz, on the router).
    function testFuzz_opensAt(uint64 issuedAt, uint64 term) public view {
        issuedAt = uint64(bound(issuedAt, 0, type(uint64).max / 2));
        term = uint64(bound(term, 1, 365 days));
        uint64 dueAt = issuedAt + term;
        uint64 opens = router.opensAt(issuedAt, dueAt);
        assertGe(opens, issuedAt + 1 hours, "never in the first hour");
        assertLe(dueAt - (opens < dueAt ? opens : dueAt), WIN);
        if (term >= 3 hours) {
            assertLe(opens, dueAt);
            assertGe(dueAt - opens, 2 hours);
        }
        if (term >= 7 days + 2 hours) assertGe(opens, issuedAt + 7 days);
        if ((term >= 1 days && term <= 7 days) || term >= 7 days + 6 hours) {
            assertEq(opens, dueAt - (term < WIN ? term : WIN));
        }
    }

    function test_early_repaysAsSoonAsCovered() public {
        _enroll(owner, AGENT, ALL, payout, CAP, true);
        uint256 loanId = _borrow(14 days);
        uint256 due = _due(loanId);
        _pay(AGENT, 10 * U);
        _sweep(AGENT);
        assertEq(uint8(_status(loanId)), uint8(IncomeRouter.Status.Short), "early, but not covered yet");
        _repayReverts(loanId, abi.encodeWithSelector(IncomeRouter.Shortfall.selector, loanId, due, 10 * U));
        _pay(AGENT, due);
        _sweep(AGENT);
        assertEq(router.checkLoan(loanId).opens, _loan(loanId).issuedAt, "early: open from issuance");
        _repay(loanId); // the block it was borrowed in
        assertEq(_loan(loanId).closedAt, _loan(loanId).issuedAt);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 0, "the cost of early: no week-long credit");
    }

    /// No closing time on the router's side: in the grace period, and after it until a default is marked.
    function test_repay_inTheGracePeriod_andUntilADefaultIsMarked() public {
        _enroll(owner, AGENT, ALL, payout, 2_000e6, false);
        uint256 a = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 b = _borrowAs(key, AGENT, 20 * U, 14 days);
        _pay(AGENT, _due(a) + _due(b));
        _sweep(AGENT);
        vm.warp(_loan(a).dueAt + 1 days);
        _repay(a);
        assertGt(_loan(a).closedAt, _loan(a).dueAt, "late, not defaulted");
        vm.warp(_loan(b).defaultableAt + 1);
        _repay(b);
        assertEq(uint8(_loan(b).status), uint8(IPoolV2.LoanStatus.Repaid));
    }

    // ------------------------------------------------------------------
    // Earliest due first among an owner's loans
    // ------------------------------------------------------------------

    /// L1 due at T, L2 two days later, the set-aside covering one: L2 waits while L1 is open, even in L2's own window
    /// (L1 then in its grace); L1 is repaid; then L2 once its money is there.
    function test_order_laterLoanWaitsWhileTheEarlierIsOpen() public {
        uint256 l1 = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 l2 = _borrowAs(key, AGENT, 20 * U, 16 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(l2)); // one loan's worth (l2's due is the larger)
        _sweep(AGENT);
        vm.warp(_opens(l2)); // past l1's due, in its grace
        uint256[] memory list = _open(AGENT);
        IncomeRouter.Quote memory q = router.checkRepay(l2, list);
        assertEq(uint8(q.status), uint8(IncomeRouter.Status.NotEarliest));
        assertEq(q.earlier, l1);
        assertEq(uint8(_status(l2)), uint8(IncomeRouter.Status.Ready), "checkLoan leaves the order out");
        assertEq(router.checkLoan(l2).earlier, 0);
        _repayReverts(l2, abi.encodeWithSelector(IncomeRouter.NotEarliest.selector, l2, l1));
        assertEq(uint8(router.checkRepay(l1, list).status), uint8(IncomeRouter.Status.Ready));
        _repay(l1);
        assertEq(uint8(_status(l2)), uint8(IncomeRouter.Status.Short), "what is left is short of l2");
        _pay(AGENT, _due(l1));
        _sweep(AGENT);
        _repay(l2);
        assertEq(uint8(_loan(l2).status), uint8(IPoolV2.LoanStatus.Repaid));
    }

    function test_order_afterTheEarlierIsRepaidByHand_theLaterIsRepayable() public {
        uint256 l1 = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 l2 = _borrowAs(key, AGENT, 20 * U, 16 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(l2));
        _sweep(AGENT);
        vm.warp(_opens(l2));
        _repayReverts(l2, abi.encodeWithSelector(IncomeRouter.NotEarliest.selector, l2, l1));
        _repayByHand(owner, l1);
        _repay(l2);
        assertEq(router.setAsideTotal(AGENT), 0);
    }

    function test_order_afterTheEarlierDefaults_theLaterIsRepayable() public {
        uint256 l1 = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 l2 = _borrowAs(key, AGENT, 20 * U, 16 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(l2));
        _sweep(AGENT);
        vm.warp(_opens(l2)); // l1 in its grace
        _repayReverts(l2, abi.encodeWithSelector(IncomeRouter.NotEarliest.selector, l2, l1));
        vm.warp(_loan(l1).defaultableAt + 1); // l2 in its own grace
        pool.markDefault(l1);
        _repay(l2);
        assertEq(uint8(_loan(l2).status), uint8(IPoolV2.LoanStatus.Repaid));
    }

    /// Equal due times: the lower id first. With `early`, the order holds from the start.
    function test_order_equalDueTimes_lowerIdFirst_earlyToo() public {
        _enroll(owner, AGENT, ALL, payout, CAP, true);
        uint256 l1 = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 l2 = _borrowAs(key, AGENT, 20 * U, 14 days); // the same block: the same dueAt
        assertEq(_loan(l1).dueAt, _loan(l2).dueAt);
        _pay(AGENT, _due(l1) + _due(l2));
        _sweep(AGENT);
        _repayReverts(l2, abi.encodeWithSelector(IncomeRouter.NotEarliest.selector, l2, l1));
        _repay(l1);
        _repay(l2);
    }

    /// Only the same owner's loans within the plan's cap come first: another owner's earlier loan, or one over the
    /// cap, never holds a loan back.
    function test_order_onlyTheSameOwnersLoansWithinTheCapCount() public {
        uint256 big = _borrowAs(key, AGENT, 100 * U, 10 days); // over the cap, due first
        uint256 small = _borrowAs(key, AGENT, 20 * U, 14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(small));
        _sweep(AGENT);
        vm.warp(_opens(small));
        _repay(small); // big is earlier, but over the cap
        _sell(owner, buyer);
        vm.prank(buyer);
        pool.setDelegate(AGENT, key);
        uint256 later = _borrowAs(key, AGENT, 10 * U, 14 days); // the buyer's
        _enroll(buyer, AGENT, ALL, payout2, CAP, false);
        _pay(AGENT, _due(later));
        _sweep(AGENT);
        vm.warp(_opens(later));
        _repay(later); // big is earlier and still open, but the earlier owner's
        assertEq(uint8(_loan(big).status), uint8(IPoolV2.LoanStatus.Active));
    }

    /// repay checks the open-loan list as sweep does; checkRepay answers NotActive for a closed or unknown loan.
    function test_repay_checksTheList_checkRepayOnClosedLoans() public {
        uint256 a = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 b = _borrowAs(key, AGENT, 20 * U, 14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a) + _due(b));
        _sweep(AGENT);
        vm.warp(_opens(a));
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.WrongLoanCount.selector, AGENT, 1, 2));
        router.repay(a, _list(a)); // hides b
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.BadLoanList.selector, a));
        router.repay(b, _list(b, a));
        uint256[] memory none = new uint256[](0);
        assertEq(uint8(router.checkRepay(999, none).status), uint8(IncomeRouter.Status.NotActive));
        _repay(a);
        assertEq(uint8(router.checkRepay(a, none).status), uint8(IncomeRouter.Status.NotActive));
    }

    // ------------------------------------------------------------------
    // Changes of hands: a plan of an earlier owner pays nothing new; its set-aside repays only its own loans, then is
    // released; owners A to B to A
    // ------------------------------------------------------------------

    function _sell(address from, address to) internal {
        vm.prank(from);
        reg.transferFrom(from, to, AGENT);
    }

    function _repayByHand(address who, uint256 loanId) internal {
        uint256 due = _due(loanId);
        uint256 agentId = _loan(loanId).agentId;
        usdg.mint(who, due);
        vm.startPrank(who);
        usdg.approve(address(pool), due);
        pool.repay(loanId, agentId, due);
        vm.stopPrank();
    }

    function test_earlierOwnersPlan_paysNothingNew() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 10 * U);
        _sweep(AGENT);
        _sell(owner, buyer);
        _pay(AGENT, 30 * U); // the buyer's income
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, buyer));
        IncomeRouter.Summary memory v = router.check(AGENT);
        assertEq(v.owner, buyer);
        assertEq(v.epoch, 2, "the sale is the next epoch, seen before any sync");
        assertFalse(v.planOn);
        assertEq(v.unswept, 30 * U, "new income waits for the buyer's plan");
        // the buyer turns a plan on: nothing of the new income goes to the old owner's loan
        _enroll(buyer, AGENT, ALL, payout2, CAP, false);
        (uint256 arrived, uint256 put, uint256 fwd,) = _sweep(AGENT);
        assertEq(arrived, 30 * U);
        assertEq(put, 0, "the open loan is the old owner's: not in the buyer's need");
        assertEq(fwd, 30 * U);
        assertEq(_bal(payout2), 30 * U);
        assertEq(router.setAsideOf(AGENT, owner), 10 * U, "the old owner's set-aside untouched");
        assertEq(_loan(a).owner, owner);
    }

    function test_earlierOwnersSetAside_repaysOnlyItsOwnLoans_thenIsReleased() public {
        uint256 a = _borrowAs(key, AGENT, 20 * U, 14 days); // under the owner
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        _sell(owner, buyer);
        vm.prank(buyer);
        pool.setDelegate(AGENT, key);
        uint256 b = _borrowAs(key, AGENT, 20 * U, 14 days); // under the buyer
        assertEq(_loan(b).owner, buyer);
        _enroll(buyer, AGENT, ALL, payout2, CAP, false);
        _pay(AGENT, 5 * U);
        _sweep(AGENT);
        assertEq(router.setAsideOf(AGENT, buyer), 5 * U);
        assertEq(router.checkLoan(b).setAside, 5 * U, "the buyer's loan sees the buyer's set-aside only");
        vm.warp(_opens(b));
        _repayReverts(b, abi.encodeWithSelector(IncomeRouter.Shortfall.selector, b, _due(b), 5 * U));
        vm.expectEmit(address(router));
        emit IncomeRouter.IncomeRepaid(a, AGENT, owner, _due(a));
        _repay(a); // the old owner's loan, from the old owner's money, after the sale
        assertEq(router.setAsideOf(AGENT, owner), 0);
        assertEq(router.setAsideOf(AGENT, buyer), 5 * U);

        // what the old owner set aside beyond its loans goes back to its payout, not to the buyer
        _sell(buyer, owner);
        vm.prank(owner);
        pool.setDelegate(AGENT, key);
        uint256 c = _borrowAs(key, AGENT, 10 * U, 14 days);
        uint256 dueC = _due(c);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, dueC);
        _sweep(AGENT);
        _sell(owner, buyer);
        _repayByHand(owner, c); // the old owner repays by hand after the sale
        uint256 before = _bal(payout);
        uint256[] memory list = _open(AGENT);
        vm.expectEmit(address(router));
        emit IncomeRouter.Released(AGENT, owner, dueC, payout);
        assertEq(router.release(AGENT, owner, list), dueC);
        assertEq(_bal(payout) - before, dueC);
        assertEq(router.setAsideOf(AGENT, buyer), 5 * U, "the buyer's set-aside untouched");
        assertEq(_release(AGENT, owner), 0, "nothing left to release");
    }

    /// A to B to A, the keeper syncing in between: the plan from before the sale stays off; A turns it on again; A's
    /// set-aside from before is still A's, for A's loans.
    function test_ownersAtoBtoA_withSync_oldPlanStaysOff() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false); // epoch 1
        _pay(AGENT, 10 * U);
        _sweep(AGENT);
        _sell(owner, buyer);
        router.sync(AGENT); // epoch 2
        _sell(buyer, owner);
        assertEq(router.sync(AGENT), 3);
        _pay(AGENT, 15 * U);
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        (,,, uint32 epoch, bool on,) = router.planOf(AGENT, owner);
        assertEq(epoch, 1);
        assertTrue(on, "stored, but of an earlier epoch: it counts for nothing");
        assertFalse(router.check(AGENT).planOn);
        _enroll(owner, AGENT, ALL, payout, CAP, false); // epoch 3
        (, uint256 put,,) = _sweep(AGENT);
        assertEq(put, 15 * U);
        assertEq(router.setAsideOf(AGENT, owner), 25 * U, "the loan is A's: A's earlier set-aside counts toward it");
        assertEq(_loan(a).owner, owner);
    }

    /// A to B to A with B active in between: B's plan and set-aside are B's; back with A, B's set-aside repays B's
    /// loan and B's leftover goes to B's payout, never to A.
    function test_ownersAtoBtoA_buyerActiveInBetween() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _sell(owner, buyer);
        vm.prank(buyer);
        pool.setDelegate(AGENT, key);
        uint256 b = _borrowAs(key, AGENT, 10 * U, 14 days);
        _enroll(buyer, AGENT, ALL, payout2, CAP, false); // epoch 2
        _pay(AGENT, _due(b) + 3 * U);
        _sweep(AGENT);
        assertEq(router.setAsideOf(AGENT, buyer), _due(b));
        _sell(buyer, owner);
        _pay(AGENT, 4 * U);
        // A's plan is of epoch 1; this is epoch 3
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        vm.warp(_opens(b));
        _repay(b);
        assertEq(router.setAsideOf(AGENT, buyer), 0);
        assertEq(_bal(payout2), 3 * U);
        assertEq(_bal(payout), 0, "nothing went to A");
    }

    /// A to B to A with no write in between: the router cannot see a sale it never observed (ownerOf is A both times
    /// it looked), so A's plan goes on. B had nothing at the router: any plan or sweep of B's would have recorded the
    /// sale. Recorded here as the known limit of an epoch on the owner alone (the keeper syncs owners each pass).
    function test_ownersAtoBtoA_unseen_planContinues() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _sell(owner, buyer);
        _sell(buyer, owner);
        _pay(AGENT, 6 * U);
        (uint256 arrived,, uint256 fwd,) = _sweep(AGENT);
        assertEq(arrived, 6 * U);
        assertEq(fwd, 6 * U);
        (, uint32 e) = router.seen(AGENT);
        assertEq(e, 1);
    }

    // ------------------------------------------------------------------
    // Leave, setPayout, the pause
    // ------------------------------------------------------------------

    function test_leave_keepsTheSetAside_forItsLoans_thenReleases() public {
        uint256 a = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 b = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 dueB = _due(b);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a) + dueB);
        _sweep(AGENT);
        reg.setOwnerBroken(true); // leave reads nothing
        vm.expectEmit(address(router));
        emit IncomeRouter.Left(AGENT, owner);
        vm.prank(owner);
        router.leave(AGENT);
        reg.setOwnerBroken(false);
        _pay(AGENT, 9 * U);
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        assertEq(router.setAsideOf(AGENT, owner), _due(a) + dueB, "kept");
        vm.warp(_opens(a));
        _repay(a); // still repays the loans it was set aside for
        // b repaid by hand: its set-aside is released to the payout; the new income still waits
        _repayByHand(owner, b);
        assertEq(_release(AGENT, owner), dueB);
        assertEq(_bal(payout), dueB);
        assertEq(router.check(AGENT).unswept, 9 * U, "new income waits until a plan is on again");
    }

    function test_setPayout_byThePlansOwner_anyTime() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        router.setPayout(AGENT, payout2);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        vm.prank(safe);
        router.pause(uint64(block.timestamp + 14 days));
        _sell(owner, buyer); // after the agent changed hands
        vm.prank(owner);
        router.leave(AGENT); // and after leave
        reg.setOwnerBroken(true); // and with the registry down
        vm.expectEmit(address(router));
        emit IncomeRouter.PayoutSet(AGENT, owner, payout2);
        vm.prank(owner);
        router.setPayout(AGENT, payout2);
        (address to,,,,,) = router.planOf(AGENT, owner);
        assertEq(to, payout2);
    }

    function test_pause_stopsSweepAndRepayOnly() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a) + 5 * U);
        _sweep(AGENT);
        vm.prank(anyone);
        vm.expectRevert(IncomeRouter.NotPauser.selector);
        router.pause(uint64(block.timestamp + 1 days));
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(
                IncomeRouter.PauseTooLong.selector, uint64(block.timestamp + 14 days + 1), block.timestamp + 14 days
            )
        );
        router.pause(uint64(block.timestamp + 14 days + 1));
        uint64 until = uint64(block.timestamp + 14 days);
        vm.expectEmit(address(router));
        emit IncomeRouter.PausedUntil(until);
        vm.prank(safe);
        router.pause(until);

        vm.warp(_opens(a));
        _pay(AGENT, 2 * U);
        _sweepReverts(AGENT, abi.encodeWithSelector(IncomeRouter.IsPaused.selector, until));
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.IsPaused.selector, until));
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Paused));
        // everything else goes on
        _enroll(owner, AGENT, 5000, payout, CAP, false);
        vm.prank(owner);
        router.setPayout(AGENT, payout2);
        router.sync(AGENT);
        Junk j = new Junk();
        j.mint(_box(AGENT), 1);
        vm.prank(owner);
        router.rescue(AGENT, IERC20(address(j)));
        assertEq(_release(AGENT, owner), 0, "nothing beyond the need, but release runs");
        vm.prank(owner);
        router.leave(AGENT);

        // renewed, then lifted
        vm.prank(safe);
        router.pause(uint64(block.timestamp + 14 days));
        vm.prank(safe);
        router.pause(0);
        _repay(a);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _sweep(AGENT);
        assertEq(_bal(payout), 5 * U + 2 * U);
    }

    function test_pause_endsByItself() public {
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        vm.prank(safe);
        router.pause(uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        _sweep(AGENT);
    }

    // ------------------------------------------------------------------
    // USDG's issuer: a frozen payout, router, box or pool; USDG paused; a seizure
    // ------------------------------------------------------------------

    /// A frozen payout refuses only a sweep that sends it something: the whole sweep reverts and nothing moves. A sweep
    /// that only sets aside goes on.
    function test_frozenPayout_revertsOnlySweepsThatSendToIt() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        usdg.freeze(payout, true);
        _pay(AGENT, 20 * U);
        _sweep(AGENT); // all of it set aside: nothing for the payout
        assertEq(router.setAsideOf(AGENT, owner), 20 * U);
        _pay(AGENT, _due(a)); // more than the rest of the need: the rest goes to the payout
        _sweepReverts(AGENT, bytes("frozen"));
        assertEq(router.setAsideOf(AGENT, owner), 20 * U, "nothing moved");
        assertEq(router.check(AGENT).unswept, _due(a));
    }

    function test_frozenPayout_newPayoutWhilePaused_thenSweeps() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        usdg.freeze(payout, true);
        _pay(AGENT, 8 * U);
        _sweepReverts(AGENT, bytes("frozen"));
        vm.warp(_opens(a));
        _repay(a); // set aside before the freeze: the payout is not involved
        vm.prank(safe);
        router.pause(uint64(block.timestamp + 1 days));
        vm.prank(owner);
        router.setPayout(AGENT, payout2); // works while paused
        vm.prank(safe);
        router.pause(0);
        _sweep(AGENT);
        assertEq(_bal(payout2), 8 * U);
    }

    /// The router frozen: repay needs the router to receive, so it reverts with nothing moved. A sweep sends from the
    /// box straight to the payout, so it goes on.
    function test_frozenRouter_repayReverts_sweepGoesOn() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        usdg.freeze(address(router), true);
        vm.warp(_opens(a));
        _repayReverts(a, bytes("frozen"));
        assertEq(router.setAsideOf(AGENT, owner), _due(a), "nothing moved");
        assertEq(_bal(_box(AGENT)), _due(a));
        _pay(AGENT, 4 * U);
        _sweep(AGENT);
        assertEq(_bal(payout), 4 * U);
        usdg.freeze(address(router), false);
        _repay(a);
    }

    function test_frozenBox_moneyWaits_untilLifted() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a) + 6 * U);
        _sweep(AGENT);
        usdg.freeze(_box(AGENT), true);
        vm.warp(_opens(a));
        _repayReverts(a, bytes("frozen"));
        _sweep(AGENT); // nothing to send: bookkeeping only, goes on
        _enroll(owner, AGENT, ALL, payout, 10 * U, false); // the loan now over the cap: its set-aside is released
        _sweepReverts(AGENT, bytes("frozen"));
        assertEq(router.setAsideOf(AGENT, owner), _due(a), "nothing moved");
        usdg.freeze(_box(AGENT), false);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _repay(a);
        assertEq(_bal(payout), 6 * U);
    }

    function test_frozenPool_repayReverts() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        usdg.freeze(address(pool), true);
        vm.warp(_opens(a));
        _repayReverts(a, bytes("frozen"));
        assertEq(router.setAsideOf(AGENT, owner), _due(a));
        usdg.freeze(address(pool), false);
        _repay(a);
    }

    function test_usdgPaused_everyMoveReverts_thenRetried() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, 5000, payout, CAP, false);
        _pay(AGENT, 2 * _due(a));
        usdg.setPaused(true);
        _sweepReverts(AGENT, bytes("paused"));
        usdg.setPaused(false);
        _sweep(AGENT);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        vm.warp(_opens(a));
        usdg.setPaused(true);
        _repayReverts(a, bytes("paused"));
        usdg.setPaused(false);
        _repay(a);
    }

    /// 2.7: a new share applies from the next sweep; what is already set aside stays set aside until its loans close.
    function test_lowerShare_keepsWhatIsSetAside() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 30 * U);
        _sweep(AGENT);
        _enroll(owner, AGENT, 0, payout2, CAP, false);
        _pay(AGENT, 30 * U);
        (, uint256 put, uint256 fwd, uint256 rel) = _sweep(AGENT);
        assertEq(put, 0);
        assertEq(fwd, 30 * U);
        assertEq(rel, 0, "the loan is still open: its set-aside stays");
        assertEq(router.setAsideOf(AGENT, owner), 30 * U);
        assertEq(_bal(payout2), 30 * U);
        assertLt(router.setAsideOf(AGENT, owner), _due(a));
    }

    /// An issuer's seizure is a loss written down on the set-asides that existed: the views show it at once, the next
    /// write records it (`WrittenDown`), and income that arrives later is new money, split under the plan, never a
    /// refill of the loss. Nothing underflows.
    function test_seizure_writtenDown_laterIncomeIsNewMoney() public {
        uint256 a = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 b = _borrowAs(key, AGENT, 20 * U, 14 days);
        uint256 dueA = _due(a);
        uint256 dueB = _due(b);
        _enroll(owner, AGENT, 5000, payout, CAP, false);
        _pay(AGENT, 2 * (dueA + dueB));
        _sweep(AGENT); // half set aside: both dues
        address box = _box(AGENT);
        usdg.seize(box, 10 * U);
        IncomeRouter.Summary memory v = router.check(AGENT);
        assertEq(v.setAsideTotal, dueA + dueB - 10 * U, "the views write down at once");
        assertEq(v.writeDown, 10 * U);
        assertEq(v.unswept, 0);
        assertEq(router.setAsideOf(AGENT, owner), dueA + dueB - 10 * U);
        (uint256 recorded,,) = router.potOf(AGENT);
        assertEq(recorded, dueA + dueB, "recorded until a write");

        vm.expectEmit(address(router));
        emit IncomeRouter.WrittenDown(AGENT, dueA + dueB, dueA + dueB - 10 * U);
        router.sync(AGENT); // the keeper sees it and records it
        _pay(AGENT, 30 * U);
        (uint256 arrived, uint256 put, uint256 fwd, uint256 rel) = _sweep(AGENT);
        assertEq(arrived, 30 * U, "later income is new money");
        assertEq(put, 10 * U, "the plan's share of it, up to the need the loss left");
        assertEq(fwd, 20 * U);
        assertEq(rel, 0);
        vm.warp(_opens(a));
        _repay(a);
        _repay(b);
        assertEq(router.setAsideTotal(AGENT), 0);
        assertEq(_bal(box), 0);
    }

    /// The review's sequence: A sets a loan's due aside, the agent goes to B, the issuer seizes part of the box, then
    /// B's income arrives. B's income is new money for B; A's set-aside is written down to what survived; A's loan is
    /// never repaid with B's money, and a release to A sends at most A's written-down value.
    function test_seizure_afterASale_buyersIncomeNeverCoversTheEarlierOwnersLoss() public {
        uint256 a = _borrow(14 days);
        uint256 dueA = _due(a);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, dueA);
        _sweep(AGENT);
        assertEq(router.setAsideOf(AGENT, owner), dueA);
        _sell(owner, buyer);
        router.sync(AGENT);
        usdg.seize(_box(AGENT), 30 * U);
        router.sync(AGENT); // records the write-down
        assertEq(router.setAsideOf(AGENT, owner), dueA - 30 * U, "A keeps what survived");
        _enroll(buyer, AGENT, ALL, payout2, CAP, false);
        _pay(AGENT, dueA); // B's income
        assertEq(router.check(AGENT).unswept, dueA, "B's income is new money for B");

        vm.warp(_opens(a));
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Short));
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.Shortfall.selector, a, dueA, dueA - 30 * U));
        _repayByHand(owner, a); // A pays its own loan
        uint256 before = _bal(payout);
        assertEq(_release(AGENT, owner), dueA - 30 * U, "at most A's written-down value");
        assertEq(_bal(payout) - before, dueA - 30 * U);
        assertEq(router.setAsideTotal(AGENT), 0);
        (uint256 arrived, uint256 put, uint256 fwd,) = _sweep(AGENT);
        assertEq(arrived, dueA);
        assertEq(put, 0, "B has no loan");
        assertEq(fwd, dueA);
        assertEq(_bal(payout2), dueA, "all of B's income reached B");
        assertEq(_bal(_box(AGENT)), 0);
    }

    /// A write-down falls on every owner's set-aside pro rata.
    function test_seizure_writtenDownProRataAcrossOwners() public {
        _borrow(14 days); // A's loan, 50 USDG
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 40 * U);
        _sweep(AGENT);
        _sell(owner, buyer);
        vm.prank(buyer);
        pool.setDelegate(AGENT, key);
        uint256 b = _borrowAs(key, AGENT, 30 * U, 14 days); // B's
        _enroll(buyer, AGENT, ALL, payout2, CAP, false);
        _pay(AGENT, 20 * U);
        _sweep(AGENT);
        assertEq(router.setAsideOf(AGENT, owner), 40 * U);
        assertEq(router.setAsideOf(AGENT, buyer), 20 * U);
        usdg.seize(_box(AGENT), 30 * U); // half of the pot
        router.sync(AGENT);
        assertEq(router.setAsideOf(AGENT, owner), 20 * U, "A's half");
        assertEq(router.setAsideOf(AGENT, buyer), 10 * U, "B's half");
        assertEq(router.setAsideTotal(AGENT), 30 * U);
        // after the write-down B sets more aside: A's value does not move
        _pay(AGENT, 10 * U);
        (uint256 arrived, uint256 put,,) = _sweep(AGENT);
        assertEq(arrived, 10 * U);
        assertEq(put, 10 * U);
        assertEq(router.setAsideOf(AGENT, buyer), 20 * U);
        assertEq(router.setAsideOf(AGENT, owner), 20 * U);
        assertLt(router.setAsideOf(AGENT, buyer), _due(b));
    }

    /// A seizure of everything voids the pot; later income is new money and starts a new pot for the owner.
    function test_seizure_toZero_thenDeposits() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 30 * U);
        _sweep(AGENT);
        usdg.seize(_box(AGENT), 30 * U);
        assertEq(router.setAsideOf(AGENT, owner), 0);
        uint256[] memory list = _open(AGENT);
        vm.expectEmit(address(router));
        emit IncomeRouter.WrittenDown(AGENT, 30 * U, 0);
        router.sweep(AGENT, list); // the sweep records it too
        (uint256 value, uint192 shares, uint32 gen) = router.potOf(AGENT);
        assertEq(value, 0);
        assertEq(shares, 0);
        assertEq(gen, 1, "the pot is void: its shares are worth nothing");
        _pay(AGENT, 25 * U);
        (uint256 arrived, uint256 put,,) = _sweep(AGENT);
        assertEq(arrived, 25 * U);
        assertEq(put, 25 * U);
        assertEq(router.setAsideOf(AGENT, owner), 25 * U, "a new pot, exact");
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        vm.warp(_opens(a));
        _repay(a);
        assertEq(router.setAsideTotal(AGENT), 0);
    }

    /// The known residual: a seizure and a deposit between the same two calls cannot be told apart from the balance
    /// alone, so the deposit covers that part of the loss. The keeper's frequent sweeps and syncs bound the window.
    function test_seizure_andDepositBetweenTheSameTwoCalls_cannotBeToldApart() public {
        _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, 30 * U);
        _sweep(AGENT);
        usdg.seize(_box(AGENT), 10 * U);
        _pay(AGENT, 10 * U); // no call in between
        (uint256 arrived,,,) = _sweep(AGENT);
        assertEq(arrived, 0, "the deposit is taken for the lost part");
        assertEq(router.setAsideOf(AGENT, owner), 30 * U);
    }

    // ------------------------------------------------------------------
    // The pool: paused; a loan repaid by hand or by AutoRepayV2 first; a default
    // ------------------------------------------------------------------

    function test_pausedPool_repayWorks() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a));
        _sweep(AGENT);
        vm.prank(guardian);
        pool.pause();
        vm.prank(key);
        vm.expectRevert();
        pool.borrow(AGENT, 5 * U, 14 days, key, type(uint256).max);
        vm.warp(_opens(a));
        _repay(a);
        assertEq(uint8(_loan(a).status), uint8(IPoolV2.LoanStatus.Repaid));
    }

    function test_repaidByHandFirst_thenReleased() public {
        uint256 a = _borrow(14 days);
        uint256 due = _due(a);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, due);
        _sweep(AGENT);
        _repayByHand(key, a);
        vm.warp(_opens(a));
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.LoanNotActive.selector, a));
        _pay(AGENT, 1 * U);
        uint256[] memory none = new uint256[](0);
        vm.expectEmit(address(router));
        emit IncomeRouter.Swept(AGENT, owner, 1 * U, 0, 1 * U, due, payout);
        router.sweep(AGENT, none);
        assertEq(_bal(payout), due + 1 * U);
        assertEq(router.setAsideTotal(AGENT), 0);
    }

    function test_repaidByAutoRepayV2First_thenReleased() public {
        AutoRepayV2 ar = new AutoRepayV2(
            IAutoRepayV2Pool(address(pool)), IAutoRepayV2Savings(address(new AssetOnly(address(usdg)))), safe, WIN
        );
        vm.prank(key);
        ar.enroll(AGENT, CAP, false, false); // Repay on time's wallet plan, from the agent's key
        uint256 a = _borrow(14 days);
        uint256 due = _due(a);
        usdg.mint(key, due);
        vm.prank(key);
        usdg.approve(address(ar), due);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, due);
        _sweep(AGENT);
        vm.warp(_opens(a));
        ar.run(a); // Repay on time gets there first
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.LoanNotActive.selector, a));
        (,,, uint256 released) = _sweep(AGENT);
        assertEq(released, due);
        assertEq(_bal(payout), due);
    }

    function test_default_thenReleased() public {
        uint256 a = _borrow(14 days);
        uint256 due = _due(a);
        _enroll(owner, AGENT, 5000, payout, CAP, false);
        _pay(AGENT, 20 * U);
        _sweep(AGENT); // half of 20 set aside: short of the due
        vm.warp(_loan(a).defaultableAt + 1);
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.Shortfall.selector, a, due, 10 * U));
        pool.markDefault(a);
        uint256 before = _bal(payout);
        (,,, uint256 released) = _sweep(AGENT);
        assertEq(released, 10 * U);
        assertEq(_bal(payout) - before, 10 * U);
    }

    // ------------------------------------------------------------------
    // Reentrancy: a backer hook during pool.repay; a token during rescue
    // ------------------------------------------------------------------

    /// I12: the pool notifies the agent's backer from inside `repay` when the agent is frozen (its line released as
    /// the loan closes). A hook that calls back into the router there is refused by the guard; the pool goes on (a
    /// failing hook never blocks it) and the repayment stands.
    function test_reentrancy_backerHookDuringPoolRepay() public {
        address hookOwner = makeAddr("hookedBacker");
        uint256 root2 = _newRoot(hookOwner, 2_000 * U);
        ReenteringHook h = new ReenteringHook();
        vm.prank(hookOwner);
        pool.setHook(root2, address(h)); // immediate: it backs nothing yet
        uint256 agent2 = _newAgent(buyer, BUYER_PK, address(0), root2);
        uint256 l1 = _borrowAs(buyer, agent2, 20 * U, 14 days);
        uint256 l2 = _borrowAs(buyer, agent2, 20 * U, 14 days);
        _enroll(buyer, agent2, ALL, payout, CAP, false);
        _pay(agent2, _due(l1) + _due(l2));
        _sweep(agent2);
        vm.prank(hookOwner);
        pool.freeze(agent2, true); // the backer stops new borrows: each repayment releases line, and notifies

        h.arm(router, agent2, l2);
        vm.warp(_opens(l1));
        _repay(l1);
        assertEq(h.attempts(), 4, "the hook ran inside pool.repay and tried four calls");
        assertEq(h.succeeded(), 0, "every one refused");
        assertEq(h.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(uint8(_loan(l1).status), uint8(IPoolV2.LoanStatus.Repaid));
        assertEq(uint8(_loan(l2).status), uint8(IPoolV2.LoanStatus.Active), "the hook could not repay l2");
        assertEq(router.setAsideOf(agent2, buyer), _due(l2));
        assertEq(_bal(address(router)), 0);
        assertEq(usdg.allowance(address(router), address(pool)), 0);
        _repay(l2);
    }

    function test_reentrancy_tokenDuringRescue() public {
        ReenteringToken t = new ReenteringToken();
        t.mint(_box(AGENT), 5);
        t.setTarget(router, AGENT);
        vm.prank(owner);
        router.rescue(AGENT, IERC20(address(t)));
        assertTrue(t.reentered());
        assertEq(t.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(t.balanceOf(owner), 5);
    }

    // ------------------------------------------------------------------
    // rescue never moves USDG
    // ------------------------------------------------------------------

    function test_rescue_anyTokenButUsdg_toTheRegistryOwner() public {
        Junk j = new Junk();
        j.mint(_box(AGENT), 77);
        _pay(AGENT, 9 * U);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NotOwner.selector, AGENT, anyone));
        router.rescue(AGENT, IERC20(address(j)));
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NotOwner.selector, AGENT, key));
        router.rescue(AGENT, IERC20(address(j)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NotRescuable.selector, address(usdg)));
        router.rescue(AGENT, IERC20(address(usdg)));
        vm.expectEmit(address(router));
        emit IncomeRouter.Rescued(AGENT, address(j), owner, 77);
        vm.prank(owner);
        assertEq(router.rescue(AGENT, IERC20(address(j))), 77); // deploys the box to do it
        assertEq(j.balanceOf(owner), 77);
        assertEq(_bal(_box(AGENT)), 9 * U, "USDG never moves by rescue");
        assertEq(_bal(owner), 0);
    }

    // ------------------------------------------------------------------
    // Repay: what the pool and the score see; the router holds nothing
    // ------------------------------------------------------------------

    function test_repay_poolSeesTheRouter_eventNamesAgentAndOwner_routerHoldsNothing() public {
        uint256 a = _borrow(14 days);
        uint256 due = _due(a);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, due + 3 * U);
        _sweep(AGENT);
        vm.warp(_opens(a));
        uint256 poolBefore = _bal(address(pool));
        vm.recordLogs();
        _repayAs(keeper, a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool repaid;
        bool income;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolV2.Repaid.selector) {
                (,, address p) = abi.decode(logs[i].data, (uint256, uint256, address));
                assertEq(p, address(router), "Repaid.payer is the router: the score pins it");
                repaid = true;
            }
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IncomeRouter.IncomeRepaid.selector) {
                assertEq(uint256(logs[i].topics[1]), a);
                assertEq(uint256(logs[i].topics[2]), AGENT);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), owner);
                assertEq(abi.decode(logs[i].data, (uint256)), due);
                income = true;
            }
        }
        assertTrue(repaid && income);
        assertEq(_bal(address(pool)) - poolBefore, due, "the pool got the due exactly");
        assertEq(_bal(address(router)), 0, "the router holds nothing");
        assertEq(usdg.allowance(address(router), address(pool)), 0, "and no allowance");
        assertEq(_bal(keeper), 0, "the caller paid nothing and got nothing");
        assertEq(_bal(_box(AGENT)), 0, "the forward went at the sweep; the due now");
        assertEq(_bal(payout), 3 * U);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function test_checkLoan_everyStatus() public {
        assertEq(uint8(_status(0)), uint8(IncomeRouter.Status.NotActive), "the sentinel");
        assertEq(uint8(_status(999)), uint8(IncomeRouter.Status.NotActive), "no such loan");
        uint256 a = _borrow(14 days);
        uint256 due = _due(a);
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.NoPlan));
        _repayReverts(a, abi.encodeWithSelector(IncomeRouter.NoPlan.selector, AGENT, owner));
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.LoanNotActive.selector, 999));
        router.repay(999, none);
        _enroll(owner, AGENT, ALL, payout, 10 * U, false);
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.OverCap));
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.TooEarly));
        vm.warp(_opens(a));
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Short));
        _pay(AGENT, due);
        _sweep(AGENT);
        IncomeRouter.Quote memory q = router.checkLoan(a);
        assertEq(uint8(q.status), uint8(IncomeRouter.Status.Ready));
        assertEq(q.agentId, AGENT);
        assertEq(q.owner, owner);
        assertEq(q.due, due);
        assertEq(q.cap, CAP);
        assertEq(q.setAside, due);
        assertEq(q.earlier, 0, "checkLoan leaves the order out");
        assertEq(q.opens, _opens(a));
        usdg.seize(_box(AGENT), 1); // written down: one unit short
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Short));
        router.sync(AGENT);
        _pay(AGENT, 1);
        _sweep(AGENT);
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Ready));
        vm.prank(safe);
        router.pause(uint64(block.timestamp + 1));
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.Paused));
        vm.warp(block.timestamp + 1);
        _repay(a);
        assertEq(uint8(_status(a)), uint8(IncomeRouter.Status.NotActive), "repaid");
    }

    function test_check_summary() public {
        IncomeRouter.Summary memory v = router.check(AGENT);
        assertEq(v.owner, owner);
        assertEq(v.epoch, 1, "first sight is epoch 1, before any write");
        assertFalse(v.planOn);
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, 4000, payout, CAP, true);
        _pay(AGENT, 50 * U);
        _sweep(AGENT);
        _pay(AGENT, 2 * U);
        v = router.check(AGENT);
        assertTrue(v.deployed);
        assertEq(v.balance, 20 * U + 2 * U);
        assertEq(v.setAsideTotal, 20 * U);
        assertEq(v.setAside, 20 * U);
        assertEq(v.unswept, 2 * U);
        assertTrue(v.planOn);
        assertEq(v.plan.shareBps, 4000);
        assertEq(v.plan.payout, payout);
        assertTrue(v.plan.early);
        assertLe(v.setAside, _due(a));
        reg.setOwnerBroken(true);
        v = router.check(AGENT);
        assertEq(v.owner, address(0), "the registry down reads as no owner; the box is still shown");
        assertEq(v.balance, 22 * U);
        assertFalse(v.planOn);
    }

    // ------------------------------------------------------------------
    // Gas, for the record (forge test -vv prints it)
    // ------------------------------------------------------------------

    /// Every account the call touches made cold first, as in a transaction of its own (the call's own 21,000 and
    /// calldata not counted).
    function _cool() internal {
        vm.cool(address(router));
        vm.cool(address(pool));
        vm.cool(address(usdg));
        vm.cool(address(reg));
        vm.cool(_box(AGENT));
        vm.cool(payout);
    }

    function test_gas_sweepAndRepay() public {
        uint256 a = _borrow(14 days);
        _enroll(owner, AGENT, ALL, payout, CAP, false);
        _pay(AGENT, _due(a) + 5 * U);
        uint256[] memory list = _open(AGENT);
        _cool();
        uint256 g = gasleft();
        router.sweep(AGENT, list); // first sweep: deploys the box
        emit log_named_uint("sweep with the box's deploy, one open loan, cold", g - gasleft());
        _pay(AGENT, 5 * U);
        _cool();
        g = gasleft();
        router.sweep(AGENT, list);
        emit log_named_uint("sweep, one open loan, cold", g - gasleft());
        vm.warp(_opens(a));
        _cool();
        g = gasleft();
        router.repay(a, list);
        emit log_named_uint("repay, one open loan, cold", g - gasleft());
    }
}
