// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

contract CreditPoolTest is Test {
    uint256 constant USDC = 1e6;
    uint256 constant DEPOSIT = 10_000 * USDC;
    uint256 constant RESERVE = 1_000 * USDC;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address rootOp = makeAddr("rootOp"); // operates the root agent
    address midOp = makeAddr("midOp"); // operates a mid-tree agent
    address leafOp = makeAddr("leafOp"); // operates a leaf agent
    address stranger = makeAddr("stranger");

    uint256 ROOT;
    uint256 MID;
    uint256 LEAF;
    uint256 OTHER;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);

        // lender seeds the pool
        usdc.mint(lender, DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(DEPOSIT, lender);
        vm.stopPrank();

        // operator funds the first-loss reserve
        usdc.mint(owner, RESERVE);
        vm.startPrank(owner);
        usdc.approve(address(pool), type(uint256).max);
        pool.fundReserve(RESERVE);
        vm.stopPrank();

        // register agents
        vm.prank(rootOp);
        ROOT = reg.register("ipfs://root");
        vm.prank(midOp);
        MID = reg.register("ipfs://mid");
        vm.prank(leafOp);
        LEAF = reg.register("ipfs://leaf");
        vm.prank(leafOp);
        OTHER = reg.register("ipfs://other");

        // fund operators
        address[3] memory ops = [rootOp, midOp, leafOp];
        for (uint256 i = 0; i < ops.length; i++) {
            usdc.mint(ops[i], 2_000 * USDC);
            vm.prank(ops[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ helpers

    /// ROOT (stake 200) -> MID (line 100, earned 50 from two seasoned repayments) -> LEAF (line 40)
    function _buildTree() internal {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        // MID earns capacity it can vouch with: $25 per epoch, two epochs
        _borrowRepay(midOp, MID, 100 * USDC, 7 days, 2 days);
        vm.warp(block.timestamp + 7 days);
        _borrowRepay(midOp, MID, 100 * USDC, 7 days, 2 days);
        assertEq(pool.getAgent(MID).earned, 50 * USDC);
        vm.prank(midOp);
        pool.vouch(MID, LEAF, 40 * USDC);
    }

    function _borrow(address op, uint256 agent, uint256 amt, uint64 term) internal returns (uint256 id) {
        vm.prank(op);
        id = pool.borrow(agent, amt, term, op);
    }

    function _borrowRepay(address op, uint256 agent, uint256 amt, uint64 term, uint256 hold) internal {
        uint256 id = _borrow(op, agent, amt, term);
        vm.warp(block.timestamp + hold);
        vm.prank(op);
        pool.repay(id);
    }

    function _lendersWhole() internal view {
        assertEq(pool.totalAssets(), DEPOSIT + pool.totalFeesEarned(), "lenders lost principal");
    }

    // ------------------------------------------------------------------ lenders

    function test_depositAndWithdraw_roundTrips() public {
        assertEq(pool.shares(lender), DEPOSIT);
        assertEq(pool.totalAssets(), DEPOSIT);
        vm.prank(lender);
        pool.withdraw(4_000 * USDC, lender);
        assertEq(usdc.balanceOf(lender), 4_000 * USDC);
        assertEq(pool.poolLiquidity(), 6_000 * USDC);
    }

    function test_withdraw_revertsWhenLiquidityIsLentOut() public {
        _buildTree();
        vm.prank(rootOp);
        pool.addStake(ROOT, 500 * USDC);
        _borrow(rootOp, ROOT, 500 * USDC, 10 days);
        vm.prank(lender);
        vm.expectRevert(); // InsufficientLiquidity
        pool.withdraw(DEPOSIT, lender);
    }

    function test_feesAreSplitBetweenLendersSponsorAndReserve() public {
        _buildTree();
        uint256 feesBefore = pool.totalFeesEarned();
        uint256 reserveBefore = pool.reserve();
        uint256 unclaimedBefore = pool.unclaimedSponsorFees();
        uint256 id = _borrow(leafOp, LEAF, 30 * USDC, 30 days);
        CreditPool.Loan memory l = pool.getLoan(id);
        assertEq(l.fee, 0.3 * 1e6); // 1% per 30 days
        vm.warp(block.timestamp + 2 days);
        vm.prank(leafOp);
        pool.repay(id);
        uint256 toSponsor = l.fee * 2500 / 10_000;
        uint256 toReserve = l.fee * 1500 / 10_000;
        assertEq(pool.totalFeesEarned(), feesBefore + l.fee - toSponsor - toReserve);
        assertEq(pool.sponsorFees(MID), toSponsor); // MID vouched LEAF
        assertEq(pool.unclaimedSponsorFees(), unclaimedBefore + toSponsor);
        assertEq(pool.reserve(), reserveBefore + toReserve);
        assertEq(pool.getAgent(LEAF).feesPaid, l.fee);
        _lendersWhole();
        assertGt(pool.convertToAssets(DEPOSIT), DEPOSIT);
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolLiquidity() + pool.totalStake() + pool.reserve() + pool.unclaimedSponsorFees()
        );
    }

    function test_sponsorFees_claimOnlyByController() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        uint256 owed = pool.sponsorFees(MID);
        assertGt(owed, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotController.selector, MID, stranger));
        pool.claimSponsorFees(MID, stranger);
        uint256 before = usdc.balanceOf(midOp);
        uint256 unclaimedBefore = pool.unclaimedSponsorFees();
        vm.prank(midOp);
        pool.claimSponsorFees(MID, midOp);
        assertEq(usdc.balanceOf(midOp) - before, owed);
        assertEq(pool.sponsorFees(MID), 0);
        assertEq(pool.unclaimedSponsorFees(), unclaimedBefore - owed);
        vm.prank(midOp);
        vm.expectRevert(CreditPool.ZeroAmount.selector);
        pool.claimSponsorFees(MID, midOp);
    }

    function test_rootsOwnLoans_sponsorShareGoesToLenders() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        uint256 id = _borrow(rootOp, ROOT, 100 * USDC, 30 days);
        uint256 fee = pool.getLoan(id).fee;
        vm.warp(block.timestamp + 2 days);
        vm.prank(rootOp);
        pool.repay(id);
        assertEq(pool.totalSponsorFees(), 0);
        assertEq(pool.totalFeesEarned(), fee - fee * 1500 / 10_000);
        assertEq(pool.totalProtocolFees(), fee * 1500 / 10_000);
    }

    // ------------------------------------------------------------------ reserve

    function test_reserve_isNotLenderMoney() public view {
        assertEq(pool.reserve(), RESERVE);
        assertEq(pool.totalAssets(), DEPOSIT);
        assertEq(usdc.balanceOf(address(pool)), DEPOSIT + RESERVE);
    }

    function test_reserve_withdrawOnlyFreePortionAndOnlyOwner() public {
        _buildTree(); // MID earned 50 -> locked
        vm.prank(stranger);
        vm.expectRevert();
        pool.withdrawReserve(1, stranger);
        uint256 free = pool.reserve() - pool.totalEarned();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.ReserveLocked.selector, free + 1, free));
        pool.withdrawReserve(free + 1, owner);
        vm.prank(owner);
        pool.withdrawReserve(free, owner);
        assertEq(pool.reserve(), pool.totalEarned());
        assertEq(pool.totalEarned(), 50 * USDC);
    }

    function test_growth_stopsWhenReserveIsExhausted() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, LEAF, 40 * USDC);
        vm.prank(owner);
        pool.withdrawReserve(RESERVE, owner); // nothing earned yet, so all of it is free
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        // the only reserve that exists is the protocol's cut of this one fee, and that is all the credit granted
        assertEq(pool.getAgent(LEAF).earned, pool.totalProtocolFees(), "unbacked credit exceeds the reserve");
        assertLt(pool.getAgent(LEAF).earned, 1 * USDC);
        assertEq(pool.getAgent(LEAF).loansRepaid, 1);
        // top the reserve up a little: growth resumes, bounded by it
        vm.prank(owner);
        pool.fundReserve(10 * USDC);
        vm.warp(block.timestamp + 7 days);
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        assertEq(pool.getAgent(LEAF).earned, pool.reserve()); // fully committed again
        assertGt(pool.getAgent(LEAF).earned, 10 * USDC);
        assertEq(pool.totalEarned(), pool.getAgent(LEAF).earned);
    }

    // ------------------------------------------------------------------ roots

    function test_enrollRoot_requiresMinStakeAndControl() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotController.selector, ROOT, stranger));
        pool.enrollRoot(ROOT, 100 * USDC);

        vm.prank(rootOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BelowMinStake.selector, 1 * USDC, 10 * USDC));
        pool.enrollRoot(ROOT, 1 * USDC);

        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 50 * USDC);
        assertEq(pool.capacity(ROOT), 50 * USDC);
        assertEq(pool.totalStake(), 50 * USDC);
        assertEq(pool.totalAssets(), DEPOSIT); // stake is not lender money
    }

    function test_withdrawStake_onlyUnusedCapacity() public {
        _buildTree(); // root stake 200, delegated 100
        vm.prank(rootOp);
        vm.expectRevert();
        pool.withdrawStake(ROOT, 150 * USDC, rootOp);
        vm.prank(rootOp);
        pool.withdrawStake(ROOT, 100 * USDC, rootOp);
        assertEq(pool.available(ROOT), 0);
    }

    function test_delegateCanActForAgent() public {
        address hotWallet = makeAddr("hot");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotController.selector, ROOT, stranger));
        pool.setDelegate(ROOT, hotWallet);
        vm.prank(rootOp);
        pool.setDelegate(ROOT, hotWallet);
        assertTrue(pool.isController(ROOT, hotWallet));
        usdc.mint(hotWallet, 100 * USDC);
        vm.startPrank(hotWallet);
        usdc.approve(address(pool), type(uint256).max);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ sponsor tree

    function test_vouch_buildsTreeAndTracksCapacity() public {
        _buildTree();
        assertEq(pool.capacity(ROOT), 200 * USDC);
        assertEq(pool.available(ROOT), 100 * USDC);
        assertEq(pool.capacity(MID), 150 * USDC); // 100 line + 50 earned
        assertEq(pool.available(MID), 110 * USDC); // minus 40 delegated
        assertEq(pool.capacity(LEAF), 40 * USDC);
        assertEq(pool.available(LEAF), 40 * USDC);
        assertEq(pool.enrolledCount(), 3);
    }

    function test_vouch_rootCannotExceedAvailable() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.InsufficientCapacity.selector, ROOT, 101 * USDC, 100 * USDC));
        pool.vouch(ROOT, MID, 101 * USDC);
    }

    function test_vouch_nonRootOnlyFromEarned() public {
        _buildTree(); // MID: earned 50, 40 already delegated, 110 available
        vm.prank(midOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.DelegationExceedsEarned.selector, MID, 11 * USDC, 10 * USDC));
        pool.vouch(MID, LEAF, 11 * USDC);
        vm.prank(midOp);
        pool.vouch(MID, LEAF, 10 * USDC);
        assertEq(pool.getAgent(MID).delegatedOut, 50 * USDC);
    }

    function test_vouch_borrowedCapacityCannotBeRedelegated() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, OTHER, 50 * USDC); // OTHER has a $50 line and nothing earned
        vm.prank(leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.DelegationExceedsEarned.selector, OTHER, 10 * USDC, 0));
        pool.vouch(OTHER, LEAF, 10 * USDC);
    }

    function test_vouch_singleSponsorAndNoCycles() public {
        _buildTree();
        vm.prank(rootOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.WrongSponsor.selector, LEAF, MID));
        pool.vouch(ROOT, LEAF, 1 * USDC);
        vm.prank(leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.IsRoot.selector, ROOT));
        pool.vouch(LEAF, ROOT, 1 * USDC);
        vm.prank(leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.WrongSponsor.selector, MID, ROOT));
        pool.vouch(LEAF, MID, 1 * USDC);
        vm.prank(rootOp);
        vm.expectRevert();
        pool.vouch(ROOT, 999, 1 * USDC); // not in the registry
    }

    function test_unvouch_onlyUnusedCapacity() public {
        _buildTree();
        _borrow(leafOp, LEAF, 30 * USDC, 5 days);
        vm.prank(midOp);
        vm.expectRevert();
        pool.unvouch(MID, LEAF, 20 * USDC);
        vm.prank(midOp);
        pool.unvouch(MID, LEAF, 10 * USDC);
        assertEq(pool.capacity(LEAF), 30 * USDC);
        assertEq(pool.available(MID), 120 * USDC);
    }

    // ------------------------------------------------------------------ borrow / repay

    function test_borrow_bounds() public {
        _buildTree();
        vm.startPrank(leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.LoanSizeOutOfRange.selector, 4 * USDC));
        pool.borrow(LEAF, 4 * USDC, 5 days, leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.TermOutOfRange.selector, uint64(31 days)));
        pool.borrow(LEAF, 10 * USDC, 31 days, leafOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.InsufficientCapacity.selector, LEAF, 41 * USDC, 40 * USDC));
        pool.borrow(LEAF, 41 * USDC, 5 days, leafOp);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.NotController.selector, LEAF, stranger));
        pool.borrow(LEAF, 10 * USDC, 5 days, stranger);
    }

    function test_borrow_transfersAndBooks() public {
        _buildTree();
        uint256 before = usdc.balanceOf(leafOp);
        uint256 liqBefore = pool.poolLiquidity();
        uint256 id = _borrow(leafOp, LEAF, 25 * USDC, 7 days);
        assertEq(usdc.balanceOf(leafOp) - before, 25 * USDC);
        assertEq(pool.totalPrincipalOut(), 25 * USDC);
        assertEq(pool.poolLiquidity(), liqBefore - 25 * USDC);
        assertEq(pool.available(LEAF), 15 * USDC);
        assertEq(pool.getLoan(id).dueAt, block.timestamp + 7 days);
        assertEq(pool.loansOf(LEAF).length, 1);
    }

    function test_repay_growsEarnedCapacity() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        CreditPool.Agent memory a = pool.getAgent(LEAF);
        assertEq(a.earned, 20 * USDC); // 50% of repaid principal
        assertEq(a.loansRepaid, 1);
        assertEq(a.volumeRepaid, 40 * USDC);
        assertEq(pool.capacity(LEAF), 60 * USDC);
        assertEq(pool.totalEarned(), 70 * USDC); // MID 50 + LEAF 20
        assertGt(pool.score(LEAF), 0);
    }

    function test_repay_noGrowthBeforeSeasoning() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 1 hours);
        assertEq(pool.getAgent(LEAF).earned, 0);
        assertEq(pool.getAgent(LEAF).loansRepaid, 1); // still counts as repaid
    }

    function test_growth_isRateLimitedPerEpoch() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 1 days);
        assertEq(pool.getAgent(LEAF).earned, 20 * USDC);
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 1 days);
        assertEq(pool.getAgent(LEAF).earned, 25 * USDC); // clipped at the $25 epoch cap
        vm.warp(block.timestamp + 7 days); // next epoch: room again
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 1 days);
        assertEq(pool.getAgent(LEAF).earned, 45 * USDC);
    }

    function test_growth_isCappedAtMaxEarned() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 900 * USDC);
        for (uint256 i = 0; i < 15; i++) {
            _borrowRepay(rootOp, ROOT, 400 * USDC, 7 days, 7 days + 1);
        }
        assertEq(pool.getAgent(ROOT).earned, 250 * USDC);
    }

    function test_anyoneCanRepay() public {
        _buildTree();
        uint256 id = _borrow(leafOp, LEAF, 20 * USDC, 7 days);
        usdc.mint(stranger, 100 * USDC);
        vm.startPrank(stranger);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(id);
        vm.stopPrank();
        assertEq(uint256(pool.getLoan(id).status), uint256(CreditPool.LoanStatus.Repaid));
    }

    // ------------------------------------------------------------------ defaults & recourse

    function test_markDefault_onlyAfterGrace() public {
        _buildTree();
        uint256 id = _borrow(leafOp, LEAF, 20 * USDC, 7 days);
        uint64 deadline = uint64(block.timestamp + 7 days + 3 days);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.LoanNotDue.selector, id, deadline));
        pool.markDefault(id);
        vm.warp(deadline + 1);
        pool.markDefault(id);
        assertTrue(pool.getAgent(LEAF).defaulted);
    }

    function test_default_leaf_issuesRecourseOnMidSponsor() public {
        _buildTree();
        uint256 id = _borrow(leafOp, LEAF, 30 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        vm.prank(stranger); // permissionless
        pool.markDefault(id);

        // leaf is dead
        assertTrue(pool.getAgent(LEAF).defaulted);
        assertEq(pool.capacity(LEAF), 0);
        assertEq(pool.score(LEAF), 0);

        // mid now owes $30 (liable = min(30, line 40)) as a recourse loan; its delegation is released
        CreditPool.Agent memory mid = pool.getAgent(MID);
        assertEq(mid.principalOut, 30 * USDC);
        assertEq(mid.delegatedOut, 0);
        assertEq(mid.childrenDefaulted, 1);
        uint256[] memory midLoans = pool.loansOf(MID);
        assertEq(midLoans.length, 3);
        CreditPool.Loan memory r = pool.getLoan(midLoans[2]);
        assertTrue(r.isRecourse);
        assertEq(r.principal, 30 * USDC);
        assertEq(r.recourseFor, id);

        // the debt moved, nothing was written off
        _lendersWhole();
        assertEq(pool.totalBadDebt(), 0);
        assertGe(pool.reserve(), RESERVE); // untouched by the default; grown a little by protocol fees
        assertEq(pool.totalPrincipalOut(), 30 * USDC);

        // mid honors it
        vm.prank(midOp);
        pool.repay(midLoans[2]);
        assertEq(pool.getAgent(MID).recourseHonored, 1);
        assertEq(pool.getAgent(MID).principalOut, 0);
        assertEq(pool.totalPrincipalOut(), 0);
        _lendersWhole();
    }

    function test_default_cascadesToRootStake() public {
        _buildTree();
        uint256 id = _borrow(leafOp, LEAF, 30 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id);
        uint256 rId = pool.loansOf(MID)[2];

        // mid ignores its recourse loan -> after 14d + grace, mid defaults, root's stake is slashed
        vm.warp(block.timestamp + 14 days + 3 days + 1);
        uint256 stakeBefore = pool.getAgent(ROOT).stake;
        pool.markDefault(rId);

        assertTrue(pool.getAgent(MID).defaulted);
        assertEq(pool.getAgent(ROOT).stake, stakeBefore - 30 * USDC);
        assertEq(pool.getAgent(ROOT).childrenDefaulted, 1);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertEq(pool.totalStake(), 170 * USDC);
        assertEq(pool.totalPrincipalOut(), 0);
        assertEq(pool.totalBadDebt(), 0);
        assertEq(pool.totalEarned(), 0); // MID's earned capacity died with it
        _lendersWhole();
    }

    function test_default_beyondBackingIsCoveredByReserve() public {
        _buildTree();
        // leaf earns capacity beyond its $40 line, then defaults big
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days); // earned +20 -> capacity 60
        uint256 id2 = _borrow(leafOp, LEAF, 60 * USDC, 7 days);
        uint256 reserveBefore = pool.reserve();
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id2);

        // sponsor liable only for what it vouched ($40); the other $20 is the reserve's problem
        assertEq(pool.getAgent(MID).principalOut, 40 * USDC);
        assertEq(pool.totalBadDebt(), 20 * USDC);
        assertEq(pool.totalReserveCovered(), 20 * USDC);
        assertEq(pool.reserve(), reserveBefore - 20 * USDC);
        _lendersWhole();
        assertGe(pool.convertToAssets(DEPOSIT), DEPOSIT);
    }

    function test_default_root_slashesOwnStake() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        uint256 id = _borrow(rootOp, ROOT, 80 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id);
        assertEq(pool.getAgent(ROOT).stake, 20 * USDC);
        assertEq(pool.totalBadDebt(), 0);
        assertTrue(pool.getAgent(ROOT).defaulted);
        _lendersWhole();
    }

    function test_default_rootSlashIsBoundedByStake() public {
        // a root with earned capacity can vouch more than its stake; the excess is reserve-backed
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        for (uint256 i = 0; i < 3; i++) {
            _borrowRepay(rootOp, ROOT, 100 * USDC, 7 days, 2 days);
            vm.warp(block.timestamp + 7 days);
        }
        assertEq(pool.getAgent(ROOT).earned, 75 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, LEAF, 150 * USDC);
        uint256 id = _borrow(leafOp, LEAF, 150 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id); // must not revert
        assertEq(pool.getAgent(ROOT).stake, 0);
        assertEq(pool.totalBadDebt(), 50 * USDC);
        assertEq(pool.totalReserveCovered(), 50 * USDC);
        _lendersWhole();
    }

    function test_defaultedAgent_cannotBorrowOrSponsor() public {
        _buildTree();
        uint256 id = _borrow(midOp, MID, 20 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id);
        vm.prank(midOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.AgentDefaulted.selector, MID));
        pool.borrow(MID, 10 * USDC, 5 days, midOp);
        vm.prank(midOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.AgentDefaulted.selector, MID));
        pool.vouch(MID, LEAF, 1 * USDC);
        assertEq(pool.capacity(LEAF), 0); // LEAF's line from MID is void now
    }

    function test_orphanedChild_canBeReSponsored() public {
        _buildTree();
        uint256 id = _borrow(midOp, MID, 20 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id); // MID dead, LEAF orphaned
        assertEq(pool.capacity(LEAF), 0);
        vm.prank(rootOp);
        pool.vouch(ROOT, LEAF, 25 * USDC);
        assertEq(pool.getAgent(LEAF).sponsor, ROOT);
        assertEq(pool.capacity(LEAF), 25 * USDC);
        assertEq(pool.getAgent(LEAF).delegatedIn, 25 * USDC);
    }

    function test_sponsorAlreadyDead_reserveCoversTheOrphan() public {
        _buildTree();
        uint256 leafLoan = _borrow(leafOp, LEAF, 30 * USDC, 7 days);
        uint256 midLoan = _borrow(midOp, MID, 20 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(midLoan); // MID dead first (root stake slashed 20)
        pool.markDefault(leafLoan); // LEAF's sponsor is dead: nobody to charge, reserve pays
        assertEq(pool.totalBadDebt(), 30 * USDC);
        assertEq(pool.totalReserveCovered(), 30 * USDC);
        assertEq(pool.getAgent(ROOT).stake, 180 * USDC);
        _lendersWhole();
    }

    /// The whole point: unbacked credit is pre-funded, so lenders never lose principal.
    function test_invariant_reserveAlwaysCoversEarned_andLendersStayWhole() public {
        _buildTree();
        assertGe(pool.reserve(), pool.totalEarned());
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        assertGe(pool.reserve(), pool.totalEarned());
        uint256 a = _borrow(leafOp, LEAF, 60 * USDC, 7 days);
        uint256 b = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(b); // MID (earned 50, line 100): root pays 100, nothing unbacked
        assertGe(pool.reserve(), pool.totalEarned());
        _lendersWhole();
        pool.markDefault(a); // LEAF, sponsor dead: 60 unbacked, of which reserve had LEAF's 20 + MID's 50 headroom
        assertGe(pool.reserve(), pool.totalEarned());
        assertEq(pool.totalReserveCovered(), 60 * USDC);
        _lendersWhole();
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolLiquidity() + pool.totalStake() + pool.reserve() + pool.unclaimedSponsorFees()
        );
    }

    // ------------------------------------------------------------------ score

    function test_score_monotoneInRepayments() public {
        _buildTree();
        uint256 s0 = pool.score(LEAF);
        _borrowRepay(leafOp, LEAF, 40 * USDC, 7 days, 2 days);
        uint256 s1 = pool.score(LEAF);
        assertGt(s1, s0);
        CreditPool.CreditReport memory r = pool.creditReport(LEAF);
        assertEq(r.score, s1);
        assertEq(r.loansRepaid, 1);
        assertEq(r.sponsor, MID);
    }

    /// v0 could be farmed with one-day loans for cents. v1 counts dollar-days and week-long loans only.
    function test_score_oneDayLoansBarelyMove_itWeekLongLoansDo() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 1_000 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 500 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, LEAF, 500 * USDC);
        uint256 t0 = block.timestamp;
        // MID farms: thirty $500 loans, each one day, all repaid
        for (uint256 i = 0; i < 30; i++) {
            _borrowRepay(midOp, MID, 500 * USDC, 1 days, 1 days);
        }
        uint256 farmed = pool.score(MID);
        assertEq(pool.creditReport(MID).qualifiedRepaid, 0, "one-day loans are not qualified");
        // LEAF does it the honest way over the same 30 days: four week-long loans of $500
        vm.warp(t0);
        for (uint256 i = 0; i < 4; i++) {
            _borrowRepay(leafOp, LEAF, 500 * USDC, 7 days, 7 days);
        }
        uint256 honest = pool.score(LEAF);
        assertEq(pool.creditReport(LEAF).qualifiedRepaid, 4);
        assertGt(honest, farmed, "holding capital for weeks must beat churning it daily");
        // and the farmed score is nowhere near the top: 30 x $500 x 1 day = 15,000 dollar-days = 150 pts of 400
        assertLt(farmed - pool.score(ROOT) + 0, 400);
    }

    function test_score_dollarDaysAreTrackedPerLoan() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 10 days, 3 days);
        CreditPool.CreditReport memory r = pool.creditReport(LEAF);
        assertEq(r.dollarSecondsRepaid, 40 * USDC * 3 days, "principal x actual holding time");
        assertEq(r.qualifiedRepaid, 0);
        _borrowRepay(leafOp, LEAF, 40 * USDC, 2 days, 1 days);
        r = pool.creditReport(LEAF);
        assertEq(r.qualifiedRepaid, 0, "early repayments are not qualified");
        assertEq(r.loansRepaid, 2);
    }

    function test_score_penalizesSponsorOfDefaulter() public {
        _buildTree();
        vm.warp(block.timestamp + 30 days);
        uint256 before = pool.score(MID);
        uint256 id = _borrow(leafOp, LEAF, 30 * USDC, 7 days);
        vm.warp(block.timestamp + 11 days);
        pool.markDefault(id);
        assertLt(pool.score(MID), before + 22); // age adds <=22 pts over 11 days; the -75 penalty dominates
    }

    // ------------------------------------------------------------------ admin

    function test_pause_blocksNewCreditButNotRepayment() public {
        _buildTree();
        uint256 id = _borrow(leafOp, LEAF, 20 * USDC, 7 days);
        vm.prank(owner);
        pool.pause();
        vm.prank(leafOp);
        vm.expectRevert();
        pool.borrow(LEAF, 10 * USDC, 5 days, leafOp);
        vm.prank(leafOp);
        pool.repay(id); // fine
        vm.prank(lender);
        pool.withdraw(1 * USDC, lender); // lenders can always leave
    }

    function test_setParams_ownerOnlyAndValidated() public {
        CreditPool.Params memory p = pool.getParams();
        vm.prank(stranger);
        vm.expectRevert();
        pool.setParams(p);
        p.minLoan = p.maxLoan + 1;
        vm.prank(owner);
        vm.expectRevert(CreditPool.InvalidParams.selector);
        pool.setParams(p);
        p.minLoan = 1 * USDC;
        vm.prank(owner);
        pool.setParams(p);
        assertEq(pool.getParams().minLoan, 1 * USDC);
        p.minScoreTerm = 31 days; // longer than maxTerm: nothing could ever qualify
        vm.prank(owner);
        vm.expectRevert(CreditPool.InvalidParams.selector);
        pool.setParams(p);
    }

    function test_invariant_poolAccountingMatchesBalance() public {
        _buildTree();
        uint256 a = _borrow(leafOp, LEAF, 30 * USDC, 7 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 7 days);
        vm.warp(block.timestamp + 3 days);
        vm.prank(leafOp);
        pool.repay(a);
        vm.warp(block.timestamp + 9 days);
        pool.markDefault(b);
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolLiquidity() + pool.totalStake() + pool.reserve() + pool.unclaimedSponsorFees()
        );
    }

    function test_immediateRepaymentCannotFarmTimeScore() public {
        _buildTree();
        _borrowRepay(leafOp, LEAF, 40 * USDC, 30 days, 0);
        CreditPool.CreditReport memory r = pool.creditReport(LEAF);
        assertEq(r.dollarSecondsRepaid, 0);
        assertEq(r.qualifiedRepaid, 0);
    }

    function test_delegateExpiresWhenIdentityChangesOwner() public {
        _buildTree();
        vm.prank(midOp);
        pool.setDelegate(MID, stranger);
        assertTrue(pool.isController(MID, stranger));
        vm.prank(midOp);
        reg.transferFrom(midOp, leafOp, MID);
        assertFalse(pool.isController(MID, stranger));
        assertTrue(pool.isController(MID, leafOp));
    }

    function test_repaymentAfterDefaultDoesNotRegrowEarnedCredit() public {
        _buildTree();
        uint256 first = _borrow(leafOp, LEAF, 20 * USDC, 1 days);
        uint256 second = _borrow(leafOp, LEAF, 20 * USDC, 7 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(first);
        vm.prank(leafOp);
        pool.repay(second);
        assertEq(pool.getAgent(LEAF).earned, 0);
    }

    // Launch blocker: preserve this regression until default accounting is corrected.
    function test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        vm.prank(owner);
        pool.withdrawReserve(RESERVE, owner);
        uint256 first = _borrow(midOp, MID, 50 * USDC, 1 days);
        uint256 second = _borrow(midOp, MID, 50 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(first);
        pool.markDefault(second);
        assertEq(pool.totalAssets(), DEPOSIT, "fully stake-backed loans must not cost lenders principal");
    }
}
