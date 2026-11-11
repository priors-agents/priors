// Published trading strategies in words: what the hosted MCP's strategies_list, strategy_read and strategy_draft
// (mcp-worker/strategy-tools.mjs) and @priors/mcp's strategies_list and strategy_read say of a strategy (the package
// holds a copy of this file, src/strategies.mjs, byte for byte). A strategy is what Go mode's Trade tab compiles (the
// strategy rules, "priors.strategy" v1) with the cards' places; it is read back into nodes by the Trade tab's own core
// and described by the board's own words, both passed in:
//   T   the Trade tab's core (web/trade-core.js: window.PriorsTradeCore): fromPublished, compile, summary, limits
//   BT  the board's strategy core (web/board-trade-core.js): pathsOf, nodeOf, recordLines, contentOf, agentsOf
// Nothing here reads the network or signs anything. Every word is English: no promise of gains, nobody named as
// running an agent, a Borrow says it opens a loan of the agent that must be repaid, and a list of others' strategies
// ends "Not an endorsement.".
//
//   strategyView(row, { T, BT, assets, clean })  a published row ({ id, name, agentId, publisher, at, strategy, layout,
//                                                 record? }) as the tools show it, or null when T can't read it
//   viewLines(view, { full })                     its lines of text (full: every trade and loan of its record too)
//   pathLines(view)                               its nodes, each trigger's path, an If's Yes and No under it
//   draftLink(appUrl, strategy, layout, BT)       Go mode's link that opens a strategy as a draft: { url } or { why }
//   base64url(text)                               the link's fragment: UTF-8, then base64url with no padding

/** The words a list of others' strategies ends with. */
export const NOT_ENDORSEMENT = "Not an endorsement.";
/** What a Borrow node does, said wherever one is shown. */
export const BORROW_WORDS = "A Borrow opens a loan of the agent that must be repaid.";
/** The most characters a draft link's fragment carries after "trade-draft=" (Go mode's reader, web/account-trade.js
 *  DRAFT_MAX, opens nothing longer): room for the board's longest content (board-trade-core.js RULES.contentMax) in
 *  base64url. */
export const DRAFT_LINK_MAX = 32768;

