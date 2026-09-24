// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV2} from "../src/SeatVaultV2.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {MockPriors, MockNoBurn, MockTaxToken} from "./helpers/TokenMocks.sol";

/// @dev $PRIORS stand-in whose transfers can be switched off, to make a hook call fail on purpose.
contract SwitchPriors is ERC20 {
    bool public blocked;

    constructor() ERC20("Switch", "SW") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked || from == address(0), "blocked");
        super._update(from, to, value);
    }
}

contract SeatVaultV2Base is Test {
    uint256 constant USDC = 1e6;
    uint256 constant SEAT = 25_000e18;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPoolV2 pool;
    MockPriors priors;
    SeatVaultV2 vault;

    address timelock = makeAddr("timelock");
    address owner = makeAddr("owner");
    address sink = makeAddr("buyback");
    address lender = makeAddr("lender");
    address staker = makeAddr("staker");
    address staker2 = makeAddr("staker2");
    address anyone = makeAddr("anyone");
    address keeper = makeAddr("keeper");

    uint256 constant AGENT_PK = 0xA1;
    uint256 constant AGENT2_PK = 0xA2;
    uint256 constant ROOT_PK = 0xB0B;
    address agentOp = vm.addr(AGENT_PK);
    address agentOp2 = vm.addr(AGENT2_PK);
    address rootOp = vm.addr(ROOT_PK);

    uint256 VAULT_ID;
    uint256 AGENT;
    uint256 AGENT2;
    uint256 ROOT; // another backer, for handoffs

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

    function _params() internal pure returns (SeatVaultV2.Params memory) {
        return SeatVaultV2.Params({
            seatSize: SEAT, line: 5 * USDC, burnBps: 5000, maxOpenSeats: 50, epochCap: 50 * USDC, epochLength: 7 days
        });
    }

    function _deployPool(CreditPool v1) internal {
        pool = new CreditPoolV2(
            IERC20(address(usdc)), IERC8004Identity(address(reg)), v1, timelock, timelock, _poolParams()
        );
        usdc.mint(address(this), 21 * USDC);
        usdc.approve(address(pool), 21 * USDC);
        pool.seed();
        pool.fundReserve(20 * USDC); // keeper bounties, rounding dust
    }

    function setUp() public virtual {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        _deployPool(CreditPool(address(0)));
        priors = new MockPriors();
        _setUpVault(IERC20(address(priors)));
    }

    function _setUpVault(IERC20 tok) internal {
        vault = new SeatVaultV2(pool, tok, owner, sink, _params());
        address[7] memory who = [lender, staker, staker2, agentOp, agentOp2, rootOp, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000 * USDC);
            MockPriors(address(tok)).mint(who[i], 1_000_000e18);
            vm.startPrank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
            tok.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        pool.deposit(10_000 * USDC, lender, 0);

        vm.startPrank(owner);
        VAULT_ID = reg.register("priors-seats-v2");
        reg.safeTransferFrom(owner, address(vault), VAULT_ID);
        vault.adopt(VAULT_ID);
        vm.stopPrank();
        _fund(100 * USDC);

        vm.prank(agentOp);
        AGENT = reg.register("ipfs://agent");
        vm.prank(agentOp2);
        AGENT2 = reg.register("ipfs://agent2");
        vm.prank(rootOp);
        ROOT = reg.register("ipfs://root");
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.fund(amount);
        vm.stopPrank();
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
        return _consentFor(id, VAULT_ID, pk);
    }

    function _accept(uint256 pk, uint256 id, address s) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(vm.addr(pk));
        vault.accept(id, s, c, sig);
    }

    function _offerAndAccept(address s, uint256 pk, uint256 id) internal {
        vm.prank(s);
        vault.offer(id);
        _accept(pk, id, s);
    }

    /// Another backer takes the agent over (its owner's consent), as a graduation to a bigger line.
    function _handoff(uint256 id, uint256 pk, uint256 amount) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(id, ROOT, pk);
        vm.prank(rootOp);
        pool.vouchWithConsent(ROOT, id, amount, 0, c, sig);
    }

    function _borrow(address op, uint256 id, uint256 amount, uint64 term) internal returns (uint256) {
        vm.prank(op);
        return pool.borrow(id, amount, term, op, type(uint256).max);
    }

    function _repay(address who, uint256 loanId) internal {
        uint256 id = pool.getLoan(loanId).agentId;
        vm.prank(who);
        pool.repay(loanId, id, type(uint256).max);
    }

    function _default(uint256 loanId) internal {
        vm.warp(pool.getLoan(loanId).defaultableAt + 1);
        vm.prank(keeper);
        pool.markDefault(loanId);
    }

    function _seat(uint256 id) internal view returns (SeatVaultV2.Seat memory) {
        return vault.getSeat(id);
    }

    function _status(uint256 id) internal view returns (SeatVaultV2.Status) {
        return vault.getSeat(id).status;
    }

    function _hookFailures(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 t = keccak256("HookFailed(uint256,bytes4)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == t) n++;
        }
    }
}

