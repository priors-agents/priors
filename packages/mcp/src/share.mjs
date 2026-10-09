// Share facts (0.8.0): what `repay` returns about each loan it repaid, so an agent's runtime can post "repaid on time"
// in its own words: the agent, the loan, the amount, on time or late (and by how many days), how many loans the agent
// has repaid in all, and its public record's address. Facts only: this package never posts anything anywhere, and
// `repaidPost` below only writes text a runtime may use.
//
// The template follows the rules for an agent's post about its own repayment: one post per repaid loan, never a reply
// and never on a borrow alone, in the agent's own words each time (X counts identical text across accounts as spam), no
// @mentions, no hashtags and no link (a post with a link costs about 13 times as much through X's API, and the record's
// link belongs in the agent's bio). Lowercase, plain and calm.

/** The public page of an agent's record. */
export const recordUrl = (agentId) => `https://priors.trade/agent?id=${BigInt(agentId)}`;

const DAY_S = 86_400;
/** USDG from base units (6 decimals), exact, at least 2 decimals (5.00, 1.01, 0.050001). */
export function exactUsdg(units) {
  const u = BigInt(units);
  const whole = u / 1_000_000n, frac = String(u % 1_000_000n).padStart(6, "0").replace(/0+$/, "");
  return `${whole}.${frac.padEnd(2, "0")}`;
}
/** USDG for a post: to the nearest cent, no trailing zeros (5.05, 12, 0.5). */
export function usdgText(units) {
  const u = BigInt(units);
  const cents = (u + 5_000n) / 10_000n; // to the nearest cent
  const whole = cents / 100n, frac = cents % 100n;
  return frac === 0n ? `${whole}` : `${whole}.${String(frac).padStart(2, "0").replace(/0$/, "")}`;
}

/**
 * The facts for one repaid loan. `dueAt` and `repaidAt` are unix seconds (repaidAt is the block's time when known,
 * else the server's clock: `timeFrom` says which); either may be null, and then `on_time` is null (unknown).
 * `defaultableAt` (unix seconds, the loan's due time plus the pool's grace period) says whether a late repayment came
 * inside the grace period: the pool takes a repayment of any loan nobody has marked defaulted, so one can come after
 * it too. Unknown (null, or 0), `within_grace` is null and nothing is claimed. `loansRepaid` (after this one) is optional.
 */
export function shareFacts({ agentId, loanId, paid, dueAt = null, repaidAt = null, timeFrom = null, loansRepaid = null, defaultableAt = null }) {
  const known = Number.isFinite(Number(dueAt)) && dueAt !== null && Number.isFinite(Number(repaidAt)) && repaidAt !== null;
  const onTime = known ? Number(repaidAt) <= Number(dueAt) : null;
  const gap = known ? Math.abs(Number(dueAt) - Number(repaidAt)) : null;
  const graceKnown = onTime === false && defaultableAt !== null && Number.isFinite(Number(defaultableAt)) && Number(defaultableAt) >= Number(dueAt);
  return {
    agent_id: String(BigInt(agentId)),
    loan_id: String(BigInt(loanId)),
    amount_usdg: exactUsdg(paid),
    amount_units: String(BigInt(paid)),
    on_time: onTime,
    timing: onTime === null ? "unknown" : onTime ? "on time" : "late",
    days_early: onTime ? Math.floor(gap / DAY_S) : null,
    days_late: onTime === false ? Math.floor(gap / DAY_S) : null,
    late_seconds: onTime === false ? gap : null,
    within_grace: graceKnown ? Number(repaidAt) <= Number(defaultableAt) : null,
    ...(known && timeFrom ? { time_from: timeFrom } : {}),
    loans_repaid: loansRepaid === null || loansRepaid === undefined ? null : String(BigInt(loansRepaid)),
    record: recordUrl(agentId),
  };
}

const days = (n) => (n === 1 ? "a day" : `${n} days`);
const lateBy = (f) => (f.late_seconds < DAY_S ? "less than a day" : days(Math.floor(f.late_seconds / DAY_S)));

/** One sentence of facts, for the repay answer. */
export function factsLine(f) {
  const when = f.on_time === null ? "repaid" : f.on_time ? `repaid on time${f.days_early > 0 ? `, ${days(f.days_early)} before it was due` : ""}` : `repaid late, ${lateBy(f)} after it was due${f.within_grace === true ? " (inside the grace period)" : f.within_grace === false ? " (after the grace period)" : ""}`;
  return `loan #${f.loan_id} of agent #${f.agent_id}: ${f.amount_usdg} USDG ${when}${f.loans_repaid !== null ? `; ${f.loans_repaid} loans repaid in all` : ""}; record ${f.record}`;
}

/**
 * A post an agent may make about one repaid loan, filled from shareFacts: lowercase, no @mention, no hashtag, and no
 * link unless `link: true` (then the record's address ends it). Text only: nothing posts it.
 */
export function repaidPost(f, { link = false } = {}) {
  const amount = usdgText(f.amount_units);
  const head = f.on_time === null ? `repaid ${amount} usdg.`
    : f.on_time ? `repaid ${amount} usdg on time${f.days_early > 0 ? `, ${days(f.days_early)} early` : ""}.`
      : `repaid ${amount} usdg, ${lateBy(f)} after it was due.`;
  const count = f.loans_repaid !== null && Number(f.loans_repaid) > 1 ? ` ${f.loans_repaid} loans repaid so far.` : "";
  const tail = link ? ` record: ${f.record.replace(/^https:\/\//, "")}` : ` record: agent ${f.agent_id} on priors.`;
  return `${head}${count}${tail}`.toLowerCase();
}

/** The rule to paste into an agent's character (ElizaOS, OpenClaw, Hermes or any runtime) so it posts after a repayment
 *  in its own words. Placeholders name the share facts' fields. */
export const REPAID_POST_TEMPLATE = [
  "after a priors repay succeeds, you may post once on x about that loan, in your own words, from the share facts repay returns:",
  "the amount repaid, on time (and how many days early) or late, how many loans you have repaid, and \"agent <your id> on priors\".",
  "for example: repaid {amount_usdg} usdg on time, {days_early} days early. {loans_repaid} loans repaid so far. record: agent {agent_id} on priors.",
  "one post per repaid loan. never a reply, never about a borrow alone. no @mentions, no hashtags, no links, no prices.",
].join("\n");
