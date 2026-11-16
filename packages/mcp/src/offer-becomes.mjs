// What an offer on Priors' line board can become under the pool's rules (0.20.0; line_offer): web/line-answer.js's
// becomes() in the repository, which Go mode, the board's Line request and the agent page share (growth loop batch 11's
// AQ), copied here byte for byte from the line after its opening to its closing `})();` (scripts/test-mcp-backer-runtime.mjs
// fails on any drift). Pure: no read, no clock, no key. becomes(f, { agent, loans, free }, o): { lines, can }.
export const becomes = (function () {
    "use strict";
    const en = (s, v) => String(s).replace(/\{(\w+)\}/g, (m, k) => (v && v[k] != null ? String(v[k]) : m));
    const big = (v) => { try { return v == null || v === "" ? null : BigInt(String(v)); } catch (_) { return null; } };
    const usd = (units) => { const c = ((big(units) || 0n) + 5_000n) / 10_000n, r = c % 100n; return "$" + (c / 100n).toLocaleString("en-US") + (r ? "." + String(r).padStart(2, "0") : ""); };
    // dates: the caller's (Go mode's), else UTC to the minute; the board's and the agent page's: "Dec 4, 10:22 UTC"
    const utc = (t) => new Date(Number(t) * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";
    const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const when = (t) => { const d = new Date(Number(t) * 1000), p2 = (n) => String(n).padStart(2, "0"); return `${MON[d.getUTCMonth()]} ${d.getUTCDate()}, ${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())} UTC`; };
    /** What offer `f` ({ root, amount, end }) can become under the pool's rules, from `agent` (the pool's record), `loans`
     *  (its open loans) and `free` (the root's free backing), each null when unread (nothing said of it): { lines, can }
     *  (go-backing-core.js's own copy says more). o: { _t, date, ask, anyone (a request any backer may answer: anyone()) }. */
    function becomes(f, { agent = null, loans = null, free = null } = {}, o) {
      const tr = (o && o._t) || en;
      if (o && o.anyone) return anyone(f, agent, loans, (o && o.date) || when, tr);
      const date = (o && o.date) || utc, ask = !!(o && o.ask), out = { lines: [], can: null };
      const amount = big(f && f.amount), root = big(f && f.root), end = Number(f && f.end);
      if (!agent || amount == null || root == null || !(end > 0)) return out;
      if (agent.defaulted === true) { out.lines.push(tr("This agent has a default on record. The pool takes no new line for it.")); out.can = false; return out; }
      const sponsor = big(agent.sponsor) || 0n, line = big(agent.delegatedIn) || 0n, other = sponsor > 0n && sponsor !== root;
      if (other && line > amount) out.lines.push(ask ? tr("Under its {line} line: taking an offer of {amount} would shrink the line to {amount}.", { line: usd(line), amount: usd(amount) }) : tr("Under its {line} line: taking it would shrink the line to {amount}.", { line: usd(line), amount: usd(amount) }));
      // the pool's LoanOpen: only where the line would change hands
      let loanOk = true;
      if (other && Number(agent.activeLoans) > 0) {
        const open = Array.isArray(loans) ? loans.filter((l) => l && Number(l.dueAt) > 0) : [];
        if (!open.length) loanOk = null;
        else {
          const last = open.reduce((a, b) => (Number(b.dueAt) > Number(a.dueAt) ? b : a)), after = Number(last.dueAt) > end;
          const v = { loan: String(last.loanId), n: open.length, due: date(Number(last.dueAt)), end: date(end) };
          const one = open.length === 1;
          out.lines.push(ask
            ? (after ? (one ? tr("Loan #{loan} is due {due}, after this request ends {end}: an offer can be sent only if that loan is repaid first.", v) : tr("Its {n} open loans are due by {due}, after this request ends {end}: an offer can be sent only if they are repaid first.", v))
              : (one ? tr("Loan #{loan} is due {due}, before this request ends {end}: its owner can take an offer once it is repaid.", v) : tr("Its {n} open loans are due by {due}, before this request ends {end}: its owner can take an offer once they are repaid.", v)))
            : (after ? (one ? tr("Loan #{loan} is due {due}, after this offer ends {end}: it can be sent only if that loan is repaid first.", v) : tr("Its {n} open loans are due by {due}, after this offer ends {end}: it can be sent only if they are repaid first.", v))
              : (one ? tr("Loan #{loan} is due {due}, before this offer ends {end}: its owner can take the offer once it is repaid.", v) : tr("Its {n} open loans are due by {due}, before this offer ends {end}: its owner can take the offer once they are repaid.", v))));
          loanOk = !after;
        }
      }
      // the pool's InsufficientBacking: the line is taken from the root's free backing when it is sent
      const fb = free == null ? null : big(free), freeOk = fb == null ? null : fb >= amount;
      if (freeOk === false) out.lines.push(tr("Backer #{root} has {free} free, less than this offer: it can be sent only once {amount} is free.", { root: String(root), free: usd(fb), amount: usd(amount) }));
      out.can = loanOk === false || freeOk === false ? false : loanOk === null || freeOk === null ? null : true;
      if (out.can === true) out.lines.push(ask ? tr("An offer can be sent once taken.") : tr("Can be sent once taken."));
      return out;
    }
    /** What an offer from any backer on request `f` ({ end }) can become, from `agent` ({ sponsor, line, activeLoans,
     *  defaulted }: zeros for no Priors record) and `loans` (null unread): the pool's LoanOpen holds only where the line
     *  changes hands (an agent with a backer), so a loan open with its loans unread says nothing at all. */
    function anyone(f, agent, loans, date, tr) {
      const out = { lines: [], can: null };
      if (!agent) return out;
      if (agent.defaulted === true) { out.lines.push(tr("This agent has a default on record. The pool takes no new line for it.")); out.can = false; return out; }
      const sponsor = big(agent.sponsor) || 0n, line = big(agent.line) || 0n, n = Math.max(0, Math.floor(Number(agent.activeLoans) || 0));
      if (n === 0) { out.lines.push(tr("No loan open: a backer's line can be sent as soon as an offer is taken.")); out.can = true; }
      else {
        const open = sponsor > 0n && Array.isArray(loans) ? loans.filter((l) => l && Number(l.dueAt) > 0) : [];
        if (!open.length) return out;
        const last = open.reduce((a, b) => (Number(b.dueAt) > Number(a.dueAt) ? b : a)), end = Number(f && f.end);
        const v = { loan: String(last.loanId), n: open.length, due: date(Number(last.dueAt)) };
        out.lines.push(open.length === 1 ? tr("Loan #{loan} open, due {due}: a line from a new backer can be sent only once it is repaid.", v) : tr("{n} loans open, the last due {due}: a line from a new backer can be sent only once they are repaid.", v));
        out.can = end > 0 ? !(Number(last.dueAt) > end) : null;
      }
      if (sponsor > 0n && line > 0n) out.lines.push(tr("Its line now is {line}: an offer under it would make the line smaller.", { line: usd(line) }));
      return out;
    }
    return becomes;
  })();
