// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TreasurySponsor} from "../src/TreasurySponsor.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";

/// `importRecords` exists for exactly one event: moving agents' repayment history onto a redeployed pool
/// when the old one cannot be upgraded. It is owner-only and it closes forever the moment lender money
/// arrives, so the whole of its trust surface is "the owner may flatter a score before anyone has
/// deposited". These tests hold it to that - especially the part where it must NOT be able to conjure
/// capacity, which is the only way an import could ever cost anyone money.
contract HistoryImportTest is Test {
    uint256 constant USD = 1e6;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address agentOwner = makeAddr("agentOwner");
    address stranger = makeAddr("stranger");

    uint256 AGENT;
    uint256 ROOT;

    function setUp() public {
        // A real migration imports dates from the past. Foundry starts at timestamp 1, so without this
        // every imported record would sit in the future - which the contract now refuses outright.
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);

        vm.startPrank(agentOwner);
        AGENT = reg.register("ipfs://agent");
        ROOT = reg.register("ipfs://root");
        vm.stopPrank();

        usdc.mint(lender, 1000 * USD);
        vm.prank(lender);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(agentOwner, 1000 * USD);
        vm.prank(agentOwner);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _record(uint256 id) internal pure returns (CreditPool.ImportedRecord memory r) {
        r.agentId = id;
        r.enrolledAt = 1_700_000_000;
        r.loansRepaid = 7;
        r.volumeRepaid = 250 * USD;
        r.feesPaid = 3 * USD;
        r.qualifiedRepaid = 5;
        r.dollarSecondsRepaid = 250 * USD * 30 days;
    }

    function _one(uint256 id) internal pure returns (CreditPool.ImportedRecord[] memory rs) {
        rs = new CreditPool.ImportedRecord[](1);
        rs[0] = _record(id);
    }

    function test_importCarriesTheRecordOver() public {
        vm.prank(owner);
        pool.importRecords(_one(AGENT));

        CreditPool.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.loansRepaid, 7, "loansRepaid");
        assertEq(a.volumeRepaid, 250 * USD, "volumeRepaid");
        assertEq(a.qualifiedRepaid, 5, "qualifiedRepaid");
        assertEq(a.enrolledAt, 1_700_000_000, "enrolledAt");
    }

    /// The whole point of the restriction: history in, never money.
    function test_importCannotCreateCapacityOrMoveFunds() public {
        uint256 poolBalBefore = usdc.balanceOf(address(pool));

        vm.prank(owner);
        pool.importRecords(_one(AGENT));

        CreditPool.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.stake, 0, "import must not create stake");
        assertEq(a.earned, 0, "import must not create earned capacity");
        assertEq(a.delegatedIn, 0, "import must not create a credit line");
        assertEq(a.principalOut, 0, "import must not create debt");
        assertFalse(a.enrolled, "import must not enrol - the agent still has to be vouched for");
        assertFalse(a.isRoot, "import must not make anyone a root");
        assertEq(pool.capacity(AGENT), 0, "no capacity");
        assertEq(pool.available(AGENT), 0, "nothing to draw");
        assertEq(pool.totalStake(), 0, "totalStake untouched");
        assertEq(pool.totalEarned(), 0, "totalEarned untouched");
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore, "not a unit of USDC moved");

        // and it still cannot borrow, because it has no line
        vm.prank(agentOwner);
        vm.expectRevert();
        pool.borrow(AGENT, 5 * USD, 7 days, agentOwner);
    }

    function test_importedAgentKeepsItsHistoryAndDateAfterBeingVouchedFor() public {
        vm.prank(owner);
        pool.importRecords(_one(AGENT));

        // a root sponsors it here, normally, spending real backing
        vm.startPrank(agentOwner);
        pool.enrollRoot(ROOT, 50 * USD);
        pool.vouch(ROOT, AGENT, 5 * USD);
        vm.stopPrank();

        CreditPool.Agent memory a = pool.getAgent(AGENT);
        assertTrue(a.enrolled, "now enrolled");
        assertEq(a.enrolledAt, 1_700_000_000, "the imported date survived enrolment");
        assertEq(a.loansRepaid, 7, "history survived enrolment");
        assertEq(a.delegatedIn, 5 * USD, "the line came from the sponsor, not the import");
        assertGt(pool.score(AGENT), 0, "the carried-over record counts toward the score");
    }

    /// A date in the future would underflow score()'s age term and revert creditReport() for good.
    function test_rejectsAnEnrolmentDateInTheFuture() public {
        CreditPool.ImportedRecord[] memory rs = _one(AGENT);
        rs[0].enrolledAt = uint64(block.timestamp + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BadEnrolmentDate.selector, AGENT, rs[0].enrolledAt));
        pool.importRecords(rs);
    }

    /// ...and a record imported with a valid past date must leave score() callable.
    function test_importedRecordLeavesScoreCallable() public {
        vm.prank(owner);
        pool.importRecords(_one(AGENT));
        pool.score(AGENT); // must not revert
        pool.creditReport(AGENT); // nor this, which the site and SDK call
    }

    /// A fresh agent must still get today's date - the guard is `enrolledAt == 0`, not a special case.
    function test_freshAgentStillGetsTodaysEnrolmentDate() public {
        vm.warp(2_000_000_000);
        vm.startPrank(agentOwner);
        pool.enrollRoot(ROOT, 50 * USD);
        pool.vouch(ROOT, AGENT, 5 * USD);
        vm.stopPrank();
        assertEq(pool.getAgent(AGENT).enrolledAt, 2_000_000_000, "fresh agents are dated now");
    }

    function test_onlyOwnerMayImport() public {
        vm.prank(stranger);
        vm.expectRevert();
        pool.importRecords(_one(AGENT));
    }

    function test_importsCloseForeverOnTheFirstDeposit() public {
        assertFalse(pool.importsSealed(), "open before anyone deposits");

        vm.prank(lender);
        pool.deposit(100 * USD, lender);

        assertTrue(pool.importsSealed(), "the first deposit seals it");
        vm.prank(owner);
        vm.expectRevert(CreditPool.ImportsAreSealed.selector);
        pool.importRecords(_one(AGENT));
    }

    function test_sealingByHandAlsoWorksAndIsOneWay() public {
        vm.prank(owner);
        pool.sealImports();
        assertTrue(pool.importsSealed(), "sealed");

        vm.prank(owner);
        vm.expectRevert(CreditPool.ImportsAreSealed.selector);
        pool.importRecords(_one(AGENT));
    }

    /// Importing over a record this pool wrote itself would be rewriting live history, not carrying it.
    function test_cannotImportOverARecordThePoolItselfWrote() public {
        vm.startPrank(agentOwner);
        pool.enrollRoot(ROOT, 50 * USD);
        pool.vouch(ROOT, AGENT, 5 * USD);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.RecordAlreadyLive.selector, AGENT));
        pool.importRecords(_one(AGENT));
    }

    function test_cannotImportTheSameAgentTwice() public {
        vm.startPrank(owner);
        pool.importRecords(_one(AGENT));
        vm.expectRevert(abi.encodeWithSelector(CreditPool.RecordAlreadyLive.selector, AGENT));
        pool.importRecords(_one(AGENT));
        vm.stopPrank();
    }

    function test_cannotImportAnIdentityThatDoesNotExist() public {
        vm.prank(owner);
        vm.expectRevert();
        pool.importRecords(_one(999_999));
    }

    /// The composition the changes review caught, made explicit rather than left to a comment.
    ///
    /// An imported record feeds TreasurySponsor.eligibleForRaise's seasoning and qualification gates,
    /// so a migrated agent can take its second line the moment it is first-lined, with no wait. That
    /// is what carrying history over means - and it is not a new power for the owner, who can already
    /// set minSeasoning to zero via setRules. This test exists so the behaviour is stated somewhere
    /// that fails if it silently changes.
    function test_importedHistoryLetsTheTreasuryRaiseWithoutSeasoning() public {
        MockPonsFeeEscrow escrow = new MockPonsFeeEscrow();
        TreasurySponsor treasury = new TreasurySponsor(
            pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, owner
        );

        vm.startPrank(owner);
        uint256 TID = reg.register("priors-treasury");
        reg.safeTransferFrom(owner, address(treasury), TID);
        treasury.adopt(TID);
        pool.importRecords(_one(AGENT)); // enrolledAt far in the past, qualifiedRepaid = 5
        vm.stopPrank();

        // seed the pool and the treasury's stake so it has real capacity to vouch out
        vm.prank(lender);
        pool.deposit(500 * USD, lender);
        usdc.mint(address(treasury), 400 * USD);
        treasury.sweep(); // permissionless; enrols the treasury as a root and funds the reserve

        uint64 minSeasoning;
        (,,,,, minSeasoning,,,) = treasury.rules();
        assertGt(minSeasoning, 0, "the rule that is being skipped is actually set");

        vm.prank(agentOwner);
        treasury.firstLine(AGENT);
        // No warp. A genuinely new agent could not pass eligibleForRaise here.
        assertTrue(treasury.eligibleForRaise(pool.creditReport(AGENT)), "imported history satisfies the gate at once");
        treasury.raise(AGENT);

        uint256 secondLine;
        (,, secondLine,,,,,,) = treasury.rules();
        assertEq(pool.creditReport(AGENT).delegatedIn, secondLine, "went straight to the second line");
    }

    /// A migration is one transaction or it is a half-written ledger.
    function test_importIsBatchedAndAtomic() public {
        CreditPool.ImportedRecord[] memory rs = new CreditPool.ImportedRecord[](2);
        rs[0] = _record(AGENT);
        rs[1] = _record(ROOT);

        vm.prank(owner);
        pool.importRecords(rs);
        assertEq(pool.getAgent(AGENT).loansRepaid, 7, "first");
        assertEq(pool.getAgent(ROOT).loansRepaid, 7, "second");

        // one bad entry rolls the whole batch back
        CreditPool.ImportedRecord[] memory bad = new CreditPool.ImportedRecord[](2);
        bad[0] = _record(999_999); // does not exist
        vm.prank(owner);
        vm.expectRevert();
        pool.importRecords(bad);
    }
}
