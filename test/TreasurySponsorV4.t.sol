// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {CreditLensV2} from "../src/CreditLensV2.sol";
import {TreasurySponsorV4} from "../src/TreasurySponsorV4.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";

contract TreasuryV4Base is Test {
    uint256 constant USDC = 1e6;
    uint64 constant FAR = type(uint64).max;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    MockPonsFeeEscrow escrow;
    CreditPoolV2 pool;
    CreditLensV2 lens;
    TreasurySponsorV4 treasury;

    address timelock = makeAddr("timelock");
    address owner = makeAddr("owner");
    address sink = makeAddr("buyback");
    address lender = makeAddr("lender");
    address anyone = makeAddr("anyone");
    address relayer = makeAddr("relayer");
    address launchToken = makeAddr("launchToken");

    uint256 constant INVITER_PK = 0xA11CE;
    uint256 constant AGENT_PK = 0xA1;
    uint256 constant AGENT2_PK = 0xA2;
    uint256 constant ROOT_PK = 0xB0B;
    address inviter = vm.addr(INVITER_PK);
    address agentOp = vm.addr(AGENT_PK);
    address agentOp2 = vm.addr(AGENT2_PK);
    address rootOp = vm.addr(ROOT_PK);

    uint256 TREASURY_ID;
    uint256 AGENT;
    uint256 AGENT2;
    bytes32 DS;
    bytes32 TH;

    function _poolParams() internal pure returns (CreditPoolV2.Params memory) {
        return CreditPoolV2.Params({
            minLoan: 5e6,
            maxLoan: 500e6,
            minTerm: 1 days,
            maxTerm: 30 days,
            grace: 3 days,
            minScoreTerm: 7 days,
            feeBps: 100,
            sponsorFeeBps: 2500,
            protocolFeeBps: 1500,
            minStake: 10e6,
            maxUtilizationBps: 9000,
            keeperBounty: 1e5
        });
    }

    function _deployPool(CreditPool v1) internal {
        pool = new CreditPoolV2(
            IERC20(address(usdc)), IERC8004Identity(address(reg)), v1, timelock, timelock, _poolParams()
        );
        lens = new CreditLensV2(pool);
        usdc.mint(address(this), 1 * USDC);
        usdc.approve(address(pool), 1 * USDC);
        pool.seed();
    }

    function _newTreasury() internal returns (TreasurySponsorV4) {
        return
            new TreasurySponsorV4(
                pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, sink
            );
    }

    function setUp() public virtual {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        escrow = new MockPonsFeeEscrow();
        _deployPool(CreditPool(address(0)));
        _setUpTreasury();
    }

    function _setUpTreasury() internal {
        treasury = _newTreasury();
        escrow.setFeeRecipient(launchToken, address(treasury));

        address[5] memory who = [lender, agentOp, agentOp2, rootOp, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000 * USDC);
            vm.prank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
        vm.prank(lender);
        pool.deposit(10_000 * USDC, lender, 0);

        vm.startPrank(owner);
        TREASURY_ID = reg.register("priors-treasury-v4");
        reg.safeTransferFrom(owner, address(treasury), TREASURY_ID);
        treasury.adopt(TREASURY_ID);
        treasury.setInviter(inviter, true);
        vm.stopPrank();
        DS = treasury.DOMAIN_SEPARATOR();
        TH = treasury.INVITE_TYPEHASH();

        vm.prank(agentOp);
        AGENT = reg.register("ipfs://agent");
        vm.prank(agentOp2);
        AGENT2 = reg.register("ipfs://agent2");
    }

    // ------------------------------------------------------------------
    // Signatures
    // ------------------------------------------------------------------

    function _invite(uint256 id, uint64 expiry) internal view returns (bytes memory) {
        return _inviteBy(INVITER_PK, id, expiry);
    }

    function _inviteBy(uint256 pk, uint256 id, uint64 expiry) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DS, keccak256(abi.encode(TH, id, expiry))));
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
        return abi.encodePacked(r, s_, v);
    }

    function _consentFor(uint256 id, uint256 sponsorId, uint256 pk)
        internal
        view
        returns (CreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: sponsorId,
            owner: vm.addr(pk),
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: vm.getBlockTimestamp() + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    function _consent(uint256 id, uint256 pk) internal view returns (CreditPoolV2.Consent memory, bytes memory) {
        return _consentFor(id, TREASURY_ID, pk);
    }

    /// The whole flow: the inviter signed, the agent's owner signed, a relayer submits.
    function _firstLine(uint256 id, uint256 pk) internal {
        _firstLineWith(id, pk, FAR);
    }

    function _firstLineWith(uint256 id, uint256 pk, uint64 expiry) internal {
        bytes memory inv = _invite(id, expiry);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(relayer);
        treasury.firstLine(id, expiry, inv, c, sig);
    }

    // ------------------------------------------------------------------
    // Money and loans
    // ------------------------------------------------------------------

    function _creatorFees(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(escrow), amount);
        escrow.creditToken(address(treasury), address(usdc), amount);
    }

    function _funded() internal {
        _creatorFees(400 * USDC);
        treasury.sweep();
    }

    function _borrow(address who, uint256 id, uint256 amount, uint64 term) internal returns (uint256) {
        vm.prank(who);
        return pool.borrow(id, amount, term, who, type(uint256).max);
    }

    function _repay(address who, uint256 loanId) internal {
        uint256 id = pool.getLoan(loanId).agentId;
        vm.prank(who);
        pool.repay(loanId, id, type(uint256).max);
    }

    function _default(uint256 loanId) internal {
        vm.warp(pool.getLoan(loanId).defaultableAt + 1);
        pool.markDefault(loanId);
    }

    function _line(uint256 id) internal view returns (uint256) {
        return pool.getAgent(id).delegatedIn;
    }

    function _idle() internal view returns (uint64 idleAfter) {
        (,,,,,,,, idleAfter) = treasury.rules();
    }

    function _qualify(address op, uint256 id) internal {
        for (uint256 i = 0; i < 3; i++) {
            uint256 loan = _borrow(op, id, 5 * USDC, 7 days);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            _repay(op, loan);
        }
    }

    function _rules() internal view returns (TreasurySponsorV4.Rules memory r) {
        (
            r.reserveBps,
            r.firstLine,
            r.secondLine,
            r.epochCap,
            r.epochLength,
            r.minSeasoning,
            r.minQualified,
            r.minScore,
            r.idleAfter
        ) = treasury.rules();
    }
}

