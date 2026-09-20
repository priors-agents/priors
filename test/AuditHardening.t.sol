// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// Three things an audit found that are not about stealing money - they are about states the contract could
/// be put into and never come back from. All three are permanent by nature, which is why they matter on a
/// non-upgradeable contract.
///
///   1. A defaulted root's remaining stake was unreachable forever: owned by nobody, credited to nobody.
///   2. `setParams` accepted durations that make `repay` or `markDefault` revert for good.
///   3. `importRecords` accepted counters that make `score()` revert for good, after the point of no return.
contract AuditHardeningTest is Test {
    uint256 constant USD = 1e6;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address rootOp = makeAddr("rootOp");
    address kidOp = makeAddr("kidOp");

    uint256 ROOT;
    uint256 KID;

    function setUp() public {
        // A real clock. At the default timestamp of 1, any `block.timestamp - 30 days` in a fixture
        // underflows before the contract is even reached.
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);

        _fund(lender, 100_000 * USD);
        vm.prank(lender);
        pool.deposit(50_000 * USD, lender);

        _fund(owner, 10_000 * USD);
        vm.prank(owner);
        pool.fundReserve(1_000 * USD);

        vm.prank(rootOp);
        ROOT = reg.register("ipfs://root");
        vm.prank(kidOp);
        KID = reg.register("ipfs://kid");
        _fund(rootOp, 10_000 * USD);
        _fund(kidOp, 10_000 * USD);
    }

    /* `deposit` seals imports - deliberately, so lender money can never arrive before the history is
       settled. That means the import tests cannot share a pool with a funded one, and need their own. */
    function _unsealedPool() internal returns (CreditPool fresh) {
        fresh = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);
        assertFalse(fresh.importsSealed(), "a fresh pool should still accept imports");
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _defaultTheRoot(uint256 stake, uint256 loan) internal returns (uint256) {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, stake);
        pool.borrow(ROOT, loan, 7 days, rootOp);
        vm.stopPrank();
        uint256 id = pool.loanCount();
        vm.warp(block.timestamp + 7 days + 3 days + 1);
        pool.markDefault(id);
        assertTrue(pool.creditReport(ROOT).defaulted, "the root should be dead");
        return id;
    }

    // ---------------------------------------------------------------- 1. frozen stake

    /// A root that defaults on one trivial loan used to lose access to its whole remaining stake, forever.
    /// Not slashed, not given to lenders - just unreachable.
    function test_aSettledDefaultedRootCanRecoverItsResidualStake() public {
        _defaultTheRoot(1_000 * USD, 5 * USD);

        uint256 left = pool.creditReport(ROOT).stake;
        assertEq(left, 995 * USD, "995 should survive the slash");
        assertEq(pool.creditReport(ROOT).activeLoans, 0, "nothing open");
        assertEq(pool.creditReport(ROOT).delegatedOut, 0, "nothing delegated");

        uint256 before = usdc.balanceOf(rootOp);
        vm.prank(rootOp);
        pool.withdrawStake(ROOT, left, rootOp);
        assertEq(usdc.balanceOf(rootOp) - before, left, "the residual stake came back");
        assertEq(pool.creditReport(ROOT).stake, 0);
        assertEq(pool.totalStake(), 0, "and the books agree");
    }

    /// But only once it owes nothing. A defaulted root with a child's line still out cannot walk away from
    /// it - that stake is what the child's loan stands on, and Task 3 made it liable.
    function test_aDefaultedRootWithDelegationOutstandingStillCannotWithdraw() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 200 * USD);
        pool.vouch(ROOT, KID, 100 * USD);
        pool.borrow(ROOT, 100 * USD, 7 days, rootOp);
        vm.stopPrank();
        uint256 id = pool.loanCount();

        vm.prank(kidOp);
        pool.borrow(KID, 100 * USD, 7 days, kidOp);

        vm.warp(block.timestamp + 7 days + 3 days + 1);
        pool.markDefault(id);

        assertGt(pool.creditReport(ROOT).delegatedOut, 0, "the child's line is still out");
        vm.prank(rootOp);
        vm.expectRevert();
        pool.withdrawStake(ROOT, 1, rootOp);
    }

    // ---------------------------------------------------------------- 2. parameter bounds

    /// The four durations that are added to a uint64 timestamp elsewhere. Each one, at max, used to brick a
    /// core operation permanently; all four are now refused at the door.
    function test_setParamsRefusesDurationsThatWouldBrickThePool() public {
        CreditPool.Params memory p = pool.getParams();

        CreditPool.Params memory bad = p;
        bad.grace = type(uint64).max;
        _expectRejected(bad, "grace");

        bad = p;
        bad.recourseTerm = type(uint64).max;
        _expectRejected(bad, "recourseTerm");

        bad = p;
        bad.minSeasoning = type(uint64).max;
        _expectRejected(bad, "minSeasoning");

        bad = p;
        bad.epochLength = type(uint64).max;
        _expectRejected(bad, "epochLength");

        bad = p;
        bad.maxTerm = type(uint64).max;
        _expectRejected(bad, "maxTerm");
    }

    /// Each case is asserted separately rather than in a table, so a failure names the parameter.
    function _expectRejected(CreditPool.Params memory bad, string memory which) internal {
        vm.prank(owner);
        vm.expectRevert(CreditPool.InvalidParams.selector);
        pool.setParams(bad);
        which; // kept for readability at the call sites
    }

    /// And the honest range still goes through, so the bound is not just "reject everything".
    function test_setParamsStillAcceptsSaneDurations() public {
        CreditPool.Params memory p = pool.getParams();
        p.grace = 30 days;
        p.recourseTerm = 90 days;
        p.minSeasoning = 14 days;
        p.epochLength = 365 days;
        p.maxTerm = 365 days;
        vm.prank(owner);
        pool.setParams(p);
        assertEq(pool.getParams().grace, 30 days);
        assertEq(pool.getParams().epochLength, 365 days);
    }

    /// The consequence the bound prevents, stated directly: with a max `grace`, `markDefault` reverts on
    /// the `dueAt + grace` addition and the loss can never be recognised. Driven through the old path by
    /// setting the param to the largest value the new bound allows and showing it still works - the point
    /// being that nothing inside the allowed range can overflow.
    function test_defaultsStayMarkableAcrossTheWholeAllowedRange() public {
        CreditPool.Params memory p = pool.getParams();
        p.grace = 365 days;
        p.recourseTerm = 365 days;
        vm.prank(owner);
        pool.setParams(p);

        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 100 * USD);
        pool.borrow(ROOT, 50 * USD, 7 days, rootOp);
        vm.stopPrank();
        uint256 id = pool.loanCount();

        vm.warp(block.timestamp + 7 days + 365 days + 1);
        pool.markDefault(id); // must not revert
        assertEq(uint256(pool.getLoan(id).status), 3, "the default was recorded");
    }

    // ---------------------------------------------------------------- 4. the fee sandwich

    /// The audit's PoC, inverted. A borrower used to wrap its own repayment in a deposit and a withdrawal
    /// and walk away having paid 46% of its fee instead of 100% - atomically, in one transaction, needing
    /// no mempool access and no privilege. Now the same sequence costs it MORE than paying the fee
    /// honestly, so there is nothing to gain by trying.
    function test_aBorrowerSandwichingItsOwnRepaymentNowLosesMoney() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 600 * USD);
        pool.vouch(ROOT, KID, 500 * USD);
        vm.stopPrank();

        vm.prank(kidOp);
        pool.borrow(KID, 500 * USD, 30 days, kidOp);
        uint256 id = pool.loanCount();
        vm.warp(block.timestamp + 30 days);

        uint256 owed = 500 * USD + pool.getLoan(id).fee;
        _fund(kidOp, 20_000 * USD);
        uint256 before = usdc.balanceOf(kidOp);

        // deposit in front of its own repayment, repay, leave immediately
        vm.startPrank(kidOp);
        pool.deposit(9_000 * USD, kidOp);
        pool.repay(id);
        uint256 sh = pool.shares(kidOp);
        pool.withdraw(sh, kidOp);
        vm.stopPrank();

        uint256 spent = before - usdc.balanceOf(kidOp);
        emit log_named_decimal_uint("owed if it had just repaid  ", owed, 6);
        emit log_named_decimal_uint("what the sandwich cost it  ", spent, 6);
        assertGt(spent, owed, "the sandwich must cost MORE than repaying honestly");
    }

    /// And the lender who carried the risk keeps the fee, which is the point. A bot that holds shares for
    /// zero seconds around the same repayment must end up worse off than when it started.
    function test_aZeroDurationDepositCannotTakeTheLendersFee() public {
        address bot = makeAddr("bot");
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 600 * USD);
        pool.vouch(ROOT, KID, 500 * USD);
        vm.stopPrank();

        vm.prank(kidOp);
        pool.borrow(KID, 500 * USD, 30 days, kidOp);
        uint256 id = pool.loanCount();
        vm.warp(block.timestamp + 30 days);

        _fund(bot, 9_000 * USD);
        uint256 botBefore = usdc.balanceOf(bot);
        vm.prank(bot);
        pool.deposit(9_000 * USD, bot);

        _fund(kidOp, 100 * USD);
        vm.prank(kidOp);
        pool.repay(id);

        uint256 sh = pool.shares(bot);
        vm.prank(bot);
        pool.withdraw(sh, bot);

        emit log_named_decimal_uint("bot started with", botBefore, 6);
        emit log_named_decimal_uint("bot ended with  ", usdc.balanceOf(bot), 6);
        assertLt(usdc.balanceOf(bot), botBefore, "a zero-duration position must not be profitable");
    }

    /// A bug I introduced with the exit fee and then caught: the hold clock was set to `block.timestamp`
    /// outright, so anyone could `deposit(1, victim)` and restart a stranger's seven days, taxing their
    /// exit 0.5% for one unit of USDG. The clock is share-weighted now.
    function test_aDustDepositCannotResetSomeoneElsesHoldClock() public {
        address victim = makeAddr("victim");
        address griefer = makeAddr("griefer");
        _fund(victim, 10_000 * USD);
        vm.prank(victim);
        pool.deposit(10_000 * USD, victim);

        vm.warp(block.timestamp + pool.MIN_HOLD() + 1); // the victim has served its time
        assertEq(pool.earlyExitFee(victim, pool.shares(victim)), 0, "the victim should be free to leave");

        _fund(griefer, 1_000 * USD);
        vm.prank(griefer);
        pool.deposit(1, victim); // one unit, to someone else's address

        assertEq(pool.earlyExitFee(victim, pool.shares(victim)), 0, "a dust deposit restarted the victim's clock");

        uint256 before = usdc.balanceOf(victim);
        uint256 sh = pool.shares(victim);
        vm.prank(victim);
        pool.withdraw(sh, victim);
        assertGe(usdc.balanceOf(victim) - before, 10_000 * USD, "the victim was taxed on someone else's deposit");
    }

    /// The other half: a real deposit still starts a real clock, so the weighting cannot be used to dodge
    /// the fee by depositing into a long-held position.
    function test_aSandwichSizedDepositStillStartsTheClock() public {
        address bot = makeAddr("bot");
        _fund(bot, 1_000 * USD);
        vm.prank(bot);
        pool.deposit(10 * USD, bot);
        vm.warp(block.timestamp + pool.MIN_HOLD() + 1); // small, long-held position

        vm.prank(bot);
        pool.deposit(990 * USD, bot); // now pile in
        assertGt(pool.earlyExitFee(bot, pool.shares(bot)), 0, "a large top-up must re-arm the fee");
    }

    // ---------------------------------------------------------------- 3. import bounds

    /// The migration this build runs is an `importRecords` call, so this is the guard protecting its own
    /// output. An unbounded counter makes `score()` revert with an arithmetic panic once the agent is
    /// enrolled - and by then the record is no longer blank and imports are sealed, so it is permanent.
    function test_importRecordsRefusesCountersThatWouldBrickTheScore() public {
        CreditPool.ImportedRecord[] memory rs = new CreditPool.ImportedRecord[](1);
        rs[0].agentId = KID;
        rs[0].enrolledAt = uint64(block.timestamp - 1);
        rs[0].qualifiedRepaid = type(uint256).max / 19; // x 20 in ScoreLib

        CreditPool fresh = _unsealedPool();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.ImportOutOfRange.selector, KID));
        fresh.importRecords(rs);
    }

    function test_importRecordsRefusesAnAbsurdChildrenDefaulted() public {
        CreditPool.ImportedRecord[] memory rs = new CreditPool.ImportedRecord[](1);
        rs[0].agentId = KID;
        rs[0].enrolledAt = uint64(block.timestamp - 1);
        rs[0].childrenDefaulted = type(uint256).max / 74; // x 75 in ScoreLib

        CreditPool fresh = _unsealedPool();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.ImportOutOfRange.selector, KID));
        fresh.importRecords(rs);
    }

    /// A real record - the shape this build's own migration imports - still goes through, and the score it
    /// produces is readable afterwards. This is the test that would catch a bound set too tight.
    function test_aRealisticRecordImportsAndItsScoreIsReadable() public {
        CreditPool.ImportedRecord[] memory rs = new CreditPool.ImportedRecord[](1);
        rs[0].agentId = KID;
        rs[0].enrolledAt = uint64(block.timestamp - 30 days);
        rs[0].loansRepaid = 3;
        rs[0].volumeRepaid = 15 * USD;
        rs[0].feesPaid = 150_000;
        rs[0].qualifiedRepaid = 3;
        rs[0].dollarSecondsRepaid = 15 * USD * 21 days;

        CreditPool fresh = _unsealedPool();
        vm.prank(owner);
        fresh.importRecords(rs);

        usdc.mint(rootOp, 1_000 * USD);
        vm.startPrank(rootOp);
        usdc.approve(address(fresh), type(uint256).max);
        fresh.enrollRoot(ROOT, 100 * USD);
        fresh.vouch(ROOT, KID, 50 * USD); // enrols it, which is when a bricked score would surface
        vm.stopPrank();

        uint256 sc = fresh.score(KID); // must not revert
        assertGt(sc, 0, "an imported record should produce a real score");
        assertEq(fresh.creditReport(KID).loansRepaid, 3, "the history carried");
        assertEq(fresh.creditReport(KID).volumeRepaid, 15 * USD);
    }
}
