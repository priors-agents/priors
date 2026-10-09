// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {V5Base} from "./V5Base.sol";
import {C} from "../../src/v5/V5Types.sol";

/// @title V5GasMeter
/// @notice The gas audit's GasMeter (test/audit2/gas/GasMeter.sol), in the builders' suite: the smallest budget of one
///         CALL from the pool's address, every touched account and slot cold, that reproduces the full-gas call's
///         storage writes and return data.
abstract contract V5GasMeter is Test {
    struct Write {
        address account;
        bytes32 slot;
        bytes32 value;
    }

    struct Meter {
        uint256 minGas; // the smallest CALL budget that reproduces the full-gas result
        uint256 fullUsed; // gas the full-gas call used (cold)
    }

    /// @dev What the reference run touched and wrote. Kept in memory: `vm.revertToState` also reverts this contract's
    ///      own storage.
    struct Ref {
        address[] touched;
        uint256 nTouched;
        Write[] writes;
        uint256 nWrites;
        bytes32 retHash;
    }

    function _coolAll(Ref memory r) internal {
        for (uint256 i; i < r.nTouched; i++) {
            vm.cool(r.touched[i]);
        }
    }

    function _sameWrites(Ref memory r) private view returns (bool) {
        for (uint256 i; i < r.nWrites; i++) {
            if (vm.load(r.writes[i].account, r.writes[i].slot) != r.writes[i].value) return false;
        }
        return true;
    }

    /// @dev Records the reference run (what it touched, its writes and its return data, with `hi` gas), then bisects
    ///      the budget in [0, hi]. State is restored after.
    function _measure(address from, address to, bytes memory data, uint256 hi) internal returns (Meter memory m) {
        return _measureAfter(_noPrep, from, to, data, hi);
    }

    function _noPrep() internal {}

    /// @dev The same, with `prep` run after the cooling and before the measured call, in the same transaction: what
    ///      the caller's own transaction touched before the call (the pool's `markDefault` before its hook) is warm,
    ///      as it is on chain.
    function _measureAfter(function() internal prep, address from, address to, bytes memory data, uint256 hi)
        internal
        returns (Meter memory m)
    {
        uint256 snap = vm.snapshotState();
        Ref memory r = _reference(prep, from, to, data, hi);
        vm.revertToState(snap);
        // the full-gas call, cold
        m.fullUsed = _coldCall(r, prep, from, to, data, hi);
        vm.revertToState(snap);
        m.minGas = _bisect(r, prep, from, to, data, hi, snap);
        vm.deleteStateSnapshot(snap);
    }

    /// @dev The accounts a measured call may touch: the rig's contracts (the test names them) and every contract whose
    ///      address is PUSH20'd in their code (V5's linked libraries), recursively. A false positive only cools an
    ///      extra account. (vm.startStateDiffRecording would list them exactly, but on forge 1.5.1 it leaves every
    ///      later vm.cool without effect; vm.record does not.)
    function _meterAccounts() internal view virtual returns (address[] memory);

    function _expand(address[] memory base) internal view returns (address[] memory out, uint256 n) {
        out = new address[](256);
        for (uint256 i; i < base.length; i++) {
            n = _push(out, n, base[i]);
        }
        for (uint256 k; k < n; k++) {
            bytes memory code = out[k].code;
            for (uint256 p; p + 21 <= code.length; p++) {
                uint8 op = uint8(code[p]);
                if (op == 0x73) {
                    uint160 a;
                    for (uint256 q = 1; q <= 20; q++) {
                        a = (a << 8) | uint160(uint8(code[p + q]));
                    }
                    if (a > 0xffff && address(a).code.length > 0) n = _push(out, n, address(a));
                    p += 20;
                } else if (op >= 0x60 && op <= 0x7f) {
                    p += op - 0x5f; // skip other PUSH data
                }
            }
        }
    }

    function _push(address[] memory out, uint256 n, address a) private view returns (uint256) {
        if (a == address(this) || a == address(vm) || n == out.length) return n;
        for (uint256 i; i < n; i++) {
            if (out[i] == a) return n;
        }
        out[n] = a;
        return n + 1;
    }

    function _reference(function() internal prep, address from, address to, bytes memory data, uint256 hi)
        private
        returns (Ref memory r)
    {
        (r.touched, r.nTouched) = _expand(_meterAccounts());
        _coolAll(r);
        prep();
        vm.record();
        vm.prank(from);
        (bool ok0, bytes memory ret0) = to.call{gas: hi}(data);
        require(ok0, "GasMeter: the reference call failed");
        r.retHash = keccak256(ret0);
        r.writes = new Write[](512);
        uint256 reads;
        for (uint256 i; i < r.nTouched; i++) {
            (bytes32[] memory rd, bytes32[] memory wr) = vm.accesses(r.touched[i]);
            reads += rd.length;
            for (uint256 j; j < wr.length && r.nWrites < 512; j++) {
                r.writes[r.nWrites++] = Write(r.touched[i], wr[j], vm.load(r.touched[i], wr[j]));
            }
        }
        vm.stopRecord();
        emit log_named_uint("GasMeter: accounts cooled", r.nTouched);
        emit log_named_uint("GasMeter: storage reads recorded", reads);
    }

    function _coldCall(Ref memory r, function() internal prep, address from, address to, bytes memory data, uint256 g)
        private
        returns (uint256 used)
    {
        _coolAll(r);
        prep();
        vm.prank(from);
        uint256 g0 = gasleft();
        (bool ok,) = to.call{gas: g}(data);
        used = g0 - gasleft();
        require(ok, "GasMeter: the cold call failed");
    }

    function _try(Ref memory r, function() internal prep, address from, address to, bytes memory data, uint256 g)
        private
        returns (bool)
    {
        _coolAll(r);
        prep();
        vm.prank(from);
        (bool ok, bytes memory ret) = to.call{gas: g}(data);
        return ok && keccak256(ret) == r.retHash && _sameWrites(r);
    }

    function _bisect(
        Ref memory r,
        function() internal prep,
        address from,
        address to,
        bytes memory data,
        uint256 hi,
        uint256 snap
    ) private returns (uint256) {
        uint256 lo = 0;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            bool good = _try(r, prep, from, to, data, mid);
            vm.revertToState(snap);
            if (good) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _pct(uint256 used, uint256 limit) internal pure returns (uint256) {
        return used * 10_000 / limit; // basis points of the limit
    }
}

/// @dev Gas bounds at the worst reachable state (2.3, V5-HOOKS, question 4; deep audit I-04 and L-01). Each scenario
///      builds its state in `setUp` (its own transaction, so every slot's original value for EIP-2200/3529 pricing is
///      the state the call meets, as on chain: first writes are priced 0 → x), then measures the call the way the pool
///      makes it: one CALL with a fixed budget from the pool's address, every account and slot it touches cooled, the
///      budget bisected to the smallest that reproduces the full-gas call's writes and return data (V5GasMeter, the gas
///      audit's GasMeter). Asserted: every hook within the pool's 300,000 with a 15% margin (255,000), `canBorrow`
///      within question 4's 200,000.
///        forge test --match-path test/v5/V5Gas.t.sol -vv
///      (Not part of test/v5/coverage.sh: an unoptimized build prices differently.)
abstract contract V5GasBase is V5Base, V5GasMeter {
    uint256 internal constant HOOK_GAS = 300_000; // CreditPoolV2's HOOK_GAS
    uint256 internal constant HOOK_MAX = 255_000; // with a 15% margin
    uint256 internal constant CAN_BORROW_MAX = 200_000; // question 4
    uint256 internal id;
    uint256 internal _dl;

    function _agentCount() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public virtual override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
        _open(id, 150_001 * T);
        _back(backer1, id, 50_000 * T);
        _skipFresh(1 days + 1);
        v5.pokeFees(id);
    }

    function _meterAccounts() internal view override returns (address[] memory a) {
        a = new address[](11);
        a[0] = address(v5);
        a[1] = address(pool);
        a[2] = address(usdg);
        a[3] = address(priors);
        a[4] = address(reg);
        a[5] = address(pm);
        a[6] = address(sizer);
        a[7] = address(limiter);
        a[8] = address(swapper);
        a[9] = address(permit2);
        a[10] = C.DEAD;
    }

    function _report(string memory what, Meter memory m, uint256 limit) internal {
        emit log_named_uint(string.concat(what, ": min budget, cold"), m.minGas);
        assertLe(m.minGas, limit, what);
    }

    // the pool's own call made first in the measured transaction, V5's hook failing

    function _prepMarkDefault() internal {
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onDefault.selector), "skip");
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onRelease.selector), "skip");
        pool.markDefault(_dl);
        vm.clearMockedCalls();
    }

    function _prepLeave() internal {
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onRelease.selector), "skip");
        vm.prank(_owner(id));
        pool.leave(id);
        vm.clearMockedCalls();
    }

    function _prepBorrow() internal {
        vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onBorrow.selector), "skip");
        _borrowRaw(id, 10 * U, 8 days);
        vm.clearMockedCalls();
    }

    /// @dev Two loans, the first repaid (its fees in the pool, not split), the second past its grace; `unseen`: the
    ///      second's onBorrow failed; a pending bucket of the owner and its own backing.
    function _defaultState(bool unseen, bool split) internal {
        _back(_owner(id), id, 20_000 * T);
        vm.prank(_owner(id));
        v5.refresh(id);
        uint256 l1 = _borrowRaw(id, 10 * U, 8 days);
        if (unseen) vm.mockCallRevert(address(v5), abi.encodeWithSelector(v5.onBorrow.selector), "starved");
        _dl = _borrowRaw(id, 30 * U, 8 days);
        vm.clearMockedCalls();
        _skip(1 days);
        _repay(l1);
        _skip(11 days + 1);
        if (split) v5.pokeFees(id);
    }

    function _onDefaultData() internal view returns (bytes memory) {
        return abi.encodeCall(v5.onDefault, (ROOT, id, _dl, 30 * U, true));
    }
}

