// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StockVault.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// Per-stock loan-to-value and the record bonus: a steadier stock lends more, and an agent that repaid credit a
/// trusted backer (the treasury, the seat vault) took the risk on needs less collateral. Its own stock lines and a
/// root it funds itself never count.
contract StockVaultLtvTest is StockVaultBase {
    address trustOwner = makeAddr("trustOwner");
    uint256 TRUST; // a trusted root (the treasury on chain)

    function setUp() public override {
        super.setUp();
        usdc.mint(trustOwner, 1000 * USDC);
        vm.startPrank(trustOwner);
        TRUST = reg.register("treasury");
        usdc.approve(address(pool), type(uint256).max);
        pool.enrollRoot(TRUST, 500 * USDC);
        vm.stopPrank();
    }

    function _consentFor(uint256 id, uint256 pk, uint256 sponsor)
        internal
        view
        returns (CreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: sponsor,
            owner: vm.addr(pk),
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: block.timestamp + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    /// The agent borrows `principal` for `term` on a line `sponsor` vouched, and repays it on time.
    function _repaidLoanUnder(uint256 sponsor, address sponsorOwner, uint256 principal, uint64 term) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, AGENT_PK, sponsor);
        vm.prank(sponsorOwner);
        pool.vouchWithConsent(sponsor, AGENT, principal, 0, c, sig);
        vm.prank(agentOp);
        uint256 loanId = pool.borrow(AGENT, principal, term, agentOp, type(uint256).max);
        vm.warp(block.timestamp + term);
        vm.prank(agentOp);
        pool.repay(loanId, AGENT, type(uint256).max);
        vm.prank(sponsorOwner);
        pool.unvouch(sponsor, AGENT, principal);
        spyFeed.set(600e8, block.timestamp); // a fresh round after the warp
    }

    function _trustBonus(uint16 perStep, uint16 max) internal {
        uint256[] memory roots = new uint256[](1);
        roots[0] = TRUST;
        vm.prank(owner);
        vault.setRecordBonus(roots, USDC / 20, perStep, max); // a step per 0.05 USDG of fees paid under the treasury
    }

    /// SPY's own loan-to-value (setAsset carries it, with the feed and cap the base set it up with).
    function _setSpyLtv(uint16 bps) internal {
        vm.prank(owner);
        vault.setAsset(address(spy), address(spyFeed), 1 days + 1 hours, true, bps, type(uint128).max);
    }

    // ---- per-stock loan-to-value ----

    function test_assetLtv_setsTheLine_andTheBorrowLimit() public {
        _setSpyLtv(3000);
        assertEq(vault.ltvOf(AGENT, address(spy)), 3000);
        assertEq(_open(AGENT_PK, AGENT, SHARE / 2), 90 * USDC); // $300 of SPY at 30%

        _setSpyLtv(5000);
        assertEq(vault.ltvOf(AGENT2, address(spy)), 5000);
        assertEq(_open(AGENT2_PK, AGENT2, SHARE / 2), 150 * USDC);
    }

    function test_assetLtv_loweredOnAnOpenLine_limitsLoansNotTheLine() public {
        assertEq(_open(AGENT_PK, AGENT, SHARE / 2), 150 * USDC); // at the default 50%
        _setSpyLtv(3000);
        assertEq(vault.getPosition(AGENT).line, 150 * USDC); // what was vouched stays
        assertEq(vault.borrowRoom(AGENT), 90 * USDC); // loans are checked at 30% now
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT, 95 * USDC, 7 days, agentOp, type(uint256).max);
        _borrow(agentOp, AGENT, 90 * USDC);
    }

    function test_assetLtv_ownerOnly_bounded() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setAsset(address(spy), address(spyFeed), 1 days + 1 hours, true, 3000, type(uint128).max);
        vm.startPrank(owner);
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setAsset(address(spy), address(spyFeed), 1 days + 1 hours, true, 7001, type(uint128).max); // > MAX_LTV_BPS
        vm.stopPrank();
        _setSpyLtv(7000);
        assertEq(vault.ltvOf(0, address(0xBEEF)), 0); // a token never accepted lends nothing
    }

    // ---- the record bonus ----

    function test_recordBonus_fromLoansTheTrustedRootBacked_raisesTheLine() public {
        _repaidLoanUnder(TRUST, trustOwner, 100 * USDC, 30 days); // fee 1 USDG, 0.25 to the sponsor
        assertEq(pool.feesFrom(TRUST, AGENT), USDC / 4);
        assertEq(vault.recordBonusBps(AGENT), 0); // off until the owner sets it
        _trustBonus(100, 1500);
        assertEq(vault.recordBonusBps(AGENT), 500); // 5 steps of 0.05
        assertEq(vault.ltvOf(AGENT, address(spy)), 5500);
        assertEq(vault.ltvOf(AGENT2, address(spy)), 5000); // no record, no bonus
        assertEq(vault.ltvOf(0, address(spy)), 5000);
        assertEq(_open(AGENT_PK, AGENT, SHARE / 2), 165 * USDC); // $300 at 55% (the agent moved from the treasury)
        _borrow(agentOp, AGENT, 165 * USDC);
    }

    function test_recordBonus_cappedByMaxBonus_andByMaxLtv() public {
        _repaidLoanUnder(TRUST, trustOwner, 100 * USDC, 30 days);
        _trustBonus(100, 300);
        assertEq(vault.recordBonusBps(AGENT), 300);
        _trustBonus(2000, 2000);
        assertEq(vault.recordBonusBps(AGENT), 2000);
        _setSpyLtv(6000);
        assertEq(vault.ltvOf(AGENT, address(spy)), 7000); // 60% + 20% capped at 70%
    }

    function test_recordBonus_ignoresLoansOnTheVaultsOwnLines() public {
        _trustBonus(100, 1500);
        _open(AGENT_PK, AGENT, 2 * SHARE);
        for (uint256 i; i < 3; ++i) {
            uint256 loanId = _borrow(agentOp, AGENT, 100 * USDC);
            vm.warp(block.timestamp + 7 days);
            vm.prank(agentOp);
            pool.repay(loanId, AGENT, type(uint256).max);
            spyFeed.set(600e8, block.timestamp);
        }
        assertGt(pool.feesFrom(VAULT_ID, AGENT), 0);
        assertEq(vault.recordBonusBps(AGENT), 0);
        assertEq(vault.ltvOf(AGENT, address(spy)), 5000);
    }

    function test_recordBonus_ignoresARootTheOwnerFundsItself() public {
        _trustBonus(100, 1500);
        vm.startPrank(agentOp);
        uint256 own = reg.register("my own root");
        pool.enrollRoot(own, 50 * USDC);
        vm.stopPrank();
        _repaidLoanUnder(own, agentOp, 20 * USDC, 30 days);
        assertGt(pool.feesFrom(own, AGENT), 0);
        assertEq(vault.recordBonusBps(AGENT), 0);
    }

    function test_setRecordBonus_refusesOwnRoot_nonRoots_duplicates_tooMany_andBadSteps() public {
        uint256[] memory roots = new uint256[](1);
        vm.startPrank(owner);
        roots[0] = VAULT_ID;
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, USDC, 100, 1500); // this vault's own root
        roots[0] = AGENT;
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, USDC, 100, 1500); // not a root
        roots[0] = 0;
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, USDC, 100, 1500);
        uint256[] memory two = new uint256[](2);
        two[0] = TRUST;
        two[1] = TRUST;
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(two, USDC, 100, 1500); // listed twice
        uint256[] memory five = new uint256[](5);
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(five, USDC, 100, 1500); // more than MAX_TRUSTED_ROOTS
        roots[0] = TRUST;
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, USDC, 100, 2001); // above MAX_BONUS_BPS
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, 0, 100, 1500); // no step
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, 999, 100, 1500); // a step under MIN_BONUS_FEE_STEP
        vm.expectRevert(StockVault.InvalidParams.selector);
        vault.setRecordBonus(roots, USDC, 0, 1500);
        vault.setRecordBonus(roots, 0, 0, 0); // off
        vault.setRecordBonus(roots, USDC, 100, 1500);
        vm.stopPrank();
        assertEq(vault.trustedRoots().length, 1);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setRecordBonus(roots, USDC, 100, 1500);
    }

    function test_recordBonus_scalesWithTheStocksOwnLtv() public {
        _repaidLoanUnder(TRUST, trustOwner, 100 * USDC, 30 days);
        _trustBonus(100, 1500); // +5 points on a 50% stock
        _setSpyLtv(2500); // a volatile name: half the default, half the bonus
        assertEq(vault.ltvOf(AGENT, address(spy)), 2750);
        assertEq(_open(AGENT_PK, AGENT, SHARE / 2), 825 * USDC / 10); // $300 at 27.5%
        _setSpyLtv(6000); // above the default: never more than the full bonus
        assertEq(vault.ltvOf(AGENT, address(spy)), 6500);
    }
}
