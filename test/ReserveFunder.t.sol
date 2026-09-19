// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {ReserveFunder, ICreditPoolReserve} from "../src/ReserveFunder.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

contract ReserveFunderTest is Test {
    uint256 constant USDC = 1e6;
    MockUSDC usdg;
    MockUSDC other;
    MockPonsFeeEscrow escrow;
    CreditPool pool;
    ReserveFunder funder;
    address owner = makeAddr("owner");
    address trader = makeAddr("trader");
    address launchToken = makeAddr("launchToken");

    function setUp() public {
        usdg = new MockUSDC();
        other = new MockUSDC();
        escrow = new MockPonsFeeEscrow();
        pool = new CreditPool(IERC20(address(usdg)), IERC8004Identity(address(new MockIdentityRegistry())), owner);
        funder = new ReserveFunder(
            ICreditPoolReserve(address(pool)),
            IPonsFeeEscrow(address(escrow)),
            IPonsFactoryCreator(address(escrow)),
            owner
        );
        escrow.setFeeRecipient(launchToken, address(funder));
        usdg.mint(trader, 1_000 * USDC);
        other.mint(trader, 1_000 * USDC);
        vm.startPrank(trader);
        usdg.approve(address(escrow), type(uint256).max);
        other.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }

    function test_sweep_claimsCreatorFeesIntoTheReserve() public {
        vm.prank(trader);
        escrow.creditToken(address(funder), address(usdg), 120 * USDC); // fees swept into escrow by Pons
        assertEq(funder.sweepable(), 120 * USDC);
        vm.prank(makeAddr("anyone"));
        uint256 funded = funder.sweep();
        assertEq(funded, 120 * USDC);
        assertEq(pool.reserve(), 120 * USDC);
        assertEq(funder.totalSwept(), 120 * USDC);
        assertEq(usdg.balanceOf(address(funder)), 0);
        assertEq(escrow.balanceOfToken(address(funder), address(usdg)), 0);
    }

    function test_sweep_alsoForwardsDirectTransfers() public {
        usdg.mint(address(funder), 5 * USDC); // someone sent asset straight here
        assertEq(funder.sweep(), 5 * USDC);
        assertEq(pool.reserve(), 5 * USDC);
        assertEq(funder.sweep(), 0); // nothing left; no revert
    }

    function test_rescue_otherAssetsAndEth_ownerOnly() public {
        vm.prank(trader);
        escrow.creditToken(address(funder), address(other), 7 * USDC);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        escrow.credit{value: 0.3 ether}(address(funder));

        vm.prank(trader);
        vm.expectRevert();
        funder.rescue(address(other), trader);

        address to = makeAddr("treasury");
        vm.prank(owner);
        funder.rescue(address(other), to);
        assertEq(other.balanceOf(to), 7 * USDC);
        vm.prank(owner);
        funder.rescue(address(0), to);
        assertEq(to.balance, 0.3 ether);

        vm.prank(owner);
        vm.expectRevert(bytes("use sweep"));
        funder.rescue(address(usdg), to);
    }

    function test_transferCreatorFeeRecipient_ownerOnly() public {
        address next = makeAddr("nextFunder");
        vm.prank(trader);
        vm.expectRevert();
        funder.transferCreatorFeeRecipient(launchToken, next);
        vm.prank(owner);
        funder.transferCreatorFeeRecipient(launchToken, next);
        assertEq(escrow.feeRecipientOf(launchToken), next);
    }
}
