// What an action reads from the user's message: plain patterns, never a model's guess. A payment needs its URL and
// the most to pay named in the message; it borrows only when the message names the most to borrow.

const num = (s) => { const n = Number(String(s).replace(",", ".")); return Number.isFinite(n) && n >= 0 ? n : null; };

// a URL as the prose holds it: everything up to the next whitespace. ")", "]", "'" and the rest are a URL's own
// characters (RFC 3986), so stopping at one left the URL's tail in the prose (GHSA-mc89)
const URL_RE = /https?:\/\/\S+/gi;
/** The message's own words: every URL taken out whole, so nothing in a seller's path, query or fragment
 * (/pay1/borrow5.json, #123, #)borrow$5) is ever read as an amount or an id (GHSA-rf6g, GHSA-62m7, GHSA-mc89). */
export const proseOf = (text) => String(text || "").replace(URL_RE, " ");

/** The first https URL in the text, or null. */
export function urlOf(text) {
  const m = String(text || "").match(/https:\/\/[^\s<>"'`)\]]+/i);
  if (!m) return null;
  try { return new URL(m[0].replace(/[.,;:!?]+$/, "")).href; } catch { return null; }
}

/** An agent id: "agent 9233" or "agent #9233" first, else a bare "#9233" that is not a loan's; null when none. */
export function agentIdOf(text) {
  const t = proseOf(text);
  const named = t.match(/agent\s*#?\s*(\d{1,12})\b/i);
  if (named) return Number(named[1]);
  for (const m of t.matchAll(/#(\d{1,12})\b/g)) if (!/loan\s*$/i.test(t.slice(0, m.index))) return Number(m[1]);
  return null;
}

/** A loan id: "loan 50327" or "loan #50327"; null when none. */
export function loanIdOf(text) {
  const m = proseOf(text).match(/\bloan\s*#?\s*(\d{1,12})\b/i);
  return m ? Number(m[1]) : null;
}

// The borrow phrase with its amount: "borrow up to 1", "borrow at most $0.50", "borrow 1" (whole words only), and an
// aside right after it ("borrow 0.50 (up to 5)"), which is the borrow's too.
const BORROW = /\bborrow(?:ing)?\s*(?:up to|at most|no more than|max(?:imum)?)?\s*\$?\s*(\d+(?:[.,]\d+)?)\b(?:\s*\([^)]*\))?/i;
const AMOUNT = "\\$?\\s*(\\d+(?:[.,]\\d+)?)";
// a cap phrase: "at most 0.10", "max $0.10", "up to 0.10", "no more than 0.10"
const CAP = new RegExp(`\\b(?:at most|max(?:imum)?|up to|no more than)\\s*${AMOUNT}(?!\\d|[.,]\\d)`, "i");
// a bare "pay 0.10": an amount (USDG, USD, dollars, or nothing more) before the end, punctuation or a preposition, not a
// count ("pay 5 items")
const PAY = new RegExp(`\\bpay\\s+${AMOUNT}(?:\\s*(?:usdg|usd|dollars?))?(?=\\s*(?:$|[.,;:!?)]|(?:for|to|at|per|each|on)\\b))`, "i");

/** The most to pay, from the message's own words (never its URL): a cap phrase ("at most 0.10", "max 0.10", "up to
 * $0.10 for it"), else a bare "pay 0.10"; null when none. The borrow phrase, wherever it stands, is taken out first, so
 * its amount is never read as the price. */
export function maxPriceOf(text) {
  const t = proseOf(text).replace(new RegExp(BORROW.source, "gi"), " ");
  const m = t.match(CAP) || t.match(PAY);
  return m ? num(m[1]) : null;
}

/** The most to borrow: "borrow up to 1", "borrow at most $0.50", "borrow 1"; 0 when the message names none. */
export function maxBorrowOf(text) {
  return borrowOf(text) ?? 0;
}

/** The borrow the message names: its amount, 0 for "don't borrow", "no borrowing", "without borrowing" or "never
 * borrow", null when it names none (then @priors/mcp's own setting decides: never, or its auto-borrow). */
export function borrowOf(text) {
  const t = proseOf(text);
  if (/\b(?:do not|don't|dont|never|no|without)\s+borrow/i.test(t)) return 0;
  const m = t.match(BORROW);
  return m ? num(m[1]) ?? 0 : null;
}

/**
 * A JSON object the message gives as the request body (a chat completion's {"model", "messages"}): the first ``` fence
 * holding one, else the first balanced {...} that parses. { body: the object as compact JSON, raw: the text it was read
 * from }, or null. The caller reads the URL and the amounts from the rest of the message, so nothing inside the body
 * (a prompt that says "up to 3") is ever taken for the price or a borrow.
 */
export function bodyOf(text) {
  const t = String(text || "");
  const obj = (s) => { try { const v = JSON.parse(s); return v && typeof v === "object" && !Array.isArray(v) ? JSON.stringify(v) : null; } catch { return null; } };
  for (const m of t.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)) { const body = obj(m[1].trim()); if (body) return { body, raw: m[0] }; }
  const start = t.indexOf("{");
  if (start < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < t.length; i++) {
    const c = t[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === "\"") inStr = false; continue; }
    if (c === "\"") inStr = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) { const raw = t.slice(start, i + 1); const body = obj(raw); return body ? { body, raw } : null; }
  }
  return null;
}
