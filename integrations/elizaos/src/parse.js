// What an action reads from the user's message: plain patterns, never a model's guess. A payment needs its URL and
// the most to pay named in the message; it borrows only when the message names the most to borrow.

const num = (s) => { const n = Number(String(s).replace(",", ".")); return Number.isFinite(n) && n >= 0 ? n : null; };

/** The first https URL in the text, or null. */
export function urlOf(text) {
  const m = String(text || "").match(/https:\/\/[^\s<>"'`)\]]+/i);
  if (!m) return null;
  try { return new URL(m[0].replace(/[.,;:!?]+$/, "")).href; } catch { return null; }
}

/** An agent id: "agent 9233" or "agent #9233" first, else a bare "#9233" that is not a loan's; null when none. */
export function agentIdOf(text) {
  const t = String(text || "");
  const named = t.match(/agent\s*#?\s*(\d{1,12})\b/i);
  if (named) return Number(named[1]);
  for (const m of t.matchAll(/#(\d{1,12})\b/g)) if (!/loan\s*$/i.test(t.slice(0, m.index))) return Number(m[1]);
  return null;
}

/** A loan id: "loan 50327" or "loan #50327"; null when none. */
export function loanIdOf(text) {
  const m = String(text || "").match(/loan\s*#?\s*(\d{1,12})\b/i);
  return m ? Number(m[1]) : null;
}

// The borrow phrase with its amount: "borrow up to 1", "borrow at most $0.50", "borrow 1".
const BORROW = /borrow(?:ing)?\s*(?:up to|at most|no more than|max(?:imum)?)?\s*\$?\s*(\d+(?:[.,]\d+)?)/i;

/** The most to pay: "at most 0.10", "max 0.10", "up to $0.10 for it", "pay 0.10"; null when none. The borrow phrase,
 * wherever it stands, is taken out first, so its amount is never read as the price. */
export function maxPriceOf(text) {
  const t = String(text || "").replace(new RegExp(BORROW.source, "gi"), " ");
  const m = t.match(/(?:at most|max(?:imum)?|up to|no more than|pay)\s*\$?\s*(\d+(?:[.,]\d+)?)/i);
  return m ? num(m[1]) : null;
}

/** The most to borrow: "borrow up to 1", "borrow at most $0.50", "borrow 1"; 0 when the message names none. */
export function maxBorrowOf(text) {
  const m = String(text || "").match(BORROW);
  return m ? num(m[1]) ?? 0 : 0;
}