contract SeatVaultV2Test is SeatVaultV2Base {
    // ------------------------------------------------------------------
    // Identity and stake
    // ------------------------------------------------------------------

    function test_adopt_onceOnlyOwnedAndFresh() public {
        SeatVaultV2 v = new SeatVaultV2(pool, IERC20(address(priors)), owner, sink, _params());
        vm.prank(agentOp);
        uint256 other = reg.register("x");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotOurs.selector, other));
        v.adopt(other);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        v.adopt(other);
        // an identity with a record is refused even when it is ours
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(agentOp);
        reg.safeTransferFrom(agentOp, address(v), AGENT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotOurs.selector, AGENT));
        v.adopt(AGENT);
        vm.prank(agentOp);
        reg.safeTransferFrom(agentOp, address(v), other);
        vm.prank(owner);
        v.adopt(other);
        vm.prank(owner);
        vm.expectRevert(SeatVaultV2.AlreadyAdopted.selector);
        v.adopt(other);
    }

    function test_fund_enrollsRootMakesItselfTheHookThenAddsStake() public {
        CreditPoolV2.Agent memory r = pool.getAgent(VAULT_ID);
        assertTrue(r.isRoot);
        assertEq(pool.hook(VAULT_ID), address(vault), "the vault hears every default and release");
        assertApproxEqAbs(pool.backing(VAULT_ID), 100 * USDC, 1);
        vm.prank(anyone);
        usdc.approve(address(vault), 50 * USDC);
        vm.prank(anyone);
        vault.fund(50 * USDC);
        assertApproxEqAbs(pool.backing(VAULT_ID), 150 * USDC, 2);
        assertEq(vault.totalFunded(), 150 * USDC);
    }

    function test_fund_needsAdoptionAndMinStake() public {
        SeatVaultV2 v = new SeatVaultV2(pool, IERC20(address(priors)), owner, sink, _params());
        vm.expectRevert(SeatVaultV2.NotAdopted.selector);
        v.fund(10 * USDC);
        vm.startPrank(owner);
        uint256 id = reg.register("v2");
        reg.safeTransferFrom(owner, address(v), id);
        v.adopt(id);
        usdc.mint(owner, 5 * USDC);
        usdc.approve(address(v), 5 * USDC);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BelowMinStake.selector, 5 * USDC, 10 * USDC));
        v.fund(5 * USDC);
        vm.expectRevert(SeatVaultV2.ZeroAmount.selector);
        v.fund(0);
        vm.stopPrank();
    }

    /// The stake earns the pool's lender yield; it belongs to the funder, who takes free backing out through the
    /// owner. Nothing vouched to an open line can leave.
    function test_retire_freeBackingOnlyWithItsYield() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        assertGt(pool.backing(VAULT_ID), 100 * USDC, "lender yield on the stake");
        uint256 all = pool.rootShares(VAULT_ID);
        vm.prank(owner);
        vm.expectRevert();
        vault.retire(all, owner);
        uint256 free = pool.convertToShares(pool.freeBacking(VAULT_ID));
        vm.prank(owner);
        uint256 out = vault.retire(free, owner);
        assertGt(out, 95 * USDC);
        assertEq(usdc.balanceOf(owner), out);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.retire(1, anyone);
    }

    // ------------------------------------------------------------------
    // Offers
    // ------------------------------------------------------------------

    function test_offer_escrowsExactlyOneSeatUnderCurrentTerms() public {
        vm.prank(staker);
        vault.offer(AGENT);
        assertEq(vault.offers(AGENT, staker), SEAT);
        (uint128 line, uint128 burnBps, address offeredTo) = vault.offerTerms(AGENT, staker);
        assertEq(line, 5 * USDC);
        assertEq(burnBps, 5000);
        assertEq(offeredTo, agentOp, "the offer is bound to the owner the staker saw");
        assertEq(vault.tokensHeld(), SEAT);
        assertEq(priors.balanceOf(address(vault)), SEAT);
        assertEq(pool.getAgent(AGENT).sponsor, 0, "nothing vouched by an offer");
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.OfferExists.selector, AGENT, staker));
        vault.offer(AGENT);
    }

    function test_offer_refusesUnknownZeroSelfRootsAndDefaulted() public {
        vm.startPrank(staker);
        vm.expectRevert();
        vault.offer(999);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotSeatable.selector, 0));
        vault.offer(0);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotSeatable.selector, VAULT_ID));
        vault.offer(VAULT_ID);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotSeatable.selector, ROOT));
        vault.offer(ROOT);
        vm.stopPrank();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _default(_borrow(agentOp, AGENT, 5 * USDC, 1 days));
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotSeatable.selector, AGENT));
        vault.offer(AGENT);
        assertEq(vault.tokensHeld(), 0);
    }

    function test_offer_refusesAFeeOnTransferToken() public {
        MockTaxToken tax = new MockTaxToken();
        SeatVaultV2 v = new SeatVaultV2(pool, IERC20(address(tax)), owner, sink, _params());
        vm.startPrank(owner);
        uint256 id = reg.register("tv");
        reg.safeTransferFrom(owner, address(v), id);
        v.adopt(id);
        vm.stopPrank();
        tax.mint(staker, SEAT * 2);
        vm.startPrank(staker);
        tax.approve(address(v), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.BadTransfer.selector, SEAT, SEAT - SEAT / 100));
        v.offer(AGENT);
        vm.stopPrank();
    }

    function test_withdrawOffer_stakerOrControllerOnly() public {
        vm.prank(staker);
        vault.offer(AGENT);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotStakerOrController.selector, AGENT, anyone));
        vault.withdrawOffer(AGENT, staker);
        uint256 before = priors.balanceOf(staker);
        vm.prank(agentOp); // the agent turns it down
        vault.withdrawOffer(AGENT, staker);
        assertEq(priors.balanceOf(staker), before + SEAT);
        assertEq(vault.tokensHeld(), 0);
        (uint128 line,,) = vault.offerTerms(AGENT, staker);
        assertEq(line, 0);
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NoOffer.selector, AGENT, staker));
        vault.withdrawOffer(AGENT, staker);
    }

    /// Offers are per staker: a griefer's offer cannot block anybody else's.
    function test_offer_cannotBeSquatted() public {
        vm.prank(anyone);
        vault.offer(AGENT);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        assertEq(_seat(AGENT).staker, staker);
        vm.prank(anyone);
        vault.withdrawOffer(AGENT, anyone);
        assertEq(vault.tokensHeld(), SEAT);
    }

    // ------------------------------------------------------------------
    // Accept: the agent owner's consent, forwarded
    // ------------------------------------------------------------------

    function test_accept_opensTheLineWithTheOwnersConsent() public {
        vm.prank(staker);
        vault.offer(AGENT);
        uint256 room = vault.epochRoom();
        _accept(AGENT_PK, AGENT, staker);
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.sponsor, VAULT_ID);
        assertEq(a.delegatedIn, 5 * USDC);
        assertEq(a.premiumBps, 0);
        assertEq(pool.nonces(AGENT), 1);
        SeatVaultV2.Seat memory s = _seat(AGENT);
        assertEq(s.staker, staker);
        assertEq(s.amount, SEAT);
        assertEq(uint256(s.line), 5 * USDC);
        assertEq(uint256(s.burnBps), 5000);
        assertEq(uint8(s.status), uint8(SeatVaultV2.Status.Open));
        assertEq(vault.offers(AGENT, staker), 0);
        assertEq(vault.tokensHeld(), SEAT);
        assertEq(vault.openCount(), 1);
        assertEq(vault.epochRoom(), room - 5 * USDC);
        _borrow(agentOp, AGENT, 5 * USDC, 7 days);
    }

    /// Only the agent's controller may take an offer, so a consent seen in the mempool cannot be redirected to
    /// another staker's offer. A delegate may submit the owner's consent.
    function test_accept_onlyTheAgentsController() public {
        vm.prank(staker);
        vault.offer(AGENT);
        vm.prank(staker2);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotController.selector, AGENT, staker2));
        vault.accept(AGENT, staker2, c, sig);
        address hot = makeAddr("hot");
        vm.prank(agentOp);
        pool.setDelegate(AGENT, hot);
        vm.prank(hot);
        vault.accept(AGENT, staker, c, sig);
        assertEq(_seat(AGENT).staker, staker);
    }

    /// The controller calling is not enough: the pool wants the NFT owner's signature for this vault.
    function test_accept_needsTheOwnersConsent() public {
        vm.prank(staker);
        vault.offer(AGENT);
        address hot = vm.addr(0x407);
        vm.prank(agentOp);
        pool.setDelegate(AGENT, hot);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, 0x407); // the delegate signs
        vm.prank(hot);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        vault.accept(AGENT, staker, c, sig);
        (c, sig) = _consentFor(AGENT, ROOT, AGENT_PK); // a consent for another backer
        vm.prank(agentOp);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        vault.accept(AGENT, staker, c, sig);
        assertEq(vault.offers(AGENT, staker), SEAT, "the offer is untouched");
        assertEq(vault.openCount(), 0);
    }

    function test_seat_selfSeatInOneCall() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        uint256 before = priors.balanceOf(agentOp);
        vm.prank(agentOp);
        vault.seat(AGENT, c, sig);
        assertEq(priors.balanceOf(agentOp), before - SEAT);
        assertEq(_seat(AGENT).staker, agentOp);
        assertEq(pool.getAgent(AGENT).delegatedIn, 5 * USDC);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotController.selector, AGENT2, anyone));
        vault.seat(AGENT2, c, sig);
    }

    function test_seat_usesAnOfferAlreadyMade() public {
        vm.prank(agentOp);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vault.seat(AGENT, c, sig);
        assertEq(vault.tokensHeld(), SEAT);
    }

    function test_accept_termsBoundToTheOffer() public {
        vm.prank(staker);
        vault.offer(AGENT);
        SeatVaultV2.Params memory p = _params();
        p.burnBps = 10_000;
        vm.prank(owner);
        vault.setParams(p);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.TermsChanged.selector, AGENT));
        vault.accept(AGENT, staker, c, sig);
        p = _params();
        p.seatSize = SEAT * 2;
        vm.prank(owner);
        vault.setParams(p);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.OfferTooSmall.selector, AGENT, SEAT, SEAT * 2));
        vault.accept(AGENT, staker, c, sig);
    }

    function test_accept_epochCapBoundsNewLines() public {
        SeatVaultV2.Params memory p = _params();
        p.epochCap = 5 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker2);
        vault.offer(AGENT2);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.EpochCapReached.selector, 5 * USDC, 0));
        vault.accept(AGENT2, staker2, c, sig);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (c, sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vault.accept(AGENT2, staker2, c, sig);
    }

    function test_accept_maxOpenSeats() public {
        SeatVaultV2.Params memory p = _params();
        p.maxOpenSeats = 1;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker2);
        vault.offer(AGENT2);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.TooManySeats.selector, 1, 1));
        vault.accept(AGENT2, staker2, c, sig);
    }

    /// The vault's own stake bounds every line: past it, the pool refuses and nothing moves.
    function test_accept_boundedByTheVaultsStake() public {
        uint256 free = pool.convertToShares(pool.freeBacking(VAULT_ID) - 4 * USDC);
        vm.prank(owner);
        vault.retire(free, owner);
        vm.prank(staker);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert();
        vault.accept(AGENT, staker, c, sig);
        assertEq(vault.openCount(), 0);
        assertEq(vault.offers(AGENT, staker), SEAT);
        assertEq(vault.epochRoom(), 50 * USDC);
    }

    /// An agent another backer holds with no loan open moves to a seat; with a loan open it cannot.
    function test_accept_handsOffFromAnotherBackerOnlyWithNoLoanOpen() public {
        _handoff(AGENT, AGENT_PK, 20 * USDC);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        vm.prank(staker);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanOpen.selector, AGENT));
        vault.accept(AGENT, staker, c, sig);
        _repay(agentOp, loan);
        vm.prank(agentOp);
        vault.accept(AGENT, staker, c, sig);
        assertEq(pool.getAgent(AGENT).sponsor, VAULT_ID);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
    }

    // ------------------------------------------------------------------
    // registerAndSeat: the vault consents for the NFT it just minted (EIP-1271)
    // ------------------------------------------------------------------

    function test_registerAndSeat_mintsSeatsAndHandsOver() public {
        address newcomer = makeAddr("newcomer");
        priors.mint(newcomer, SEAT);
        vm.startPrank(newcomer);
        priors.approve(address(vault), SEAT);
        uint256 id = vault.registerAndSeat("ipfs://new-agent");
        vm.stopPrank();
        assertEq(reg.ownerOf(id), newcomer, "the identity is the caller's");
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        assertEq(a.sponsor, VAULT_ID);
        assertEq(a.delegatedIn, 5 * USDC);
        assertEq(pool.nonces(id), 1, "a real consent was used");
        assertEq(_seat(id).staker, newcomer);
        assertEq(vault.tokensHeld(), SEAT);
        // the approval lived only inside the call
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: VAULT_ID,
            owner: address(vault),
            maxPremiumBps: 0,
            nonce: 0,
            deadline: vm.getBlockTimestamp()
        });
        assertEq(vault.isValidSignature(pool.consentDigest(c), ""), bytes4(0xffffffff));
        assertEq(vault.isValidSignature(bytes32(0), ""), bytes4(0xffffffff));
        // and the newcomer uses and closes it
        vm.prank(newcomer);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(newcomer, 1 * USDC);
        uint256 loan = _borrow(newcomer, id, 5 * USDC, 1 days);
        _repay(newcomer, loan);
        vm.prank(newcomer);
        vault.close(id);
        assertEq(priors.balanceOf(newcomer), SEAT);
    }

    function test_registerAndSeat_respectsPauseAndCaps() public {
        vm.prank(owner);
        vault.pauseSeats(true);
        vm.prank(staker);
        vm.expectRevert(SeatVaultV2.Paused.selector);
        vault.registerAndSeat("x");
        vm.prank(owner);
        vault.pauseSeats(false);
        uint256 free = pool.convertToShares(pool.freeBacking(VAULT_ID) - 1);
        vm.prank(owner);
        vault.retire(free, owner);
        vm.prank(staker);
        vm.expectRevert();
        vault.registerAndSeat("x");
        assertEq(vault.tokensHeld(), 0);
    }

    // ------------------------------------------------------------------
    // Close: freeze, then the seat closes when the last loan does
    // ------------------------------------------------------------------

    function test_close_noLoanOpen_everyTokenBackAtOnce() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.close(AGENT);
        assertEq(priors.balanceOf(staker), before + SEAT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
        CreditPoolV2.Agent memory a = pool.getAgent(AGENT);
        assertEq(a.sponsor, 0);
        assertEq(a.delegatedIn, 0);
        assertFalse(a.frozen);
        assertEq(pool.getAgent(VAULT_ID).delegatedOut, 0);
        assertEq(vault.tokensHeld(), 0);
        assertEq(vault.openCount(), 0);
        assertEq(vault.epochRoom(), 50 * USDC, "a clean close refunds the epoch");
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NoOpenSeat.selector, AGENT));
        vault.close(AGENT);
    }

    function test_close_byControllerSendsTokensToStaker() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 before = priors.balanceOf(staker);
        vm.prank(agentOp);
        vault.close(AGENT);
        assertEq(priors.balanceOf(staker), before + SEAT);
        assertEq(priors.balanceOf(agentOp), 1_000_000e18);
    }

    function test_close_strangerCannot() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotStakerOrController.selector, AGENT, anyone));
        vault.close(AGENT);
    }

    /// A loan out: new borrows stop, the undrawn line comes back now, and the repayment of the last loan closes
    /// the seat in the same transaction with every token and every fee.
    function test_close_withALoanOut_closesWhenItIsRepaid() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 10 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.close(AGENT);
        SeatVaultV2.Seat memory s = _seat(AGENT);
        assertEq(uint8(s.status), uint8(SeatVaultV2.Status.Open));
        assertTrue(s.closing);
        assertTrue(pool.getAgent(AGENT).frozen);
        assertEq(pool.getAgent(AGENT).delegatedIn, 5 * USDC, "undrawn half back");
        assertFalse(
            vault.canBorrow(VAULT_ID, AGENT, 5 * USDC, 1 days, 0, agentOp, agentOp, agentOp),
            "no borrow on a closing seat"
        );
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.IsFrozen.selector, AGENT));
        pool.borrow(AGENT, 5 * USDC, 1 days, agentOp, type(uint256).max);
        vm.prank(staker);
        vault.close(AGENT); // idempotent while the loan is out
        vm.recordLogs();
        _repay(agentOp, loan);
        assertEq(_hookFailures(vm.getRecordedLogs()), 0);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed), "closed in the repayment");
        assertEq(priors.balanceOf(staker), before + SEAT);
        assertEq(vault.feesOwed(staker), pool.getLoan(loan).sponsorCut, "every fee, exactly");
        assertEq(pool.getAgent(AGENT).sponsor, 0);
        assertEq(vault.tokensHeld(), 0);
    }

    function test_close_withALoanOut_thenDefault_settles() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        vm.prank(staker);
        vault.close(AGENT);
        uint256 before = priors.balanceOf(staker);
        _default(loan);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertEq(vault.totalBurnt(), SEAT / 2);
    }

    function test_close_thenReseat() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker);
        vault.close(AGENT);
        _offerAndAccept(staker2, AGENT_PK, AGENT);
        assertEq(_seat(AGENT).staker, staker2);
        assertEq(pool.getAgent(AGENT).delegatedIn, 5 * USDC);
        assertEq(pool.nonces(AGENT), 2, "a fresh consent each time");
    }

    /// The pool paused: nothing new opens, but a staker still gets every token back.
    function test_poolPaused_closeStillWorks() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker2);
        vault.offer(AGENT2);
        vm.prank(timelock);
        pool.pause();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(CreditPoolV2.Paused.selector);
        vault.accept(AGENT2, staker2, c, sig);
        vm.prank(staker);
        vault.close(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
    }

    function test_seatsPaused_stopsNewSeatsOnly() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker2);
        vault.offer(AGENT2);
        vm.prank(owner);
        vault.pauseSeats(true);
        vm.prank(anyone);
        vm.expectRevert(SeatVaultV2.Paused.selector);
        vault.offer(AGENT2);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(SeatVaultV2.Paused.selector);
        vault.accept(AGENT2, staker2, c, sig);
        vm.prank(staker2);
        vault.withdrawOffer(AGENT2, staker2);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        vm.prank(staker);
        vault.close(AGENT);
        vm.prank(staker);
        vault.claim(staker);
    }

    // ------------------------------------------------------------------
    // Graduation: leave or handoff, every token back in the same transaction
    // ------------------------------------------------------------------

    function test_graduation_leave() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        uint256 before = priors.balanceOf(staker);
        vm.recordLogs();
        vm.prank(agentOp);
        pool.leave(AGENT);
        assertEq(_hookFailures(vm.getRecordedLogs()), 0);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
        assertEq(priors.balanceOf(staker), before + SEAT);
        assertEq(vault.feesOwed(staker), pool.getLoan(loan).sponsorCut);
        assertEq(vault.tokensHeld(), 0);
        assertEq(vault.epochRoom(), 50 * USDC);
    }

    /// The credit ladder: a seated agent moves to a bigger backer. No line is ever left uncovered and the staker
    /// gets every token back the moment the new backer takes over.
    function test_graduation_handoffToABiggerBacker() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, ROOT, AGENT_PK);
        vm.prank(rootOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.LoanOpen.selector, AGENT));
        pool.vouchWithConsent(ROOT, AGENT, 50 * USDC, 0, c, sig);
        _repay(agentOp, loan);
        uint256 before = priors.balanceOf(staker);
        vm.prank(rootOp);
        pool.vouchWithConsent(ROOT, AGENT, 50 * USDC, 0, c, sig);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed), "graduated");
        assertEq(priors.balanceOf(staker), before + SEAT, "every token back");
        assertEq(pool.getAgent(AGENT).sponsor, ROOT);
        assertEq(pool.getAgent(AGENT).delegatedIn, 50 * USDC);
        assertEq(pool.getAgent(VAULT_ID).delegatedOut, 0);
        assertEq(vault.feesOwed(staker), pool.getLoan(loan).sponsorCut);
        // fees the agent pays its new backer are not the staker's
        uint256 l2 = _borrow(agentOp, AGENT, 50 * USDC, 30 days);
        _repay(agentOp, l2);
        vault.skim();
        assertEq(vault.feesOwed(staker), pool.getLoan(loan).sponsorCut);
    }

    // ------------------------------------------------------------------
    // Default: onDefault settles and burns in the same transaction
    // ------------------------------------------------------------------

    function test_default_settlesInTheSameTransaction() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 paid = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, paid);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        uint256 before = priors.balanceOf(staker);
        uint256 supply = priors.totalSupply();
        uint256 backing0 = pool.backing(VAULT_ID);
        uint256 lenderValue = pool.convertToAssets(pool.shares(lender));
        backing0 -= 5 * USDC + pool.getLoan(loan).fee; // the burn: principal + unpaid fee (fee lock, 2026-09-24)
        vm.recordLogs();
        _default(loan);
        backing0 += pool.getLoan(loan).fee * pool.rootShares(VAULT_ID) / pool.totalShares(); // its cut of the fee
        assertEq(_hookFailures(vm.getRecordedLogs()), 0, "the hook fit its gas and did not fail");
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertEq(priors.totalSupply(), supply - SEAT / 2, "burnt, not parked");
        assertEq(vault.totalBurnt(), SEAT / 2);
        assertEq(vault.tokensHeld(), 0);
        assertEq(vault.openCount(), 0);
        assertEq(
            vault.feesOwed(staker), pool.getLoan(paid).sponsorCut, "fees paid before the default stay the staker's"
        );
        assertApproxEqAbs(pool.backing(VAULT_ID), backing0, 1, "the vault's stake pays");
        assertGe(pool.convertToAssets(pool.shares(lender)), lenderValue, "lenders untouched");
        assertEq(pool.totalBadDebt(), 0);
        assertEq(vault.epochRoom(), 45 * USDC, "a default is not refunded");
    }

    /// Two loans out: the seat settles at the first default; the leftover line comes back when the second closes,
    /// and that release never returns the burnt half.
    function test_default_withAnotherLoanOpen() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 10 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 a = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        uint256 b = _borrow(agentOp, AGENT, 5 * USDC, 20 days);
        uint256 before = priors.balanceOf(staker);
        _default(a);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertFalse(vault.canBorrow(VAULT_ID, AGENT, 5 * USDC, 1 days, 0, agentOp, agentOp, agentOp));
        _repay(agentOp, b); // DefaultResidual: ignored, the seat is settled
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertEq(pool.getAgent(VAULT_ID).delegatedOut, 0);
        // the fee on the leftover loan belongs to no staker: skim sends it to the sink
        uint256 got = vault.skim();
        assertEq(got, pool.getLoan(b).sponsorCut);
        assertEq(usdc.balanceOf(sink), got);
    }

    function test_default_bothLoansDefault_theVaultPaysBoth() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 10 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 a = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        uint256 b = _borrow(agentOp, AGENT, 5 * USDC, 2 days);
        // each default burns principal + unpaid fee (fee lock, 2026-09-24), less the vault's cut of that fee
        uint256 expected = pool.backing(VAULT_ID) - 5 * USDC - pool.getLoan(a).fee;
        _default(a);
        expected += pool.getLoan(a).fee * pool.rootShares(VAULT_ID) / pool.totalShares();
        assertApproxEqAbs(pool.backing(VAULT_ID), expected, 1);
        expected = pool.backing(VAULT_ID) - 5 * USDC - pool.getLoan(b).fee;
        _default(b);
        expected += pool.getLoan(b).fee * pool.rootShares(VAULT_ID) / pool.totalShares();
        assertEq(vault.totalBurnt(), SEAT / 2, "one seat, one burn");
        assertApproxEqAbs(pool.backing(VAULT_ID), expected, 1);
        assertEq(pool.totalBadDebt(), 0);
    }

    /// The owner cannot change a seat's terms after it opened.
    function test_default_termsFixedAtOpening() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        SeatVaultV2.Params memory p = _params();
        p.burnBps = 10_000;
        vm.prank(owner);
        vault.setParams(p);
        uint256 before = priors.balanceOf(staker);
        _default(_borrow(agentOp, AGENT, 5 * USDC, 1 days));
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
    }

    function test_default_fallsBackToDeadWithoutBurn() public {
        MockNoBurn nb = new MockNoBurn();
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        _deployPool(CreditPool(address(0)));
        _setUpVault(IERC20(address(nb)));
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _default(_borrow(agentOp, AGENT, 5 * USDC, 1 days));
        assertEq(nb.balanceOf(vault.DEAD()), SEAT / 2);
        assertEq(nb.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------
    // Hooks: only the pool, only for the vault's root
    // ------------------------------------------------------------------

    function test_hooks_ignoreCallsNotFromThePool() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.startPrank(anyone);
        vault.onDefault(VAULT_ID, AGENT, 1, 5 * USDC, true);
        vault.onRelease(VAULT_ID, AGENT, 5 * USDC, uint8(CreditPoolV2.Release.Leave));
        vault.onBorrow(VAULT_ID, AGENT, 1);
        vm.stopPrank();
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open));
        assertEq(vault.tokensHeld(), SEAT);
    }

    function test_hooks_ignoreOtherRoots() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.startPrank(address(pool));
        vault.onDefault(ROOT, AGENT, 1, 5 * USDC, true);
        vault.onRelease(ROOT, AGENT, 5 * USDC, uint8(CreditPoolV2.Release.Leave));
        vm.stopPrank();
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open));
        assertFalse(vault.canBorrow(ROOT, AGENT, 5 * USDC, 1 days, 0, agentOp, agentOp, agentOp));
        assertTrue(vault.canBorrow(VAULT_ID, AGENT, 5 * USDC, 1 days, 0, agentOp, agentOp, agentOp));
        assertFalse(vault.canBorrow(VAULT_ID, AGENT2, 5 * USDC, 1 days, 0, agentOp, agentOp, agentOp));
    }

    /// A partial release (a freeze with a loan still out) keeps the seat open.
    function test_hooks_partialReleaseKeepsTheSeat() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 15 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 a = _borrow(agentOp, AGENT, 5 * USDC, 10 days);
        uint256 b = _borrow(agentOp, AGENT, 5 * USDC, 10 days);
        vm.prank(staker);
        vault.close(AGENT);
        _repay(agentOp, a); // releases 5, one loan still out
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open));
        assertEq(pool.getAgent(AGENT).delegatedIn, 5 * USDC);
        _repay(agentOp, b);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
        assertEq(vault.feesOwed(staker), pool.getLoan(a).sponsorCut + pool.getLoan(b).sponsorCut);
    }

    // ------------------------------------------------------------------
    // The manual path: a hook call that failed is recoverable
    // ------------------------------------------------------------------

    function _switchVault() internal returns (SwitchPriors sw) {
        sw = new SwitchPriors();
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        _deployPool(CreditPool(address(0)));
        _setUpVault(IERC20(address(sw)));
    }

    function test_settle_afterAFailedOnDefault() public {
        SwitchPriors sw = _switchVault();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        sw.setBlocked(true);
        vm.recordLogs();
        _default(loan);
        assertEq(_hookFailures(vm.getRecordedLogs()), 2, "onDefault and the residual both failed");
        assertTrue(pool.getAgent(AGENT).defaulted, "the default landed anyway");
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open));
        sw.setBlocked(false);
        // close refuses a defaulted agent; a wrong proof is refused
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.AgentDefaulted.selector, AGENT));
        vault.close(AGENT);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.BadProof.selector, AGENT, 0));
        vault.settle(AGENT, 0);
        uint256 before = sw.balanceOf(staker);
        vm.prank(anyone);
        vault.settle(AGENT, loan);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(sw.balanceOf(staker), before + SEAT / 2);
        assertEq(vault.totalBurnt(), SEAT / 2);
    }

    /// With the default's other loan still out, the vault still backs the agent: settle burns without a proof.
    function test_settle_whileStillBacked_needsNoProof() public {
        SwitchPriors sw = _switchVault();
        SeatVaultV2.Params memory p = _params();
        p.line = 10 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 a = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        _borrow(agentOp, AGENT, 5 * USDC, 20 days);
        sw.setBlocked(true);
        _default(a);
        sw.setBlocked(false);
        assertEq(pool.getAgent(AGENT).sponsor, VAULT_ID);
        vault.settle(AGENT, 0);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(vault.totalBurnt(), SEAT / 2);
    }

    /// A graduation whose hook failed: the seat is closed by hand, every token back. If the agent later
    /// defaults under its new backer, that loan proves the seat had ended cleanly: no burn.
    function test_settle_afterAFailedGraduation_thenADefaultElsewhere() public {
        SwitchPriors sw = _switchVault();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        sw.setBlocked(true);
        _handoff(AGENT, AGENT_PK, 20 * USDC);
        sw.setBlocked(false);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open), "stale: the hook failed");
        assertFalse(vault.seatable(AGENT));
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        _default(loan);
        // a proof from this seat is not available; the other backer's loan proves a clean exit
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.BadProof.selector, AGENT, 0));
        vault.settle(AGENT, 0);
        uint256 before = sw.balanceOf(staker);
        vault.settle(AGENT, loan);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
        assertEq(sw.balanceOf(staker), before + SEAT, "every token back");
        assertEq(vault.totalBurnt(), 0);
    }

    function test_settle_afterAFailedLeave_noDefault() public {
        SwitchPriors sw = _switchVault();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.StillBacked.selector, AGENT));
        vault.settle(AGENT, 0);
        sw.setBlocked(true);
        vm.prank(agentOp);
        pool.leave(AGENT);
        sw.setBlocked(false);
        uint256 before = sw.balanceOf(staker);
        vm.prank(staker); // close works too on a stale seat
        vault.close(AGENT);
        assertEq(sw.balanceOf(staker), before + SEAT);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NoOpenSeat.selector, AGENT));
        vault.settle(AGENT, 0);
    }

    // ------------------------------------------------------------------
    // Fees: exact, per agent
    // ------------------------------------------------------------------

    function test_fees_stakerEarnsExactlyTheSponsorShare() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        uint256 cut = pool.getLoan(loan).sponsorCut;
        assertEq(vault.pendingFees(AGENT), cut);
        vm.prank(anyone);
        vault.poke(AGENT);
        assertEq(vault.feesOwed(staker), cut);
        assertEq(vault.pendingFees(AGENT), 0);
        uint256 before = usdc.balanceOf(staker);
        vm.prank(staker);
        assertEq(vault.claim(staker), cut, "claim collects from the pool when short");
        assertEq(usdc.balanceOf(staker), before + cut);
        assertEq(vault.totalFeesOwed(), 0);
        assertEq(pool.sponsorFees(VAULT_ID), 0);
        vm.prank(staker);
        vm.expectRevert(SeatVaultV2.ZeroAmount.selector);
        vault.claim(staker);
    }

    function test_fees_twoSeatsAreKeptApartExactly() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _offerAndAccept(staker2, AGENT2_PK, AGENT2);
        uint256 cut1;
        for (uint256 i = 0; i < 3; i++) {
            uint256 l = _borrow(agentOp, AGENT, 5 * USDC, 7 days); // odd fees, rounded per loan by the pool
            cut1 += pool.getLoan(l).sponsorCut;
            _repay(agentOp, l);
        }
        uint256 l2 = _borrow(agentOp2, AGENT2, 5 * USDC, 30 days);
        _repay(agentOp2, l2);
        vault.skim();
        assertEq(vault.feesOwed(staker), cut1, "to the unit");
        assertEq(vault.feesOwed(staker2), pool.getLoan(l2).sponsorCut);
        assertEq(usdc.balanceOf(sink), 0, "nothing unowed");
    }

    function test_skim_sendsOnlyTheUnowed() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        usdc.mint(address(vault), 3 * USDC); // stray
        assertEq(vault.skim(), 3 * USDC);
        assertEq(usdc.balanceOf(address(vault)), vault.totalFeesOwed());
        assertEq(vault.feesOwed(staker), pool.getLoan(loan).sponsorCut);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function test_rescue_cannotTouchStakersTokensOrUSDG() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.Protected.selector, address(usdc)));
        vault.rescue(address(usdc), owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.Protected.selector, address(priors)));
        vault.rescue(address(priors), owner);
        vm.stopPrank();
        priors.mint(address(vault), 7);
        vm.prank(owner);
        vault.rescue(address(priors), owner);
        assertEq(priors.balanceOf(owner), 7);
        assertEq(priors.balanceOf(address(vault)), SEAT);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.rescue(address(priors), anyone);
    }

    function test_setParams_validated() public {
        SeatVaultV2.Params memory p = _params();
        vm.startPrank(owner);
        p.burnBps = 2499;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        p = _params();
        p.burnBps = 10_001;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        p = _params();
        p.maxOpenSeats = 201;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        p = _params();
        p.epochLength = 366 days;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        p = _params();
        p.line = 0;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        p = _params();
        p.seatSize = 0;
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setParams(p);
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        vault.setFeeSink(address(0));
        vault.setFeeSink(anyone);
        vm.stopPrank();
        assertEq(vault.feeSink(), anyone);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setParams(_params());
    }

    function test_constructor_refusesUSDGAsTheSeatToken() public {
        vm.expectRevert(SeatVaultV2.InvalidParams.selector);
        new SeatVaultV2(pool, IERC20(address(usdc)), owner, sink, _params());
    }

    /// The whole attack a seat prices: seat your own agent, borrow the line, walk. It costs half a seat of
    /// $PRIORS; the loss stays inside the vault's stake; lenders and the reserve are untouched.
    function test_attack_selfSeatAndWalk() public {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        uint256 reserve0 = pool.reserve();
        vm.prank(agentOp);
        vault.seat(AGENT, c, sig);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        uint256 lenderValue = pool.convertToAssets(pool.shares(lender));
        _default(loan);
        assertEq(priors.balanceOf(agentOp), 1_000_000e18 - SEAT / 2, "the walk cost half a seat");
        assertGe(pool.convertToAssets(pool.shares(lender)), lenderValue);
        assertEq(pool.reserve(), reserve0 - pool.getParams().keeperBounty, "only the keeper bounty");
        assertEq(pool.ownerDefaults(agentOp), 1, "and the owner is marked");
    }

    function test_gas_skimAtMaxOpenSeats() public {
        SeatVaultV2.Params memory p = _params();
        p.maxOpenSeats = 200;
        p.epochCap = 1_000 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _fund(1_000 * USDC);
        for (uint256 i = 0; i < 200; i++) {
            uint256 pk = 0x10000 + i;
            address op = vm.addr(pk);
            priors.mint(op, SEAT);
            vm.prank(op);
            uint256 id = reg.register("");
            vm.prank(op);
            priors.approve(address(vault), SEAT);
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
            vm.prank(op);
            vault.seat(id, c, sig);
        }
        assertEq(vault.openCount(), 200);
        uint256 g = gasleft();
        vault.skim();
        assertLt(g - gasleft(), 3_000_000);
    }
}

