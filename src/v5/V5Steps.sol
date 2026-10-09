// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditPoolV2} from "../interfaces/ICreditPoolV2.sol";
import {IPriorsBurn} from "../interfaces/IV5Deps.sol";
import {Env, C, IV5Events, IV5Errors} from "./V5Types.sol";
import {V5Storage as S} from "./V5Storage.sol";
import {V5Math as M} from "./V5Math.sol";
import {V5Core as K} from "./V5Core.sol";
import {V5Pos} from "./V5Pos.sol";

/// @title V5Steps
/// @notice 2.2's first steps, in their one order (docs/PRIORS-UNDERWRITING-SPEC.md rev 5): the owner-change step, on
///         a payout path `markDefault` on every listed loan past `defaultableAt`, the settle (split, then one burn),
///         reconciliation (counting, lateness, the breaker's records, engine 2's points), then the poke (the split,
///         `releasableAt` and retirements, merges). A linked library run by DELEGATECALL in SeatVaultV5's context.
library V5Steps {
    using SafeERC20 for IERC20;

    /// @notice 2.2's order for a call on the agent's latest generation: the owner-change step; on a payout path,
    ///         `markDefault` (in try/catch) on every listed loan past `defaultableAt`; the settle when a loan of the
    ///         generation is `Defaulted`; reconciliation; the poke.
    function firstSteps(Env memory e, uint256 id, bool payout) public returns (K.Steps memory st) {
        S.Layout storage l = S.layout();
        st.genNo = l.latest[id];
        address owner;
        (st.readOk, owner) = K.ownerOf(e, id);
        if (st.genNo == 0) return st;
        st.hasBook = true;
        S.Gen storage g = l.gens[id][st.genNo];
        if (st.readOk && owner != g.owner && g.status == C.OPEN && !g.ownerChanged) ownerChange(e, id, st.genNo, g);
        if (g.movePending) {
            // a close made inside `onRelease`: every layer moves to leaving now, in mode 1, as of the close's time and
            // at the close's P, so its bucket is the close's day and the 7-day release clock starts at the close
            // (audit L-02); never on a generation a hook settled in between, which pays its positions at once (2.5:
            // "on a settled generation no move to leaving runs", deep audit D-05)
            g.movePending = false;
            if (g.status != C.SETTLED) {
                uint160 p = g.movePendingSqrt;
                uint64 at = g.movePendingAt;
                V5Pos.endLayer(e, id, st.genNo, C.OWNER, 1, p, at);
                V5Pos.endLayer(e, id, st.genNo, C.OTHERS, 1, p, at);
                V5Pos.endLayer(e, id, st.genNo, C.OWN, 1, p, at);
            }
        }
        if (g.pointsVoid) {
            // a hook only flagged the points (O(1) inside the pool's gas): erase them from the global totals now, so
            // engine 2's W_e stops counting them (audit L-01). The generation is closed or settled and never earns
            // points again, so the flag is cleared and the next first steps skip this.
            g.pointsVoid = false;
            K.erasePoints(e, g);
        }
        ICreditPoolV2.Loan[] memory ls = K.fetchList(e, g);
        if (payout && g.status != C.SETTLED) {
            for (uint256 i = 0; i < ls.length; i++) {
                if (ls[i].status == ICreditPoolV2.LoanStatus.Active && block.timestamp > ls[i].defaultableAt) {
                    try e.pool.markDefault(g.list[i]) {}
                    catch (bytes memory err) {
                        if (err.length >= 4 && bytes4(err) == K.HOOK_STARVED) {
                            assembly {
                                revert(add(err, 0x20), mload(err))
                            }
                        }
                    }
                    ls[i] = e.pool.getLoan(g.list[i]);
                }
            }
        }
        if (g.status != C.SETTLED) {
            uint256 proof = g.defaultProof;
            for (uint256 i = 0; proof == 0 && i < ls.length; i++) {
                if (ls[i].status == ICreditPoolV2.LoanStatus.Defaulted) proof = g.list[i];
            }
            if (proof != 0) settle(e, id, st.genNo, proof, false);
        }
        reconcile(e, id, st.genNo, g, ls);
        poke(e, id, st.genNo);
        st.ls = ls;
    }

    /// @notice The first steps on any generation: the latest takes `firstSteps`; a superseded one only its poke (it
    ///         never reads `feesFrom`, never compares its list and never settles, 2.2).
    function stepsFor(Env memory e, uint256 id, uint32 genNo, bool payout) external returns (K.Steps memory st) {
        if (S.layout().latest[id] == genNo) return firstSteps(e, id, payout);
        poke(e, id, genNo);
        st.genNo = genNo;
        st.hasBook = true;
        st.readOk = true;
    }

    /// @notice Split first, then burn 75% of the owner layer and 50% of every other, each rounded up, in one `_burn`;
    ///         mark the generation settled; the points erased. Inside a hook the split and the erase are flags, run by
    ///         the generation's next first steps before anything reads its index (deep audit L-01: the split's first
    ///         writes do not fit the pool's 300,000 gas beside the burn), and the fees owed before the default still
    ///         go to the generation's holders.
    function settle(Env memory e, uint256 id, uint32 genNo, uint256 proof, bool inHook) public {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        if (inHook) g.splitPending = true;
        else splitFees(e, id, genNo, g);
        uint256 b0 = M.burnOf(g.tokens[C.OWNER], C.OWNER_BURN_BPS);
        uint256 b1 = M.burnOf(g.tokens[C.OTHERS], C.BACK_BURN_BPS);
        uint256 b2 = M.burnOf(g.tokens[C.OWN], C.BACK_BURN_BPS);
        uint256 cb = g.cUnits - M.remainderOf(g.cUnits, C.BACK_BURN_BPS);
        g.status = C.SETTLED;
        g.defaultProof = proof;
        if (inHook) g.pointsVoid = true;
        else K.erasePoints(e, g);
        uint256 total = b0 + b1 + b2;
        l.ledger -= total;
        l.burned += total;
        burnTokens(e, total);
        emit IV5Events.Settled(id, genNo, proof, b0, b1 + b2 - cb, cb);
    }

    /// @notice A late repayment (2.4, 2A.2): down one tier (at T1 the clock restarts), the count to 0, the points
    ///         erased, nothing placed for 28 days from its `closedAt`, and all of C moved to leaving.
    function applyLate(Env memory e, uint256 id, uint32 genNo, S.Gen storage g, uint64 closedAt) public {
        if (closedAt > g.lastLateAt) g.lastLateAt = closedAt;
        if (g.status != C.OPEN) return;
        if (g.tier > 1) {
            g.tier -= 1;
            uint256 c = C.ceiling(g.tier);
            if (g.roomLine > c) g.roomLine = c;
            emit IV5Events.Demoted(id, genNo, g.tier);
        }
        g.tierStep += 1;
        g.countedAtTier = 0;
        g.tierSince = uint64(block.timestamp);
        K.erasePoints(e, g);
        V5Pos.moveOne(e, id, genNo, C.OWN, e.buyAndBack, K.pDown());
    }

    /// @notice The split: what `feesFrom[root][id]` rose by since the agent's fee mark, 75% to the generation's index
    ///         (rounded down) and the rest to the buffer; all of it to the buffer on a settled generation or one with
    ///         no counted stake, except the split a hook's settle deferred (`splitPending`), which goes as before the
    ///         default. Only the agent's latest generation reads `feesFrom` (2.2).
    function splitFees(Env memory e, uint256 id, uint32 genNo, S.Gen storage g) internal {
        S.Layout storage l = S.layout();
        bool deferred = g.splitPending;
        if (deferred) g.splitPending = false;
        uint256 cur = e.pool.feesFrom(e.root, id);
        uint256 mark = l.feeMark[id];
        if (cur <= mark) return;
        uint256 d = cur - mark;
        l.feeMark[id] = cur;
        if ((g.status == C.SETTLED && !deferred) || g.divisor == 0) {
            l.bufferOwed += d;
            emit IV5Events.FeesPoked(id, genNo, 0, d);
            return;
        }
        (uint256 book, uint256 buf) = M.split(d);
        g.index += book * C.INDEX / g.divisor;
        l.holdersOwed += book;
        l.bufferOwed += buf;
        emit IV5Events.FeesPoked(id, genNo, book, buf);
    }

    /// @notice The poke (2.7), never run inside a hook (a hook only splits, through `settle`): the split (latest
    ///         generation only); `releasableAt` stored and due leaving buckets retired, oldest first per layer; then
    ///         pending buckets at least 24 h old merged.
    function poke(Env memory e, uint256 id, uint32 genNo) internal {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][genNo];
        bool latest = l.latest[id] == genNo;
        if (latest) splitFees(e, id, genNo, g);
        bool condOk = loanCondBase(e, id, g, latest);
        for (uint8 layer = 0; layer < 3; layer++) {
            storeRetire(id, genNo, g, layer, condOk);
        }
        if (g.status == C.OPEN) merge(e, id, genNo, g);
    }

    /// @dev The part of the release rule's loan condition that does not depend on a bucket: for the latest generation
    ///      while V5's root sponsors the agent, the listed open loans equal the pool's `activeLoans`. Called after
    ///      reconciliation, so every listed loan of an unsettled generation is open.
    function loanCondBase(Env memory e, uint256 id, S.Gen storage g, bool latest) internal view returns (bool) {
        if (!latest || g.status == C.SETTLED) return true;
        ICreditPoolV2.Agent memory a = e.pool.getAgent(id);
        return a.sponsor != e.root || a.activeLoans == g.listLen;
    }

    /// @dev Store `releasableAt` once (after the bucket's UTC day, once no listed loan with an id up to its count is
    ///      left), then retire every bucket whose `releasableAt` has passed: its counted stake leaves the fee divisor at
    ///      the index of this poke and its stake leaves the room checks. Oldest first, stopping at the first not due.
    function storeRetire(uint256 id, uint32 genNo, S.Gen storage g, uint8 layer, bool condOk) internal {
        S.Layout storage l = S.layout();
        uint32[] storage days_ = l.leaveDays[id][genNo][layer];
        uint256 h = g.leaveHead[layer];
        uint256 n = days_.length;
        // at most RETIRE_MAX buckets a layer a call, so a backlog never outgrows a transaction: the next poke resumes
        // at the head (deep audit I-01)
        if (n > h + C.RETIRE_MAX) n = h + C.RETIRE_MAX;
        while (h < n) {
            uint32 d = days_[h];
            S.Leaving storage b = l.leaving[id][genNo][layer][d];
            if (b.releasableAt == 0) {
                if (block.timestamp < (uint256(d) + 1) * 1 days || !condOk || !K.listClearUpTo(g, b.loanCount)) break;
                uint256 at = M.max256(uint256(b.latestLeave) + C.RELEASE_WAIT, g.closedMark);
                b.releasableAt = uint64(at);
            }
            if (block.timestamp < b.releasableAt) break;
            b.retired = true;
            b.retireIndex = g.index;
            g.divisor -= b.counted;
            g.leavingLive[layer] -= b.counted + b.uncounted;
            if (layer == C.OWN) g.cLive -= l.cInBucket[id][genNo][d];
            h++;
        }
        g.leaveHead[layer] = uint32(h);
    }

    /// @dev Merge each live pending bucket whose latest deposit is at least 24 h old; the owner layer's wait while the
    ///      breaker or the depth guard's lasting predicate is on (2.7).
    function merge(Env memory e, uint256 id, uint32 genNo, S.Gen storage g) internal {
        S.Layout storage l = S.layout();
        uint8 frozen; // 0 unknown, 1 no, 2 yes
        for (uint8 layer = 0; layer < 3; layer++) {
            for (uint256 s = 0; s < 2; s++) {
                uint32 d1 = g.liveDay[layer][s];
                if (d1 == 0) continue;
                S.Pending storage p = l.pend[id][genNo][layer][d1 - 1];
                if (block.timestamp < uint256(p.lastDeposit) + C.WARMUP) continue;
                if (layer == C.OWNER) {
                    if (frozen == 0) frozen = K.mergeFrozenA(e) ? 2 : 1;
                    if (frozen == 2) continue;
                }
                p.merged = true;
                p.mergeIndex = g.index;
                g.counted[layer] += p.amount;
                g.divisor += p.amount;
                g.pendingTok[layer] -= p.amount;
                g.liveDay[layer][s] = 0;
            }
        }
    }

    /// @notice The owner-change latch (2.4), set only by a read that succeeds and names another owner: new loans stop,
    ///         every backing position moves to leaving in mode 1, the book's points are erased, and the owner stake
    ///         stays counted and burnable until the book closes.
    function ownerChange(Env memory e, uint256 id, uint32 genNo, S.Gen storage g) internal {
        g.ownerChanged = true;
        emit IV5Events.OwnerChanged(id, genNo);
        uint160 p = K.pDown();
        uint64 at = uint64(block.timestamp);
        V5Pos.endLayer(e, id, genNo, C.OTHERS, 1, p, at);
        V5Pos.endLayer(e, id, genNo, C.OWN, 1, p, at);
        K.erasePoints(e, g);
    }

    /// @notice Reconciliation (2.3): closed loans leave the list (raising `closedMark`), on-time counted loans count
    ///         (promotion, breaker's repaid side, engine 2's points), defaulted listed loans enter the breaker, and late
    ///         repayments apply last, after the counting (review B-F17).
    struct Acc {
        uint256 lates;
        uint64 lateAt;
        bool recorded;
    }

    function reconcile(Env memory e, uint256 id, uint32 genNo, S.Gen storage g, ICreditPoolV2.Loan[] memory ls)
        internal
    {
        Acc memory acc;
        uint256 i;
        uint256 n = g.listLen;
        while (i < n) {
            if (_reconcileOne(e, id, genNo, g, ls[i], g.list[i], acc)) {
                n--;
                g.list[i] = g.list[n];
                ls[i] = ls[n];
                g.list[n] = 0;
                continue;
            }
            i++;
        }
        g.listLen = uint8(n);
        for (uint256 k = 0; k < acc.lates; k++) {
            applyLate(e, id, genNo, g, acc.lateAt);
        }
        if (acc.recorded) K.breakerEval();
    }

    /// @dev One listed loan; returns whether it leaves the list (repaid, or defaulted on a settled generation).
    function _reconcileOne(
        Env memory e,
        uint256 id,
        uint32 genNo,
        S.Gen storage g,
        ICreditPoolV2.Loan memory ln,
        uint256 loanId,
        Acc memory acc
    ) private returns (bool remove) {
        bool repaid = ln.status == ICreditPoolV2.LoanStatus.Repaid;
        bool defaulted = ln.status == ICreditPoolV2.LoanStatus.Defaulted;
        if (defaulted && K.breakerDefault(e, loanId, ln)) acc.recorded = true;
        if (!repaid && !(defaulted && g.status == C.SETTLED)) return false;
        bool late;
        bool counted_;
        if (repaid) {
            if (ln.closedAt > g.closedMark) g.closedMark = ln.closedAt;
            S.LoanRec storage lr = S.layout().loans[loanId];
            counted_ = applyRepaid(e, g, lr, ln);
            if (counted_) acc.recorded = true;
            if (ln.closedAt > ln.dueAt && !lr.lateDone) {
                lr.lateDone = true;
                late = true;
                acc.lates++;
                if (ln.closedAt > acc.lateAt) acc.lateAt = ln.closedAt;
            }
        }
        emit IV5Events.LoanReconciled(id, genNo, loanId, counted_, late);
        return true;
    }

    /// @dev A repaid listed loan: counted under 2.4's predicate, once (the `counted` bit).
    function applyRepaid(Env memory e, S.Gen storage g, S.LoanRec storage lr, ICreditPoolV2.Loan memory ln)
        internal
        returns (bool counted_)
    {
        if (!lr.viaHook || lr.counted) return false;
        uint256 term = ln.dueAt - ln.issuedAt;
        if (
            term < C.COUNT_MIN_TERM || term > C.MAX_LOAN_TERM || ln.closedAt - ln.issuedAt < C.COUNT_MIN_HOLD
                || ln.closedAt > ln.dueAt || ln.principal * 2 < C.ceiling(lr.tier)
        ) return false;
        lr.counted = true;
        counted_ = true;
        K.breakerRepaid(ln);
        if (g.status != C.OPEN) return true;
        if (lr.tierStep == g.tierStep && ln.principal * 2 >= C.ceiling(g.tier) && g.countedAtTier < 255) {
            g.countedAtTier++;
        }
        if (!g.ownerChanged && !g.optOut) K.addPoints(e, g, ln.principal * term / 30 days);
    }

    /// @notice $PRIORS `burn()`, falling back to the dead address for whatever it did not take (V4's `_burn`).
    function burnTokens(Env memory e, uint256 amount) internal {
        uint256 before = e.priors.balanceOf(address(this));
        try IPriorsBurn(address(e.priors)).burn(amount) {} catch {}
        uint256 afterBal = e.priors.balanceOf(address(this));
        uint256 gone = afterBal < before ? before - afterBal : 0;
        if (gone < amount) e.priors.safeTransfer(C.DEAD, amount - gone);
    }
}
