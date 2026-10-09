// Daily limits that survive a restart (0.8.0): PRIORS_MAX_SPEND_DAY_USD (what pay_url may sign) and
// PRIORS_MAX_BORROW_DAY_USD (what borrow, pay_url and fund_base may borrow), per agent and per UTC day, counted across
// every process that shares PRIORS_STATE_DIR. The per-run limits (PRIORS_MAX_SPEND_USD, PRIORS_MAX_BORROW_TOTAL_USD)
// start again from zero whenever the server restarts, and an agent's runtime restarts it as often as it likes; these
// do not.
//
// A ledger is a directory per owner and day, <state dir>/daily-<owner>/<YYYY-MM-DD>/, holding one empty file per
// money call whose NAME is the call's amounts: `<signed>-<borrowed>-<pid>-<random>.r`, in USDG base units. A call
// reserves the most it may sign and borrow BEFORE its check passes (its file is created first, then the directory is
// listed and every file in it summed, its own included), and once it ends its file is renamed to what it really did
// (removed when that is nothing). Two processes on one state dir can never both pass a limit together: whichever
// creates its file second lists both files. Both may refuse when they race for the last room, which is the safe
// direction. Creating a file (O_EXCL) and renaming one are atomic on every local file system, and a name is never
// half-written, so there is no lock to go stale and nothing to parse. A process that dies in the middle of a call
// leaves its reservation at its most, counted for the rest of that day (as a borrow whose answer was lost stays counted).
//
// Every call counts in two ledgers and must fit in both. The agent's, "agent-<id>", from PRIORS_AGENT_ID, which a
// daily limit requires: every key and every process acting for that agent shares one count, whichever client it runs
// in (a count named after the wallet when the id was left out split one agent's day in two). And the wallet's,
// "wallet-<address>": a key run under another agent id, by mistake or for a second agent it controls, still shares
// one count of the money it holds. All of a call's files are created before any ledger is listed, so the argument
// above holds in each. The day is the UTC date when the call starts; days before yesterday are deleted as new ones
// begin. A file whose name is not a ledger entry is left alone and not counted.
import { closeSync, mkdirSync, openSync, readdirSync, renameSync, rmSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

const ENTRY = /^(\d{1,30})-(\d{1,30})-\d{1,10}-[0-9a-f]{16}\.r$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const OWNER = /^(agent-\d{1,78}|wallet-0x[0-9a-f]{40})$/;

/** The UTC date of `ms` (YYYY-MM-DD). */
export const utcDay = (ms) => new Date(ms).toISOString().slice(0, 10);

/** The agent PRIORS_AGENT_ID names, as a BigInt (leading zeros dropped: 007 and 7 are one agent), or null when it is
 *  not a decimal id. */
export function agentOf(agentIdEnv) {
  const s = String(agentIdEnv ?? "").trim();
  return /^\d{1,78}$/.test(s) ? BigInt(s) : null;
}

/** The ledgers a server counts in: ["agent-<id>", "wallet-<address>"] (the address in lowercase), or null when
 *  PRIORS_AGENT_ID is not a decimal agent id (a daily limit then stops the start). */
export function ledgerOwners(agentIdEnv, walletAddress) {
  const id = agentOf(agentIdEnv);
  if (id === null) return null;
  return [`agent-${id}`, `wallet-${String(walletAddress).toLowerCase()}`];
}

/** What is counted today: { signed, borrowed } in base units, summed over every entry of `dir`. */
function sum(dir, fs) {
  let signed = 0n, borrowed = 0n;
  let names;
  try { names = fs.readdirSync(dir); } catch (e) { if (e?.code === "ENOENT") return { signed, borrowed }; throw e; }
  for (const n of names) { const m = ENTRY.exec(n); if (m) { signed += BigInt(m[1]); borrowed += BigInt(m[2]); } }
  return { signed, borrowed };
}

/**
 * A daily ledger under `stateDir` that counts in every one of `owners` (ledgerOwners; or `owner`, one name).
 * `caps.signed` / `caps.borrowed` are base units, or null for no limit of that kind; each holds in every owner's
 * ledger. `now` and `fs` are replaceable for tests.
 */
export function dailyLedger({ stateDir, owners, owner, caps, now = () => Date.now(), fs = { closeSync, mkdirSync, openSync, readdirSync, renameSync, rmSync, unlinkSync } }) {
  const list = owners ?? [owner];
  if (!list.length || !list.every((o) => OWNER.test(String(o)))) throw new Error(`not a daily ledger owner: ${list.join(", ")}`);
  const rootOf = (o) => join(stateDir, `daily-${o}`);
  const swept = new Map();
  /** Days before yesterday go, once per owner and new day (best effort: a leftover day is never read again). */
  function sweep(o, today) {
    if (swept.get(o) === today) return;
    swept.set(o, today);
    const yesterday = utcDay(Date.parse(`${today}T00:00:00Z`) - 86_400_000);
    try { for (const d of fs.readdirSync(rootOf(o))) if (DAY.test(d) && d < yesterday) fs.rmSync(join(rootOf(o), d), { recursive: true, force: true }); } catch (_) { /* best effort */ }
  }
  const entryName = (s, b) => `${s}-${b}-${process.pid}-${randomBytes(8).toString("hex")}.r`;
  /** Takes a call's files back (a refusal, or a ledger that could not be written): best effort, since one left behind
   *  only counts until the day ends, the safe direction. */
  const drop = (files) => { for (const f of files) { try { fs.unlinkSync(join(f.dir, f.name)); } catch (_) { /* counted */ } } };
  return {
    caps,
    owners: list,
    /** Today's totals: for each kind, the most any of the owners' ledgers holds (what the limits are held against). */
    used() {
      const day = utcDay(now());
      const out = { signed: 0n, borrowed: 0n };
      for (const o of list) {
        const t = sum(join(rootOf(o), day), fs);
        if (t.signed > out.signed) out.signed = t.signed;
        if (t.borrowed > out.borrowed) out.borrowed = t.borrowed;
      }
      return out;
    },
    /**
     * Reserve `signed` and `borrowed` (base units) for one call in every owner's ledger, or throw { code: "DAY_LIMIT",
     * kind, owner, used, cap, want } when either would pass its limit in any of them (nothing is then kept), or the file
     * system's error when a ledger cannot be written (nothing is then kept, and nothing may be signed or borrowed: the
     * limit could not be kept).
     */
    reserve(signed, borrowed) {
      const day = utcDay(now());
      const files = [];
      try {
        for (const o of list) {
          const dir = join(rootOf(o), day);
          fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
          sweep(o, day);
          const name = entryName(signed, borrowed);
          fs.closeSync(fs.openSync(join(dir, name), "wx", 0o600));
          files.push({ owner: o, dir, name });
        }
      } catch (e) { drop(files); throw e; }
      // each ledger is listed only once all of this call's files exist: a racing process sees them, or this one sees its
      for (const f of files) {
        let total;
        try { total = sum(f.dir, fs); } catch (e) { drop(files); throw e; }
        for (const [kind, want] of [["signed", signed], ["borrowed", borrowed]]) {
          const cap = caps[kind];
          if (cap === null || cap === undefined || want === 0n || total[kind] <= cap) continue;
          drop(files);
          throw Object.assign(new Error(`daily ${kind} limit`), { code: "DAY_LIMIT", kind, owner: f.owner, used: total[kind] - want, cap, want });
        }
      }
      return { files, signed, borrowed };
    },
    /** Once the call has ended: its entries become what it really did (signed, borrowed: what the server counted, which
     *  includes anything that may have happened, like a payment signed before the request failed), or go when that is
     *  nothing. Best effort: an entry that cannot be renamed stays at its most. */
    settle(r, signed, borrowed) {
      if (!r) return;
      const s = signed < 0n ? 0n : signed, b = borrowed < 0n ? 0n : borrowed;
      if (s === r.signed && b === r.borrowed) return;
      for (const f of r.files) {
        try {
          if (s === 0n && b === 0n) fs.unlinkSync(join(f.dir, f.name));
          else fs.renameSync(join(f.dir, f.name), join(f.dir, entryName(s, b)));
        } catch (_) { /* stays counted at its most */ }
      }
    },
  };
}
