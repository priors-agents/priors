/* Trade on the board (SITE_BOARD_TRADE, with SITE_BOARD and SITE_TRADE; docs/builds/2026-11-10-trade-strategies.md, Task 4):
   the published strategies' one source of truth for three places. Pure (no DOM, no fetch, no clock of its own), UMD as
   board-core.js: window.PriorsStrategyBoardCore; node and the data Worker require it as it is.
     - the data Worker's store (data-worker/strategy-board.mjs): the typed data it checks, the content's one written form;
     - Go mode's Publish and Unpublish (web/account-trade.js's [board-trade] lines): the typed data the account signs;
     - the board's Trade tab (web/board-trade.js): each strategy's card, its record's words, Copy into Go mode's link.

   Publishing is one EIP-712 message, domain "Priors Strategy Board" 1 on chain 4663 (a board message can never be read as
   any other Priors message), signed by the publisher: a Go mode account (a smart account: ERC-1271, ERC-6492's wrapper
   while it is not on chain yet) or, in Builder mode, a plain wallet. The publisher must be the registry owner of the
   agent the message names, and every agent the strategy names is that one.
     StrategyPublish   { publisher address, agentId uint256, name string, strategy string, at uint256 }
                       `strategy`: contentOf({ strategy, layout }), the strategy rules (trade-core.js compile, priors.strategy
                       v1) and the cards' places, as one canonical JSON text (keys sorted, no space): the wallet shows
                       exactly what is published. `at`: when it was signed (unix seconds). Its id: the message's EIP-712
                       hash, in lower case.
     StrategyUnpublish { publisher address, id bytes32, at uint256 }   the same publisher, for one id

     DOMAIN, TYPES, RULES, contentOf(x), parseContent(text), layoutOf(graph), agentsOf(strategy), publishMessage(o),
     unpublishMessage(o), typedData(primaryType, message, { bigint }), copyHref(app, id)
     cardOf(row, x)        a strategy as the board's card shows it (x: { T: trade-core.js, C: board-core.js, board, assets })
     recordLines(record)   its record read on chain, in words: [{ key, text }]
   Every word is English (the board has no dictionary): no promise of gains, no one named as running an agent, a borrow
   says it opens a loan of the agent that must be repaid, and the list ends "Not an endorsement." */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module && module.exports) module.exports = api;
  if (root) root.PriorsStrategyBoardCore = api;
})(typeof window !== "undefined" ? window : typeof globalThis !== "undefined" ? globalThis : null, function () {
  "use strict";

  const CHAIN_ID = 4663;
  const DOMAIN = Object.freeze({ name: "Priors Strategy Board", version: "1", chainId: CHAIN_ID });
  const TYPES = Object.freeze({
    StrategyPublish: Object.freeze([
      { name: "publisher", type: "address" },
      { name: "agentId", type: "uint256" },
      { name: "name", type: "string" },
      { name: "strategy", type: "string" },
      { name: "at", type: "uint256" },
    ]),
    StrategyUnpublish: Object.freeze([
      { name: "publisher", type: "address" },
      { name: "id", type: "bytes32" },
      { name: "at", type: "uint256" },
    ]),
  });
  // the store's rules (data-worker/strategy-board.mjs holds them; Go mode and Builder mode read them to say why first)
  const RULES = Object.freeze({
    nameMax: 60, // a name, after its spaces are trimmed
    contentMax: 24000, // the content's characters
    bodyBytes: 32768, // a POST's body
    signedAgoS: 3600, // a message signed at most an hour ago
    signedAheadS: 300, // and at most 5 minutes ahead of the store's clock
    livePerPublisher: 10, // live strategies a publisher keeps on the board
    liveMax: 300, // live strategies on the board, each space
    writesPerSignerDay: 30, // writes a publisher signs in any 24 hours
    listMax: 100, // GET /api/strategies' rows, newest first
    recordTtlS: 600, // a record read on chain is read again after this long
  });
  const SCHEMA = "priors.strategy", NODE_ID = /^n\d{1,4}$/, AGENT = /^[1-9]\d{0,11}$/;
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o || {}, k);

  /* ---- the content: one written form ---- */
  function canon(v) {
    if (Array.isArray(v)) return v.map(canon);
    if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
    return v;
  }
  /** The cards' places a graph gives (trade-core.js's graph: its nodes' id, type, x, y), whole pixels from 0 to 4000. */
  function layoutOf(graph) {
    const nodes = graph && Array.isArray(graph.nodes) ? graph.nodes : [];
    const px = (v) => Math.max(0, Math.min(4000, Math.round(Number(v) || 0)));
    return nodes.filter((n) => n && NODE_ID.test(String(n.id)) && typeof n.type === "string").map((n) => ({ id: n.id, type: n.type, x: px(n.x), y: px(n.y) }));
  }
  /** The text a StrategyPublish message carries as `strategy`: { layout, strategy } as canonical JSON. */
  const contentOf = (x) => JSON.stringify(canon({ layout: Array.isArray(x && x.layout) ? x.layout : [], strategy: x && x.strategy }));
  /** The content back: { strategy, layout }, or an Error naming what is wrong. Its one written form only (the same text
   *  contentOf gives), at most RULES.contentMax characters, with a priors.strategy v1 and a layout of known nodes. */
  function parseContent(text) {
    if (typeof text !== "string" || !text || text.length > RULES.contentMax) throw new Error(`the strategy must be a JSON text of at most ${RULES.contentMax} characters`);
    let x;
    try { x = JSON.parse(text); } catch (_) { throw new Error("the strategy is not JSON"); }
    if (!x || typeof x !== "object" || Array.isArray(x) || Object.keys(x).sort().join(",") !== "layout,strategy") throw new Error("the strategy takes exactly layout and strategy");
    if (!x.strategy || x.strategy.kind !== SCHEMA || x.strategy.v !== 1) throw new Error("the strategy is not a priors.strategy v1");
    if (!Array.isArray(x.layout) || x.layout.length > 40 || !x.layout.every((n) => n && Object.keys(n).sort().join(",") === "id,type,x,y" && NODE_ID.test(n.id) && typeof n.type === "string" && n.type.length <= 12 && Number.isInteger(n.x) && Number.isInteger(n.y) && n.x >= 0 && n.y >= 0 && n.x <= 4000 && n.y <= 4000)) throw new Error("the layout must list the cards' places: { id, type, x, y }, whole pixels from 0 to 4000");
    if (contentOf(x) !== text) throw new Error("the strategy is not in its one written form (contentOf: keys sorted, no space)");
    return { strategy: x.strategy, layout: x.layout };
  }
  /** Every agent id the strategy rules name (a trigger's, a step's, a test's), as decimal strings, A to Z. */
  function agentsOf(strategy) {
    const out = new Set();
    const seen = (o) => { if (o && typeof o === "object" && own(o, "agent")) out.add(String(o.agent)); };
    const steps = (list, depth) => {
      if (!Array.isArray(list) || depth > 50) return;
      for (const s of list) { seen(s); if (s && s.op === "if") { seen(s.test); steps(s.yes, depth + 1); steps(s.no, depth + 1); } }
    };
    for (const r of (strategy && Array.isArray(strategy.rules) ? strategy.rules : [])) { seen(r && r.when); steps(r && r.do, 0); }
    return [...out].sort();
  }

  /* ---- the messages ---- */
  const uint = (v) => String(typeof v === "bigint" ? v : Math.floor(Number(v)));
  /** A StrategyPublish message: publisher (an address), agentId, name (trimmed), the content of { strategy, layout }, at. */
  const publishMessage = (o) => ({ publisher: String(o.publisher), agentId: uint(o.agentId), name: String(o.name == null ? "" : o.name).trim().slice(0, RULES.nameMax), strategy: contentOf({ strategy: o.strategy, layout: o.layout }), at: uint(o.at) });
  const unpublishMessage = (o) => ({ publisher: String(o.publisher), id: String(o.id).toLowerCase(), at: uint(o.at) });
  /** The typed data for eth_signTypedData_v4 and the account's own signTypedData: { domain, types, primaryType, message };
   *  with `bigint`, its uints as bigints (viem's account), else as decimal strings (ethers, a wallet's JSON). */
  function typedData(primaryType, message, { bigint = false } = {}) {
    if (!own(TYPES, primaryType)) throw new Error("no such message: " + primaryType);
    const m = { ...message };
    for (const f of TYPES[primaryType]) if (f.type === "uint256" && m[f.name] != null) m[f.name] = bigint ? BigInt(m[f.name]) : String(m[f.name]);
    return { domain: { ...DOMAIN }, types: { [primaryType]: TYPES[primaryType].map((f) => ({ ...f })) }, primaryType, message: m };
  }
  const ID = /^0x[0-9a-f]{64}$/;
  /** Copy into Go mode: the account's Trade tab, which opens the strategy `id` as a draft (account-trade.js). */
  const copyHref = (app, id) => (typeof app === "string" && /^https:\/\/[a-z0-9.-]+$/.test(app) && ID.test(String(id)) ? `${app}/account?trade=${id}` : null);

  /* ---- the board's words ---- */
  const TITLE = "Trade";
  const SUB = "Trading strategies their owners published for their agents: each one's nodes, levels and amounts in full, the agent it runs for, and that agent's record read on chain. Copy one into Go mode to start from it: it opens as a draft, and nothing runs before you turn it on there.";
  const NOT_ENDORSEMENT = "Not an endorsement.";
  const EMPTY = "No strategy is published yet.";
  const LOADING = "Loading strategies…";
  const UNREAD = "The strategies can't be read just now. The board tries again in a minute.";
  const COPY = "Copy into Go mode";
  const COPY_NOTE = "Opens as a draft in Go mode's Trade tab, with these levels and amounts. Nothing runs until you check it and turn it on there.";
  const BORROW_NOTE = "Opens a loan of the agent that must be repaid.";
  const TITLES = {
    schedule: "On a timer", price_up: "Price rises to", price_down: "Price falls to", loan_due: "Loan due soon", tick: "Every pass",
    if: "If", borrow: "Borrow on the agent's line", buy: "Buy a token", sell: "Sell a share of a token", repay: "Repay the agent's loan", stop: "Stop here",
  };
  const KINDS = { trigger: "Trigger", if: "If", action: "Action" };
  const NUM = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
  const money = (v) => { const n = NUM(v); return "$" + (Math.round(n * 100) / 100).toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 }); };

  /** A node as the card shows it: its title, its kind, what it does in a few words (its levels and amounts). */
  function nodeOf(T, n, ctx) {
    const m = T.node(n.type, n.values);
    let summary = T.summary(n, ctx);
    if (n.type === "buy") summary = summary.replace(/ · (?:your USDG|borrowed USDG)$/, "") + (n.values && n.values.from === "loan" ? ", with the USDG borrowed before it" : ", with the account's USDG");
    const out = { id: n.id, type: n.type, kind: m.kind, kindLabel: KINDS[m.kind] || m.kind, title: TITLES[n.type] || m.title, summary };
    if (n.type === "borrow") out.note = BORROW_NOTE;
    return out;
  }
  /** Each trigger's path, top to bottom: [{ node, then: [paths] (an If's Yes and No: { branch, label, steps }) }]; a node
   *  two paths share is shown once, and named again where the second meets it. */
  function pathsOf(T, g, ctx) {
    const shown = new Set(), byId = (id) => g.nodes.find((x) => x.id === id) || null;
    const walk = (id, depth) => {
      const steps = [];
      for (let cur = id; cur && depth < 40; depth++) {
        const n = byId(cur); if (!n) break;
        if (shown.has(n.id)) { steps.push({ again: n.id }); break; }
        shown.add(n.id);
        const step = { node: nodeOf(T, n, ctx) };
        steps.push(step);
        if (T.kindOf(n.type) === "if") { step.branches = [["yes", "Yes"], ["no", "No"]].map(([b, label]) => ({ branch: b, label, steps: walk(T.next(g, n.id, b), depth + 1) })); break; }
        if (!T.outputs(n.type).length) break;
        cur = T.next(g, n.id, "out");
      }
      return steps;
    };
    const ts = g.nodes.filter((n) => T.kindOf(n.type) === "trigger").sort((a, b) => a.y - b.y || a.x - b.x);
    return ts.map((t) => walk(t.id, 0));
  }
  /** The agent's Priors record as the board's row has it, in a few words. */
  function agentRecord(C, row) {
    if (!row) return "No Priors record yet";
    if (row.defaulted) return "Defaulted";
    const n = NUM(row.loansRepaid), late = NUM(row.late);
    return plural(n, "loan repaid", "loans repaid") + (late > 0 ? ` · ${late} late` : "");
  }
  /**
   * A published strategy as the board's card shows it (`row`: GET /api/strategies' row: { id, name, agentId, at, strategy,
   * layout, record }), or null when trade-core.js can't read it. x: { T (trade-core.js), C (board-core.js), board (the
   * board's answer, for the agent's name and record), assets ([{ symbol, name, token }]), app (Go mode's origin) }.
   * { id, name, agent: { id, name, idText, href, record }, limits, paths, record (recordLines), copy }
   */
  function cardOf(row, x) {
    const T = x && x.T, C = x && x.C;
    if (!row || !T || !C || !ID.test(String(row.id))) return null;
    let g;
    try { g = T.fromPublished({ id: row.id, name: row.name, strategy: row.strategy, graph: { nodes: Array.isArray(row.layout) ? row.layout : [] } }); } catch (_) { return null; }
    const agentId = String(row.agentId), rows = x.board && Array.isArray(x.board.agents) ? x.board.agents : [];
    const r = rows.find((a) => a && String(a.id) === agentId) || null, nm = C.nameOf(r || { id: agentId });
    const ctx = { assets: x.assets || [], agents: [{ id: agentId, label: `#${agentId}` }] };
    return {
      id: row.id,
      name: String(row.name || "").trim() || "Strategy",
      agent: { id: agentId, name: nm.name, idText: nm.id, href: C.agentPath(agentId), record: agentRecord(C, r) },
      published: NUM(row.at) > 0 ? C.date(NUM(row.at)) : "",
      limits: T.limitsSentence(T.limitsOf(g)),
      paths: pathsOf(T, g, ctx),
      record: recordLines(row.record),
      copy: copyHref(x.app, row.id),
    };
  }

  /**
   * A strategy's record read on chain (data-worker/strategy-board.mjs's `record`), in words: [{ key, text }].
   *   trades   the trades its account's trading key made (the key's operations' Uniswap swaps)
   *   loans    the loans of the agent paid to the account, and how they ended: "repaid on time" is Score v2's, repaid
   *            at most 24 hours after the due time; a late one says so
   *   own      the loans on a line its owner backs itself, or on its owner's own collateral, which build nothing in
   *            Score v2
   *   reading  the record is still being read (older blocks wait for the next read)
   */
  function recordLines(record) {
    if (!record || typeof record !== "object" || !record.counts) return [{ key: "none", text: "Its record is being read on chain." }];
    const c = record.counts, out = [];
    const trades = NUM(c.trades), buys = NUM(c.buys), sells = NUM(c.sells);
    out.push({ key: "trades", text: trades ? `Trades by its account's key: ${trades} (${plural(buys, "buy", "buys")}, ${plural(sells, "sell", "sells")}), ${money(c.tradedUsd)} in all.` : "Trades by its account's key: none yet." });
    const loans = NUM(c.loans);
    if (!loans) out.push({ key: "loans", text: "Loans of the agent paid to its account: none yet." });
    else {
      const parts = [`${NUM(c.onTime)} repaid on time`];
      if (NUM(c.late)) parts.push(`${NUM(c.late)} repaid late`);
      if (NUM(c.open)) parts.push(`${NUM(c.open)} open`);
      if (NUM(c.overdue)) parts.push(`${NUM(c.overdue)} past due`);
      if (NUM(c.defaulted)) parts.push(`${NUM(c.defaulted)} defaulted`);
      out.push({ key: "loans", text: `Loans of the agent paid to its account: ${loans}, ${money(c.borrowedUsd)} borrowed. ${parts.join(", ")}. On time as Score v2 counts it: repaid at most 24 hours after the due time.` });
    }
    if (NUM(c.ownLine)) out.push({ key: "own", text: `${NUM(c.ownLine) === loans ? (loans === 1 ? "It is" : "All of them are") : `${NUM(c.ownLine)} of them ${NUM(c.ownLine) === 1 ? "is" : "are"}`} on a line its owner backs itself or on its owner's own collateral, which builds nothing in Score v2.` });
    if (record.partial) out.push({ key: "reading", text: "Older blocks are still being read: the record grows at the next reads." });
    return out;
  }

  return {
    CHAIN_ID, DOMAIN, TYPES, RULES, SCHEMA, contentOf, parseContent, layoutOf, agentsOf, publishMessage, unpublishMessage, typedData, copyHref,
    TITLE, SUB, NOT_ENDORSEMENT, EMPTY, LOADING, UNREAD, COPY, COPY_NOTE, BORROW_NOTE, TITLES, cardOf, pathsOf, nodeOf, recordLines, agentRecord,
  };
});