/// @notice onDefault's worst state (deep audit L-01): V5's first default (its breaker day, `recordedDefaults` and
///         `burned` 0 → x), a loan V5 never saw (the pool's `getLoan`, the record's fields), the book's first split due
///         (deferred to the next first steps), three layers and a pending bucket; burn() working and failing.
contract V5GasOnDefaultWorstTest is V5GasBase {
    function setUp() public override {
        super.setUp();
        _defaultState(true, false);
    }

    function test_gas_onDefault_worst() public {
        Meter memory m = _measureAfter(_prepMarkDefault, address(pool), address(v5), _onDefaultData(), 3_000_000);
        _report("onDefault worst (unseen loan, first split due, first default)", m, HOOK_MAX);
        priors.setBurnBroken(true);
        Meter memory b = _measureAfter(_prepMarkDefault, address(pool), address(v5), _onDefaultData(), 3_000_000);
        _report("onDefault worst, burn() failing (the dead-address fallback)", b, HOOK_MAX);
    }
}

/// @notice A loan V5 saw, the book's first split due, the first default (the audit's 90.2% row before the fix).
contract V5GasOnDefaultSeenTest is V5GasBase {
    function setUp() public override {
        super.setUp();
        _defaultState(false, false);
    }

    function test_gas_onDefault_seen_firstSplitDue() public {
        Meter memory m = _measureAfter(_prepMarkDefault, address(pool), address(v5), _onDefaultData(), 3_000_000);
        _report("onDefault (seen loan, first split due)", m, HOOK_MAX);
    }
}

