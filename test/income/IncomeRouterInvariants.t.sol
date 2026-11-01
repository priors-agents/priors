// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolV2} from "./IPoolV2.sol";
import {IncomeRouter} from "../../src/IncomeRouter.sol";
import {IncomeBase, IssuerUSDG, MockAgentRegistry} from "./IncomeBase.sol";

/// @dev Random sequences of borrows (by an agent's owner or its key), x402 payments into boxes, plans set, changed and
///      left, payouts moved, sweeps (with the exact open-loan list, or a tampered one), repayments by the router, by
///      hand, defaults, releases, agents sold and bought back, syncs, time, the Safe's pause, a payout frozen by the
///      issuer, the issuer's seizures from a box, and USDG donated to the router.
///
///      Every router call that succeeds is checked against the rules of section 2 of
///      docs/proposals/2026-11-01-income-repay-and-inference-on-credit.md, from balances and the pool read around it
///      and from the handler's own model of each agent's epoch (a ghost that never reads the router's). A breach is
///      counted in `violations` (an assert inside a handler would be dropped as a revert); the invariants read it and
///      the ghost ledgers. As test/autopay2/AutoRepayV2Invariants.t.sol.
contract IncomeRouterHandler is Test {
    uint256 constant U = 1e6;
    uint256 constant ALL = 10_000;

    IncomeRouter router;
    IPoolV2 pool;
    MockAgentRegistry reg;
    IssuerUSDG usdg;
    address safe;

    address[] public owners;
    address[] public keys;
    address[] public payouts;
    uint256[] public agents;
    uint256[] public loans;
    address[] internal everyone; // every address whose USDG a call could move

    uint256 public violations;
    string public lastViolation;

    // ghost ledgers
    uint256 public donated;
    uint64 public pauseSetAt;
    uint64 public pauseSetTo;
    uint256 public arrivedTotal;
    uint256 public putTotal;
    uint256 public forwardedTotal;
    mapping(uint256 => uint256) public paidIn; // agentId => USDG paid into its box
    mapping(uint256 => uint256) public seized; // agentId => USDG the issuer took from its box
    mapping(uint256 => uint256) public outForwarded; // agentId => left its box to a payout at a sweep (forward)
    mapping(uint256 => uint256) public outReleased; // agentId => left its box to a payout (release)
    mapping(uint256 => uint256) public outRepaid; // agentId => left its box to the pool
    mapping(uint256 => mapping(address => uint256)) public gPut; // set aside for an owner
    mapping(uint256 => mapping(address => uint256)) public gRepaid; // repaid for that owner's loans
    mapping(uint256 => mapping(address => uint256)) public gReleased; // released to that owner's payout

    // the handler's own model of each agent's epoch: the owner it last saw the router write under, and how many changes
    mapping(uint256 => address) public gOwner;
    mapping(uint256 => uint32) public gEpoch;

    // how often each path ran (printed with INCOME_INV_LOG=1)
    uint256 public sweeps;
    uint256 public sweepsSetAside;
    uint256 public sweepsReleased;
    uint256 public repays;
    uint256 public repaysOfEarlierOwner;
    uint256 public releases;
    uint256 public tamperedRefused;
    uint256 public refusedNotEarliest;
    uint256 public seizures;

    constructor(
        IncomeRouter router_,
        IPoolV2 pool_,
        MockAgentRegistry reg_,
        IssuerUSDG usdg_,
        address safe_,
        address[] memory owners_,
        address[] memory keys_,
        address[] memory payouts_,
        uint256[] memory agents_
    ) {
        router = router_;
        pool = pool_;
        reg = reg_;
        usdg = usdg_;
        safe = safe_;
        owners = owners_;
        keys = keys_;
        payouts = payouts_;
        agents = agents_;
        for (uint256 i = 0; i < owners_.length; i++) {
            everyone.push(owners_[i]);
        }
        for (uint256 i = 0; i < keys_.length; i++) {
            everyone.push(keys_[i]);
        }
        for (uint256 i = 0; i < payouts_.length; i++) {
            everyone.push(payouts_[i]);
        }
        for (uint256 i = 0; i < agents_.length; i++) {
            everyone.push(router_.incomeAddressOf(agents_[i]));
        }
        everyone.push(address(pool_));
        everyone.push(address(router_));
    }

    function _breach(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    function _agent(uint256 s) internal view returns (uint256) {
        return agents[s % agents.length];
    }

    function _box(uint256 id) internal view returns (address) {
        return router.incomeAddressOf(id);
    }

    function _due(IPoolV2.Loan memory l) internal pure returns (uint256) {
        return l.principal + l.fee;
    }

    /// The model's sync, after the router wrote under the registry's owner (it syncs first, the same way).
    function _gSync(uint256 id) internal {
        address o = reg.ownerOf(id);
        if (o != gOwner[id]) {
            gOwner[id] = o;
            gEpoch[id]++;
        }
    }

    function _gEpochNow(uint256 id) internal view returns (uint32) {
        return reg.ownerOf(id) != gOwner[id] ? gEpoch[id] + 1 : gEpoch[id];
    }

    function _open(uint256 id) internal view returns (uint256[] memory list) {
        uint256[] memory all = pool.loansOf(id);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (pool.getLoan(all[i]).status == IPoolV2.LoanStatus.Active) n++;
        }
        list = new uint256[](n);
        n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (pool.getLoan(all[i]).status == IPoolV2.LoanStatus.Active) list[n++] = all[i];
        }
    }

    /// The dues of `o`'s open loans of the agent within `cap` (the need before what is set aside).
    function _dues(uint256 id, address o, uint256 cap) internal view returns (uint256 dues) {
        uint256[] memory list = _open(id);
        for (uint256 i = 0; i < list.length; i++) {
            IPoolV2.Loan memory l = pool.getLoan(list[i]);
            if (l.owner == o && _due(l) <= cap) dues += _due(l);
        }
    }

    function _balances() internal view returns (uint256[] memory b) {
        b = new uint256[](everyone.length);
        for (uint256 i = 0; i < everyone.length; i++) {
            b[i] = usdg.balanceOf(everyone[i]);
        }
    }

    /// Every address's USDG moved by exactly the expected deltas (an address listed twice gets their sum), and no
    /// other address's at all.
    function _checkMoves(uint256[] memory before, address[3] memory who, int256[3] memory delta, string memory why)
        internal
    {
        for (uint256 i = 0; i < everyone.length; i++) {
            int256 want;
            for (uint256 j = 0; j < 3; j++) {
                if (who[j] == everyone[i]) want += delta[j];
            }
            if (int256(usdg.balanceOf(everyone[i])) - int256(before[i]) != want) _breach(why);
        }
    }

    function _setAsides(uint256 id) internal view returns (uint256[] memory s) {
        s = new uint256[](owners.length);
        for (uint256 i = 0; i < owners.length; i++) {
            s[i] = router.setAsideOf(id, owners[i]);
        }
    }

    /// Only `o`'s set-aside moved, by `delta`: exactly in a pot that never lost anything, within one unit of rounding
    /// after a write-down.
    function _checkSetAsides(uint256 id, uint256[] memory before, address o, int256 delta, string memory why) internal {
        int256 slack = seized[id] == 0 ? int256(0) : int256(1);
        for (uint256 i = 0; i < owners.length; i++) {
            int256 want = owners[i] == o ? delta : int256(0);
            int256 got = int256(router.setAsideOf(id, owners[i])) - int256(before[i]);
            if (got > want + slack || got < want - slack) _breach(why);
        }
    }

    // ---- the world ----

    function borrow(uint256 agentSeed, uint256 amountSeed, uint256 termSeed) public {
        uint256 id = _agent(agentSeed);
        // the owner's account, or the agent's own key (its pool delegate since the last sale)
        address by = amountSeed % 3 == 0 ? keys[agentSeed % keys.length] : reg.ownerOf(id);
        uint64[4] memory terms = [uint64(1 days), 7 days, 7 days + 6 hours, 14 days];
        uint256 amount = bound(amountSeed, 5 * U, 40 * U);
        vm.prank(by);
        try pool.borrow(id, amount, terms[termSeed % terms.length], by, type(uint256).max) returns (uint256 loanId) {
            loans.push(loanId);
        } catch {}
    }

    /// x402 income: USDG lands in the box, deployed or not, with no call to it.
    /// Income never refills a set-aside: what is set aside, every owner's and in total, is the same before and after
    /// money arrives (a recorded write-down stays written down).
    function pay(uint256 agentSeed, uint256 amount) public {
        uint256 id = _agent(agentSeed);
        amount = amount % 7 == 0 ? bound(amount, 0, 3) : bound(amount, 0, 60 * U); // dust too
        uint256 total = router.setAsideTotal(id);
        uint256[] memory sa = _setAsides(id);
        usdg.mint(_box(id), amount);
        paidIn[id] += amount;
        if (router.setAsideTotal(id) != total) _breach("a deposit changed what is set aside");
        for (uint256 i = 0; i < owners.length; i++) {
            if (router.setAsideOf(id, owners[i]) != sa[i]) _breach("a deposit refilled an owner's set-aside");
        }
    }

    function enroll(uint256 agentSeed, uint256 partySeed, uint256 share, uint256 cap, bool early) public {
        uint256 id = _agent(agentSeed);
        address o = partySeed % 5 == 0 ? owners[partySeed % owners.length] : reg.ownerOf(id);
        bool owns = reg.ownerOf(id) == o;
        share = share % 4 == 0 ? ALL : bound(share, 0, ALL);
        cap = cap % 4 == 1 ? bound(cap, 1, 20 * U) : bound(cap, 41 * U, 100 * U); // mostly above every loan's due
        address to = payouts[(partySeed / 5) % payouts.length];
        vm.prank(o);
        try router.enroll(id, share, to, cap, early) {
            if (!owns) _breach("enroll by someone other than the registry owner");
            _gSync(id);
            (,,, uint32 e, bool on,) = router.planOf(id, o);
            if (e != gEpoch[id] || !on) _breach("a plan written in another epoch than the model's");
        } catch {
            if (owns) _breach("enroll refused for the registry owner");
        }
    }

    function leave(uint256 agentSeed, uint256 partySeed) public {
        uint256 id = _agent(agentSeed);
        address o = owners[partySeed % owners.length];
        vm.prank(o);
        try router.leave(id) {
            (,,,, bool on,) = router.planOf(id, o);
            if (on) _breach("leave: plan still on");
        } catch {
            _breach("leave reverted");
        }
    }

    function setPayout(uint256 agentSeed, uint256 partySeed, uint256 payoutSeed) public {
        uint256 id = _agent(agentSeed);
        address o = owners[partySeed % owners.length];
        address to = payouts[payoutSeed % payouts.length];
        (address had,,,,,) = router.planOf(id, o);
        vm.prank(o);
        try router.setPayout(id, to) {
            if (had == address(0)) _breach("setPayout without a plan");
        } catch {
            if (had != address(0)) _breach("setPayout refused to the plan's owner");
        }
    }

    function sell(uint256 agentSeed, uint256 toSeed) public {
        uint256 id = _agent(agentSeed);
        address from = reg.ownerOf(id);
        address to = owners[toSeed % owners.length];
        if (to == from) return;
        vm.prank(from);
        reg.transferFrom(from, to, id);
        if (toSeed % 3 == 0) {
            vm.prank(to);
            reg.transferFrom(to, from, id); // bought straight back
        }
        // the new owner names the agent's key its delegate (a sale lapses it), so the key can borrow again
        address now_ = reg.ownerOf(id);
        vm.prank(now_);
        pool.setDelegate(id, keys[agentSeed % keys.length]);
    }

    function sync(uint256 agentSeed) public {
        uint256 id = _agent(agentSeed);
        try router.sync(id) returns (uint256 e) {
            _gSync(id);
            if (e != gEpoch[id]) _breach("the router's epoch differs from the model's");
        } catch {
            _breach("sync refused");
        }
    }

    function warp(uint256 dt) public {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }

    function repayByHand(uint256 loanSeed) public {
        if (loans.length == 0) return;
        _repayByHand(loans[loanSeed % loans.length], owners[loanSeed % owners.length]);
    }

    function _repayByHand(uint256 loanId, address p) internal {
        IPoolV2.Loan memory l = pool.getLoan(loanId);
        if (l.status != IPoolV2.LoanStatus.Active) return;
        usdg.mint(p, _due(l));
        vm.startPrank(p);
        usdg.approve(address(pool), _due(l));
        pool.repay(loanId, l.agentId, _due(l));
        vm.stopPrank();
    }

    function markDefault(uint256 loanSeed) public {
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        IPoolV2.Loan memory l = pool.getLoan(loanId);
        // rare: a default bars its owner from borrowing again, and the handler has three owners
        if (l.status != IPoolV2.LoanStatus.Active || loanSeed % 20 != 0) return;
        if (block.timestamp <= l.defaultableAt) vm.warp(l.defaultableAt + 1);
        pool.markDefault(loanId);
    }

    function pause(uint256 untilSeed) public {
        // an eighth of the calls pause (up to a day past the bound, which must be refused); the rest lift it
        uint64 until = untilSeed % 8 != 0 ? 0 : uint64(block.timestamp + bound(untilSeed, 0, 15 days));
        vm.prank(safe);
        try router.pause(until) {
            if (until > block.timestamp + 14 days) _breach("a pause over 14 days");
            pauseSetAt = uint64(block.timestamp);
            pauseSetTo = until;
        } catch {
            if (until <= block.timestamp + 14 days) _breach("a pause within 14 days refused");
        }
    }

    /// The issuer freezes or unfreezes a payout (mostly unfrozen).
    function freezePayout(uint256 seed) public {
        usdg.freeze(payouts[seed % payouts.length], seed % 8 == 1);
    }

    /// The issuer takes USDG from a box (rare); the keeper sees it and records the write-down (`sync`). Every owner's
    /// set-aside only falls, and what is set aside fits the balance.
    function seize(uint256 agentSeed, uint256 amount) public {
        if (agentSeed % 8 != 0) return;
        uint256 id = _agent(agentSeed);
        uint256 b = usdg.balanceOf(_box(id));
        amount = bound(amount, 0, b);
        uint256[] memory sa = _setAsides(id);
        usdg.seize(_box(id), amount);
        seized[id] += amount;
        seizures++;
        router.sync(id);
        _gSync(id);
        for (uint256 i = 0; i < owners.length; i++) {
            if (router.setAsideOf(id, owners[i]) > sa[i]) _breach("a seizure raised a set-aside");
        }
        (uint256 recorded,,) = router.potOf(id);
        if (recorded > usdg.balanceOf(_box(id))) _breach("a sync left the pot above the box's balance");
    }

    function donate(uint256 amount) public {
        amount = bound(amount, 0, 5 * U);
        usdg.mint(address(router), amount);
        donated += amount;
    }

    // ---- the router's calls, checked ----

    struct SweepCtx {
        uint256 id;
        address o;
        address to;
        uint256 share;
        uint256 dues;
        uint256 held;
        uint256 bal;
        uint256 total;
        bool planOk;
        bool tampered;
        uint256[] sa;
        uint256[] before;
    }

    function sweep(uint256 agentSeed, uint256 mode) public {
        (SweepCtx memory c, uint256[] memory list) = _sweepCtx(agentSeed, mode);
        vm.prank(keeper());
        try router.sweep(c.id, list) returns (uint256 arrived, uint256 put, uint256 fwd, uint256 rel) {
            _afterSweep(c, arrived, put, fwd, rel);
        } catch {
            if (c.tampered) tamperedRefused++;
        }
    }

    function _afterSweep(SweepCtx memory c, uint256 arrived, uint256 put, uint256 fwd, uint256 rel) internal {
        sweeps++;
        _gSync(c.id);
        if (c.tampered) _breach("a sweep with a tampered open-loan list");
        if (!c.planOk) _breach("a sweep without a plan of the current owner, in its epoch");
        if (block.timestamp < router.pausedUntil()) _breach("a sweep while paused");
        _checkSweep(c, arrived, put, fwd, rel);
        _checkMoves(
            c.before,
            [_box(c.id), c.to, address(0)],
            [-int256(fwd + rel), int256(fwd + rel), int256(0)],
            "a sweep moved USDG other than from the box to the owner's payout"
        );
        _checkSetAsides(c.id, c.sa, c.o, int256(put) - int256(rel), "a sweep moved another owner's set-aside");
        arrivedTotal += arrived;
        putTotal += put;
        forwardedTotal += fwd;
        outForwarded[c.id] += fwd;
        outReleased[c.id] += rel;
        gPut[c.id][c.o] += put;
        gReleased[c.id][c.o] += rel;
        if (put > 0) sweepsSetAside++;
        if (rel > 0) sweepsReleased++;
    }

    function _sweepCtx(uint256 agentSeed, uint256 mode)
        internal
        view
        returns (SweepCtx memory c, uint256[] memory list)
    {
        c.id = _agent(agentSeed);
        c.o = reg.ownerOf(c.id);
        list = _open(c.id);
        // mostly the exact list; sometimes one that hides, repeats or swaps in a loan (must be refused)
        if (mode % 16 == 1 && list.length > 0) {
            uint256[] memory shorter = new uint256[](list.length - 1);
            for (uint256 i = 0; i + 1 < list.length; i++) {
                shorter[i] = list[i + 1];
            }
            list = shorter; // hides the first
            c.tampered = true;
        } else if (mode % 16 == 2 && list.length > 1) {
            list[list.length - 1] = list[0]; // repeats the first
            c.tampered = true;
        } else if (mode % 16 == 3 && list.length > 0 && loans.length > 0) {
            uint256 other = loans[(mode / 16) % loans.length];
            IPoolV2.Loan memory ol = pool.getLoan(other);
            if (ol.agentId != c.id || ol.status != IPoolV2.LoanStatus.Active) {
                list[list.length - 1] = other; // a loan of another agent, or a closed one
                c.tampered = true;
            }
        }
        (address to, uint16 share, uint32 cap, uint32 e, bool on,) = router.planOf(c.id, c.o);
        c.to = to;
        c.share = share;
        c.planOk = on && e == _gEpochNow(c.id);
        c.dues = _dues(c.id, c.o, cap);
        c.held = router.setAsideOf(c.id, c.o);
        c.bal = usdg.balanceOf(_box(c.id));
        c.total = router.setAsideTotal(c.id);
        c.sa = _setAsides(c.id);
        c.before = _balances();
    }

    function _checkSweep(SweepCtx memory c, uint256 arrived, uint256 put, uint256 fwd, uint256 rel) internal {
        // 2.3: new money is the balance beyond every owner's set-aside; split once, between set-aside and forward
        uint256 fresh = c.bal > c.total ? c.bal - c.total : 0;
        if (arrived != fresh) _breach("arrived is not the balance beyond the set-asides");
        if (put + fwd != arrived) _breach("new money not split exactly once");
        uint256 need = c.dues > c.held ? c.dues - c.held : 0;
        uint256 shareUp = (arrived * c.share + ALL - 1) / ALL;
        if (put != (need < shareUp ? need : shareUp)) _breach("set-aside is not min(need, share rounded up)");
        // step 6: what is held beyond the need goes out, all of it
        uint256 excess = c.held > c.dues ? c.held - c.dues : 0;
        if (rel != excess) _breach("the excess not released exactly");
        uint256 slack = seized[c.id] == 0 ? 0 : 1; // the rounding a write-down allows
        if (router.setAsideOf(c.id, c.o) > c.dues + slack) _breach("set-aside above the need");
    }

    struct RepayCtx {
        uint256 loanId;
        IPoolV2.Loan l;
        uint256 due;
        uint256 held;
        uint256 cap;
        uint256 earlier; // the model's: an open loan of the same owner within the cap, due first
        bool early;
        bool hasPlan;
        bool active;
        bool tampered;
        uint256[] list;
    }

    function repay(uint256 loanSeed) public {
        if (loans.length == 0) return;
        _repay(loans[loanSeed % loans.length], loanSeed / loans.length);
    }

    function _repay(uint256 loanId, uint256 warpMode) internal {
        RepayCtx memory c;
        c.loanId = loanId;
        c.l = pool.getLoan(c.loanId);
        // often straight to the loan's window, or to its due time
        uint256 opens = router.opensAt(c.l.issuedAt, c.l.dueAt);
        if (warpMode % 3 == 1 && block.timestamp < opens) vm.warp(opens);
        if (warpMode % 3 == 2 && block.timestamp < c.l.dueAt) vm.warp(c.l.dueAt);
        c.due = _due(c.l);
        c.active = c.l.status == IPoolV2.LoanStatus.Active;
        c.held = router.setAsideOf(c.l.agentId, c.l.owner);
        address to;
        uint32 cap;
        (to,, cap,,, c.early) = router.planOf(c.l.agentId, c.l.owner);
        c.cap = cap;
        c.hasPlan = to != address(0);
        c.earlier = _earlierOpen(c.l, c.loanId, cap);
        c.list = _open(c.l.agentId);
        if (warpMode % 11 == 5 && c.list.length > 1) {
            c.list[c.list.length - 1] = c.list[0]; // a repeated id: must be refused
            c.tampered = true;
        }
        uint256[] memory sa = _setAsides(c.l.agentId);
        uint256[] memory before = _balances();

        vm.prank(keeper());
        try router.repay(c.loanId, c.list) returns (uint256 paid) {
            repays++;
            if (c.tampered) _breach("a repay with a tampered open-loan list");
            if (c.earlier != 0) _breach("repaid a loan while an earlier one of the same owner was open");
            if (!c.active) _breach("repaid a loan that was not active");
            if (block.timestamp < router.pausedUntil()) _breach("a repay while paused");
            if (!c.hasPlan) _breach("a repay with no plan of the loan's owner");
            if (c.due > c.cap) _breach("repaid a loan over the plan's cap");
            if (!c.early && block.timestamp < opens) _breach("repaid before the window");
            if (c.held < c.due) _breach("repaid more than the owner's set-aside");
            if (paid != c.due) _breach("repay did not pay the due exactly");
            if (pool.getLoan(c.loanId).status != IPoolV2.LoanStatus.Repaid) _breach("not repaid");
            // 2.8: the box's USDG goes to the pool, for a loan of its own agent, from the loan owner's set-aside
            _checkMoves(
                before,
                [_box(c.l.agentId), address(pool), address(router)],
                [-int256(c.due), int256(c.due), int256(0)],
                "a repay moved USDG other than from the agent's box to the pool"
            );
            _checkSetAsides(c.l.agentId, sa, c.l.owner, -int256(c.due), "a repay spent another owner's set-aside");
            outRepaid[c.l.agentId] += c.due;
            gRepaid[c.l.agentId][c.l.owner] += c.due;
            if (reg.ownerOf(c.l.agentId) != c.l.owner) repaysOfEarlierOwner++;
        } catch (bytes memory err) {
            if (bytes4(err) == IncomeRouter.NotEarliest.selector) refusedNotEarliest++;
        }
    }

    /// The model's order: the first open loan of `l`'s owner within `cap`, other than `loanId`, due before it (equal
    /// due times: the lower id).
    function _earlierOpen(IPoolV2.Loan memory l, uint256 loanId, uint256 cap) internal view returns (uint256) {
        uint256[] memory list = _open(l.agentId);
        for (uint256 i = 0; i < list.length; i++) {
            IPoolV2.Loan memory o = pool.getLoan(list[i]);
            if (list[i] == loanId || o.owner != l.owner || _due(o) > cap) continue;
            if (o.dueAt < l.dueAt || (o.dueAt == l.dueAt && list[i] < loanId)) return list[i];
        }
        return 0;
    }

    function release(uint256 agentSeed, uint256 ownerSeed) public {
        _release(_agent(agentSeed), owners[ownerSeed % owners.length]);
    }

    function _release(uint256 id, address o) internal {
        (address to,, uint32 cap,,,) = router.planOf(id, o);
        uint256 held = router.setAsideOf(id, o);
        uint256 dues = _dues(id, o, cap);
        uint256[] memory sa = _setAsides(id);
        uint256[] memory before = _balances();
        uint256[] memory list = _open(id);
        vm.prank(keeper());
        try router.release(id, o, list) returns (uint256 r) {
            uint256 excess = held > dues ? held - dues : 0;
            if (r != excess) _breach("a release sent other than the owner's excess");
            _checkMoves(
                before,
                [_box(id), to, address(0)],
                [-int256(r), int256(r), int256(0)],
                "a release moved USDG other than from the box to that owner's payout"
            );
            _checkSetAsides(id, sa, o, -int256(r), "a release moved another owner's set-aside");
            outReleased[id] += r;
            gReleased[id][o] += r;
            if (r > 0) releases++;
        } catch {}
    }

    /// A whole loan's life in one call, so sequences reach real repayments: a borrow, a plan, income, a sweep, a jump
    /// to the window, and the checked repay. Whatever the other actions left (pauses, sales, frozen payouts, plans
    /// left) still applies.
    function cycle(uint256 agentSeed, uint256 amountSeed, uint256 share, bool early) external {
        uint256 before = loans.length;
        borrow(agentSeed, amountSeed, amountSeed / 7);
        if (loans.length == before) return;
        enroll(agentSeed, 1, share, 100 * U, early);
        pay(agentSeed, amountSeed / 3);
        sweep(agentSeed, 0);
        _repay(loans[loans.length - 1], 1 + amountSeed % 2);
    }

    /// A change of hands in one call: the owner borrows, sets everything aside for it, and sells (sometimes bought
    /// straight back); then the earlier owner's loan is repaid from its set-aside after the sale, or repaid by hand and
    /// its set-aside released to the earlier owner's payout.
    function cycleSale(uint256 agentSeed, uint256 seed) external {
        uint256 id = _agent(agentSeed);
        address o = reg.ownerOf(id);
        uint256 before = loans.length;
        borrow(agentSeed, 3 * bound(seed, 2 * U, 13 * U) + 1, seed); // by the owner's account
        if (loans.length == before) return;
        uint256 loanId = loans[loans.length - 1];
        enroll(agentSeed, 1, ALL, 100 * U, seed % 4 == 0);
        IPoolV2.Loan memory l = pool.getLoan(loanId);
        usdg.mint(_box(id), _due(l));
        paidIn[id] += _due(l);
        sweep(agentSeed, 0);
        sell(agentSeed, seed / 4);
        if (seed % 2 == 0) {
            _repay(loanId, 1);
        } else {
            _repayByHand(loanId, o);
            _release(id, o);
        }
    }

    function keeper() public pure returns (address) {
        return address(0x4B1);
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }

    function loanCount() external view returns (uint256) {
        return loans.length;
    }
}

