// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {CreditPoolV2Base} from "../CreditPoolV2.t.sol";

/// F-1 (Medium), the launch-time mitigation. `markDefault` pays `keeperBounty` from the reserve to whoever calls it,
/// while the backer is only charged the principal its own agents already walked off with. A root that defaults its
/// own throwaway agents therefore nets one bounty per default (ReviewPoolV2.test_F1_keeperBountyFarmedBySelfDefault).
///
/// The same loop, run at the bounty the migration runbook deploys with (0), has nothing to farm. That is the
/// mitigation this repo can apply without touching the audited contract; the permanent fix (charge the bounty to
/// the defaulting backer's stake instead of the reserve, a change to spec §12) is left to the v2 author.
contract F1KeeperBountyMitigationTest is CreditPoolV2Base {
    uint256 constant N = 10;

    function _farm(uint256 bounty) internal returns (int256 profit, uint256 reserveSpent) {
        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(pool), 100 * USDC);
        pool.fundReserve(100 * USDC);

        CreditPoolV2.Params memory p = pool.getParams();
        p.keeperBounty = bounty;
        vm.prank(owner);
        pool.setParams(p);

        address atk = makeAddr("attacker");
        uint256 stake = N * 5 * USDC + 1 * USDC;
        usdc.mint(atk, stake);
        vm.startPrank(atk);
        usdc.approve(address(pool), type(uint256).max);
        uint256 rootId = reg.register("atk-root");
        pool.enrollRoot(rootId, stake);
        vm.stopPrank();

        uint256 reserveBefore = pool.reserve();
        uint256[] memory loans = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            uint256 pk = 0x6000 + i;
            address o = vm.addr(pk);
            vm.prank(o);
            uint256 id = reg.register("throwaway");
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, rootId, pk, 0);
            vm.prank(atk);
            pool.vouchWithConsent(rootId, id, 5 * USDC, 0, c, sig);
            vm.prank(o);
            loans[i] = pool.borrow(id, 5 * USDC, 1 days, atk, type(uint256).max);
        }
        vm.warp(pool.getLoan(loans[N - 1]).defaultableAt + 1);
        vm.startPrank(atk);
        for (uint256 i = 0; i < N; i++) {
            pool.markDefault(loans[i]);
        }
        pool.unlock(rootId, pool.rootShares(rootId), atk);
        vm.stopPrank();

        profit = int256(usdc.balanceOf(atk)) - int256(stake);
        reserveSpent = reserveBefore - pool.reserve();
    }

    /// RED: at the constant cap the loop is profitable, one bounty per self-default, paid by the reserve. Since the
    /// 2026-09-24 fee lock each self-default also burns the loan's unpaid fee, far below the bounty at the cap.
    function test_F1_atMaxBounty_selfDefaultIsProfitable() public {
        uint256 cap = pool.MAX_KEEPER_BOUNTY();
        (uint256 fee,,,) = pool.quoteFee(0, 5 * USDC, 1 days); // premium 0: every throwaway's loan quotes this
        (int256 profit, uint256 spent) = _farm(cap);
        assertEq(spent, N * cap, "reserve pays one bounty per self-default");
        assertGt(profit, int256(N * (cap - fee)) - int256(N), "attacker keeps the bounties, less the fees");
    }

    /// GREEN: at keeperBounty = 0 (the runbook's launch value) the same loop earns nothing and the reserve is untouched.
    function test_F1_atZeroBounty_selfDefaultEarnsNothing() public {
        (int256 profit, uint256 spent) = _farm(0);
        assertEq(spent, 0, "reserve paid something with no bounty");
        assertLe(profit, 0, "self-default is profitable with no bounty");
    }
}
