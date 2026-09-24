// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2, IBackerHook} from "../src/CreditPoolV2.sol";
import {CreditLensV2} from "../src/CreditLensV2.sol";
import {PoolV2Lib} from "../src/libraries/PoolV2Lib.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// @dev A backer hook that records every call and can be told to refuse, revert, burn gas or re-enter.
contract RecordingHook is IBackerHook {
    CreditPoolV2 public pool;
    bool public allow = true;
    bool public revertAll;
    bool public reenter;
    bool public bomb;
    uint256 public borrows;
    uint256 public defaults;
    uint256 public releases;
    uint256 public lastRoot;
    uint256 public lastAgent;
    uint256 public lastAmount;
    uint8 public lastReason;
    bool public lastLastLoan;
    address public lastTo;

    function set(CreditPoolV2 p) external {
        pool = p;
    }

    function setAllow(bool a) external {
        allow = a;
    }

    function setRevert(bool r) external {
        revertAll = r;
    }

    function setReenter(bool r) external {
        reenter = r;
    }

    function setBomb(bool b) external {
        bomb = b;
    }

    function canBorrow(uint256, uint256, uint256, uint64, uint256, address, address, address to)
        external
        view
        returns (bool)
    {
        if (revertAll) revert("no");
        if (bomb) {
            assembly {
                return(0, 100000)
            }
        }
        to;
        return allow;
    }

    function onBorrow(uint256 rootId, uint256 agentId, uint256) external {
        if (revertAll) revert("no");
        borrows++;
        lastRoot = rootId;
        lastAgent = agentId;
    }

    function onDefault(uint256 rootId, uint256 agentId, uint256, uint256 principal, bool lastLoan) external {
        if (revertAll) revert("no");
        if (reenter) pool.unvouch(rootId, agentId, 1); // must fail: the pool holds its lock
        defaults++;
        lastRoot = rootId;
        lastAgent = agentId;
        lastAmount = principal;
        lastLastLoan = lastLoan;
    }

    function onRelease(uint256 rootId, uint256 agentId, uint256 amount, uint8 reason) external {
        if (revertAll) revert("no");
        releases++;
        lastRoot = rootId;
        lastAgent = agentId;
        lastAmount = amount;
        lastReason = reason;
    }
}