contract IncomeRouterInvariants is IncomeBase {
    IncomeRouterHandler h;

    function setUp() public override {
        super.setUp();
        address third = vm.addr(0xA3);
        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (owner, buyer, third);
        address[] memory keys = new address[](3);
        (keys[0], keys[1], keys[2]) = (key, makeAddr("agentKey2"), makeAddr("agentKey3"));
        address[] memory outs = new address[](3);
        (outs[0], outs[1], outs[2]) = (payout, payout2, makeAddr("payout3"));
        uint256[] memory ids = new uint256[](3);
        ids[0] = AGENT;
        ids[1] = _newAgent(buyer, BUYER_PK, keys[1], ROOT);
        ids[2] = _newAgent(third, 0xA3, keys[2], ROOT);
        h = new IncomeRouterHandler(router, pool, reg, usdg, safe, owners, keys, outs, ids);
        targetContract(address(h));
        bytes4[] memory skip = new bytes4[](4);
        (skip[0], skip[1], skip[2], skip[3]) =
        (h.keeper.selector, h.agentCount.selector, h.ownerCount.selector, h.loanCount.selector);
        excludeSelector(FuzzSelector({addr: address(h), selectors: skip}));
    }

    /// Every router call that succeeded kept the rules (the handler counts each breach).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_rulesHoldOnEveryCall() public view {
        assertEq(h.violations(), 0, h.lastViolation());
    }

    /// 1. The router holds no USDG after any call (only what was donated to it), and no allowance to the pool.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_routerHoldsNothing() public view {
        assertEq(usdg.balanceOf(address(router)), h.donated());
        assertEq(usdg.allowance(address(router), address(pool)), 0);
    }

    /// 2. What is set aside in a box never exceeds its balance (a seizure is written down, never underflowing), and
    ///    the owners' set-asides add up to the total: exactly in a pot that never lost anything, never more after a
    ///    write-down (its rounding dust stays in the pot until the last owner leaves).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_setAsideWithinBalance() public view {
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            uint256 total = router.setAsideTotal(id);
            assertLe(total, usdg.balanceOf(router.incomeAddressOf(id)));
            uint256 sum;
            for (uint256 j = 0; j < h.ownerCount(); j++) {
                sum += router.setAsideOf(id, h.owners(j));
            }
            if (h.seized(id) == 0) assertEq(sum, total);
            else assertLe(sum, total);
        }
    }

    /// 3. Every unit of new money is split once: set aside plus forwarded equals arrived, over every sweep.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_newMoneySplitOnce() public view {
        assertEq(h.putTotal() + h.forwardedTotal(), h.arrivedTotal());
    }

    /// 4. A box's USDG leaves only through the router's three paths (to the pool, to a payout at a sweep, to a payout
    ///    at a release) or by the issuer: what came in is what is there plus what left by those.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_boxMoneyLeavesOnlyByTheRules() public view {
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            assertEq(
                h.paidIn(id),
                usdg.balanceOf(router.incomeAddressOf(id)) + h.outForwarded(id) + h.outReleased(id) + h.outRepaid(id)
                    + h.seized(id)
            );
        }
    }

    /// 5. No plan pays a loan of another owner: per agent and owner, what was set aside for it is what repaid its
    ///    loans, what was released to its payout, and what is still set aside, exactly. After a seizure (written down
    ///    pro rata, so no longer exact per owner) nothing comes out beyond what went in, and each call's per-owner
    ///    moves are checked by the handler.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_eachOwnersMoneyPaysOnlyItsOwnLoans() public view {
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            uint256 putSum;
            uint256 outSum;
            for (uint256 j = 0; j < h.ownerCount(); j++) {
                address o = h.owners(j);
                uint256 out = h.gRepaid(id, o) + h.gReleased(id, o) + router.setAsideOf(id, o);
                if (h.seized(id) == 0) assertEq(h.gPut(id, o), out);
                putSum += h.gPut(id, o);
                outSum += out;
            }
            assertLe(outSum, putSum);
        }
    }

    /// The Safe's pause never reaches past 14 days from when it was set; nothing else changes the router's settings.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 150
    function invariant_pauseBoundedAndImmutables() public view {
        assertLe(router.pausedUntil(), uint256(h.pauseSetAt()) + 14 days);
        assertEq(router.pausedUntil(), h.pauseSetTo());
        assertEq(address(router.pool()), address(pool));
        assertEq(router.PAUSER(), safe);
        assertEq(router.WINDOW(), WIN);
    }

    /// Totals over every sequence, so a change that makes paths unreachable shows (INCOME_INV_LOG=1 prints them).
    function afterInvariant() external {
        if (vm.envOr("INCOME_INV_LOG", uint256(0)) == 0) return;
        console2.log("sweeps", h.sweeps(), "that set aside", h.sweepsSetAside());
        console2.log("sweeps that released", h.sweepsReleased(), "releases", h.releases());
        console2.log("repays", h.repays(), "of an earlier owner's loan", h.repaysOfEarlierOwner());
        console2.log("tampered lists refused", h.tamperedRefused(), "seizures", h.seizures());
        console2.log("repays refused, an earlier loan open", h.refusedNotEarliest());
        console2.log("loans", h.loanCount());
    }
}
