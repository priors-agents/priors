// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Env, C, IV5Events, IV5Errors} from "./V5Types.sol";
import {V5Storage as S} from "./V5Storage.sol";
import {V5Math as M} from "./V5Math.sol";
import {V5Core as K} from "./V5Core.sol";

/// @title V5Pos
/// @notice Positions, pending and leaving buckets, the forced moves to leaving, the debit of every payout, the close
///         and the zap (docs/PRIORS-UNDERWRITING-SPEC.md rev 5, 2.2, 2.5, 2.7, 2A.1). A linked library: it runs by
///         DELEGATECALL in SeatVaultV5's context, called from V5's other libraries.
library V5Pos {
    using SafeERC20 for IERC20;

    /// @notice Bring a position up to date: credit its counted shares, resolve merged pending amounts from their
    ///         buckets' merge index, and, once its layer moved to leaving, move what it holds into its leaving record
    ///         for that day (counted shares counted, unmerged pending stake uncounted), its credit capped at the
    ///         bucket's retirement index.
    function _resolve(Env memory e, uint256 id, uint32 genNo, uint8 layer, address holder)
        internal
        returns (S.Pos storage pp)
    {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        pp = l.pos[id][genNo][layer][holder];
        uint256 cap = g.index;
        uint64 end = g.layerEnd[layer];
        uint32 endDay = uint32(uint256(end) / 1 days);
        if (end != 0) {
            S.Leaving storage eb = l.leaving[id][genNo][layer][endDay];
            if (eb.retired) cap = eb.retireIndex;
        }
        K.creditTo(e, holder, M.credit(pp.counted, pp.checkpoint, cap));
        pp.checkpoint = cap;
        if (pp.d0 != 0) {
            S.Pending storage p0 = l.pend[id][genNo][layer][pp.d0 - 1];
            if (p0.merged) {
                K.creditTo(e, holder, M.credit(pp.a0, p0.mergeIndex, cap));
                pp.counted += pp.a0;
                pp.a0 = 0;
                pp.d0 = 0;
            }
        }
        if (pp.d1 != 0) {
            S.Pending storage p1 = l.pend[id][genNo][layer][pp.d1 - 1];
            if (p1.merged) {
                K.creditTo(e, holder, M.credit(pp.a1, p1.mergeIndex, cap));
                pp.counted += pp.a1;
                pp.a1 = 0;
                pp.d1 = 0;
            }
        }
        if (end != 0 && (pp.counted | pp.a0 | pp.a1) != 0) {
            S.Rec storage r = l.recs[id][genNo][layer][endDay][holder];
            S.Leaving storage b = l.leaving[id][genNo][layer][endDay];
            bool fresh = (r.counted | r.uncounted) == 0;
            K.creditRec(e, r, b, holder, g.index);
            if (fresh) {
                r.mode = holder == g.owner ? g.ownerEndMode[layer] : 1;
                r.sqrtLeave = g.endSqrt[layer];
            } else if (g.endSqrt[layer] < r.sqrtLeave) {
                r.sqrtLeave = g.endSqrt[layer];
            }
            r.counted += pp.counted;
            r.uncounted += pp.a0 + pp.a1;
            r.creditedTo = cap;
            pp.counted = 0;
            pp.a0 = 0;
            pp.a1 = 0;
            pp.d0 = 0;
            pp.d1 = 0;
            pp.autoAdd = false;
        }
    }

    /// @notice `_resolve` for callers outside this library (it returns nothing; read the position after it).
    function resolve(Env memory e, uint256 id, uint32 genNo, uint8 layer, address holder) external {
        _resolve(e, id, genNo, layer, holder);
    }

    /// @notice New stake as a pending amount on today's bucket (2.7). A layer's live buckets and a position's two
    ///         pending slots are indexed by the parity of their UTC day. The poke that runs before every deposit, in
    ///         the same transaction, has merged every bucket two or more UTC days old: a bucket merges 24 h after its
    ///         latest deposit, and the only things that hold A's merge back (the breaker, `depthGuardOn` and the
    ///         median-valued depth form, `mergeFrozenA`) also refuse every deposit, each checked after the call's own
    ///         first steps (`requireAddGuards` in `back`, each compound item's re-check, deep audit D-01). So the slot
    ///         of today's parity holds today's bucket or nothing, and `_resolve` above has cleared the position's slot
    ///         of a merged bucket. Should any path ever skip a guard, the deposit reverts `ThirdSlot` rather than
    ///         overwrite an unmerged bucket's slot (2.2: "a deposit that would need a third slot reverts").
    function deposit(Env memory e, uint256 id, uint32 genNo, uint8 layer, address holder, uint256 amount) external {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        S.Pos storage pp = _resolve(e, id, genNo, layer, holder);
        uint32 d1 = K.today() + 1;
        uint32 held = g.liveDay[layer][d1 % 2];
        uint32 mine = d1 % 2 == 0 ? pp.d0 : pp.d1;
        if ((held != 0 && held != d1) || (mine != 0 && mine != d1)) revert IV5Errors.ThirdSlot();
        g.liveDay[layer][d1 % 2] = d1;
        S.Pending storage p = l.pend[id][genNo][layer][d1 - 1];
        p.amount += uint128(amount);
        p.lastDeposit = uint64(block.timestamp);
        if (d1 % 2 == 0) {
            pp.d0 = d1;
            pp.a0 += amount;
        } else {
            pp.d1 = d1;
            pp.a1 += amount;
        }
        g.pendingTok[layer] += amount;
        g.tokens[layer] += amount;
        l.ledger += amount;
        if (holder == e.buyAndBack) {
            g.cLive += amount;
            g.cUnits += amount;
        }
    }

    /// @notice Counted stake that counts at once (only the two opening paths post it, question 3).
    function depositCounted(uint256 id, uint32 genNo, uint8 layer, address holder, uint256 amount) external {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        S.Pos storage pp = l.pos[id][genNo][layer][holder];
        pp.counted += amount;
        pp.checkpoint = g.index;
        g.counted[layer] += amount;
        g.divisor += amount;
        g.tokens[layer] += amount;
        l.ledger += amount;
    }

    /// @notice Open (or reuse) the leaving bucket of `layer` for the UTC day of `at`, recording `at` as its latest
    ///         leave and the pool's `loanCount()`. `at` is now, except for the deferred move of a close made inside
    ///         `onRelease`, which uses the close's time (audit L-02): nothing can leave a closed generation in between,
    ///         so that day's bucket, if it exists, holds only earlier leaves and has no `releasableAt` yet.
    function _touchBucket(Env memory e, uint256 id, uint32 genNo, uint8 layer, uint64 at)
        internal
        returns (S.Leaving storage b, uint32 d)
    {
        S.Layout storage l = S.layout();
        d = uint32(uint256(at) / 1 days);
        b = l.leaving[id][genNo][layer][d];
        if (!b.exists) {
            b.exists = true;
            l.leaveDays[id][genNo][layer].push(d);
        }
        b.latestLeave = at;
        b.loanCount = e.pool.loanCount();
    }

    /// @notice `_touchBucket` for callers outside this library, now: returns today's bucket day.
    function touchBucket(Env memory e, uint256 id, uint32 genNo, uint8 layer) external returns (uint32 d) {
        (, d) = _touchBucket(e, id, genNo, layer, uint64(block.timestamp));
    }

    /// @notice A forced move of a whole layer to leaving in O(1) (2.5): its counted total and its unmerged pending
    ///         total join the bucket of `at`'s day as counted and uncounted stake, its pending buckets never merge, and
    ///         each position resolves into its record at its next touch. `at` is the move's time (now, or the time of
    ///         a close made inside `onRelease`): the layer's end, its bucket's day and the start of the 7 days.
    function endLayer(Env memory e, uint256 id, uint32 genNo, uint8 layer, uint8 ownerMode, uint160 sqrtP, uint64 at)
        public
    {
        S.Gen storage g = S.layout().gens[id][genNo];
        if (g.layerEnd[layer] != 0) return;
        (S.Leaving storage b, uint32 d) = _touchBucket(e, id, genNo, layer, at);
        uint256 pend_ = _killPending(g, id, genNo, layer);
        uint256 cnt = g.counted[layer];
        b.counted += cnt;
        b.uncounted += pend_;
        g.counted[layer] = 0;
        g.pendingTok[layer] = 0;
        g.leavingLive[layer] += cnt + pend_;
        g.layerEnd[layer] = at;
        g.endSqrt[layer] = sqrtP;
        g.ownerEndMode[layer] = ownerMode;
        if (layer == C.OWN) _cIntoBucket(e, id, genNo, d);
        emit IV5Events.LayerMoved(id, genNo, layer, address(0), d, at, cnt, pend_);
    }

    /// @dev C's units in a moved OWN layer join its bucket's C total (2A.2).
    function _cIntoBucket(Env memory e, uint256 id, uint32 genNo, uint32 d) private {
        S.Layout storage l = S.layout();
        S.Pos storage cp = l.pos[id][genNo][C.OWN][e.buyAndBack];
        uint256 cu = cp.counted + cp.a0 + cp.a1;
        if (cu != 0) l.cInBucket[id][genNo][d] += cu;
    }

    /// @dev A moved layer's live pending buckets: marked dead (they never merge); returns their total.
    function _killPending(S.Gen storage g, uint256 id, uint32 genNo, uint8 layer) private returns (uint256 pend_) {
        for (uint256 s = 0; s < 2; s++) {
            uint32 d1 = g.liveDay[layer][s];
            if (d1 == 0) continue;
            S.Pending storage p = S.layout().pend[id][genNo][layer][d1 - 1];
            pend_ += p.amount;
            p.dead = true;
            g.liveDay[layer][s] = 0;
        }
    }

    /// @notice One position moved to leaving on its own (C's opt-out or late move, 2A.2): its counted shares counted,
    ///         its pending amounts uncounted, debiting the buckets they came from, in mode 1.
    function moveOne(Env memory e, uint256 id, uint32 genNo, uint8 layer, address holder, uint160 sqrtP) external {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        if (g.layerEnd[layer] != 0) return;
        S.Pos storage pp = _resolve(e, id, genNo, layer, holder);
        uint256 cnt = pp.counted;
        uint256 unc = pp.a0 + pp.a1;
        if (cnt + unc == 0) return;
        if (pp.d0 != 0) l.pend[id][genNo][layer][pp.d0 - 1].amount -= uint128(pp.a0);
        if (pp.d1 != 0) l.pend[id][genNo][layer][pp.d1 - 1].amount -= uint128(pp.a1);
        g.pendingTok[layer] -= unc;
        g.counted[layer] -= cnt;
        g.leavingLive[layer] += cnt + unc;
        (S.Leaving storage b, uint32 d) = _touchBucket(e, id, genNo, layer, uint64(block.timestamp));
        b.counted += cnt;
        b.uncounted += unc;
        S.Rec storage r = l.recs[id][genNo][layer][d][holder];
        K.creditRec(e, r, b, holder, g.index);
        if ((r.counted | r.uncounted) == 0 || sqrtP < r.sqrtLeave) r.sqrtLeave = sqrtP;
        r.counted += cnt;
        r.uncounted += unc;
        r.creditedTo = g.index;
        r.mode = 1;
        if (holder == e.buyAndBack) l.cInBucket[id][genNo][d] += cnt + unc;
        emit IV5Events.LayerMoved(id, genNo, layer, holder, d, uint64(block.timestamp), cnt, unc);
        pp.counted = 0;
        pp.a0 = 0;
        pp.a1 = 0;
        pp.d0 = 0;
        pp.d1 = 0;
        pp.autoAdd = false;
    }

    /// @notice Debit `units` from a leaving record, its bucket and its layer (counted first), crediting it first;
    ///         returns the $PRIORS they are worth now (units before a settle; floor(units × (1 − rate)) after).
    function debitRec(Env memory e, uint256 id, uint32 genNo, uint8 layer, uint32 day, address holder, uint256 units)
        external
        returns (uint256 tokens)
    {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        S.Rec storage r = l.recs[id][genNo][layer][day][holder];
        S.Leaving storage b = l.leaving[id][genNo][layer][day];
        K.creditRec(e, r, b, holder, g.index);
        uint256 c = units < r.counted ? units : r.counted;
        uint256 u = units - c;
        r.counted -= c;
        r.uncounted -= u;
        b.counted -= c;
        b.uncounted -= u;
        if (!b.retired) {
            g.divisor -= c;
            g.leavingLive[layer] -= units;
            if (holder == e.buyAndBack) {
                l.cInBucket[id][genNo][day] -= units;
                g.cLive -= units;
            }
        }
        tokens = K.payUnits(e, g, layer, holder, units);
    }

    /// @notice Close a generation (2.4, 2.5): every layer, pending stake included, moves to leaving in O(1) (the bound
    ///         owner's records take `mode` when it closes, every other position mode 1), the points are erased (a
    ///         flag inside a hook) and the 30-day reopen ban starts, except after the idle close of a book that never
    ///         borrowed. `how`: 1 close, 2 expire, 3 sync(id), 4 onRelease.
    function closeGen(Env memory e, uint256 id, uint32 genNo, uint8 mode, bool byOwner, uint8 how, bool inHook)
        external
    {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        if (inHook) {
            // O(1) and cheap inside the pool's 300,000 gas: the layers move at the next book call's first steps, as of
            // this close's time (audit L-02) and at this close's P (deep audit D-05)
            g.movePending = true;
            g.movePendingAt = uint64(block.timestamp);
            g.movePendingSqrt = K.pDown();
        } else {
            uint160 p = K.pDown();
            uint8 om = byOwner ? mode : 1;
            uint64 at = uint64(block.timestamp);
            endLayer(e, id, genNo, C.OWNER, om, p, at);
            endLayer(e, id, genNo, C.OTHERS, 1, p, at);
            endLayer(e, id, genNo, C.OWN, om, p, at);
        }
        g.status = C.CLOSED;
        g.closedByOwner = byOwner;
        if (inHook) g.pointsVoid = true;
        else K.erasePoints(e, g);
        if (how != 2 || g.openRoomCharged) l.reopenAt[id] = uint64(block.timestamp) + C.REOPEN_BAN;
        emit IV5Events.BookClosed(id, genNo, how);
    }

    /// @notice The zap (2A.1): `usdgIn` USDG from `msg.sender` swapped for $PRIORS in one exact-input swap, the
    ///         $PRIORS counted by balance delta around the swap alone, the allowance reset and unspent USDG refunded.
    ///         All or nothing: at least `minOut`, or the call reverts.
    function zap(Env memory e, uint256 usdgIn, uint256 minOut, uint256 deadline) external returns (uint256 got) {
        if (usdgIn == 0) return 0;
        K.userSwapCheck(e, usdgIn, S.layout().maxSwapUsdg);
        K.pull(e, e.usdg, usdgIn);
        got = swapIn(e, usdgIn, minOut, deadline);
    }

    /// @notice One USDG→$PRIORS swap through V4SwapOnce (exact allowance, reset after, unspent USDG refunded to
    ///         `msg.sender`); returns the $PRIORS by balance delta.
    function swapIn(Env memory e, uint256 usdgIn, uint256 minOut, uint256 deadline) internal returns (uint256 got) {
        uint256 pBefore = e.priors.balanceOf(address(this));
        uint256 uBefore = e.usdg.balanceOf(address(this));
        e.usdg.forceApprove(address(e.swapper), usdgIn);
        e.swapper.swapExactIn(e.key, true, uint128(usdgIn), minOut, C.MIN_SQRT_PLUS_ONE, address(this), deadline);
        e.usdg.forceApprove(address(e.swapper), 0);
        got = e.priors.balanceOf(address(this)) - pBefore;
        uint256 spent = uBefore - e.usdg.balanceOf(address(this));
        if (got < minOut) revert IV5Errors.SwapShort(got, minOut);
        if (spent < usdgIn) e.usdg.safeTransfer(msg.sender, usdgIn - spent);
    }
}