contract TreasurySponsorV4Test is TreasuryV4Base {
    // ------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------

    function test_adopt_onceOwnedAndFresh() public {
        TreasurySponsorV4 t = _newTreasury();
        vm.prank(agentOp);
        uint256 other = reg.register("other");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotOurs.selector, other));
        t.adopt(other);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        t.adopt(other);
        // an identity with a record (here: a root already) is refused even when it is ours
        vm.prank(rootOp);
        uint256 root = reg.register("root");
        vm.prank(rootOp);
        pool.enrollRoot(root, 10 * USDC);
        vm.prank(rootOp);
        reg.safeTransferFrom(rootOp, address(t), root);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotOurs.selector, root));
        t.adopt(root);
        // a fresh one, once
        vm.prank(owner);
        uint256 fresh = reg.register("fresh");
        vm.prank(owner);
        reg.safeTransferFrom(owner, address(t), fresh);
        vm.prank(owner);
        t.adopt(fresh);
        assertEq(t.agentId(), fresh);
        vm.prank(owner);
        vm.expectRevert(TreasurySponsorV4.AlreadyAdopted.selector);
        t.adopt(fresh);
    }

    // ------------------------------------------------------------------
    // Sweep
    // ------------------------------------------------------------------

    function test_sweep_splitsCreatorFeesIntoReserveAndStakeShares() public {
        _creatorFees(200 * USDC);
        uint256 reserveBefore = pool.reserve();
        vm.prank(anyone);
        (uint256 toReserve, uint256 toStake) = treasury.sweep();
        assertEq(toReserve, 100 * USDC);
        assertEq(toStake, 100 * USDC);
        assertEq(pool.reserve(), reserveBefore + 100 * USDC);
        CreditPoolV2.Agent memory r = pool.getAgent(TREASURY_ID);
        assertTrue(r.isRoot);
        assertApproxEqAbs(pool.backing(TREASURY_ID), 100 * USDC, 1);
        assertGt(pool.rootShares(TREASURY_ID), 0, "the stake is held as pool shares");
        _creatorFees(50 * USDC);
        treasury.sweep();
        assertApproxEqAbs(pool.backing(TREASURY_ID), 125 * USDC, 2);
        assertEq(treasury.totalStaked(), 125 * USDC);
        assertEq(treasury.totalToReserve(), 125 * USDC);
        assertEq(treasury.pendingStake(), 0);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_sweep_holdsStakeUntilAdopted() public {
        TreasurySponsorV4 fresh = _newTreasury();
        usdc.mint(address(fresh), 40 * USDC);
        (uint256 toReserve, uint256 toStake) = fresh.sweep();
        assertEq(toReserve, 20 * USDC);
        assertEq(toStake, 0);
        assertEq(fresh.pendingStake(), 20 * USDC);
        assertEq(usdc.balanceOf(address(fresh)), 20 * USDC, "the stake half waits for an identity");
    }

    /// A paused pool refuses new stake; the sweep still funds the reserve and keeps the stake share waiting.
    function test_sweep_holdsStakeWhilePoolPaused() public {
        _creatorFees(100 * USDC);
        treasury.sweep();
        vm.prank(timelock);
        pool.pause();
        _creatorFees(40 * USDC);
        (uint256 toReserve, uint256 toStake) = treasury.sweep();
        assertEq(toReserve, 20 * USDC);
        assertEq(toStake, 0);
        assertEq(treasury.pendingStake(), 20 * USDC);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        (toReserve, toStake) = treasury.sweep();
        assertEq(toReserve, 0, "the waiting share is not split again");
        assertEq(toStake, 20 * USDC);
        assertEq(treasury.totalStaked(), 70 * USDC);
    }

    /// The stake share that waits below the minimum stake is not split again on the next sweep (v3 audit).
    function test_sweep_keepsAWaitingStakeShareOutOfTheReserve() public {
        TreasurySponsorV4 t = _newTreasury();
        vm.startPrank(owner);
        uint256 id = reg.register("priors-treasury-2");
        reg.safeTransferFrom(owner, address(t), id);
        t.adopt(id);
        vm.stopPrank();
        usdc.mint(address(t), 10 * USDC);
        uint256 reserve0 = pool.reserve();
        (uint256 toReserve, uint256 toStake) = t.sweep();
        assertEq(toReserve, 5 * USDC);
        assertEq(toStake, 0, "below the minimum: waits");
        for (uint256 i = 0; i < 25; i++) {
            vm.prank(anyone);
            (toReserve, toStake) = t.sweep();
            assertEq(toReserve, 0);
            assertEq(toStake, 0);
        }
        assertEq(pool.reserve(), reserve0 + 5 * USDC, "the reserve got its half once");
        usdc.mint(address(t), 10 * USDC);
        (toReserve, toStake) = t.sweep();
        assertEq(toReserve, 5 * USDC);
        assertEq(toStake, 10 * USDC);
        assertEq(t.pendingStake(), 0);
        assertTrue(pool.getAgent(id).isRoot);
        assertEq(t.totalToReserve(), 10 * USDC);
        assertEq(t.totalStaked(), 10 * USDC);
    }

    /// A unit of dust that would mint no share does not brick the permissionless sweep.
    function test_sweep_dustWaitsInsteadOfReverting() public {
        _funded();
        // raise the share price a little so one unit mints zero shares
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        assertEq(pool.convertToShares(1), 0);
        TreasurySponsorV4.Rules memory r = _rules();
        r.reserveBps = 0;
        vm.prank(owner);
        treasury.setRules(r);
        usdc.mint(address(treasury), 1);
        (uint256 toReserve, uint256 toStake) = treasury.sweep();
        assertEq(toReserve + toStake, 0);
        assertEq(treasury.pendingStake(), 1);
    }

    // ------------------------------------------------------------------
    // First line: invite + consent
    // ------------------------------------------------------------------

    /// One signature for the agent's owner: the inviter signed the invite, the owner signs the pool consent,
    /// anyone submits. The line opens and the agent can borrow at once.
    function test_firstLine_inviteAndConsent_anyoneSubmits() public {
        _funded();
        uint256 room = treasury.epochRoom();
        _firstLine(AGENT, AGENT_PK);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.sponsor, TREASURY_ID);
        assertEq(a.delegatedIn, 5 * USDC);
        assertEq(a.premiumBps, 0, "treasury lines carry no premium");
        assertEq(pool.nonces(AGENT), 1, "the consent was used");
        assertTrue(treasury.firstLined(AGENT));
        assertEq(treasury.lineAt(AGENT), vm.getBlockTimestamp());
        assertEq(treasury.epochRoom(), room - 5 * USDC);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        assertEq(pool.getLoan(loan).sponsorId, TREASURY_ID);
        // a line open now cannot be opened again, whatever the signatures
        bytes memory inv = _invite(AGENT, FAR - 1);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.AlreadyLined.selector, AGENT));
        treasury.firstLine(AGENT, FAR - 1, inv, c, sig);
    }

    /// Registration is permissionless; treasury money is not. Without an invite from a named inviter there is
    /// no line, whoever signs the consent.
    function test_firstLine_needsAnInvite() public {
        _funded();
        uint256 room = treasury.epochRoom();
        uint256 strangerPk = 0xBAD;
        bytes memory inv = _inviteBy(strangerPk, AGENT, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotInvited.selector, AGENT, vm.addr(strangerPk)));
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), room, "nothing spent");
        assertEq(pool.getAgent(AGENT).sponsor, 0);
    }

    /// The cheapest attack on the cap is lining identities that already exist. An invite alone does not do it:
    /// the identity's owner has to sign the consent, and a stranger's signature or a consent for another
    /// sponsor is refused by the pool. Nothing is spent.
    function test_firstLine_strangersCannotBurnTheCapOnOtherPeoplesIdentities() public {
        _funded();
        uint256 room = treasury.epochRoom();
        bytes memory inv = _invite(AGENT, FAR);
        // signed by a stranger claiming to own it
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, 0xBAD);
        vm.prank(anyone);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        // the owner's real signature, but naming another sponsor
        vm.prank(rootOp);
        uint256 root = reg.register("root");
        (c, sig) = _consentFor(AGENT, root, AGENT_PK);
        vm.prank(anyone);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        // a consent for another agent does not carry over either
        (c, sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(anyone);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), room, "nothing spent");
        assertFalse(treasury.inviteUsed(treasury.inviteDigest(AGENT, FAR)), "the invite is still good");
        // and the real pair works
        _firstLine(AGENT, AGENT_PK);
        assertEq(_line(AGENT), 5 * USDC);
    }

    /// A consent does not survive the NFT changing hands, and a delegate cannot consent for the owner.
    function test_firstLine_consentFollowsTheOwnerNotTheDelegate() public {
        _funded();
        bytes memory inv = _invite(AGENT, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        reg.transferFrom(agentOp, agentOp2, AGENT);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        // the new owner's delegate signs: refused, consent is the owner's alone
        uint256 hotPk = 0x407;
        vm.prank(agentOp2);
        pool.setDelegate(AGENT, vm.addr(hotPk));
        (c, sig) = _consent(AGENT, hotPk);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        (c, sig) = _consent(AGENT, AGENT2_PK);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(_line(AGENT), 5 * USDC);
    }

    /// An invite names one identity and one deadline; it seats an agent once.
    function test_invite_isBoundToTheIdentityAndTheDeadline() public {
        _funded();
        bytes memory forAgent = _invite(AGENT, FAR);
        (CreditPoolV2.Consent memory c2, bytes memory sig2) = _consent(AGENT2, AGENT2_PK);
        vm.expectRevert(); // recovers to a different, un-named signer
        treasury.firstLine(AGENT2, FAR, forAgent, c2, sig2);
        uint64 soon = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory brief = _invite(AGENT, soon);
        vm.warp(soon + 1);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.InviteExpired.selector, AGENT, soon));
        treasury.firstLine(AGENT, soon, brief, c, sig);
        treasury.firstLine(AGENT, FAR, forAgent, c, sig);
        assertTrue(treasury.inviteUsed(treasury.inviteDigest(AGENT, FAR)));
    }

    function test_owner_revokesAnInviter() public {
        _funded();
        bytes memory inv = _invite(AGENT, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(owner);
        treasury.setInviter(inviter, false);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotInvited.selector, AGENT, inviter));
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        treasury.setInviter(anyone, true);
    }

    /// An agent backed elsewhere with no loan open moves to the treasury (the pool's handoff); with a loan open
    /// it cannot, and nothing is spent.
    function test_firstLine_handsOffFromAnotherSponsorOnlyWithNoLoanOpen() public {
        _funded();
        vm.prank(rootOp);
        uint256 root = reg.register("root");
        vm.prank(rootOp);
        pool.enrollRoot(root, 100 * USDC);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, root, AGENT_PK);
        vm.prank(rootOp);
        pool.vouchWithConsent(root, AGENT, 20 * USDC, 0, c, sig);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        uint256 room = treasury.epochRoom();
        bytes memory inv = _invite(AGENT, FAR);
        (c, sig) = _consent(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanOpen.selector, AGENT));
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), room);
        _repay(agentOp, loan);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(pool.getAgent(AGENT).sponsor, TREASURY_ID);
        assertEq(_line(AGENT), 5 * USDC);
        assertEq(pool.getAgent(root).delegatedOut, 0, "the old sponsor got its line back");
    }

    /// An owner a default marked cannot borrow, so the treasury does not spend a line on it; a defaulted agent
    /// is refused by the pool.
    function test_firstLine_refusesMarkedOwnersAndDefaultedAgents() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        _default(loan);
        vm.prank(agentOp);
        uint256 fresh = reg.register("fresh");
        bytes memory inv = _invite(fresh, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(fresh, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.OwnerDefaulted.selector, agentOp));
        treasury.firstLine(fresh, FAR, inv, c, sig);
        inv = _invite(AGENT, FAR - 1);
        vm.prank(agentOp);
        reg.transferFrom(agentOp, agentOp2, AGENT);
        (c, sig) = _consent(AGENT, AGENT2_PK);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AgentDefaulted.selector, AGENT));
        treasury.firstLine(AGENT, FAR - 1, inv, c, sig);
    }

    function test_epochCap_boundsWhatASybilCanDrain() public {
        _creatorFees(2_000 * USDC);
        treasury.sweep();
        uint256 n = 100 * USDC / (5 * USDC);
        uint256 pk = 0x5000;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(vm.addr(pk + i));
            uint256 id = reg.register("sybil");
            _firstLine(id, pk + i);
        }
        vm.prank(vm.addr(pk + n));
        uint256 extra = reg.register("sybil");
        bytes memory inv = _invite(extra, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(extra, pk + n);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.EpochCapReached.selector, 5 * USDC, 0));
        treasury.firstLine(extra, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(treasury.epochRoom(), 100 * USDC);
        (c, sig) = _consent(extra, pk + n);
        treasury.firstLine(extra, FAR, inv, c, sig);
    }

    /// Lines stand on the treasury's free backing: past it, the pool refuses and nothing is spent.
    function test_firstLine_boundedByTheTreasurysStake() public {
        _creatorFees(20 * USDC);
        treasury.sweep(); // 10 staked
        _firstLine(AGENT, AGENT_PK);
        _firstLine(AGENT2, AGENT2_PK);
        vm.prank(anyone);
        uint256 third = reg.register("third");
        uint256 room = treasury.epochRoom();
        bytes memory inv = _invite(third, FAR);
        uint256 thirdPk = 0x333;
        vm.prank(anyone);
        reg.transferFrom(anyone, vm.addr(thirdPk), third);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(third, thirdPk);
        vm.expectRevert();
        treasury.firstLine(third, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), room);
    }

    // ------------------------------------------------------------------
    // Reclaim: the pool's own timestamps, no watermark
    // ------------------------------------------------------------------

    function test_reclaim_anIdleLineGoesBackToTheTreasury() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 freeBefore = pool.freeBacking(TREASURY_ID);
        uint256 at = vm.getBlockTimestamp() + _idle();
        assertEq(treasury.reclaimableAt(AGENT), at);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotIdle.selector, AGENT, at));
        treasury.reclaim(AGENT);
        vm.warp(at);
        vm.prank(anyone);
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.delegatedIn, 0, "the vouch is gone");
        assertEq(a.sponsor, 0, "the sponsorship ended");
        assertTrue(a.enrolledAt != 0, "the record stays");
        assertEq(pool.freeBacking(TREASURY_ID), freeBefore + 5 * USDC, "capacity is back");
        assertEq(treasury.reclaimableAt(AGENT), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NothingToReclaim.selector, AGENT));
        treasury.reclaim(AGENT);
        // the spent invite does not reopen the seat
        bytes memory old = _invite(AGENT, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.InviteUsed.selector, AGENT));
        treasury.firstLine(AGENT, FAR, old, c, sig);
    }

    /// Borrowing or repaying is activity (read from the pool); an open loan is never idle.
    function test_reclaim_sparesAnAgentThatUsesItsLine() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 lined = vm.getBlockTimestamp();
        vm.warp(lined + 20 days);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        // 31 days after the borrow the idle clock has run out, but the loan is still open (late, not yet marked)
        vm.warp(lined + 51 days);
        assertEq(treasury.reclaimableAt(AGENT), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.LoanOpen.selector, AGENT));
        treasury.reclaim(AGENT);
        _repay(agentOp, loan);
        uint256 at = lined + 51 days + _idle();
        assertEq(treasury.reclaimableAt(AGENT), at, "the clock runs from the repayment");
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotIdle.selector, AGENT, at));
        treasury.reclaim(AGENT);
        vm.warp(at);
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
    }

    /// The borrow clock alone also counts: a loan borrowed and still inside its term keeps the line.
    function test_reclaim_lastBorrowCountsEvenBeforeARepayment() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        vm.warp(vm.getBlockTimestamp() + 25 days);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        _repay(agentOp, loan); // repaid early, 35 days after the line opened
        assertEq(treasury.reclaimableAt(AGENT), vm.getBlockTimestamp() + _idle());
    }

    function test_reclaim_hasNothingToTakeFromADefault() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        _default(loan);
        vm.warp(vm.getBlockTimestamp() + 60 days);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NothingToReclaim.selector, AGENT));
        treasury.reclaim(AGENT);
    }

    /// Reopening a reclaimed seat is a person's fresh decision: a new invite (and a new consent) works, the
    /// old invite does not, and the reopened line is the first line with a new idle clock.
    function test_firstLine_reopensAReclaimedSeatOnlyWithAFreshInvite() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        vm.warp(vm.getBlockTimestamp() + _idle());
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
        uint64 later = uint64(vm.getBlockTimestamp() + 3 days);
        uint256 room = treasury.epochRoom();
        _firstLineWith(AGENT, AGENT_PK, later);
        assertEq(_line(AGENT), 5 * USDC);
        assertEq(treasury.epochRoom(), room - 5 * USDC);
        assertEq(treasury.reclaimableAt(AGENT), vm.getBlockTimestamp() + _idle());
    }

    // ------------------------------------------------------------------
    // Raise: a top-up vouch out of the treasury's own stake
    // ------------------------------------------------------------------

    function test_raise_onlyAfterACleanSeasonedRecord() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        _qualify(agentOp, AGENT);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.qualifiedRepaid, 3);
        assertGe(treasury.score(AGENT), 100);
        assertEq(treasury.score(AGENT), lens.score(AGENT), "same formula as the lens");
        assertTrue(treasury.eligibleForRaise(AGENT), "three qualified loans over 21 days, clean");
    }

    function test_raise_needsSeasoningAndQualifiedLoans() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        TreasurySponsorV4.Rules memory r = _rules();
        r.minSeasoning = 30 days;
        vm.prank(owner);
        treasury.setRules(r);
        _qualify(agentOp, AGENT);
        assertFalse(treasury.eligibleForRaise(AGENT), "21 days is not 30");
        vm.warp(vm.getBlockTimestamp() + 9 days);
        assertTrue(treasury.eligibleForRaise(AGENT));
        r.minQualified = 4;
        vm.prank(owner);
        treasury.setRules(r);
        assertFalse(treasury.eligibleForRaise(AGENT));
        r.minQualified = 3;
        r.minScore = 1001;
        vm.prank(owner);
        treasury.setRules(r);
        assertFalse(treasury.eligibleForRaise(AGENT));
    }

    function test_raise_topsUpToTheSecondTierAndChargesTheEpoch() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(treasury.eligibleForRaise(AGENT));
        uint256 room = treasury.epochRoom();
        uint256 free = pool.freeBacking(TREASURY_ID);
        vm.prank(anyone);
        treasury.raise(AGENT);
        assertEq(_line(AGENT), 50 * USDC);
        assertEq(treasury.epochRoom(), room - 45 * USDC, "only the top-up is charged");
        assertEq(pool.freeBacking(TREASURY_ID), free - 45 * USDC, "out of the treasury's own stake");
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        // the raised line is usable at once
        _borrow(agentOp, AGENT, 50 * USDC, 7 days);
    }

    function test_raise_boundedByTheEpochCap() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        TreasurySponsorV4.Rules memory r = _rules();
        r.epochCap = 30 * USDC;
        vm.prank(owner);
        treasury.setRules(r);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.EpochCapReached.selector, 45 * USDC, 30 * USDC));
        treasury.raise(AGENT);
    }

    /// A reclaimed seat is closed: raise() does not reopen it, so reclaim/raise cannot be alternated to spend
    /// the epoch's budget on a line nobody holds (v3 audit).
    function test_raise_doesNotReopenAReclaimedSeat() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        vm.warp(vm.getBlockTimestamp() + _idle());
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
        uint256 room = treasury.epochRoom();
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        assertEq(treasury.epochRoom(), room, "nothing spent");
    }

    /// A raise is activity: the bigger line gets its own idleAfter before anyone can take it back.
    function test_raise_refreshesTheIdleClock() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        vm.warp(vm.getBlockTimestamp() + _idle() - 1 days);
        treasury.raise(AGENT);
        uint256 at = vm.getBlockTimestamp() + _idle();
        assertEq(treasury.reclaimableAt(AGENT), at);
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotIdle.selector, AGENT, at));
        treasury.reclaim(AGENT);
        vm.warp(at);
        assertEq(treasury.reclaim(AGENT), 50 * USDC);
    }

    /// A frozen line is on its way back; it is never raised.
    function test_raise_refusesAFrozenLine() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        vm.prank(owner);
        treasury.freeze(AGENT, true);
        assertFalse(treasury.eligibleForRaise(AGENT));
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
    }

    /// An agent whose owner a default marked (with another identity) is not raised.
    function test_raise_refusesAMarkedOwner() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        vm.prank(agentOp);
        uint256 other = reg.register("other");
        _firstLine(other, AGENT_PK);
        uint256 bad = _borrow(agentOp, other, 5 * USDC, 1 days);
        _default(bad);
        assertFalse(treasury.eligibleForRaise(AGENT));
    }

    function test_raise_seededAgentsAreNeverRaisedByRule() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        _qualify(agentOp, AGENT);
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT;
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        treasury.setSeeded(ids, true);
        vm.prank(owner);
        treasury.setSeeded(ids, true);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsorV4.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        vm.prank(owner);
        treasury.setSeeded(ids, false);
        treasury.raise(AGENT);
        assertEq(_line(AGENT), 50 * USDC);
    }

    // ------------------------------------------------------------------
    // Defaults, fees
    // ------------------------------------------------------------------

    /// A default burns the treasury's own shares worth the principal and the unpaid fee (fee lock, 2026-09-24).
    /// Lenders do not move by a unit.
    function test_default_slashesTheTreasuryLendersUntouched() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        uint256 backing0 = pool.backing(TREASURY_ID) - 5 * USDC - pool.getLoan(loan).fee;
        uint256 lenderValue = pool.convertToAssets(pool.shares(lender));
        _default(loan);
        backing0 += pool.getLoan(loan).fee * pool.rootShares(TREASURY_ID) / pool.totalShares(); // its cut of the fee
        assertApproxEqAbs(pool.backing(TREASURY_ID), backing0, 1, "the treasury pays");
        assertGe(pool.convertToAssets(pool.shares(lender)), lenderValue, "lenders whole");
        assertEq(pool.totalBadDebt(), 0);
        assertEq(pool.getAgent(TREASURY_ID).childrenDefaulted, 1);
        assertEq(pool.getAgent(TREASURY_ID).delegatedOut, 0, "the leftover came back");
    }

    function test_collect_sendsSponsorFeesToTheBuybackWallet() public {
        _funded();
        assertEq(treasury.collect(), 0, "nothing yet: no revert");
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        uint256 owed = pool.sponsorFees(TREASURY_ID);
        assertEq(owed, pool.getLoan(loan).sponsorCut);
        assertEq(pool.feesFrom(TREASURY_ID, AGENT), owed);
        vm.prank(anyone);
        assertEq(treasury.collect(), owed);
        assertEq(usdc.balanceOf(sink), owed);
        assertEq(treasury.totalCollected(), owed);
    }

    /// The treasury's stake earns the pool's lender yield; the owner takes free stake back as cash.
    function test_retire_unlocksFreeStakeWithItsYield() public {
        _creatorFees(200 * USDC);
        treasury.sweep(); // 100 staked
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        assertGt(pool.backing(TREASURY_ID), 100 * USDC, "lender yield on the stake");
        uint256 all = pool.rootShares(TREASURY_ID);
        vm.prank(owner);
        vm.expectRevert(); // 5 is still vouched
        treasury.retire(all, owner);
        uint256 free = pool.convertToShares(pool.freeBacking(TREASURY_ID));
        vm.prank(owner);
        uint256 out = treasury.retire(free, owner);
        assertGt(out, 95 * USDC);
        assertEq(usdc.balanceOf(owner), out);
        assertGe(pool.backing(TREASURY_ID), 5 * USDC);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        treasury.retire(1, anyone);
    }

    /// The treasury holds its root NFT, so only it can move the root's money or lines; nobody else, including
    /// the treasury's owner, can go around the rules at the pool.
    function test_rootIsOnlyReachableThroughTheTreasury() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, TREASURY_ID, owner));
        pool.unlock(TREASURY_ID, 1, owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, TREASURY_ID, owner));
        pool.vouch(TREASURY_ID, AGENT, 1 * USDC);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, TREASURY_ID, owner));
        pool.unvouch(TREASURY_ID, AGENT, 1 * USDC);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, TREASURY_ID, owner));
        pool.freeze(AGENT, true);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, TREASURY_ID, owner));
        pool.claimSponsorFees(TREASURY_ID, owner);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    /// Wind-down: freeze stops new borrows; loans out run to term and the line comes back as they close.
    function test_freeze_windsDownALineWithALoanOut() public {
        _funded();
        _firstLine(AGENT, AGENT_PK);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        treasury.freeze(AGENT, true);
        vm.prank(owner);
        treasury.freeze(AGENT, true);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.IsFrozen.selector, AGENT));
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOp, type(uint256).max);
        _repay(agentOp, loan);
        assertEq(pool.getAgent(AGENT).sponsor, 0);
        assertEq(pool.getAgent(TREASURY_ID).delegatedOut, 0);
        // a frozen seat is reopened only by a fresh invite
        _firstLineWith(AGENT, AGENT_PK, FAR - 7);
        assertEq(_line(AGENT), 5 * USDC);
    }

    function test_ownerControls_rulesSinkRecipientRescue() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        treasury.setFeeSink(anyone);
        vm.startPrank(owner);
        vm.expectRevert(TreasurySponsorV4.InvalidAddress.selector);
        treasury.setFeeSink(address(0));
        treasury.setFeeSink(anyone);
        assertEq(treasury.feeSink(), anyone);
        TreasurySponsorV4.Rules memory r = TreasurySponsorV4.Rules({
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
        assertEq(_rules().reserveBps, 3000);
        r.secondLine = 1 * USDC;
        vm.expectRevert(TreasurySponsorV4.InvalidRules.selector);
        treasury.setRules(r);
        r.secondLine = 80 * USDC;
        r.idleAfter = 0;
        vm.expectRevert(TreasurySponsorV4.InvalidRules.selector);
        treasury.setRules(r);
        r.idleAfter = 10 days;
        r.epochLength = 366 days;
        vm.expectRevert(TreasurySponsorV4.InvalidRules.selector);
        treasury.setRules(r);
        r.epochLength = 1 days;
        r.reserveBps = 10_001;
        vm.expectRevert(TreasurySponsorV4.InvalidRules.selector);
        treasury.setRules(r);
        treasury.transferCreatorFeeRecipient(launchToken, owner);
        assertEq(escrow.feeRecipientOf(launchToken), owner);
        vm.expectRevert(TreasurySponsorV4.UseSweep.selector);
        treasury.rescue(address(usdc), owner);
        vm.stopPrank();
        // another token credited by the escrow, and ETH
        MockUSDC other = new MockUSDC();
        other.mint(address(this), 7);
        other.approve(address(escrow), 7);
        escrow.creditToken(address(treasury), address(other), 7);
        vm.deal(address(this), 1 ether);
        escrow.credit{value: 1 ether}(address(treasury));
        vm.startPrank(owner);
        treasury.rescue(address(other), owner);
        treasury.rescue(address(0), owner);
        vm.stopPrank();
        assertEq(other.balanceOf(owner), 7);
        assertEq(owner.balance, 1 ether);
    }
}

