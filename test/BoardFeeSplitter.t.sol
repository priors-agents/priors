// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BoardFeeSplitter} from "../src/BoardFeeSplitter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {FreezableUSDG} from "./mocks/FreezableUSDG.sol";

/// @dev A recipient contract with no receive and no fallback.
contract NoHooks {}

contract BoardFeeSplitterTest is Test {
    uint256 constant USDG = 1e6;
    MockUSDC usdg;
    MockUSDC other;
    BoardFeeSplitter splitter;
    address owner = makeAddr("owner");
    address engines = makeAddr("engines");
    address treasury = makeAddr("treasury");
    address anyone = makeAddr("anyone");

    function setUp() public {
        usdg = new MockUSDC();
        other = new MockUSDC();
        splitter = new BoardFeeSplitter(IERC20(address(usdg)), engines, treasury, 5_000, owner);
    }

    // ------------------------------------------------------------------
    // split
    // ------------------------------------------------------------------

    function test_split_sendsHalfToEachSide() public {
        usdg.mint(address(splitter), 2 * USDG); // two sales' fees at the 1 USDG minimum
        vm.prank(anyone);
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(toEngines, USDG);
        assertEq(toTreasury, USDG);
        assertEq(usdg.balanceOf(engines), USDG);
        assertEq(usdg.balanceOf(treasury), USDG);
        assertEq(usdg.balanceOf(address(splitter)), 0);
        assertEq(splitter.totalToEngines(), USDG);
        assertEq(splitter.totalToTreasury(), USDG);
    }

    function test_split_roundsTheOddUnitToTheTreasury() public {
        usdg.mint(address(splitter), 3);
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(toEngines, 1);
        assertEq(toTreasury, 2);
    }

    function test_split_withNothingSendsNothing() public {
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(toEngines, 0);
        assertEq(toTreasury, 0);
        assertEq(usdg.balanceOf(engines), 0);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_split_emitsWhatEachSideGot() public {
        usdg.mint(address(splitter), 10 * USDG);
        vm.expectEmit(address(splitter));
        emit BoardFeeSplitter.Split(anyone, 5 * USDG, 5 * USDG);
        vm.prank(anyone);
        splitter.split();
    }

    function test_splittable_matchesSplit() public {
        usdg.mint(address(splitter), 7 * USDG + 1);
        (uint256 e, uint256 t) = splitter.splittable();
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(e, toEngines);
        assertEq(t, toTreasury);
    }

    function testFuzz_split_sidesAddUpToWhatArrived(uint256 amount, uint256 bps) public {
        amount = bound(amount, 0, 1e15 * USDG);
        bps = bound(bps, 0, 10_000);
        BoardFeeSplitter s = new BoardFeeSplitter(IERC20(address(usdg)), engines, treasury, bps, owner);
        usdg.mint(address(s), amount);
        (uint256 toEngines, uint256 toTreasury) = s.split();
        assertEq(toEngines + toTreasury, amount);
        assertEq(toEngines, (amount * bps) / 10_000);
        assertEq(usdg.balanceOf(address(s)), 0);
    }

    // ------------------------------------------------------------------
    // settings: the 48 h queue
    // ------------------------------------------------------------------

    function test_queueSettings_appliesAfter48Hours() public {
        address newEngines = makeAddr("newEngines");
        vm.prank(owner);
        splitter.queueSettings(newEngines, treasury, 7_000);
        (,,, uint64 readyAt) = splitter.pendingSettings();
        assertEq(readyAt, block.timestamp + 48 hours);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.SettingsNotReady.selector, readyAt));
        splitter.applySettings();

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        splitter.applySettings();
        assertEq(splitter.engines(), newEngines);
        assertEq(splitter.engineBps(), 7_000);
        (,,, uint64 after_) = splitter.pendingSettings();
        assertEq(after_, 0);

        usdg.mint(address(splitter), 10 * USDG);
        splitter.split();
        assertEq(usdg.balanceOf(newEngines), 7 * USDG);
        assertEq(usdg.balanceOf(treasury), 3 * USDG);
    }

    function test_queueSettings_requeueStartsANew48Hours() public {
        vm.startPrank(owner);
        splitter.queueSettings(engines, treasury, 6_000);
        vm.warp(block.timestamp + 40 hours);
        splitter.queueSettings(engines, treasury, 4_000);
        vm.warp(block.timestamp + 8 hours);
        (,,, uint64 readyAt) = splitter.pendingSettings();
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.SettingsNotReady.selector, readyAt));
        splitter.applySettings();
        vm.warp(readyAt);
        splitter.applySettings();
        vm.stopPrank();
        assertEq(splitter.engineBps(), 4_000);
    }

    function test_cancelSettings_dropsTheQueuedChange() public {
        vm.startPrank(owner);
        splitter.queueSettings(engines, treasury, 9_000);
        splitter.cancelSettings();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(BoardFeeSplitter.NoPendingSettings.selector);
        splitter.applySettings();
        vm.expectRevert(BoardFeeSplitter.NoPendingSettings.selector);
        splitter.cancelSettings();
        vm.stopPrank();
        assertEq(splitter.engineBps(), 5_000);
    }

    function test_settings_onlyTheOwner() public {
        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        splitter.queueSettings(engines, treasury, 9_000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        splitter.applySettings();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        splitter.cancelSettings();
        vm.stopPrank();
    }

    function test_settings_refuseBadValues() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.BadBps.selector, 10_001));
        splitter.queueSettings(engines, treasury, 10_001);
        vm.expectRevert(BoardFeeSplitter.ZeroAddress.selector);
        splitter.queueSettings(address(0), treasury, 5_000);
        vm.expectRevert(BoardFeeSplitter.ZeroAddress.selector);
        splitter.queueSettings(engines, address(0), 5_000);
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.BadAddress.selector, address(splitter)));
        splitter.queueSettings(address(splitter), treasury, 5_000);
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.BadAddress.selector, address(splitter)));
        splitter.queueSettings(engines, address(splitter), 5_000);
        vm.stopPrank();
    }

    function test_constructor_refusesBadValues() public {
        vm.expectRevert(BoardFeeSplitter.ZeroAddress.selector);
        new BoardFeeSplitter(IERC20(address(0)), engines, treasury, 5_000, owner);
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.BadBps.selector, 10_001));
        new BoardFeeSplitter(IERC20(address(usdg)), engines, treasury, 10_001, owner);
        vm.expectRevert(BoardFeeSplitter.ZeroAddress.selector);
        new BoardFeeSplitter(IERC20(address(usdg)), address(0), treasury, 5_000, owner);
    }

    // ------------------------------------------------------------------
    // rescue
    // ------------------------------------------------------------------

    function test_rescue_neverUsdg() public {
        usdg.mint(address(splitter), 5 * USDG);
        vm.prank(owner);
        vm.expectRevert(BoardFeeSplitter.RescueUsdg.selector);
        splitter.rescue(IERC20(address(usdg)), owner);
        assertEq(usdg.balanceOf(address(splitter)), 5 * USDG);
    }

    function test_rescue_sendsAnotherTokenOn() public {
        other.mint(address(splitter), 3 * USDG);
        vm.prank(owner);
        splitter.rescue(IERC20(address(other)), owner);
        assertEq(other.balanceOf(owner), 3 * USDG);
        assertEq(other.balanceOf(address(splitter)), 0);
    }

    function test_rescue_onlyTheOwner() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        splitter.rescue(IERC20(address(other)), anyone);
    }

    // ------------------------------------------------------------------
    // the deploy review (2026-10-29): recipients, other assets, dust, the owner
    // ------------------------------------------------------------------

    /// USDG is an ERC-20 without transfer hooks: a recipient contract with no receive and no fallback takes its share
    /// like any account, since nothing calls into a recipient.
    function test_split_toContractsWithoutHooks() public {
        address e = address(new NoHooks());
        address t = address(new NoHooks());
        BoardFeeSplitter s = new BoardFeeSplitter(IERC20(address(usdg)), e, t, 5_000, owner);
        usdg.mint(address(s), 3 * USDG);
        s.split();
        assertEq(usdg.balanceOf(e), 1_500_000);
        assertEq(usdg.balanceOf(t), 1_500_000);
    }

    /// A transfer USDG itself refuses (a frozen recipient) reverts the whole split: both shares stay here, nothing is
    /// lost, and once the owner points that side elsewhere (48 h) everything leaves.
    function test_split_aFrozenRecipientHoldsBothSharesUntilTheOwnerRepoints() public {
        FreezableUSDG f = new FreezableUSDG();
        BoardFeeSplitter s = new BoardFeeSplitter(IERC20(address(f)), engines, treasury, 5_000, owner);
        f.mint(address(s), 4 * USDG);
        f.setFrozen(treasury, true);
        vm.expectRevert(abi.encodeWithSelector(FreezableUSDG.Frozen.selector, treasury));
        s.split();
        assertEq(f.balanceOf(address(s)), 4 * USDG);
        assertEq(f.balanceOf(engines), 0);

        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        s.queueSettings(engines, newTreasury, 5_000);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        s.applySettings();
        s.split();
        assertEq(f.balanceOf(engines), 2 * USDG);
        assertEq(f.balanceOf(newTreasury), 2 * USDG);
        assertEq(f.balanceOf(address(s)), 0);
    }

    /// No receive, no fallback, nothing payable: plain ETH sent here is refused.
    function test_eth_refused() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(splitter).balance, 0);
    }

    /// The markets' new minimum fee, 0.25 USDG (MECHANICS.md 6.4): one fee at the minimum splits exactly in two.
    function test_split_aFeeAtThe25CentMinimum() public {
        usdg.mint(address(splitter), 250_000);
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(toEngines, 125_000);
        assertEq(toTreasury, 125_000);
    }

    /// Anyone may split any balance at any time: a split of one unit sends it to the treasury, a split of nothing sends
    /// nothing, and neither changes what a later split sends.
    function test_split_dustByAnyoneChangesNothingLater() public {
        usdg.mint(address(splitter), 1);
        vm.prank(anyone);
        (uint256 toEngines, uint256 toTreasury) = splitter.split();
        assertEq(toEngines, 0);
        assertEq(toTreasury, 1);
        vm.prank(anyone);
        splitter.split();
        usdg.mint(address(splitter), 10 * USDG);
        splitter.split();
        assertEq(usdg.balanceOf(engines), 5 * USDG);
        assertEq(usdg.balanceOf(treasury), 5 * USDG + 1);
        assertEq(splitter.totalToEngines() + splitter.totalToTreasury(), 10 * USDG + 1);
    }

    /// Ownable2Step: a new owner must accept, and even then changes the split only through the 48 h queue.
    function test_ownership_twoStepsAndStillTheQueue() public {
        address next = makeAddr("next");
        vm.prank(owner);
        splitter.transferOwnership(next);
        assertEq(splitter.owner(), owner);
        assertEq(splitter.pendingOwner(), next);
        vm.prank(next);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), next);

        vm.startPrank(next);
        splitter.queueSettings(engines, next, 0);
        (,,, uint64 readyAt) = splitter.pendingSettings();
        vm.expectRevert(abi.encodeWithSelector(BoardFeeSplitter.SettingsNotReady.selector, readyAt));
        splitter.applySettings();
        vm.stopPrank();
        assertEq(splitter.treasury(), treasury);
        assertEq(splitter.engineBps(), 5_000);
    }
}
