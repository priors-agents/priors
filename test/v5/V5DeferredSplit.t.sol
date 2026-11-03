// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {C} from "../../src/v5/V5Types.sol";

/// @dev The split a settle inside `onDefault` defers (deep audit L-01; docs/PRIORS-UNDERWRITING-SPEC.md 2.6): the
///      generation's next first steps split every fee observed since the mark, "a repayment of the agent's other loan"
///      between the default and those steps included, so the positions' fees never depend on which call marked the
///      default. Fees observed after the deferred split go all to the buffer. Reviewed for GHSA-xcqr-5gw3-vfv4.
contract V5DeferredSplitTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
    }

    /// @dev A settle in the hook and a settle after a failed hook credit the holders the same fees: those of the
    ///      other loan repaid before V5's next first steps included.
    function test_deferredSplit_hookAndFailedHookPaths_creditTheSame() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 10 * U, 8 days);
        uint256 b = _borrow(id, 10 * U, 10 days);
        _borrow(id, 10 * U, 10 days); // left open: no onRelease when b is repaid
        _skipFresh(11 days + 1);
        uint256 snap = vm.snapshotState();
        (uint256 o0,,,,,,) = lens.totals();
        pool.markDefault(a); // the hook settles, the split deferred
        assertTrue(_gen(id).splitPending);
        _repay(b);
        v5.pokeFees(id);
        (uint256 o1,,,,,,) = lens.totals();
        uint256 viaHook = o1 - o0;
        vm.revertToState(snap);
        (o0,,,,,,) = lens.totals();
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "hook failed");
        pool.markDefault(a); // the pool records the default, V5's hook fails
        vm.clearMockedCalls();
        _repay(b);
        v5.settle(id, 1, a); // anyone's settle: it splits first, then burns
        (o1,,,,,,) = lens.totals();
        assertEq(_gen(id).status, C.SETTLED);
        assertGt(o1 - o0, 0, "the other loan's fee is split to the holders on this path");
        assertEq(viaHook, o1 - o0, "the positions' fees do not depend on which call marked the default");
    }

    /// @dev Once the deferred split has run (any first steps: the keeper pokes a settled book's fees), a later fee
    ///      is all buffer.
    function test_deferredSplit_afterItRan_laterFeesAllBuffer() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 20 * U, 8 days);
        uint256 b = _borrow(id, 20 * U, 10 days);
        _skipFresh(11 days + 1);
        pool.markDefault(a);
        v5.pokeFees(id);
        assertFalse(_gen(id).splitPending);
        (uint256 owed0, uint256 buf0,,,,,) = lens.totals();
        uint256 idx0 = _gen(id).index;
        _repay(b);
        uint256 fee = pool.feesFrom(ROOT, id);
        v5.pokeFees(id);
        (uint256 owed1, uint256 buf1,,,,,) = lens.totals();
        assertEq(owed1, owed0, "no holder credit");
        assertEq(buf1 - buf0, fee, "all of it to the buffer");
        assertEq(_gen(id).index, idx0);
    }
}
