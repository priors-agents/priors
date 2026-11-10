// What an action reads from the user's message: plain patterns, never a model's guess. A payment needs its URL and
// the most to pay named in the message; it borrows only when the message names the most to borrow.

const num = (s) => { const n = Number(String(s).replace(",", ".")); return Number.isFinite(n) && n >= 0 ? n : null; };

// a URL as the prose holds it: everything up to the next whitespace. ")", "]", "'" and the rest are a URL's own
// characters (RFC 3986), so stopping at one left the URL's tail in the prose (GHSA-mc89)
const URL_RE = /https?:\/\/\S+/gi;
const urlSpans = (t) => [...t.matchAll(URL_RE)].map((m) => [m.index, m.index + m[0].length]);
const inSpans = (spans, i) => spans.some(([s, e]) => i >= s && i < e);

/** Where the {...} that opens at `start` closes (the index after its "}"), strings read as JSON spells them; -1 if never.
 * `memo` keeps what one scan learns of every { it passes outside a string (a scan from there would read the same), so a
 * run of braces that never close is scanned once, not once per brace. */
function closeOf(t, start, memo = new Map()) {
  if (memo.has(start)) return memo.get(start);
  const open = [];
  let inStr = false, esc = false;
  for (let i = start; i < t.length; i++) {
    const c = t[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === "\"") inStr = false; continue; }
    if (c === "\"") inStr = true;
    else if (c === "{") open.push(i);
    else if (c === "}" && open.length) { memo.set(open.pop(), i + 1); if (!open.length) return i + 1; }
  }
  for (const j of open) memo.set(j, -1);
  return -1;
}

/** A JSON object as compact JSON, or null. */
const objectOf = (s) => { try { const v = JSON.parse(s); return v && typeof v === "object" && !Array.isArray(v) ? JSON.stringify(v) : null; } catch { return null; } };

/**
 * The message's objects: each ``` block, and each balanced {...} that opens outside a URL and outside a ``` block (one
 * that never closes is skipped). Each is { start, end, json, body }: `json` when it is written as JSON (a block holding
 * { or [, a {...} opening with a quote or closing at once), `body` the JSON object it holds as compact JSON, or null.
 * None of their text is the message's own words: a request body, an example of one, a template's {model}. A brace
 * inside a URL is the URL's (GHSA-p87w): it was taken for the body, and taking it out cut the URL in two.
 */
