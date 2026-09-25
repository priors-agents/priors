// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../src/SeatVaultV3.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {MockPriors} from "./helpers/TokenMocks.sol";
import {SeatVaultV3Base} from "./SeatVaultV3.t.sol";

/// Whether a seat burns for a default on v1 depends on the ORDER of three independent calls, not on what happened.
///
/// `SeatVaultV3MigrationTest` pins one order: the agent was never imported, it defaults on v1 while seated, then
/// someone imports it, which ORs `defaulted` into v2 and settles the seat (half the tokens burnt). These pin the
/// other two orders, which return every token for the same v1 default:
///   A. the agent was imported BEFORE the v1 default: `importFromV1` runs once per agent, so v2 never learns of it;
///   B. the staker closes after the v1 default but before anyone imports: v2 does not know yet, the seat closes.
/// So the burn is not a deterrent a staker can count on either way, and v2's USDG lost nothing in every order.
/// The deciding lines: CreditPoolV2.importFromV1 (once only; ORs `defaulted`, then `_settleDead` -> onRelease),
/// PoolV2Lib.v1Clean (blocks new v2 borrows while v1 shows a default), SeatVaultV3.onRelease / close.
contract SeatVaultV3V1DefaultOrderTest is SeatVaultV3Base {
    CreditPool v1;
    uint256 v1root;

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
        // a v1 root that vouches the agent on v1, which also gives it a v1 record
        vm.startPrank(rootOp);
        v1root = reg.register("v1root");
        usdc.approve(address(v1), type(uint256).max);
        v1.enrollRoot(v1root, 100 * USDC);
        v1.vouch(v1root, AGENT, 10 * USDC);
        vm.stopPrank();
    }

    function _defaultOnV1() internal {
        vm.prank(agentOp);
        uint256 bad = v1.borrow(AGENT, 5 * USDC, 1 days, agentOp);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        v1.markDefault(bad);
        assertTrue(v1.getAgent(AGENT).defaulted, "not defaulted on v1");
    }

    /// A. Imported clean first; the later v1 default is never carried to v2, and the staker gets every token back.
    function test_A_importedBeforeTheV1Default_seatReturnsEveryToken() public {
        pool.importFromV1(AGENT); // clean on v1 at this point: activeLoans 0, not defaulted
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _defaultOnV1();

        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AlreadyImported.selector, AGENT));
        pool.importFromV1(AGENT);
        assertFalse(pool.getAgent(AGENT).defaulted, "v2 learned of the v1 default after all");

        // v2 still refuses to lend to it: v1Clean reads v1 on every borrow
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.V1Busy.selector, AGENT));
        pool.borrow(AGENT, 5 * USDC, 1 days, agentOp, 1 * USDC);

        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.close(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed), "seat did not close");
        assertEq(priors.balanceOf(staker), before + SEAT, "staker lost tokens to a v1 default");
    }

    /// B. Not imported yet; the staker closes before anyone imports, and gets every token back.
    function test_B_stakerClosesBeforeTheImport_seatReturnsEveryToken() public {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _defaultOnV1();

        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.close(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed), "seat did not close");
        assertEq(priors.balanceOf(staker), before + SEAT, "staker lost tokens to a v1 default");

        // the import still records the default afterwards; the closed seat is untouched
        pool.importFromV1(AGENT);
        assertTrue(pool.getAgent(AGENT).defaulted);
        assertEq(priors.balanceOf(staker), before + SEAT);
    }
}