/// A v1 default imported while the agent is seated makes it defaulted on v2: the vault's line comes back whole
/// (DefaultResidual), and the seat settles per its terms, never as a graduation.
contract SeatVaultV2MigrationTest is SeatVaultV2Base {
    CreditPool v1;

    function setUp() public override {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        v1 = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), makeAddr("v1owner"));
        _deployPool(v1);
        priors = new MockPriors();
        _setUpVault(IERC20(address(priors)));
        usdc.mint(lender, 1_000 * USDC);
        vm.startPrank(lender);
        usdc.approve(address(v1), type(uint256).max);
        v1.deposit(1_000 * USDC, lender);
        vm.stopPrank();
    }

    function test_v1DefaultWhileSeated_settlesTheSeat() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        // on v1 (not yet paused) the agent borrows and defaults
        vm.startPrank(rootOp);
        uint256 v1root = reg.register("v1root");
        usdc.approve(address(v1), type(uint256).max);
        v1.enrollRoot(v1root, 100 * USDC);
        v1.vouch(v1root, AGENT, 10 * USDC);
        vm.stopPrank();
        vm.prank(agentOp);
        uint256 bad = v1.borrow(AGENT, 5 * USDC, 1 days, agentOp);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        v1.markDefault(bad);
        uint256 backing0 = pool.backing(VAULT_ID);
        uint256 before = priors.balanceOf(staker);
        pool.importFromV1(AGENT);
        assertTrue(pool.getAgent(AGENT).defaulted);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Settled));
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertEq(pool.getAgent(VAULT_ID).delegatedOut, 0, "the whole line came back");
        assertGe(pool.backing(VAULT_ID), backing0, "the vault lost nothing");
    }
}
