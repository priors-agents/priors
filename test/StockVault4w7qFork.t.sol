// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {StockVault, StockVaultHolds} from "../src/StockVault.sol";
import {PtLinearDiscountFeed} from "../src/PtLinearDiscountFeed.sol";

/// GHSA-4w7q-8vph-j5mr on the live vault, its live PT-USDG feed and its one open PT-USDG position (agent #20023, its
/// line drawn as loan #49544, defaultable from 2026-11-14 02:53:50 UTC), at the latest block FORK_RPC serves:
///   FORK_RPC=<rpc> forge test --match-path test/StockVault4w7qFork.t.sol -vv
/// The tape is recorded once (current, as the keeper keeps it), then the feed is pushed 1,100 rounds at its live pace
/// (one an hour, which anyone may) with nobody recording the tape, past the loan's defaultableAt: the default waits for
/// the tape (TapeBehind) until anyone records it, then settles. On mainnet as it runs (SV-20's implementation
/// 0x9E80…d1a6) the seizure takes the whole deposit; on a fork where this source was put live through the timelock
/// (sim/tape-upgrade.mjs --upgrade 4w7q --fork) it takes what is owed plus the buffer at the feed's price and gives the
/// rest back. Skipped without FORK_RPC.
contract StockVault4w7qForkTest is Test {
    StockVault constant VAULT = StockVault(0xbEcd07EC689988e16b870C121756C4c2C8cb02B6);
    CreditPoolV2 constant POOL = CreditPoolV2(0x281210097f0de7A8FB6F87310AF0f089c9C8DE21);
    PtLinearDiscountFeed constant FEED = PtLinearDiscountFeed(0x95961f54F9c8a29A1393ADB5719053C98914B259);
    address constant PT = 0x6982e39521A070a3C40782548bfBED6Dc8F566ef;
    uint256 constant AGENT = 20023;
    uint256 constant LOAN = 49544;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function test_fork_livePtPosition_resumedTapePastTheRing_defaultSeizesOwedPlusBuffer() public {
        if (!forked) vm.skip(true);
        emit log_named_address("implementation", address(uint160(uint256(vm.load(address(VAULT), IMPL_SLOT)))));
        emit log_named_address("holds", address(VAULT.holds()));
        StockVault.Position memory p = VAULT.getPosition(AGENT);
        assertEq(p.token, PT, "the live PT-USDG position");
        assertEq(uint256(p.status), uint256(StockVault.Status.Open));
        CreditPoolV2.Loan memory l = POOL.getLoan(LOAN);
        assertEq(l.agentId, AGENT);
        assertEq(uint256(l.status), uint256(CreditPoolV2.LoanStatus.Active), "its loan is open");

        StockVaultHolds holds = VAULT.holds();
        holds.record(address(FEED), 10_000); // current, as the keeper keeps it
        (uint80 last,) = holds.tapes(address(FEED));
        assertEq(last, FEED.latestRound());
        assertEq(VAULT.lendStatus(PT), 0, "PT credit lends");
        for (uint256 i; i < 1100; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            FEED.push(); // nobody records the tape
        }
        assertGt(vm.getBlockTimestamp(), l.defaultableAt, "past the loan's defaultableAt");
        vm.expectRevert(abi.encodeWithSelector(PtLinearDiscountFeed.NoRound.selector, last + 1));
        FEED.getRoundData(last + 1); // the round after the tape's last: dropped from the ring

        address seizeTo = VAULT.seizeTo();
        uint256 s0 = IERC20(PT).balanceOf(seizeTo);
        uint256 d0 = IERC20(PT).balanceOf(p.depositor);
        POOL.markDefault(LOAN); // the vault's hook reverts TapeBehind: the position waits, the whole deposit with it
        assertEq(uint256(VAULT.getPosition(AGENT).status), uint256(StockVault.Status.Open), "waiting");
        vm.expectRevert(abi.encodeWithSelector(StockVault.TapeBehind.selector, address(FEED)));
        VAULT.settle(AGENT, 0);

        holds.record(address(FEED), 10_000); // anyone: the only way to let the waiting default settle
        (uint80 through,) = holds.tapes(address(FEED));
        assertEq(through, FEED.latestRound(), "the tape is current again");
        l = POOL.getLoan(LOAN);
        uint256 owed = l.principal + l.fee;
        (, int256 answer,,,) = FEED.latestRoundData();
        uint256 buffer = VAULT.seizeBufferOf(PT);
        // PT 6 decimals, the feed 18: ceil(owed * (1 + buffer) / price) in PT base units, as SV-11 states it
        uint256 fair = Math.mulDiv(owed * (10_000 + buffer), 1e18, 10_000 * uint256(answer), Math.Rounding.Ceil);
        VAULT.settle(AGENT, 0);
        uint256 seized = IERC20(PT).balanceOf(seizeTo) - s0;
        uint256 returned = IERC20(PT).balanceOf(p.depositor) - d0;
        emit log_named_uint("deposit (PT base units)", p.amount);
        emit log_named_uint("owed (USDG base units)", owed);
        emit log_named_uint("buffer (bps)", buffer);
        emit log_named_uint("owed + buffer in PT at the feed's price", fair);
        emit log_named_uint("seized PT", seized);
        emit log_named_uint("returned PT", returned);
        assertEq(seized, fair, "SV-11: owed + buffer at the price");
        assertEq(seized + returned, p.amount, "the rest back to the depositor");
        assertEq(VAULT.lendStatus(PT), 0, "no hold: the price is linear");
    }
}
