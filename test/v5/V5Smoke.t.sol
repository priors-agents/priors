// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C} from "../../src/v5/V5Types.sol";

contract V5SmokeTest is V5Base {
    function test_smoke_openBorrowRepayBackLeaveRelease() public {
        uint256 id = agents[0];
        // k reads 3 under the fail-safe: $50 line needs $150 of A at $0.001 = 150,000 $PRIORS
        _open(id, 150_000 * T);
        S.Gen memory g = _gen(id);
        assertEq(g.status, C.OPEN);
        assertEq(g.openLine, 50 * U);
        assertEq(lens.lineOf(id), 50 * U);
        uint256 loanId = _borrow(id, 40 * U, 8 days);
        assertEq(_gen(id).listLen, 1);
        _skipFresh(7 days);
        _repay(loanId);
        v5.recordRepay(id);
        g = _gen(id);
        assertEq(g.listLen, 0);
        assertEq(g.countedAtTier, 1);
        (uint256 h,,,,,,) = lens.totals();
        assertGt(h, 0);
        // backing (open backing on)
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _back(backer1, id, 10_000 * T);
        _skipFresh(1 days);
        vm.prank(backer1);
        v5.leave(id, 10_000 * T, 0);
        uint32 day = _today();
        _skipFresh(8 days);
        uint256 before = priors.balanceOf(backer1);
        vm.prank(backer1);
        v5.release(id, 1, day, 0, 0);
        assertEq(priors.balanceOf(backer1) - before, 10_000 * T);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        vm.prank(_owner(id));
        v5.collect(ids, gens);
        (uint256 l,) = _ledger();
        assertEq(priors.balanceOf(address(v5)), l);
        assertTrue(_solvent());
    }

    function test_smoke_default_burns() public {
        uint256 id = agents[1];
        _open(id, 150_000 * T);
        _borrow(id, 50 * U, 8 days);
        _skipFresh(12 days);
        uint256 loanId = 0;
        // find the loan: the last one
        loanId = pool.loanCount();
        (bool ok,) = address(pool).call(abi.encodeWithSignature("markDefault(uint256)", loanId));
        assertTrue(ok);
        S.Gen memory g = _gen(id);
        assertEq(g.status, C.SETTLED);
        (,,,,, uint256 burned,) = lens.totals();
        uint256 a = g.tokens[0];
        uint256 own = g.tokens[2];
        assertEq(burned, (a * 7500 + 9999) / 10_000 + (own * 5000 + 9999) / 10_000);
        v5.claimSettled(id, 1, _owner(id));
        (uint256 l,) = _ledger();
        assertEq(priors.balanceOf(address(v5)), l);
    }
}