function objectsOf(text) {
  const t = String(text || ""), urls = urlSpans(t), out = [], memo = new Map();
  for (let i = 0; i < t.length;) {
    if (t.startsWith("```", i) && !inSpans(urls, i)) {
      // a block holding an object ends after it, so a ``` inside one of its strings does not end the block
      const open = /^```(?:json\b)?\s*/i.exec(t.slice(i))[0].length + i;
      const objEnd = t[open] === "{" ? closeOf(t, open, memo) : -1;
      const after = objEnd > 0 ? /^\s*```/.exec(t.slice(objEnd)) : null;
      if (after) {
        out.push({ start: i, end: objEnd + after[0].length, json: true, body: objectOf(t.slice(open, objEnd)) });
        i = objEnd + after[0].length;
        continue;
      }
      const close = t.indexOf("```", i + 3);
      if (close >= 0) {
        const inner = t.slice(i + 3, close).replace(/^json\b/i, "").trim();
        out.push({ start: i, end: close + 3, json: /^[{[]/.test(inner), body: objectOf(inner) });
        i = close + 3;
        continue;
      }
    }
    if (t[i] === "{" && !inSpans(urls, i)) {
      const end = closeOf(t, i, memo);
      if (end > 0) {
        const raw = t.slice(i, end);
        out.push({ start: i, end, json: /^\{\s*["}]/.test(raw), body: objectOf(raw) });
        i = end;
        continue;
      }
    }
    i++;
  }
  return out;
}

/** The text with the given [start, end) spans each replaced by one space. */
function without(t, spans) {
  let out = "", at = 0;
  for (const [s, e] of [...spans].sort((a, b) => a[0] - b[0])) {
    if (e <= at) continue;
    out += t.slice(at, Math.max(at, s)) + " ";
    at = e;
  }
  return out + t.slice(at);
}

/** The message's own words: every URL taken out whole, so nothing in a seller's path, query or fragment
 * (/pay1/borrow5.json, #123, #)borrow$5) is ever read as an amount or an id (GHSA-rf6g, GHSA-62m7, GHSA-mc89), and every
 * object (a request body, an example, a template's {model}: objectsOf) taken out too, wherever it stands, so nothing
 * inside one is ever read either (GHSA-p87w, GHSA-8pvh). */
export const proseOf = (text) => {
  const t = String(text || "");
  return without(t, [...urlSpans(t), ...objectsOf(t).map((o) => [o.start, o.end])]);
};

/** The first https URL in the text outside its objects (a URL inside a request body is the body's), or null. */
export function urlOf(text) {
  const t = String(text || "");
  const m = without(t, objectsOf(t).map((o) => [o.start, o.end])).match(/https:\/\/[^\s<>"'`)\]]+/i);
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
// aside right after it, after its unit too ("borrow 0.50 (up to 5)", "borrow 0.50 USDG (up to 5)"), which is the
// borrow's (GHSA-p87w).
const BORROW = /\bborrow(?:ing)?\s*(?:up to|at most|no more than|max(?:imum)?)?\s*\$?\s*(\d+(?:[.,]\d+)?)\b(?:\s*(?:usdg|usd|dollars?)\b)?(?:\s*\([^)]*\))?/i;
const AMOUNT = "\\$?\\s*(\\d+(?:[.,]\\d+)?)(?!\\d|[.,]\\d)";
const UNIT = "(?:\\s*(?:usdg|usd|dollars?))?";
// a cap phrase: "at most 0.10", "max $0.10", "up to 0.10", "no more than 0.10". Its number is an amount, not a count
// ("up to 50 items", "max 100 tokens", GHSA-p87w): after "$", or followed by a unit, then the end, a line break,
// punctuation or a joining word, never by a noun.
const CAP_AFTER = `${UNIT}(?=[ \\t]*(?:$|[\\r\\n.,;:!?)\\]"'’]|(?:for|to|at|per|each|on|in|a|an|if|and|or|but|plus|then|so|please|with|without|unless|borrow(?:ing)?|do|don't|don’t|dont|never|no|not)\\b))`;
const CAP = new RegExp(`\\b(?:at most|max(?:imum)?|up to|no more than)\\s*(?:\\$\\s*(\\d+(?:[.,]\\d+)?)(?!\\d|[.,]\\d)|(\\d+(?:[.,]\\d+)?)(?!\\d|[.,]\\d)${CAP_AFTER})`, "i");
// a bare "pay 0.10": an amount (USDG, USD, dollars, or nothing more) before the end, punctuation or a preposition, not a
// count ("pay 5 items")
const PAY = new RegExp(`\\bpay\\s+${AMOUNT}${UNIT}(?=\\s*(?:$|[.,;:!?)]|(?:for|to|at|per|each|on)\\b))`, "i");

/** The most to pay, from the message's own words (never its URL, its request body or another object of it): a cap
 * phrase ("at most 0.10", "max 0.10", "up to $0.10 for it"), else a bare "pay 0.10"; null when none. The borrow phrase,
 * wherever it stands, is taken out first, so its amount is never read as the price. */
export function maxPriceOf(text) {
  const t = proseOf(text).replace(new RegExp(BORROW.source, "gi"), " ");
  const m = t.match(CAP) || t.match(PAY);
  return m ? num(m[1] ?? m[2]) : null;
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
 * The JSON object the message gives as the request body (a chat completion's {"model", "messages"}), in a ``` block or
 * as a balanced {...} outside a URL, wherever it stands in the message: { body: the object as compact JSON, raw: the
 * text it was read from }; null when the message writes none (a template's {model} is not one). The message must write
 * exactly one, so nothing is guessed: two (an example before the body, a config object), one that does not parse as an
 * object, or one joined to a URL with no space before it answer { error } and nothing is paid (GHSA-8pvh, GHSA-p87w).
 * The URL and the amounts are read with every object taken out (proseOf, urlOf), so nothing inside the body (a prompt
 * that says "up to 3") is ever taken for the price or a borrow.
 */
export function bodyOf(text) {
  const t = String(text || "");
  const objects = objectsOf(t), written = objects.filter((o) => o.json);
  const inObject = (i) => objects.some((o) => i >= o.start && i < o.end);
  if (urlSpans(t).some(([s, e]) => !inObject(s) && /\{\s*"/.test(t.slice(s, e)))) {
    return { error: "a JSON object is joined to a URL in the message: put a space between the URL and the request body" };
  }
  if (objects.some((o) => !o.json && /\{\s*"/.test(t.slice(o.start + 1, o.end)))) {
    return { error: "a JSON object is inside other braces or a ``` block that is not JSON: give the request body on its own" };
  }
  if (!written.length) return null;
  if (written.some((o) => o.body === null)) return { error: "the message holds JSON that is not one JSON object: write the request body as one JSON object" };
  if (written.length > 1) return { error: `the message holds ${written.length} JSON objects (in \`\`\` blocks or braces): give the request body as the only one` };
  return { body: written[0].body, raw: t.slice(written[0].start, written[0].end) };
}
