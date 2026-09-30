// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {StockVault} from "../src/StockVault.sol";
import {StockVaultBase, MockFeed} from "./StockVault.t.sol";

interface IProxyAdminU {
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

/// An 18-decimal stock token with the issuer's `adminBurn` (the live Robinhood tokens have it, ADMIN_BURNER_ROLE).
contract BurnStock is ERC20 {
    constructor() ERC20("BURN", "BURN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// Regression for GHSA-cwm2-g4fh-wvf2 and GHSA-wh68-cx3m-5r7p. The properties, not a particular fix:
///   RC-1: an issuer burn is carried by the positions it hit. A deposit made after it (open or addCollateral) is
///         either refused or paid back whole, and never pays an earlier position (on close or on seizure).
///   RC-2: after a burn, a loan stays within the loan-to-value of what the position would actually be paid.
/// Token at $1, 50% loan-to-value; A and B each hold 200 tokens.
contract StockVaultShortfallTest is StockVaultBase {
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103; // ERC-1967
    BurnStock tok;
    MockFeed feed;
    uint256 constant ONE = 1e18;

    function setUp() public override {
        super.setUp();
        // PVR2_IMPL="<file>.sol:StockVault": upgrade the proxy (through its ProxyAdmin, as `owner`) to that build,
        // e.g. test/pvr2/variants/StockVaultDeployed.sol (the deployed source) or StockVaultFixed.sol. Unset: src/.
        string memory art = vm.envOr("PVR2_IMPL", string(""));
        if (bytes(art).length != 0) {
            address impl = deployCode(art, abi.encode(address(pool)));
            address admin = address(uint160(uint256(vm.load(address(vault), ADMIN_SLOT))));
            vm.prank(owner);
            IProxyAdminU(admin).upgradeAndCall(address(vault), impl, "");
        }
        tok = new BurnStock();
        feed = new MockFeed(8, 1e8);
        vm.prank(owner);
        vault.setAsset(address(tok), address(feed), 1 days + 1 hours, true, 5000, type(uint128).max);
        tok.mint(agentOp, 200 * ONE);
        tok.mint(agentOp2, 200 * ONE);
        vm.prank(agentOp);
        tok.approve(address(vault), type(uint256).max);
        vm.prank(agentOp2);
        tok.approve(address(vault), type(uint256).max);
    }

    function _openT(uint256 pk, uint256 id, uint256 amount) internal returns (uint256) {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(vm.addr(pk));
        return vault.open(id, address(tok), amount, c, sig);
    }

    /// true if the vault took the deposit
    function _tryOpenT(uint256 pk, uint256 id, uint256 amount) internal returns (bool) {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(vm.addr(pk));
        try vault.open(id, address(tok), amount, c, sig) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _closeT(address op, uint256 id) internal returns (uint256 got) {
        uint256 before = tok.balanceOf(op);
        vm.prank(op);
        vault.close(id);
        got = tok.balanceOf(op) - before;
    }

    // ---- RC-1 ----

    function test_depositAfterBurn_neverPaysTheEarlierShortfall() public {
        _openT(AGENT_PK, AGENT, 100 * ONE);
        tok.adminBurn(address(vault), 60 * ONE); // A's 100 are now worth 40
        bool bIn = _tryOpenT(AGENT2_PK, AGENT2, 100 * ONE);

        uint256 a = _closeT(agentOp, AGENT);
        assertApproxEqAbs(a, 40 * ONE, 1, "A gets what the burn left it, not B's tokens");
        if (bIn) {
            assertApproxEqAbs(_closeT(agentOp2, AGENT2), 100 * ONE, 1, "B's deposit comes back whole");
        } else {
            assertEq(tok.balanceOf(agentOp2), 200 * ONE, "B's tokens never left");
            // the refusal lasts only while the burn is unpaid: with A gone, B opens and is paid back whole
            _openT(AGENT2_PK, AGENT2, 100 * ONE);
            assertEq(_closeT(agentOp2, AGENT2), 100 * ONE, "B, after the shortfall is paid out");
        }
    }

    function test_topUpAfterBurn_isPaidBackWhole_andSubsidizesNoOne() public {
        _openT(AGENT_PK, AGENT, 100 * ONE);
        _openT(AGENT2_PK, AGENT2, 100 * ONE);
        tok.adminBurn(address(vault), 60 * ONE); // each position is now worth 70
        uint256 added;
        vm.prank(agentOp);
        try vault.addCollateral(AGENT, 60 * ONE) {
            added = 60 * ONE;
        } catch {}
        assertApproxEqAbs(_closeT(agentOp, AGENT), 70 * ONE + added, 1, "A: its 70, plus any top-up whole");
        assertApproxEqAbs(_closeT(agentOp2, AGENT2), 70 * ONE, 1, "B: its 70, no more, no less");
    }

    function test_defaultAfterBurn_seizesOnlyItsOwnShare_neverALaterDeposit() public {
        _openT(AGENT_PK, AGENT, 100 * ONE);
        tok.adminBurn(address(vault), 60 * ONE);
        bool bIn = _tryOpenT(AGENT2_PK, AGENT2, 100 * ONE);
        uint256 room = vault.borrowRoom(AGENT);
        uint256 loanId = _borrow(agentOp, AGENT, room);
        vm.warp(pool.getLoan(loanId).defaultableAt + 1);
        pool.markDefault(loanId);
        assertEq(uint256(vault.getPosition(AGENT).status), uint256(StockVault.Status.Seized));
        assertApproxEqAbs(tok.balanceOf(treasury), 40 * ONE, 1, "seized: A's 40, none of B's");
        if (bIn) assertApproxEqAbs(_closeT(agentOp2, AGENT2), 100 * ONE, 1, "B's deposit comes back whole");
    }

    // ---- RC-2 ----

    function test_afterBurn_loansStayWithinLtvOfWhatThePositionIsPaid() public {
        uint256 line = _openT(AGENT_PK, AGENT, 100 * ONE);
        assertEq(line, 50 * USDC);
        tok.adminBurn(address(vault), 50 * ONE); // the position is now paid 50 tokens: $50, so $25 at 50%
        uint256 limit = 25 * USDC;
        assertLe(vault.borrowRoom(AGENT), limit, "borrowRoom quotes the collateral the position still has");
        assertFalse(
            vault.canBorrow(VAULT_ID, AGENT, limit + 1, 7 days, 0, agentOp, agentOp, agentOp),
            "canBorrow refuses past the loan-to-value of what is left"
        );
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT, limit + 1, 7 days, agentOp, type(uint256).max);
        _borrow(agentOp, AGENT, limit); // still lends within it, as after a price fall
    }
}