/// @dev An EIP-1271 wallet that owns an agent and approves exactly one digest.
contract Wallet1271 {
    bytes32 public approved;

    function approve(bytes32 d) external {
        approved = d;
    }

    function isValidSignature(bytes32 d, bytes calldata) external view returns (bytes4) {
        return d == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract CreditPoolV2Base is Test {
    uint256 constant USDC = 1e6;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPoolV2 pool;
    CreditLensV2 lens;

    address owner = makeAddr("timelock");
    address guardian = makeAddr("guardian");
    address lender = makeAddr("lender");
    address keeper = makeAddr("keeper");
    address anyone = makeAddr("anyone");

    uint256 constant ROOT_PK = 0xB0B;
    uint256 constant ROOT2_PK = 0xB0C;
    uint256 constant AGENT_PK = 0xA1;
    uint256 constant AGENT2_PK = 0xA2;
    address rootOwner = vm.addr(ROOT_PK);
    address root2Owner = vm.addr(ROOT2_PK);
    address agentOwner = vm.addr(AGENT_PK);
    address agent2Owner = vm.addr(AGENT2_PK);

    uint256 ROOT;
    uint256 ROOT2;
    uint256 AGENT;
    uint256 AGENT2;

    function _params() internal pure returns (CreditPoolV2.Params memory) {
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

    function _deploy(CreditPool v1_) internal {
        pool = new CreditPoolV2(IERC20(address(usdc)), IERC8004Identity(address(reg)), v1_, owner, guardian, _params());
        lens = new CreditLensV2(pool);
        usdc.mint(address(this), 1 * USDC);
        usdc.approve(address(pool), 1 * USDC);
        pool.seed();
    }

    function setUp() public virtual {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        _deploy(CreditPool(address(0)));

        address[6] memory who = [lender, rootOwner, root2Owner, agentOwner, agent2Owner, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 100_000 * USDC);
            vm.prank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
        vm.prank(lender);
        pool.deposit(1_000 * USDC, lender, 0);

        vm.prank(rootOwner);
        ROOT = reg.register("root");
        vm.prank(root2Owner);
        ROOT2 = reg.register("root2");
        vm.prank(agentOwner);
        AGENT = reg.register("agent");
        vm.prank(agent2Owner);
        AGENT2 = reg.register("agent2");

        vm.prank(rootOwner);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(root2Owner);
        pool.enrollRoot(ROOT2, 100 * USDC);
    }

    function _consent(uint256 agentId, uint256 sponsorId, uint256 pk, uint256 maxPrem)
        internal
        view
        returns (CreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = CreditPoolV2.Consent({
            agentId: agentId,
            sponsorId: sponsorId,
            owner: vm.addr(pk),
            maxPremiumBps: maxPrem,
            nonce: pool.nonces(agentId),
            deadline: block.timestamp + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    function _sponsor(uint256 rootId, address rOwner, uint256 agentId, uint256 agentPk, uint256 amount) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(agentId, rootId, agentPk, 0);
        vm.prank(rOwner);
        pool.vouchWithConsent(rootId, agentId, amount, 0, c, sig);
    }

    function _borrow(address who, uint256 agentId, uint256 amount, uint64 term) internal returns (uint256) {
        vm.prank(who);
        return pool.borrow(agentId, amount, term, who, type(uint256).max);
    }

    function _repay(address who, uint256 loanId) internal {
        CreditPoolV2.Loan memory l = pool.getLoan(loanId);
        vm.prank(who);
        pool.repay(loanId, l.agentId, type(uint256).max);
    }

    function _default(uint256 loanId) internal {
        vm.warp(pool.getLoan(loanId).defaultableAt + 1);
        vm.prank(keeper);
        pool.markDefault(loanId);
    }

    function _price() internal view returns (uint256) {
        return pool.totalAssets() * 1e18 / pool.totalShares();
    }

    /// Since the 2026-09-24 fee lock (final audit N-1) a borrow holds its fee out of the backer's free backing, so a
    /// backer that vouches its whole stake stakes that loan's fee on top.
    function _stakeFee(address rOwner, uint256 rootId, uint256 agentId, uint256 principal, uint64 term)
        internal
        returns (uint256 fee)
    {
        (fee,,,) = pool.quoteFee(agentId, principal, term);
        vm.prank(rOwner);
        pool.addStake(rootId, fee);
    }
}

contract CreditPoolV2Test is CreditPoolV2Base {
    // ------------------------------------------------------------------
    // Lenders
    // ------------------------------------------------------------------

    function test_seed_onceAndRequired() public {
        vm.expectRevert(CreditPoolV2.AlreadySeeded.selector);
        pool.seed();
        CreditPoolV2 p = new CreditPoolV2(
            IERC20(address(usdc)), IERC8004Identity(address(reg)), CreditPool(address(0)), owner, guardian, _params()
        );
        vm.prank(lender);
        vm.expectRevert(CreditPoolV2.NotSeeded.selector);
        p.deposit(1 * USDC, lender, 0);
        assertEq(pool.shares(pool.DEAD()), 1 * USDC);
    }

    function test_deposit_minShares() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.SlippageShares.selector, 10 * USDC, 10 * USDC + 1));
        pool.deposit(10 * USDC, anyone, 10 * USDC + 1);
    }

    /// The first-depositor trick (one unit of shares, then inflate the price with exit fees) cannot rob a
    /// later depositor: the dead shares already set the price.
    function test_shareInflation_cannotRobTheNextDepositor() public {
        CreditPoolV2 p = new CreditPoolV2(
            IERC20(address(usdc)), IERC8004Identity(address(reg)), CreditPool(address(0)), owner, guardian, _params()
        );
        usdc.mint(address(this), 1 * USDC);
        usdc.approve(address(p), 1 * USDC);
        p.seed();
        address a = makeAddr("attackerA");
        address b = makeAddr("attackerB");
        address victim = makeAddr("victim");
        usdc.mint(a, 1);
        usdc.mint(b, 20_000 * USDC);
        usdc.mint(victim, 199 * USDC);
        vm.startPrank(a);
        usdc.approve(address(p), 1);
        p.deposit(1, a, 0);
        vm.stopPrank();
        vm.startPrank(b);
        usdc.approve(address(p), type(uint256).max);
        uint256 sb = p.deposit(20_000 * USDC, b, 0);
        p.withdraw(sb, b); // leaves a 0.5% exit fee behind for everyone
        vm.stopPrank();
        vm.startPrank(victim);
        usdc.approve(address(p), type(uint256).max);
        uint256 sv = p.deposit(199 * USDC, victim, 0);
        vm.stopPrank();
        // the victim's shares are worth what it put in, give or take one share's rounding (~$0.0001)
        assertApproxEqAbs(p.convertToAssets(sv), 199 * USDC, 200);
        // and attacker A's one unit did not capture the fee (it gained about $0.0001): the dead shares took it
        assertLt(p.convertToAssets(p.shares(a)), 1_000);
    }

    function test_withdraw_earlyExitFeeThenFree() public {
        vm.prank(anyone);
        uint256 s = pool.deposit(100 * USDC, anyone, 0);
        uint256 before = usdc.balanceOf(anyone);
        vm.prank(anyone);
        uint256 out = pool.withdraw(s / 2, anyone);
        assertEq(out, 50 * USDC - 50 * USDC * 50 / 10_000);
        vm.warp(block.timestamp + 7 days);
        uint256 rest = pool.shares(anyone);
        vm.prank(anyone);
        uint256 out2 = pool.withdraw(rest, anyone);
        assertGe(out2, 50 * USDC);
        assertEq(usdc.balanceOf(anyone), before + out + out2);
    }

    // ------------------------------------------------------------------
    // Roots
    // ------------------------------------------------------------------

    function test_enrollRoot_ownerOnlyAndMinStake() public {
        vm.prank(anyone);
        uint256 id = reg.register("x");
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, id, rootOwner));
        pool.enrollRoot(id, 10 * USDC);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BelowMinStake.selector, 9 * USDC, 10 * USDC));
        pool.enrollRoot(id, 9 * USDC);
        vm.prank(anyone);
        pool.enrollRoot(id, 10 * USDC);
        assertTrue(pool.getAgent(id).isRoot);
        assertApproxEqAbs(pool.backing(id), 10 * USDC, 1);
    }

    function test_backing_earnsLenderYield() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 50 * USDC, 30 days);
        uint256 b0 = pool.backing(ROOT);
        _repay(agentOwner, l);
        assertGt(pool.backing(ROOT), b0, "the backer's stake earned the lender share too");
    }

    function test_unlock_onlyFreeBackingAndOwnerOnly() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 60 * USDC);
        uint256 all = pool.rootShares(ROOT);
        vm.prank(rootOwner);
        vm.expectRevert();
        pool.unlock(ROOT, all, rootOwner);
        // a pool delegate of the root cannot move its money
        address hot = makeAddr("hot");
        vm.prank(rootOwner);
        pool.setDelegate(ROOT, hot);
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, ROOT, hot));
        pool.unlock(ROOT, 1, hot);
        uint256 sh = pool.convertToShares(39 * USDC);
        vm.prank(rootOwner);
        pool.unlock(ROOT, sh, rootOwner);
        assertGe(pool.backing(ROOT), 60 * USDC);
    }

    function test_retireRoot_onlyWhenEmpty() public {
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.StillBacking.selector, ROOT));
        pool.retireRoot(ROOT);
        uint256 sh = pool.rootShares(ROOT);
        vm.prank(rootOwner);
        pool.unlock(ROOT, sh, rootOwner);
        vm.prank(rootOwner);
        pool.retireRoot(ROOT);
        assertFalse(pool.getAgent(ROOT).isRoot);
    }

    // ------------------------------------------------------------------
    // Consent
    // ------------------------------------------------------------------

    function test_consent_opensALine() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 5 * USDC);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.sponsor, ROOT);
        assertEq(a.delegatedIn, 5 * USDC);
        assertEq(pool.getAgent(ROOT).delegatedOut, 5 * USDC);
        assertEq(pool.nonces(AGENT), 1);
        assertEq(lens.available(AGENT), 5 * USDC);
    }

    /// The squat is gone: nobody can put a line behind an agent without its owner's signature.
    function test_consent_noSquat() public {
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.WrongSponsor.selector, AGENT, 0));
        pool.vouch(ROOT, AGENT, 1);
        // a consent for another sponsor cannot be used
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT2, AGENT_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(ROOT, AGENT, 1, 0, c, sig);
    }

    function test_consent_onlyTheSponsorsOwnerCanUseIt() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 0);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, ROOT, anyone));
        pool.vouchWithConsent(ROOT, AGENT, 1, 0, c, sig);
    }

    function test_consent_replayWrongSignerExpired() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 0);
        vm.prank(rootOwner);
        pool.vouchWithConsent(ROOT, AGENT, 1 * USDC, 0, c, sig);
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.BadConsent.selector); // nonce used
        pool.vouchWithConsent(ROOT, AGENT, 1 * USDC, 0, c, sig);
        // signed by somebody else
        (CreditPoolV2.Consent memory c2, bytes memory sig2) = _consent(AGENT2, ROOT, AGENT_PK, 0);
        c2.owner = agent2Owner;
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(ROOT, AGENT2, 1 * USDC, 0, c2, sig2);
        // expired
        (CreditPoolV2.Consent memory c3, bytes memory sig3) = _consent(AGENT2, ROOT, AGENT2_PK, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.ConsentExpired.selector);
        pool.vouchWithConsent(ROOT, AGENT2, 1 * USDC, 0, c3, sig3);
    }

    /// A consent does not survive the NFT changing hands.
    function test_consent_diesWithASale() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 0);
        vm.prank(agentOwner);
        reg.transferFrom(agentOwner, anyone, AGENT);
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(ROOT, AGENT, 1 * USDC, 0, c, sig);
    }

    function test_consent_contractOwnerViaEIP1271() public {
        Wallet1271 w = new Wallet1271();
        vm.prank(agentOwner);
        reg.transferFrom(agentOwner, address(w), AGENT);
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: AGENT,
            sponsorId: ROOT,
            owner: address(w),
            maxPremiumBps: 0,
            nonce: 0,
            deadline: block.timestamp + 1
        });
        w.approve(pool.consentDigest(c));
        vm.prank(rootOwner);
        pool.vouchWithConsent(ROOT, AGENT, 5 * USDC, 0, c, "");
        assertEq(pool.getAgent(AGENT).sponsor, ROOT);
    }

    function test_consent_premiumCapped() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 100);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.PremiumTooHigh.selector, 101, 100));
        pool.vouchWithConsent(ROOT, AGENT, 5 * USDC, 101, c, sig);
        vm.prank(rootOwner);
        pool.vouchWithConsent(ROOT, AGENT, 5 * USDC, 100, c, sig);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.PremiumTooHigh.selector, 150, 100));
        pool.setPremium(AGENT, 150);
        // no consent above the protocol cap
        (CreditPoolV2.Consent memory c2, bytes memory sig2) = _consent(AGENT2, ROOT, AGENT2_PK, 201);
        vm.prank(rootOwner);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(ROOT, AGENT2, 5 * USDC, 0, c2, sig2);
    }

    function test_consent_refusesRootsSelfAndDefaulted() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(ROOT2, ROOT, ROOT2_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.IsRoot.selector, ROOT2));
        pool.vouchWithConsent(ROOT, ROOT2, 1, 0, c, sig);
        (c, sig) = _consent(ROOT, ROOT, ROOT_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InvalidAgent.selector, ROOT));
        pool.vouchWithConsent(ROOT, ROOT, 1, 0, c, sig);
    }

    function test_vouch_boundedByFreeBacking() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 0);
        uint256 free = pool.freeBacking(ROOT);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientBacking.selector, ROOT, free + 1, free));
        pool.vouchWithConsent(ROOT, AGENT, free + 1, 0, c, sig);
    }

    // ------------------------------------------------------------------
    // Handoff, leave, unvouch, freeze
    // ------------------------------------------------------------------

    function test_handoff_movesTheAgentWhenNothingIsDrawn() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 5 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT2, AGENT_PK, 0);
        vm.prank(root2Owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanOpen.selector, AGENT));
        pool.vouchWithConsent(ROOT2, AGENT, 50 * USDC, 0, c, sig);
        _repay(agentOwner, l);
        vm.prank(root2Owner);
        pool.vouchWithConsent(ROOT2, AGENT, 50 * USDC, 0, c, sig);
        assertEq(pool.getAgent(AGENT).sponsor, ROOT2);
        assertEq(pool.getAgent(AGENT).delegatedIn, 50 * USDC);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0, "the old sponsor got its line back");
    }

    function test_leave_onlyWithNoLoanOpen() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 5 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanOpen.selector, AGENT));
        pool.leave(AGENT);
        _repay(agentOwner, l);
        vm.prank(agentOwner);
        pool.leave(AGENT);
        assertEq(pool.getAgent(AGENT).sponsor, 0);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotController.selector, AGENT, anyone));
        pool.leave(AGENT);
    }

    function test_unvouch_onlyUndrawnAndEndsTheSponsorship() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientCapacity.selector, AGENT, 6 * USDC, 5 * USDC));
        pool.unvouch(ROOT, AGENT, 6 * USDC);
        vm.prank(rootOwner);
        pool.unvouch(ROOT, AGENT, 5 * USDC);
        _repay(agentOwner, l);
        vm.prank(rootOwner);
        pool.unvouch(ROOT, AGENT, 5 * USDC);
        assertEq(pool.getAgent(AGENT).sponsor, 0);
    }

    /// The rolling-loan lock is gone: a frozen agent cannot draw again, and the line comes back as loans close.
    function test_freeze_stopsBorrowsAndReleasesTheLine() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, ROOT, anyone));
        pool.freeze(AGENT, true);
        vm.prank(rootOwner);
        pool.freeze(AGENT, true);
        assertEq(pool.getAgent(AGENT).delegatedIn, 5 * USDC, "undrawn half back at once");
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.IsFrozen.selector, AGENT));
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, type(uint256).max);
        _repay(agentOwner, l);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.delegatedIn, 0);
        assertEq(a.sponsor, 0, "sponsorship over");
        assertFalse(a.frozen);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
    }

    // ------------------------------------------------------------------
    // Loans
    // ------------------------------------------------------------------

    function test_borrow_controllerDelegateAndLapse() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotController.selector, AGENT, anyone));
        pool.borrow(AGENT, 5 * USDC, 7 days, anyone, type(uint256).max);
        address hot = makeAddr("hot");
        vm.prank(agentOwner);
        pool.setDelegate(AGENT, hot);
        vm.prank(hot);
        pool.borrow(AGENT, 5 * USDC, 7 days, hot, type(uint256).max);
        vm.prank(agentOwner);
        reg.transferFrom(agentOwner, anyone, AGENT);
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotController.selector, AGENT, hot));
        pool.borrow(AGENT, 5 * USDC, 7 days, hot, type(uint256).max);
    }

    function test_borrow_limits() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        vm.startPrank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientCapacity.selector, AGENT, 11 * USDC, 10 * USDC));
        pool.borrow(AGENT, 11 * USDC, 7 days, agentOwner, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanSizeOutOfRange.selector, 4 * USDC));
        pool.borrow(AGENT, 4 * USDC, 7 days, agentOwner, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.TermOutOfRange.selector, 31 days));
        pool.borrow(AGENT, 5 * USDC, 31 days, agentOwner, type(uint256).max);
        vm.expectRevert();
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, 1);
        vm.stopPrank();
    }

    function test_borrow_utilizationCapKeepsLiquidityForLenders() public {
        CreditPoolV2.Params memory p = _params();
        p.maxUtilizationBps = 500; // 5%
        vm.prank(owner);
        pool.setParams(p);
        vm.prank(rootOwner);
        pool.addStake(ROOT, 1 * USDC); // headroom for the loans' fees, locked out of the backer's free backing
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        _borrow(agentOwner, AGENT, 50 * USDC, 7 days);
        vm.prank(agentOwner);
        vm.expectRevert(CreditPoolV2.UtilizationTooHigh.selector);
        pool.borrow(AGENT, 50 * USDC, 7 days, agentOwner, type(uint256).max);
    }

    /// Everything that closes a loan is fixed at borrow: a later param change touches none of it.
    function test_loan_termsFixedAtBorrow() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 10 * USDC, 30 days);
        CreditPoolV2.Loan memory before = pool.getLoan(l);
        CreditPoolV2.Params memory p = _params();
        p.feeBps = 500;
        p.grace = 1 days;
        p.sponsorFeeBps = 0;
        p.minScoreTerm = 30 days;
        vm.prank(owner);
        pool.setParams(p);
        CreditPoolV2.Loan memory now_ = pool.getLoan(l);
        assertEq(now_.fee, before.fee);
        assertEq(now_.defaultableAt, before.dueAt + 3 days);
        assertEq(now_.sponsorCut, before.sponsorCut);
        vm.warp(before.dueAt + 2 days); // inside the grace the loan was given
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanNotDue.selector, l, before.defaultableAt));
        pool.markDefault(l);
        _repay(agentOwner, l);
        assertEq(pool.feesFrom(ROOT, AGENT), before.sponsorCut);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 1, "qualified under the term in force at borrow");
    }

    function test_repay_splitsExactly() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, AGENT_PK, 200);
        vm.startPrank(rootOwner);
        pool.addStake(ROOT, 3 * USDC); // headroom for the fee, locked out of the backer's free backing
        pool.vouchWithConsent(ROOT, AGENT, 100 * USDC, 200, c, sig);
        vm.stopPrank();
        uint256 l = _borrow(agentOwner, AGENT, 100 * USDC, 30 days);
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        assertEq(ln.premium, 2 * USDC);
        assertEq(ln.fee, 3 * USDC);
        uint256 liq = pool.poolLiquidity();
        uint256 res = pool.reserve();
        _repay(agentOwner, l);
        uint256 base = 1 * USDC;
        assertEq(pool.sponsorFees(ROOT), base * 2500 / 10_000 + 2 * USDC);
        assertEq(pool.feesFrom(ROOT, AGENT), base * 2500 / 10_000 + 2 * USDC);
        assertEq(pool.reserve(), res + base * 1500 / 10_000);
        assertEq(pool.poolLiquidity(), liq + 100 * USDC + base * 6000 / 10_000);
        vm.prank(rootOwner);
        pool.claimSponsorFees(ROOT, rootOwner);
        assertEq(pool.unclaimedSponsorFees(), 0);
    }

    function test_repay_guards() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 10 * USDC, 7 days);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.WrongLoan.selector, l));
        pool.repay(l, AGENT2, type(uint256).max);
        vm.prank(anyone);
        vm.expectRevert();
        pool.repay(l, AGENT, 10 * USDC);
        vm.prank(anyone);
        pool.repay(l, AGENT, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Default
    // ------------------------------------------------------------------

    /// The whole promise of v2: a default is paid by its backer's shares, and lenders do not move by a unit.
    function test_default_backerPaysLendersUntouched() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        vm.prank(anyone);
        pool.fundReserve(10 * USDC);
        uint256 lenderValue = pool.convertToAssets(pool.shares(lender));
        uint256 price0 = _price();
        uint256 backing0 = pool.backing(ROOT);
        uint256 l = _borrow(agentOwner, AGENT, 50 * USDC, 7 days);
        backing0 -= 50 * USDC + pool.getLoan(l).fee; // the burn: principal + unpaid fee (N-1 fee lock)
        _default(l);
        assertGe(_price(), price0, "share price never falls");
        assertGe(pool.convertToAssets(pool.shares(lender)), lenderValue);
        assertEq(pool.totalBadDebt(), 0);
        // the burnt fee accrues to the remaining shares, the backer's own included (its pro-rata cut)
        backing0 += pool.getLoan(l).fee * pool.rootShares(ROOT) / pool.totalShares();
        assertApproxEqAbs(pool.backing(ROOT), backing0, 2);
        assertEq(pool.feeLocked(ROOT), 0, "the lock is released");
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertTrue(pool.getAgent(AGENT).defaulted);
        assertEq(pool.getAgent(ROOT).childrenDefaulted, 1);
        assertEq(pool.ownerDefaults(agentOwner), 1);
        assertEq(usdc.balanceOf(keeper), 1e5, "keeper bounty from the reserve");
    }

    /// Defaults follow the person: the owner cannot borrow again, with this agent or a fresh one.
    function test_default_marksTheOwner() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 5 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        _default(l);
        vm.prank(agentOwner);
        uint256 fresh = reg.register("fresh");
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(fresh, ROOT2, AGENT_PK, 0);
        vm.prank(root2Owner);
        pool.vouchWithConsent(ROOT2, fresh, 5 * USDC, 0, c, sig);
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.OwnerDefaulted.selector, agentOwner));
        pool.borrow(fresh, 5 * USDC, 1 days, agentOwner, type(uint256).max);
        // a delegate used by the defaulted owner is NOT marked (a shared relayer cannot be bricked)
        assertEq(pool.ownerDefaults(address(this)), 0);
    }

    function test_default_custodianNotMarked() public {
        address custody = makeAddr("custody");
        vm.prank(owner);
        pool.setCustodian(custody, true);
        vm.prank(agentOwner);
        reg.transferFrom(agentOwner, custody, AGENT);
        // consent must now come from the custodian; use EIP-1271-less path: custodian is an EOA here
        uint256 custodyPk = 0xC0;
        address c2 = vm.addr(custodyPk);
        vm.prank(owner);
        pool.setCustodian(c2, true);
        vm.prank(custody);
        reg.transferFrom(custody, c2, AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, ROOT, custodyPk, 0);
        vm.prank(rootOwner);
        pool.vouchWithConsent(ROOT, AGENT, 5 * USDC, 0, c, sig);
        vm.prank(c2);
        uint256 l = pool.borrow(AGENT, 5 * USDC, 1 days, c2, type(uint256).max);
        _default(l);
        assertEq(pool.ownerDefaults(c2), 0);
    }

    function test_default_withAnotherLoanOpenThenResidual() public {
        RecordingHook h = new RecordingHook();
        h.set(pool);
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 20 * USDC);
        uint256 a = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        uint256 b = _borrow(agentOwner, AGENT, 5 * USDC, 20 days);
        _default(a);
        assertEq(h.defaults(), 1);
        assertFalse(h.lastLastLoan());
        assertEq(pool.getAgent(ROOT).delegatedOut, 15 * USDC);
        _repay(agentOwner, b);
        // last loan closed: the rest of the line (undrawn 10 + the repaid 5) comes back, and the backer hears why
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertEq(h.lastReason(), uint8(CreditPoolV2.Release.DefaultResidual));
        assertEq(h.lastAmount(), 15 * USDC);
    }

    // ------------------------------------------------------------------
    // Hooks
    // ------------------------------------------------------------------

    function test_hook_setImmediateWhenIdleDelayedWhenBacking() public {
        RecordingHook h = new RecordingHook();
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        assertEq(pool.hook(ROOT), address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 5 * USDC);
        RecordingHook h2 = new RecordingHook();
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h2));
        assertEq(pool.hook(ROOT), address(h), "not while backing");
        vm.expectRevert();
        pool.applyHook(ROOT);
        vm.warp(block.timestamp + 48 hours);
        pool.applyHook(ROOT);
        assertEq(pool.hook(ROOT), address(h2));
    }

    function test_hook_refusesBadTargets() public {
        vm.startPrank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InvalidHook.selector, address(pool)));
        pool.setHook(ROOT, address(pool));
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InvalidHook.selector, address(usdc)));
        pool.setHook(ROOT, address(usdc));
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InvalidHook.selector, anyone));
        pool.setHook(ROOT, anyone);
        vm.stopPrank();
    }

    function test_hook_canBorrowDecides() public {
        RecordingHook h = new RecordingHook();
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        h.setAllow(false);
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, ROOT));
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, type(uint256).max);
        h.setAllow(true);
        h.setBomb(true); // a huge reply is not copied; not a clean 1, so blocked, and no gas blow-up
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, ROOT));
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, type(uint256).max);
        h.setBomb(false);
        _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        assertEq(h.borrows(), 1);
        assertEq(h.lastRoot(), ROOT);
    }

    /// A broken or hostile hook never blocks a default or an exit.
    function test_hook_failingNeverBlocksDefaultsOrExits() public {
        RecordingHook h = new RecordingHook();
        h.set(pool);
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        h.setRevert(true);
        _default(l);
        assertTrue(pool.getAgent(AGENT).defaulted);
        _sponsor(ROOT, rootOwner, AGENT2, AGENT2_PK, 5 * USDC);
        vm.prank(agent2Owner);
        pool.leave(AGENT2);
        assertEq(pool.getAgent(AGENT2).sponsor, 0);
    }

    function test_hook_cannotReenter() public {
        RecordingHook h = new RecordingHook();
        h.set(pool);
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        h.setReenter(true);
        _default(l); // the hook's unvouch reverts on the lock; the default still lands
        assertTrue(pool.getAgent(AGENT).defaulted);
        assertEq(h.defaults(), 0, "the hook call failed as a whole");
    }

    /// Starving the hook on purpose reverts the whole call: nobody can skip a backer's settlement.
    function test_hook_cannotBeStarved() public {
        RecordingHook h = new RecordingHook();
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        vm.warp(pool.getLoan(l).defaultableAt + 1);
        (bool ok,) = address(pool).call{gas: 200_000}(abi.encodeCall(CreditPoolV2.markDefault, (l)));
        assertFalse(ok);
        assertFalse(pool.getAgent(AGENT).defaulted);
        pool.markDefault(l);
        assertEq(h.defaults(), 1);
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    function test_pause_stopsNewRiskNotExitsAndExpires() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.prank(anyone);
        vm.expectRevert(CreditPoolV2.NotGuardian.selector);
        pool.pause();
        vm.prank(guardian);
        pool.pause();
        vm.prank(agentOwner);
        vm.expectRevert(CreditPoolV2.Paused.selector);
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, type(uint256).max);
        vm.prank(anyone);
        vm.expectRevert(CreditPoolV2.Paused.selector);
        pool.deposit(1 * USDC, anyone, 0);
        // exits
        _repay(agentOwner, l);
        vm.prank(rootOwner);
        pool.freeze(AGENT, true);
        vm.warp(block.timestamp + 7 days);
        uint256 half = pool.shares(lender) / 2;
        vm.prank(lender);
        pool.withdraw(half, lender);
        uint256 rhalf = pool.rootShares(ROOT) / 2;
        vm.prank(rootOwner);
        pool.unlock(ROOT, rhalf, rootOwner);
        // and it lapses by itself
        vm.warp(block.timestamp + 14 days);
        vm.prank(anyone);
        pool.deposit(1 * USDC, anyone, 0);
    }

    function test_owner_cannotRenounceAndParamsBounded() public {
        vm.prank(owner);
        vm.expectRevert(CreditPoolV2.Renounce.selector);
        pool.renounceOwnership();
        CreditPoolV2.Params memory p = _params();
        p.grace = 1 hours;
        vm.prank(owner);
        vm.expectRevert(CreditPoolV2.InvalidParams.selector);
        pool.setParams(p);
        p = _params();
        p.feeBps = 501;
        vm.prank(owner);
        vm.expectRevert(CreditPoolV2.InvalidParams.selector);
        pool.setParams(p);
        p = _params();
        p.keeperBounty = 5e6 + 1;
        vm.prank(owner);
        vm.expectRevert(CreditPoolV2.InvalidParams.selector);
        pool.setParams(p);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        pool.setParams(_params());
    }

    function test_reserve_toStakeAndWithdraw() public {
        vm.prank(anyone);
        pool.fundReserve(20 * USDC);
        uint256 b0 = pool.backing(ROOT);
        vm.prank(owner);
        pool.reserveToStake(ROOT, 10 * USDC);
        assertApproxEqAbs(pool.backing(ROOT), b0 + 10 * USDC, 1);
        vm.prank(owner);
        pool.withdrawReserve(10 * USDC, owner);
        assertEq(pool.reserve(), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.ReserveShort.selector, 1, 0));
        pool.withdrawReserve(1, owner);
    }

    // ------------------------------------------------------------------
    // Lens
    // ------------------------------------------------------------------

    function test_lens_v1Layout() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 10 * USDC, 10 days);
        vm.warp(block.timestamp + 10 days);
        _repay(agentOwner, l);
        CreditPool.CreditReport memory r = lens.creditReport(AGENT);
        assertTrue(r.enrolled);
        assertEq(r.sponsor, ROOT);
        assertEq(r.capacity, 10 * USDC);
        assertEq(r.available, 10 * USDC);
        assertEq(r.earned, 0);
        assertEq(r.loansRepaid, 1);
        assertGt(r.score, 0);
        CreditPool.CreditReport memory rr = lens.creditReport(ROOT);
        assertTrue(rr.isRoot);
        assertEq(rr.stake, pool.backing(ROOT));
    }
}