const ID = /^0x[0-9a-f]{64}$/;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const AGENT = /^[1-9][0-9]{0,11}$/;
const TX = /^0x[0-9a-f]{64}$/;
const DEC = /^\d{1,12}(?:\.\d{1,18})?$/;
const isObj = (x) => !!x && typeof x === "object" && !Array.isArray(x);
const iso = (t) => (Number.isSafeInteger(Number(t)) && Number(t) > 0 ? new Date(Number(t) * 1000).toISOString().replace(".000Z", "Z") : null);
const nid = (id) => { const m = /^n(\d+)$/.exec(String(id)); return m ? Number(m[1]) : Infinity; };
const plain = (s, n) => {
  const t = String(s ?? "").replace(/[\u0000-\u001f\u007f-\u00a0\u2028\u2029\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, " ").replace(/ {2,}/g, " ").trim();
  return t.length > n ? `${t.slice(0, n)}…` : t;
};

/** The agents a context names: each id once, as "#<id>". */
const agentsCtx = (ids) => [...new Set(ids.map(String).filter((x) => AGENT.test(x)))].map((id) => ({ id, label: `#${id}` }));

/** A record as GET /api/strategies/<id> gives it (data-worker/strategy-record.mjs summaryOf), checked field by field:
 *  { lines (the board's words), counts, trades, loans, partial }, or null for none. */
function recordView(record, BT) {
  if (!isObj(record) || !isObj(record.counts)) return null;
  const n = (v) => (Number.isSafeInteger(Number(v)) && Number(v) >= 0 ? Number(v) : 0);
  const d = (v) => (typeof v === "string" && DEC.test(v) ? v : null);
  const c = record.counts;
  const counts = { trades: n(c.trades), buys: n(c.buys), sells: n(c.sells), tradedUsd: d(c.tradedUsd) || "0.00", loans: n(c.loans), borrowedUsd: d(c.borrowedUsd) || "0.00", repaid: n(c.repaid), onTime: n(c.onTime), late: n(c.late), open: n(c.open), overdue: n(c.overdue), defaulted: n(c.defaulted), ownLine: n(c.ownLine) };
  const trades = (Array.isArray(record.trades) ? record.trades : []).slice(0, 20).filter(isObj).map((t) => ({
    tx: TX.test(t.tx) ? t.tx : null, at: iso(t.at), side: t.side === "buy" || t.side === "sell" ? t.side : null,
    token: ADDRESS.test(t.token) ? t.token : null, symbol: typeof t.symbol === "string" && /^[A-Z0-9.]{1,12}$/.test(t.symbol) ? t.symbol : null, usd: d(t.usd), amount: d(t.amount),
  })).filter((t) => t.tx && t.side);
  const loans = (Array.isArray(record.loans) ? record.loans : []).slice(0, 20).filter(isObj).map((l) => ({
    loanId: typeof l.loanId === "string" && /^\d{1,30}$/.test(l.loanId) ? l.loanId : null, tx: TX.test(l.tx) ? l.tx : null, principal: d(l.principal), fee: d(l.fee),
    issuedAt: iso(l.issuedAt), dueAt: iso(l.dueAt), closedAt: iso(l.closedAt), state: ["repaid", "open", "defaulted"].includes(l.state) ? l.state : null,
    onTime: l.onTime === true ? true : l.onTime === false ? false : null, late: l.late === true, overdue: l.overdue === true,
    own: l.own === "owner" || l.own === "collateral" ? l.own : null, lineKey: l.lineKey === true, sponsorId: typeof l.sponsorId === "string" && AGENT.test(l.sponsorId) ? l.sponsorId : null,
  })).filter((l) => l.loanId && l.state);
  const lines = BT.recordLines({ ...record, counts }).map((x) => x.text);
  return { lines, counts, trades, loans, partial: record.partial === true };
}

/**
 * A strategy as the tools show it, or null when the Trade tab's core can't read it. `row`: { id?, name?, agentId?,
 * publisher?, at?, strategy, layout?, record? } (a row of /api/strategies; a draft has no id). `assets`: the stock tokens
 * ({ symbol, name, token }). `clean(text, n)`: the server's cleaning of others' words (its fence's).
 * { id, name, agentId, publisher, publishedAt, limits, nodes, paths, borrows, record }
 */
export function strategyView(row, { T, BT, assets = [], clean = plain } = {}) {
  if (!isObj(row) || !T || !BT || !isObj(row.strategy)) return null;
  let g;
  try { g = T.fromPublished({ name: "", strategy: row.strategy, graph: { nodes: Array.isArray(row.layout) ? row.layout : [] } }); } catch (_) { return null; }
  const agentId = AGENT.test(String(row.agentId ?? "")) ? String(row.agentId) : null;
  let named = [];
  try { named = BT.agentsOf(row.strategy); } catch (_) { named = []; }
  const ctx = { assets: Array.isArray(assets) ? assets : [], agents: agentsCtx([...(agentId ? [agentId] : []), ...named]) };
  const nodes = g.nodes.slice().sort((a, b) => nid(a.id) - nid(b.id)).map((n) => BT.nodeOf(T, n, ctx));
  return {
    id: typeof row.id === "string" && ID.test(row.id.toLowerCase()) ? row.id.toLowerCase() : null,
    name: clean(String(row.name ?? ""), 60) || "Strategy",
    agentId: agentId ? Number(agentId) : null,
    publisher: typeof row.publisher === "string" && ADDRESS.test(row.publisher) ? row.publisher : null,
    publishedAt: iso(row.at),
    limits: T.limitsSentence(T.limitsOf(g)),
    nodes,
    paths: BT.pathsOf(T, g, ctx),
    borrows: nodes.some((n) => n.type === "borrow"),
    record: row.record === undefined ? undefined : recordView(row.record, BT),
  };
}

/** One node in words: its title, what it does with its levels and amounts, and a Borrow's loan. */
const nodeText = (n) => `${n.title}: ${n.summary}${n.note ? `. ${n.note}` : ""}`;

/** The strategy's nodes, path by path: each trigger, the nodes it leads to, an If's Yes and No under it. */
export function pathLines(view, pad = "  ") {
  const out = [], byId = new Map(view.nodes.map((n) => [n.id, n]));
  const walk = (steps, at) => {
    if (!steps.length) { out.push(`${at}(nothing)`); return; }
    for (const s of steps) {
      if (s.again) { const n = byId.get(s.again); out.push(`${at}then on to [${s.again}] ${n ? n.title : "a node"}, shown above`); continue; }
      out.push(`${at}[${s.node.id}] ${nodeText(s.node)}`);
      if (s.branches) for (const b of s.branches) { out.push(`${at}  ${b.label}:`); walk(b.steps, at + "    "); }
    }
  };
  view.paths.forEach((p, i) => { out.push(`${pad}Path ${i + 1}:`); walk(p, pad + "  "); });
  return out;
}

/** A loan of the record in words, as Score v2 counts it. */
function loanText(l) {
  const ended = l.state === "repaid" ? (l.onTime === false || l.late ? "repaid late" : "repaid on time") : l.state === "defaulted" ? "defaulted" : l.overdue ? "past due" : "open";
  const own = l.own === "owner" ? ", on a line its owner backs itself (it builds nothing in Score v2)" : l.own === "collateral" ? ", on its owner's own collateral (it builds nothing in Score v2)" : "";
  return `loan #${l.loanId}: ${l.principal ?? "?"} USDG, fee ${l.fee ?? "?"} USDG${l.dueAt ? `, due ${l.dueAt}` : ""}, ${ended}${own}${l.lineKey ? ", drawn through LineKey" : ""}${l.tx ? ` (tx ${l.tx})` : ""}`;
}
const tradeText = (t) => `${t.side} ${t.amount ?? "?"} ${t.symbol ?? t.token ?? "a token"} for ${t.usd ?? "?"} USDG${t.at ? ` on ${t.at}` : ""} (tx ${t.tx})`;

/** A strategy's lines of text: its name, agent, publisher and limits, its nodes path by path, and its record (`full`:
 *  each trade and loan of it too). */
export function viewLines(view, { full = false } = {}) {
  const head = [`"${view.name}"`];
  if (view.id) head.push(`(id ${view.id})`);
  if (view.agentId) head.push(`for agent #${view.agentId}`);
  const when = [view.publisher ? `published by ${view.publisher}` : "", view.publishedAt ? `on ${view.publishedAt}` : ""].filter(Boolean).join(" ");
  const lines = [`${head.join(" ")}${when ? `, ${when}` : ""}.`, `  Limits: ${view.limits}`, "  Nodes:", ...pathLines(view, "    ")];
  if (view.borrows) lines.push(`  ${BORROW_WORDS}`);
  if (view.record !== undefined) {
    const r = view.record;
    lines.push(`  Record read on chain: ${r ? r.lines.join(" ") : "Its record could not be read just now."}`);
    if (full && r) {
      for (const t of r.trades) lines.push(`    - ${tradeText(t)}`);
      for (const l of r.loans) lines.push(`    - ${loanText(l)}`);
    }
  }
  return lines;
}

/** UTF-8 `text` in base64url, with no padding. */
export function base64url(text) {
  const bytes = new TextEncoder().encode(String(text));
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * Go mode's link that opens a strategy as a draft in the account's Trade tab: `<appUrl>#trade-draft=<base64url of
 * contentOf({ strategy, layout })>` (the board's one written form of a strategy and its cards' places). In the address's
 * fragment, which no server is sent. { url } or { url: null, why } when it is longer than a link carries.
 */
export function draftLink(appUrl, strategy, layout, BT) {
  const content = BT.contentOf({ strategy, layout: Array.isArray(layout) ? layout : [] });
  if (content.length > BT.RULES.contentMax) return { url: null, why: `it is ${content.length} characters long written out, and a draft link carries at most ${BT.RULES.contentMax}` };
  const frag = base64url(content);
  if (frag.length > DRAFT_LINK_MAX) return { url: null, why: `its link would carry ${frag.length} characters, and Go mode reads at most ${DRAFT_LINK_MAX}` };
  const u = new URL(appUrl);
  u.hash = `trade-draft=${frag}`;
  return { url: u.href };
}