/// @notice onBorrow at its worst: a generation's first loan in a new room epoch whose open room was used.
contract V5GasOnBorrowTest is V5GasBase {
    function setUp() public override {
        super.setUp();
        uint256 other = agents[1];
        _open(other, 150_001 * T);
        _skipFresh(1 days + 1);
        vm.prank(_owner(other));
        v5.refresh(other);
        _borrowRaw(other, 10 * U, 8 days);
        _skipFresh(7 days);
        vm.prank(_owner(id));
        v5.refresh(id);
    }

    function test_gas_onBorrow_firstLoan() public {
        bytes memory data = abi.encodeCall(v5.onBorrow, (ROOT, id, pool.loanCount() + 1));
        Meter memory m = _measureAfter(_prepBorrow, address(pool), address(v5), data, 3_000_000);
        _report("onBorrow (first loan, room epoch roll)", m, HOOK_MAX);
    }
}

/// @notice onRelease: the close in the hook (a flag, its time and its P).
contract V5GasOnReleaseTest is V5GasBase {
    function test_gas_onRelease_close() public {
        bytes memory data = abi.encodeCall(v5.onRelease, (ROOT, id, 0, 1));
        Meter memory m = _measureAfter(_prepLeave, address(pool), address(v5), data, 3_000_000);
        _report("onRelease (close in the hook)", m, HOOK_MAX);
    }
}

/// @notice canBorrow's worst approving path: LIST_CAP - 1 listed open loans read, the delegate recorded 24 h ago,
///         Stage 3's premium check on, every check run; the pool's staticcall, cold.
contract V5GasCanBorrowTest is V5GasBase {
    address internal del;

    function setUp() public override {
        super.setUp();
        del = makeAddr("delegate");
        vm.prank(_owner(id));
        pool.setDelegate(id, del);
        v5.noteDelegate(id);
        vm.startPrank(timelock);
        v5.setPremiumCap(0);
        v5.setPremiumCheck(true);
        vm.stopPrank();
        _skipFresh(7 days + 1);
        vm.prank(_owner(id));
        v5.refresh(id);
        for (uint256 i = 0; i < C.LIST_CAP - 1; i++) {
            _borrowRaw(id, 10 * U, 8 days);
        }
    }

    function test_gas_canBorrow_worstApprovingPath() public {
        address o = _owner(id);
        bytes memory data = abi.encodeCall(v5.canBorrow, (ROOT, id, 10 * U, 10 days, 1, del, o, o));
        (, bytes memory r) = address(v5).staticcall(data);
        assertTrue(abi.decode(r, (bool)), "approves");
        Meter memory m = _measure(address(pool), address(v5), data, 3_000_000);
        _report("canBorrow (LIST_CAP - 1 listed, delegate, premium check)", m, CAN_BORROW_MAX);
    }
}

