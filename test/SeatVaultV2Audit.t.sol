// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV2} from "../src/SeatVaultV2.sol";
import {SeatVaultV2Base} from "./SeatVaultV2.t.sol";

/// @dev An agent's pool delegate that repays its loan and draws the next one in the same transaction.
contract LoanRollerV2 {
    CreditPoolV2 immutable pool;

    constructor(CreditPoolV2 p) {
        pool = p;
        p.usdg().approve(address(p), type(uint256).max);
    }

    function roll(uint256 id, uint256 loanId, uint256 amount, uint64 term) external returns (uint256) {
        if (loanId != 0) pool.repay(loanId, id, type(uint256).max);
        return pool.borrow(id, amount, term, address(this), type(uint256).max);
    }

    function repay(uint256 id, uint256 loanId) external {
        pool.repay(loanId, id, type(uint256).max);
    }
}

/// The findings of the v1 SeatVault review, replayed against v2. What v1 could only document (the squat, the
/// rolling-loan lock, fees priced at the pool's current share) is closed here by the pool's consent, freeze and
/// per-agent fee ledger; the fixes v1 made itself (epoch churn, terms bound to offers) are kept.
contract SeatVaultV2AuditTest is SeatVaultV2Base {
    // ------------------------------------------------------------------
    // The squat is impossible
    // ------------------------------------------------------------------

    /// v1: anyone vouched 1 unit to an agent and pulled it back, and the agent could never be seated. v2: no
    /// line lands without the agent owner's signature, so an existing identity is always seatable.
    function test_squat_impossibleWithoutTheOwnersConsent() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 100 * USDC);
        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        uint256 root = reg.register("griefer-root");
        pool.enrollRoot(root, 10 * USDC);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.WrongSponsor.selector, AGENT, 0));
        pool.vouch(root, AGENT, 1);
        vm.stopPrank();
        // a consent the attacker signs itself is not the owner's
        uint256 attackerPk = 0xBAD;
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, root, attackerPk);
        vm.prank(attacker);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(root, AGENT, 1, 0, c, sig);
        // and one with the right owner but a forged signature
        c.owner = agentOp;
        vm.prank(attacker);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(root, AGENT, 1, 0, c, sig);
        assertTrue(vault.seatable(AGENT));
        _offerAndAccept(staker, AGENT_PK, AGENT);
        assertEq(pool.getAgent(AGENT).sponsor, VAULT_ID);
    }

    /// A consent seen in the mempool cannot be taken by another staker or another backer: accept is the
    /// controller's call, and the pool lets only the named sponsor's owner use a consent.
    function test_consent_cannotBeRedirected() public {
        vm.prank(staker);
        vault.offer(AGENT);
        vm.prank(staker2);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotController.selector, AGENT, staker2));
        vault.accept(AGENT, staker2, c, sig);
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.NotOwnerOf.selector, VAULT_ID, staker2));
        pool.vouchWithConsent(VAULT_ID, AGENT, 5 * USDC, 0, c, sig);
        vm.prank(agentOp);
        vault.accept(AGENT, staker, c, sig);
        assertEq(vault.getSeat(AGENT).staker, staker);
        // used once: after the seat closes, the same consent cannot reopen it
        vm.prank(staker);
        vault.close(AGENT);
        vm.prank(agentOp);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        vault.accept(AGENT, staker2, c, sig);
    }

    /// The vault's EIP-1271 approval exists only inside registerAndSeat. An NFT handed to the vault can never
    /// be vouched on the vault's say-so, by any backer.
    function test_eip1271_theVaultNeverSignsForStrayNFTs() public {
        vm.prank(agentOp2);
        reg.safeTransferFrom(agentOp2, address(vault), AGENT2);
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: AGENT2,
            sponsorId: ROOT,
            owner: address(vault),
            maxPremiumBps: 200,
            nonce: 0,
            deadline: vm.getBlockTimestamp() + 1
        });
        assertEq(vault.isValidSignature(pool.consentDigest(c), ""), bytes4(0xffffffff));
        vm.prank(rootOp);
        vm.expectRevert(CreditPoolV2.BadConsent.selector);
        pool.vouchWithConsent(ROOT, AGENT2, 5 * USDC, 200, c, "");
    }

    // ------------------------------------------------------------------
    // The rolling-loan lock is escapable
    // ------------------------------------------------------------------

    /// v1: an agent that repaid and borrowed again in one transaction kept its seat open for as long as it liked.
    /// v2: the staker closes, the vault freezes the line, the next roll cannot borrow, and the seat closes with
    /// every token the moment the loan is repaid (or settles if it defaults).
    function test_rolling_stakerEscapesViaFreeze() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        LoanRollerV2 roller = new LoanRollerV2(pool);
        usdc.mint(address(roller), 100 * USDC);
        vm.prank(agentOp);
        pool.setDelegate(AGENT, address(roller));
        uint256 loan = roller.roll(AGENT, 0, 5 * USDC, 30 days);
        for (uint256 m = 0; m < 2; m++) {
            vm.warp(vm.getBlockTimestamp() + 30 days);
            loan = roller.roll(AGENT, loan, 5 * USDC, 30 days);
        }
        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.close(AGENT); // with the loan out
        assertTrue(pool.getAgent(AGENT).frozen);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(); // the roll's borrow is refused, so the whole roll reverts
        roller.roll(AGENT, loan, 5 * USDC, 30 days);
        roller.repay(AGENT, loan);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Closed));
        assertEq(priors.balanceOf(staker), before + SEAT, "every token back");
        assertGt(vault.feesOwed(staker), 0, "paid for every roll");
        assertEq(vault.tokensHeld(), 0);
    }

    // ------------------------------------------------------------------
    // Fees are exact per agent, whatever the pool's fee split does
    // ------------------------------------------------------------------

    function _setSponsorBps(uint256 bps) internal {
        CreditPoolV2.Params memory pp = pool.getParams();
        pp.sponsorFeeBps = bps;
        vm.prank(timelock);
        pool.setParams(pp);
    }

    /// v1 priced a seat's fees at the pool's current sponsor share, so a change moved fees between seats unless
    /// skim() ran around it. v2 reads the pool's per-agent ledger: every staker gets exactly the sponsor cut of
    /// its own agent's loans (fixed at borrow), in any order, with no ops rule.
    function test_fees_sponsorShareChangeNeverMovesFeesBetweenSeats() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _offerAndAccept(staker2, AGENT2_PK, AGENT2);
        uint256 a1 = _borrow(agentOp, AGENT, 5 * USDC, 30 days); // at 25%
        uint256 b1 = _borrow(agentOp2, AGENT2, 5 * USDC, 30 days); // at 25%
        _setSponsorBps(5000);
        _repay(agentOp, a1); // repaid under the new split: its cut was fixed at borrow
        uint256 a2 = _borrow(agentOp, AGENT, 5 * USDC, 30 days); // at 50%
        _repay(agentOp, a2);
        _setSponsorBps(0);
        _repay(agentOp2, b1);
        uint256 b2 = _borrow(agentOp2, AGENT2, 5 * USDC, 30 days); // at 0%
        _repay(agentOp2, b2);
        _setSponsorBps(8000);
        // credit in the "wrong" order, with no skim around any change
        vault.poke(AGENT2);
        vault.poke(AGENT);
        uint256 s1 = pool.getLoan(a1).sponsorCut + pool.getLoan(a2).sponsorCut;
        uint256 s2 = pool.getLoan(b1).sponsorCut + pool.getLoan(b2).sponsorCut;
        assertEq(pool.getLoan(a2).sponsorCut, 2 * pool.getLoan(a1).sponsorCut);
        assertEq(pool.getLoan(b2).sponsorCut, 0);
        assertEq(vault.feesOwed(staker), s1);
        assertEq(vault.feesOwed(staker2), s2);
        assertEq(pool.sponsorFees(VAULT_ID), s1 + s2, "every unit the pool paid is credited");
        vm.prank(staker);
        vault.claim(staker);
        vm.prank(staker2);
        vault.claim(staker2);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.skim(), 0, "nothing left for the sink");
    }

    /// v1 gave up a unit per loan to rounding; v2 is exact to the unit, and a raise of the share after the fact
    /// changes nothing.
    function test_fees_exactToTheUnit() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 6 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 paid;
        for (uint256 i = 0; i < 5; i++) {
            uint256 l = _borrow(agentOp, AGENT, 5 * USDC + i * 777, 7 days + uint64(i) * 3601);
            paid += pool.getLoan(l).sponsorCut;
            _repay(agentOp, l);
        }
        _setSponsorBps(8500);
        assertEq(vault.pendingFees(AGENT), paid);
        vault.poke(AGENT);
        assertEq(vault.feesOwed(staker), paid);
    }

    // ------------------------------------------------------------------
    // Kept from v1: epoch churn, terms
    // ------------------------------------------------------------------

    function test_epochCap_notSpentByOpenCloseChurn() public {
        uint256 priorsBefore = priors.balanceOf(agentOp2);
        for (uint256 i = 0; i < 20; i++) {
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
            vm.startPrank(agentOp2);
            vault.seat(AGENT2, c, sig);
            vault.close(AGENT2);
            vm.stopPrank();
        }
        assertEq(priors.balanceOf(agentOp2), priorsBefore);
        assertEq(vault.epochRoom(), 50 * USDC, "a clean close gives its line back to the week");
    }

    /// A graduation is a clean close too: the line is refunded to this epoch.
    function test_epochCap_graduationRefunds() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        assertEq(vault.epochRoom(), 45 * USDC);
        _handoff(AGENT, AGENT_PK, 10 * USDC);
        assertEq(vault.epochRoom(), 50 * USDC);
    }

    function test_epochCap_defaultStaysSpent() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _default(_borrow(agentOp, AGENT, 5 * USDC, 1 days));
        assertEq(vault.epochRoom(), 45 * USDC);
    }

    function test_epochCap_closeInALaterEpochRefundsNothing() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _offerAndAccept(staker2, AGENT2_PK, AGENT2); // new epoch: 5 spent
        vm.prank(staker);
        vault.close(AGENT);
        assertEq(vault.epochRoom(), 45 * USDC);
    }

    // ------------------------------------------------------------------
    // Hooks cannot be spoofed; a default is never a graduation
    // ------------------------------------------------------------------

    /// Another root may point its hook at the vault (it has code), but calls for that root never touch a seat.
    function test_hooks_anotherRootPointingAtTheVaultChangesNothing() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        address attacker = makeAddr("attacker");
        uint256 attackerPk = 0xBAD;
        address attackerOp = vm.addr(attackerPk);
        usdc.mint(attacker, 100 * USDC);
        usdc.mint(attackerOp, 100 * USDC);
        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        uint256 root = reg.register("attacker-root");
        pool.enrollRoot(root, 20 * USDC);
        pool.setHook(root, address(vault));
        vm.stopPrank();
        vm.prank(attackerOp);
        uint256 puppet = reg.register("puppet");
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(puppet, root, attackerPk);
        vm.prank(attacker);
        pool.vouchWithConsent(root, puppet, 10 * USDC, 0, c, sig);
        // the vault's canBorrow refuses the attacker's root: its own borrows are blocked, nothing else
        vm.prank(attackerOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, root));
        pool.borrow(puppet, 5 * USDC, 1 days, attackerOp, type(uint256).max);
        vm.prank(attackerOp);
        pool.leave(puppet); // onRelease(root, ...) to the vault: ignored
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV2.Status.Open));
        assertEq(vault.tokensHeld(), SEAT);
        assertEq(vault.openCount(), 1);
    }

    /// The residual release after a default never hands back the burnt half, and the tokens the vault holds
    /// stay exactly what it owes.
    function test_defaultThenResidual_neverAGraduation() public {
        SeatVaultV2.Params memory p = _params();
        p.line = 10 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(staker2);
        vault.offer(AGENT2);
        uint256 a = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        uint256 b = _borrow(agentOp, AGENT, 5 * USDC, 10 days);
        uint256 before = priors.balanceOf(staker);
        _default(a);
        _repay(agentOp, b);
        assertEq(priors.balanceOf(staker), before + SEAT / 2);
        assertEq(vault.tokensHeld(), SEAT, "only staker2's offer is left");
        assertEq(priors.balanceOf(address(vault)), SEAT);
        // and the dead agent can never be seated again
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.NotSeatable.selector, AGENT));
        vault.offer(AGENT);
    }

    /// The owner can never reach stakers' tokens or fees: not by rescue, not by retiring the stake behind open
    /// lines, not by changing terms after the fact.
    function test_owner_cannotTouchStakersTokensOrFees() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        _repay(agentOp, loan);
        vault.poke(AGENT);
        uint256 owed = vault.feesOwed(staker);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.Protected.selector, address(usdc)));
        vault.rescue(address(usdc), owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV2.Protected.selector, address(priors)));
        vault.rescue(address(priors), owner);
        uint256 all = pool.rootShares(VAULT_ID);
        vm.expectRevert();
        vault.retire(all, owner);
        vault.setFeeSink(owner);
        vault.skim();
        vm.stopPrank();
        assertEq(vault.feesOwed(staker), owed);
        assertEq(usdc.balanceOf(address(vault)) + pool.sponsorFees(VAULT_ID), owed);
        assertEq(priors.balanceOf(address(vault)), SEAT);
        vm.prank(staker);
        assertEq(vault.claim(staker), owed);
    }
}
