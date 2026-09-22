// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TreasurySponsor} from "../src/TreasurySponsor.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";

contract TreasurySponsorTest is Test {
    uint256 constant USDC = 1e6;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    MockPonsFeeEscrow escrow;
    CreditPool pool;
    TreasurySponsor treasury;

    address owner = makeAddr("owner");
    address sink = makeAddr("buyback");
    address lender = makeAddr("lender");
    address agentOp = makeAddr("agentOp");
    address anyone = makeAddr("anyone");
    address launchToken = makeAddr("launchToken");

    uint256 TREASURY_ID;
    uint256 AGENT;

    // the inviter: a key the owner names; its EIP-712 signature over (agentId, expiry) is the seat
    uint256 constant INVITER_PK = 0xA11CE;
    address inviter = vm.addr(INVITER_PK);
    uint64 constant FAR = type(uint64).max;
    bytes32 DS;
    bytes32 TH; // cached: a prank must not be consumed by a view call while an invite is being built

    function _sig(uint256 id, uint64 expiry) internal view returns (bytes memory) {
        return _sigBy(INVITER_PK, id, expiry);
    }

    function _sigBy(uint256 pk, uint256 id, uint64 expiry) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DS, keccak256(abi.encode(TH, id, expiry))));
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
        return abi.encodePacked(r, s_, v);
    }

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        escrow = new MockPonsFeeEscrow();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);
        treasury = new TreasurySponsor(
            pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, sink
        );
        escrow.setFeeRecipient(launchToken, address(treasury));

        usdc.mint(lender, 10_000 * USDC);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(10_000 * USDC, lender);
        vm.stopPrank();

        // the treasury's identity: registered by the owner, handed over, adopted
        vm.startPrank(owner);
        TREASURY_ID = reg.register("priors-treasury");
        reg.safeTransferFrom(owner, address(treasury), TREASURY_ID);
        treasury.adopt(TREASURY_ID);
        treasury.setInviter(inviter, true);
        vm.stopPrank();
        DS = treasury.DOMAIN_SEPARATOR();
        TH = treasury.INVITE_TYPEHASH();

        vm.prank(agentOp);
        AGENT = reg.register("ipfs://agent");
        usdc.mint(agentOp, 1_000 * USDC);
        vm.prank(agentOp);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _creatorFees(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(escrow), amount);
        escrow.creditToken(address(treasury), address(usdc), amount);
    }

    function test_adopt_requiresOwningTheIdentity() public {
        vm.prank(agentOp);
        uint256 other = reg.register("ipfs://other");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotOurs.selector, other));
        treasury.adopt(other);
    }

    function test_sweep_splitsCreatorFeesIntoReserveAndStake() public {
        _creatorFees(200 * USDC);
        uint256 reserveBefore = pool.reserve();
        vm.prank(anyone);
        (uint256 toReserve, uint256 toStake) = treasury.sweep();
        assertEq(toReserve, 100 * USDC);
        assertEq(toStake, 100 * USDC);
        assertEq(pool.reserve(), reserveBefore + 100 * USDC);
        CreditPool.CreditReport memory r = pool.creditReport(TREASURY_ID);
        assertTrue(r.enrolled && r.isRoot);
        assertEq(r.stake, 100 * USDC);
        // a second sweep adds stake instead of enrolling again
        _creatorFees(50 * USDC);
        treasury.sweep();
        assertEq(pool.creditReport(TREASURY_ID).stake, 125 * USDC);
        assertEq(treasury.totalStaked(), 125 * USDC);
        assertEq(treasury.totalToReserve(), 125 * USDC);
    }

    function test_sweep_holdsStakeUntilAdopted() public {
        TreasurySponsor fresh = new TreasurySponsor(
            pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, sink
        );
        usdc.mint(address(fresh), 40 * USDC);
        (uint256 toReserve, uint256 toStake) = fresh.sweep();
        assertEq(toReserve, 20 * USDC);
        assertEq(toStake, 0);
        assertEq(usdc.balanceOf(address(fresh)), 20 * USDC, "the stake half waits for an identity");
    }

    function test_firstLine_theIdentitysOwnerOpensItOnce() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        CreditPool.CreditReport memory r = pool.creditReport(AGENT);
        assertTrue(r.enrolled);
        assertEq(r.sponsor, TREASURY_ID);
        assertEq(r.delegatedIn, 5 * USDC);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.AlreadyLined.selector, AGENT));
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        // the agent can borrow against it right away
        vm.prank(agentOp);
        uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
        assertEq(pool.getLoan(loan).principal, 5 * USDC);
    }

    function test_firstLine_refusesAlreadyEnrolledAgents() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        // enrolled under someone else first
        address rootOp = makeAddr("rootOp");
        vm.prank(rootOp);
        uint256 root = reg.register("ipfs://root");
        usdc.mint(rootOp, 100 * USDC);
        vm.startPrank(rootOp);
        usdc.approve(address(pool), type(uint256).max);
        pool.enrollRoot(root, 100 * USDC);
        pool.vouch(root, AGENT, 20 * USDC);
        vm.stopPrank();
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.AlreadyEnrolled.selector, AGENT));
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
    }

    /// The cheapest attack on the cap is not registering identities - it is lining the ones that already
    /// exist. Four hundred identities sit in the registry; twenty calls would have burnt a week's cap and
    /// tied twenty lines to agents that never asked. Only the identity's controller can ask.
    function test_firstLine_strangersCannotBurnTheCapOnOtherPeoplesIdentities() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        uint256 roomBefore = treasury.epochRoom();
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotController.selector, AGENT, anyone));
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        assertEq(treasury.epochRoom(), roomBefore, "nothing spent");
        assertFalse(pool.creditReport(AGENT).enrolled);
        // the pool delegate the owner named can ask on its behalf
        address bot = makeAddr("bot");
        vm.prank(agentOp);
        pool.setDelegate(AGENT, bot);
        vm.prank(bot);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        assertEq(pool.creditReport(AGENT).delegatedIn, 5 * USDC);
    }

    /// A line nobody uses is capacity nobody else can have. After `idleAfter` anyone can hand it back.
    function test_reclaim_anIdleLineGoesBackToTheTreasury() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        uint256 freeBefore = pool.creditReport(TREASURY_ID).available;
        (,,,,,,,, uint64 idleAfter) = treasury.rules();
        assertEq(treasury.reclaimableAt(AGENT), block.timestamp + idleAfter);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotIdle.selector, AGENT, block.timestamp + idleAfter));
        treasury.reclaim(AGENT);
        vm.warp(block.timestamp + idleAfter);
        vm.prank(anyone);
        uint256 got = treasury.reclaim(AGENT);
        assertEq(got, 5 * USDC);
        CreditPool.CreditReport memory r = pool.creditReport(AGENT);
        assertEq(r.delegatedIn, 0, "the vouch is gone");
        assertTrue(r.enrolled, "the record stays");
        assertEq(pool.creditReport(TREASURY_ID).available, freeBefore + 5 * USDC, "capacity is back");
        // the spent invite does not reopen the seat (a fresh one would: see TreasuryV3Audit), and nothing is left to reclaim
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.InviteUsed.selector, AGENT));
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NothingToReclaim.selector, AGENT));
        treasury.reclaim(AGENT);
    }

    /// An agent that uses its line keeps it: a look that finds an open loan or a new repayment only
    /// refreshes the watermark, and the clock restarts from that look.
    function test_reclaim_sparesAnAgentThatUsesItsLine() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        (,,,,,,,, uint64 idleAfter) = treasury.rules();
        uint256 lined = block.timestamp;
        // borrows on day 20, repays on day 27
        vm.warp(lined + 20 days);
        vm.prank(agentOp);
        uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
        // an open loan: not reclaimable, the look just refreshes
        vm.warp(lined + 25 days);
        assertEq(treasury.reclaimableAt(AGENT), 0);
        assertEq(treasury.reclaim(AGENT), 0);
        vm.warp(lined + 27 days);
        vm.prank(agentOp);
        pool.repay(loan);
        // day 35: the first look since the repayment sees a new repayment and refreshes again
        vm.warp(lined + 35 days);
        assertEq(treasury.reclaim(AGENT), 0);
        assertEq(treasury.reclaimableAt(AGENT), lined + 35 days + idleAfter);
        vm.warp(lined + 35 days + idleAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotIdle.selector, AGENT, lined + 35 days + idleAfter));
        treasury.reclaim(AGENT);
        // and a truly idle month after that, it goes
        vm.warp(lined + 35 days + idleAfter);
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
    }

    /// A defaulted agent has nothing left to reclaim - the default already consumed or released it.
    function test_reclaim_hasNothingToTakeFromADefault() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.prank(agentOp);
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
        vm.warp(block.timestamp + 7 days + 3 days + 1);
        pool.markDefault(1);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NothingToReclaim.selector, AGENT));
        treasury.reclaim(AGENT);
    }

    function test_epochCap_boundsWhatASybilCanDrain() public {
        _creatorFees(2_000 * USDC);
        treasury.sweep(); // $1,000 staked, far more than the cap
        uint256 n = 100 * USDC / (5 * USDC); // cap / firstLine = 20 identities per epoch
        vm.startPrank(anyone);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = reg.register("ipfs://sybil");
            treasury.firstLine(id, FAR, _sig(id, FAR));
        }
        uint256 extra = reg.register("ipfs://sybil");
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.EpochCapReached.selector, 5 * USDC, 0));
        treasury.firstLine(extra, FAR, _sig(extra, FAR));
        assertEq(treasury.epochRoom(), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(treasury.epochRoom(), 100 * USDC);
        treasury.firstLine(extra, FAR, _sig(extra, FAR));
        vm.stopPrank();
    }

    function test_raise_onlyAfterACleanSeasonedRecord() public {
        _creatorFees(400 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        // three qualified loans over three weeks
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agentOp);
            uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
            vm.warp(block.timestamp + 7 days);
            vm.prank(agentOp);
            pool.repay(loan);
        }
        CreditPool.CreditReport memory r = pool.creditReport(AGENT);
        assertEq(r.qualifiedRepaid, 3);
        assertGe(r.score, 100, "three week-long loans, three weeks of age and $5 backing should clear 100");
        vm.prank(anyone);
        treasury.raise(AGENT);
        r = pool.creditReport(AGENT);
        assertEq(r.delegatedIn, 50 * USDC);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotEligible.selector, AGENT));
        treasury.raise(AGENT); // already at the second tier
    }

    function test_defaultSlashesTheTreasury_andItsScoreTakesThePenalty() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.prank(agentOp);
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
        vm.warp(block.timestamp + 7 days + 3 days + 1);
        uint256 stakeBefore = pool.creditReport(TREASURY_ID).stake;
        pool.markDefault(1);
        assertEq(pool.creditReport(TREASURY_ID).stake, stakeBefore - 5 * USDC, "treasury eats the loss");
        assertEq(pool.creditReport(TREASURY_ID).childrenDefaulted, 1);
        assertEq(pool.totalAssets(), 10_000 * USDC + pool.totalFeesEarned(), "lenders whole");
    }

    function test_collect_sendsSponsorFeesToTheBuybackWallet() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.prank(agentOp);
        uint256 loan = pool.borrow(AGENT, 5 * USDC, 30 days, agentOp);
        vm.warp(block.timestamp + 30 days);
        vm.prank(agentOp);
        pool.repay(loan);
        uint256 owed = pool.sponsorFees(TREASURY_ID);
        assertGt(owed, 0);
        vm.prank(anyone);
        uint256 got = treasury.collect();
        assertEq(got, owed);
        assertEq(usdc.balanceOf(sink), owed);
        assertEq(treasury.totalCollected(), owed);
    }

    function test_ownerControls_rulesSinkRetireAndRecipient() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), anyone));
        vm.prank(anyone);
        treasury.setFeeSink(anyone);
        vm.startPrank(owner);
        treasury.setFeeSink(anyone);
        assertEq(treasury.feeSink(), anyone);
        TreasurySponsor.Rules memory r = TreasurySponsor.Rules({
            reserveBps: 3000,
            firstLine: 10 * USDC,
            secondLine: 80 * USDC,
            epochCap: 200 * USDC,
            epochLength: 1 days,
            minSeasoning: 1 days,
            minQualified: 1,
            minScore: 50,
            idleAfter: 10 days
        });
        treasury.setRules(r);
        (uint256 reserveBps,,,,,,,,) = treasury.rules();
        assertEq(reserveBps, 3000);
        r.secondLine = 1 * USDC; // below firstLine
        vm.expectRevert(TreasurySponsor.InvalidRules.selector);
        treasury.setRules(r);
        r.secondLine = 80 * USDC;
        r.idleAfter = 0; // a zero idle period would let anyone reclaim an honest line the block after it opened
        vm.expectRevert(TreasurySponsor.InvalidRules.selector);
        treasury.setRules(r);
        treasury.retire(40 * USDC, owner);
        assertEq(usdc.balanceOf(owner), 40 * USDC);
        treasury.transferCreatorFeeRecipient(launchToken, owner);
        assertEq(escrow.feeRecipientOf(launchToken), owner);
        vm.stopPrank();
    }

    /// Registration is permissionless; treasury money is not. Without an invite there is no line, and the
    /// caller being the identity's owner does not change that.
    function test_firstLine_needsAnInvite() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        uint256 roomBefore = treasury.epochRoom();
        uint256 strangerPk = 0xBAD;
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotInvited.selector, AGENT, vm.addr(strangerPk)));
        treasury.firstLine(AGENT, FAR, _sigBy(strangerPk, AGENT, FAR));
        assertEq(treasury.epochRoom(), roomBefore, "nothing spent");
        assertFalse(pool.creditReport(AGENT).enrolled);
    }

    /// An invite names one identity and one deadline. It cannot be moved to another id, used after it expires,
    /// or reused once a line exists.
    function test_invite_isBoundToTheIdentityAndTheDeadline() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        uint256 other = reg.register("ipfs://other");
        bytes memory forAgent = _sig(AGENT, FAR);
        // a different identity recovers to a different, un-named signer
        vm.prank(agentOp);
        vm.expectRevert();
        treasury.firstLine(other, FAR, forAgent);
        // expired
        uint64 soon = uint64(block.timestamp + 1 hours);
        bytes memory brief = _sig(AGENT, soon);
        vm.warp(soon + 1);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.InviteExpired.selector, AGENT, soon));
        treasury.firstLine(AGENT, soon, brief);
        // valid, once
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, forAgent);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.AlreadyLined.selector, AGENT));
        treasury.firstLine(AGENT, FAR, forAgent);
    }

    /// The owner can revoke an inviter; invites it already signed stop working at once.
    function test_owner_revokesAnInviter() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        bytes memory sig = _sig(AGENT, FAR);
        vm.prank(owner);
        treasury.setInviter(inviter, false);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotInvited.selector, AGENT, inviter));
        treasury.firstLine(AGENT, FAR, sig);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), anyone));
        vm.prank(anyone);
        treasury.setInviter(anyone, true);
    }
}