/// v1 → v2: records come over by anyone's call, add up, and a v1 default always follows the agent.
contract CreditPoolV2MigrationTest is CreditPoolV2Base {
    CreditPool v1;
    address v1Owner = makeAddr("v1owner");

    function setUp() public override {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        v1 = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), v1Owner);
        _deploy(v1);
        address[6] memory who = [lender, rootOwner, root2Owner, agentOwner, agent2Owner, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 100_000 * USDC);
            vm.startPrank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
            usdc.approve(address(v1), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        pool.deposit(1_000 * USDC, lender, 0);
        vm.prank(lender);
        v1.deposit(1_000 * USDC, lender);
        vm.prank(rootOwner);
        ROOT = reg.register("root");
        vm.prank(root2Owner);
        ROOT2 = reg.register("root2");
        vm.prank(agentOwner);
        AGENT = reg.register("agent");
        vm.prank(agent2Owner);
        AGENT2 = reg.register("agent2");
        vm.prank(rootOwner);
        pool.enrollRoot(ROOT, 100 * USDC);

        // history on v1: AGENT repays twice, AGENT2 defaults
        vm.prank(root2Owner);
        v1.enrollRoot(ROOT2, 100 * USDC);
        vm.startPrank(root2Owner);
        v1.vouch(ROOT2, AGENT, 10 * USDC);
        v1.vouch(ROOT2, AGENT2, 10 * USDC);
        vm.stopPrank();
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(agentOwner);
            uint256 l = v1.borrow(AGENT, 5 * USDC, 7 days, agentOwner);
            vm.warp(block.timestamp + 7 days);
            vm.prank(agentOwner);
            v1.repay(l);
        }
        vm.prank(agent2Owner);
        uint256 bad = v1.borrow(AGENT2, 5 * USDC, 1 days, agent2Owner);
        vm.warp(block.timestamp + 5 days);
        v1.markDefault(bad);
    }

    function test_import_addsTheRecord() public {
        vm.prank(anyone);
        pool.importFromV1(AGENT);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        CreditPool.Agent memory o = v1.getAgent(AGENT);
        assertEq(o.loansRepaid, 2);
        assertEq(a.loansRepaid, o.loansRepaid);
        assertEq(a.qualifiedRepaid, o.qualifiedRepaid);
        assertEq(a.volumeRepaid, o.volumeRepaid);
        assertEq(a.dollarSecondsRepaid, o.dollarSecondsRepaid);
        assertEq(a.enrolledAt, v1.getAgent(AGENT).enrolledAt);
        assertFalse(a.defaulted);
        assertGt(lens.score(AGENT), 0, "score shows before any v2 line");
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AlreadyImported.selector, AGENT));
        pool.importFromV1(AGENT);
    }

    function test_import_carriesTheDefault() public {
        pool.importFromV1(AGENT2);
        assertTrue(pool.getAgent(AGENT2).defaulted);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, ROOT, AGENT2_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AgentDefaulted.selector, AGENT2));
        pool.vouchWithConsent(ROOT, AGENT2, 5 * USDC, 0, c, sig);
    }

    /// Even without an import, v2 sees a v1 default or an open v1 loan.
    function test_v1StateIsCheckedLive() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, ROOT, AGENT2_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.V1Busy.selector, AGENT2));
        pool.vouchWithConsent(ROOT, AGENT2, 5 * USDC, 0, c, sig);
        // an open v1 loan blocks both the import and a v2 line
        vm.prank(agentOwner);
        v1.borrow(AGENT, 5 * USDC, 7 days, agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.V1Busy.selector, AGENT));
        pool.importFromV1(AGENT);
        (c, sig) = _consent(AGENT, ROOT, AGENT_PK, 0);
        vm.prank(rootOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.V1Busy.selector, AGENT));
        pool.vouchWithConsent(ROOT, AGENT, 5 * USDC, 0, c, sig);
    }

    /// An agent already live on v2 can still import, and the counters add.
    function test_import_afterGoingLiveOnV2() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.warp(block.timestamp + 7 days);
        _repay(agentOwner, l);
        pool.importFromV1(AGENT);
        assertEq(pool.getAgent(AGENT).loansRepaid, 1 + v1.getAgent(AGENT).loansRepaid);
    }
}