/// v1 → v4: an agent with a v1 record may be invited (v3 refused any identity the pool knew), keeps its record,
/// and is raised by rule unless the owner flagged its v1 volume as protocol-seeded.
contract TreasurySponsorV4MigrationTest is TreasuryV4Base {
    CreditPool v1;
    address v1Owner = makeAddr("v1owner");

    function setUp() public override {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        escrow = new MockPonsFeeEscrow();
        v1 = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), v1Owner);
        _deployPool(v1);
        _setUpTreasury();
        // v1 history: AGENT repays three week-long loans under a v1 root
        usdc.mint(lender, 1_000 * USDC);
        vm.startPrank(lender);
        usdc.approve(address(v1), type(uint256).max);
        v1.deposit(1_000 * USDC, lender);
        vm.stopPrank();
        vm.startPrank(rootOp);
        uint256 v1root = reg.register("v1root");
        usdc.approve(address(v1), type(uint256).max);
        v1.enrollRoot(v1root, 100 * USDC);
        v1.vouch(v1root, AGENT, 10 * USDC);
        vm.stopPrank();
        vm.prank(agentOp);
        usdc.approve(address(v1), type(uint256).max);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agentOp);
            uint256 l = v1.borrow(AGENT, 5 * USDC, 7 days, agentOp);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            vm.prank(agentOp);
            v1.repay(l);
        }
    }

    function test_importedAgent_canBeInvitedAndRaisedByItsRecord() public {
        pool.importFromV1(AGENT);
        assertTrue(pool.getAgent(AGENT).enrolledAt != 0, "known to v2");
        _funded();
        _firstLine(AGENT, AGENT_PK);
        assertEq(_line(AGENT), 5 * USDC);
        assertTrue(treasury.eligibleForRaise(AGENT), "the v1 record counts");
        treasury.raise(AGENT);
        assertEq(_line(AGENT), 50 * USDC);
    }

    function test_importedAgent_seededIsInvitedButNotRaised() public {
        pool.importFromV1(AGENT);
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT;
        vm.prank(owner);
        treasury.setSeeded(ids, true);
        _funded();
        _firstLine(AGENT, AGENT_PK);
        assertEq(_line(AGENT), 5 * USDC);
        assertFalse(treasury.eligibleForRaise(AGENT));
    }

    /// A v1 loan open blocks a v2 line; nothing is spent.
    function test_v1LoanOpen_blocksTheFirstLine() public {
        _funded();
        vm.prank(agentOp);
        v1.borrow(AGENT, 5 * USDC, 7 days, agentOp);
        uint256 room = treasury.epochRoom();
        bytes memory inv = _invite(AGENT, FAR);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.V1Busy.selector, AGENT));
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        assertEq(treasury.epochRoom(), room);
    }
}
