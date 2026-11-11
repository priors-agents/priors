/* Trade's core: everything Go mode's Trade tab knows (web/account-trade.js), with no DOM, so Node loads it too
   (scripts/test-trade-core.mjs, and the executor's side: autopilot/strategy.mjs compiles the same graphs and compares).
   It ships with the tab, behind its own switch (SITE_TRADE=on, and only with Automations: scripts/build-site.mjs).

   A strategy is a graph an account draws for its agent, n8n's idea: nodes joined by links, each node a card on a canvas.
   - Triggers start a path: on a timer, a price rises to a level, a price falls to a level, a loan of the agent comes due
     soon, every pass of the executor (every 10 minutes).
   - If checks one thing the executor reads on chain (a Chainlink price against a level, a token held, the USDG kept, a
     loan of the agent open or due within some hours, the time of day in UTC) and follows Yes or No: both need a next node.
   - Actions: borrow on the agent's line (through its line key, LineKey, paid to the account, $5 to $10: it opens a loan of
     the agent that must be repaid), buy a stock token, sell some of it, repay the agent's loan, stop.
   - Limits: the most per trade, the most the key spends in all, the USDG always kept, how long the key lasts, never past
     the stage's caps (STAGE: autopilot/rules.mjs STAGE and automation-core.js STAGE, held equal by the test).
   problems() refuses a graph that cannot run, each refusal one sentence that names the fix: a loop, a buy with no
   funding, a borrow over the caps, a sell of a token the strategy never buys before it, an If with a branch missing, a
   node left unconnected, more buys or sells than one key takes, a field's value. Every refusal line below carries its
   code (// check:<code>), so the test can take each one out and see its own case fail.

   The graph (kept in the browser, localStorage priors.trade.<account>, account-trade.js):
     { v: 1, id, name, seq, nodes: [{ id: "n1", type, values, x, y }], edges: [{ from, to, branch? }],
       limits: { perTrade, total, keep, days }, template?, from?, applied? }
     node types: schedule, price_up, price_down, loan_due, tick (triggers); if; borrow, buy, sell, repay, stop (actions).
     An edge leaves a node's output and enters another's input. Triggers have no input; If has two outputs, its edges
     carry branch "yes" or "no"; Stop has none; every other node has one output ("out", no branch on its edge). One edge
     per output: linking an output again replaces its edge. Several edges may enter one input.

   compile(graph) -> the strategy rules, version 1 (what Tasks 2 and 3's executor runs, autopilot/strategy.mjs; amounts
   are decimal strings of dollars, prices decimal strings of dollars by Chainlink, tokens the stock tokens' addresses
   as the graph holds them, agents decimal strings of their ids, hours and days integers):
     { "kind": "priors.strategy", "v": 1,
       "caps": { "perTradeUsd": "5", "totalUsd": "20", "keepUsd": "5" }, "days": 14,
       "rules": [ { "id": "<trigger node id>", "when": <when>, "do": [<step>, ...] }, ... ] }   (by trigger id: n1, n2, ..)
     <when>:  { "on": "schedule", "everyHours": 168 }              starts at the first pass, then every everyHours
              { "on": "price_up", "token": "0x…", "above": "450" }  Chainlink's price >= above (fresh), at most hourly
              { "on": "price_down", "token": "0x…", "below": "380" } Chainlink's price <= below (fresh), at most hourly
              { "on": "loan_due", "agent": "7310", "withinHours": 24 } a loan of the agent the account took is due within
              { "on": "tick" }                                       every pass
     <step>:  { "op": "if", "node": "n2", "test": <test>, "yes": [<step>…], "no": [<step>…] }   (always a list's last)
              { "op": "borrow", "node": "n3", "agent": "7310", "usd": "5", "days": 7 }   LineKey's spend to the account,
                                                                    Repay on time's coverLast in the same operation
              { "op": "buy", "node": "n4", "token": "0x…", "usd": "5", "from": "loan" | "usdg" }
              { "op": "sell", "node": "n5", "token": "0x…", "pct": 100 }
              { "op": "repay", "node": "n6", "agent": "7310", "capUsd": "6" }
              { "op": "stop", "node": "n7" }                         (always a list's last)
     <test>:  { "is": "price_above", "token": "0x…", "price": "450" }   Chainlink's price >= price
              { "is": "price_below", "token": "0x…", "price": "380" }   Chainlink's price <= price
              { "is": "holds", "token": "0x…" }                          the account's balance of it > 0
              { "is": "usdg_at_least", "usd": "10" }                     the account's USDG >= usd
              { "is": "loan_open", "agent": "7310" }                     a loan of the agent the account took is open
              { "is": "loan_due_within", "agent": "7310", "hours": 24 }  one of them is due within hours
              { "is": "time_between", "fromHour": 14, "toHour": 20, "weekdays": true }  UTC, from included, to not
                                                                    (from > to wraps midnight), Monday to Friday
     Several links into one node compile to the same steps under each path (the node id says it is one node).
   toAutomationRules(graph): for a graph with no If, no borrow and nothing today's executors don't run, what they run
   unchanged: { rules: Trade by rules' rules ({ buys, sells, caps, days }, automation-core.js compile's form) or null,
   plans: Repay on time's plans ([{ agent_id, cap_usd, use_savings, late }], desk-core's autopay_on) }; else null.
   fromPublished(strategy) -> a draft graph (Copy into Go mode): a published record { id?, name?, strategy, graph? } or
   the strategy rules alone; the rules are the source, the published graph only gives the cards their places.

   window.PriorsTradeCore:
     STAGE, BORROW, LIQUID, SCHEMA, VERSION, NODES, TRIGGERS, ACTIONS, TESTS, TEMPLATES, CODES
     node(type, values)            a node's words: { type, kind, kindLabel, title, help, example, note?, fields }
     outputs(type), hasInput(type)
     newGraph(name), addNode(g, type, at, ctx), connect(g, from, to, branch), canConnect(…), disconnect(g, from, branch),
     removeNode(g, id), moveNode(g, id, x, y), setValue(g, id, key, value), next(g, id, port), insertAfter(g, from,
     branch, type, ctx), layout(g), template(key), fromTemplate(key, ctx), tradable(ctx)
     fieldError(type, key, value, ctx, values), problems(g, ctx): [{ code, node, field, text }]
     compile(g), toAutomationRules(g), needsExecutor(g), fromPublished(x), summary(node, ctx), limitsSentence(L)
   ctx: { assets: [{ symbol, name, token }], prices: { SYMBOL: dollars }, agents: [{ id, label, cap }], caps (the gas
   gate's, when it names lower ones), repayCap }. */
(function (root) {
  "use strict";
  const fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (m, k) => (v && v[k] != null ? String(v[k]) : m));
  const _t = (s, v) => (root.PriorsI18n ? root.PriorsI18n.t(s, v) : fill(s, v));
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o || {}, k);
  const clone = (x) => JSON.parse(JSON.stringify(x));

  // the stage's caps (autopilot/rules.mjs STAGE, automation-core.js STAGE: the test holds the three equal)
  const STAGE = Object.freeze({ perTradeUsd: 10, totalUsd: 50, days: 31, buys: 4, sells: 4, minTradeUsd: 1, minEveryHours: 1 });
  // a borrow: the pool's smallest loan, and the most per trade
  const BORROW = Object.freeze({ minUsd: 5, maxUsd: 10 });
  // the stock tokens a strategy may trade (automation-core.js LIQUID, the Desk's own list)
  const LIQUID = Object.freeze(["TSLA", "NVDA", "SPY", "QQQ", "AAPL", "MSFT", "GOOGL", "AMZN", "META", "PLTR"]);
  // Repay on time's most per loan for now (automation-core.js REPAY_CAP), unless the gate names less
  const REPAY_CAP = 25;
  const SCHEMA = "priors.strategy", VERSION = 1, MAX_NODES = 40;
  const LIMITS = Object.freeze({ perTrade: "5", total: "20", keep: "5", days: 14 });

  // ---- amounts: dollars as a person types them, kept as a plain decimal string (automation-core.js's own rules) ----
  function dec(v) {
    if (typeof v === "number") v = Number.isFinite(v) ? String(v) : "";
    if (typeof v !== "string") return null;
    let s = v.replace(/[\s$ ]/g, "");
    if (/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) s = s.replace(/,/g, "");
    else if (/^\d+,\d+$/.test(s)) s = s.replace(",", ".");
    if (!/^\d+(\.\d+)?$/.test(s)) return null;
    let [w, f = ""] = s.split(".");
    w = w.replace(/^0+(?=\d)/, ""); f = f.replace(/0+$/, "");
    return f ? w + "." + f : w;
  }
  function units(d, places) {
    if (d == null) return null;
    const [w, f = ""] = d.split(".");
    if (f.length > places) return null;
    return BigInt(w) * 10n ** BigInt(places) + BigInt((f + "0".repeat(places)).slice(0, places) || "0");
  }
  const usdOk = (d) => d != null && /^\d{1,7}(\.\d{1,6})?$/.test(d);
  const priceOk = (d) => d != null && /^\d{1,9}(\.\d{1,8})?$/.test(d);
  const usd6 = (v) => { const d = dec(v == null ? "" : String(v)); return usdOk(d) ? units(d, 6) : null; };
  function money(v) {
    const d = dec(String(v)); if (d == null) return String(v);
    const [w, f = ""] = d.split(".");
    return "$" + Number(w).toLocaleString("en-US") + (f ? "." + (f.length === 1 ? f + "0" : f) : "");
  }
  const money6 = (u) => money((Number(u) / 1e6).toFixed(6));
  const quoted = (v) => "“" + String(v == null ? "" : v).trim().slice(0, 24) + "”";

  // ---- the catalog ----
  const EVERY = [6, 12, 24, 72, 168];
  const everyWords = (h) => (h > 24 && h % 24 === 0 ? _t("Every {n} days", { n: h / 24 }) : _t("Every {n} hours", { n: h }));
  const PCT = [100, 50, 25];
  const pctWords = (p) => _t("{pct}% of what it holds", { pct: p });
  const TERMS = [7, 14, 30];
  const KEY_DAYS = [7, 14, 31];
  const daysWords = (n) => _t("{n} days", { n });
  const DUE = [6, 24, 48];
  const WITHIN = [6, 24, 48, 72];
  const HOURS = Array.from({ length: 24 }, (_, h) => h);
  const hourWords = (h) => _t("{h}:00 UTC", { h: String(h).padStart(2, "0") });
  const TESTS = Object.freeze(["price_above", "price_below", "holds", "usdg_min", "loan_open", "loan_due", "time"]);
  const TEST_WORDS = {
    price_above: () => _t("A price is at or above a level"), price_below: () => _t("A price is at or below a level"),
    holds: () => _t("Your account holds a token"), usdg_min: () => _t("Your account keeps at least some USDG"),
    loan_open: () => _t("A loan of your agent is open"), loan_due: () => _t("A loan of your agent is due soon"),
    time: () => _t("The time is in a window (UTC)"),
  };
  const FROM = { usdg: () => _t("Your account's USDG"), loan: () => _t("The USDG borrowed before it") };

  const fToken = () => ({ key: "token", type: "token", label: _t("Which token"), help: _t("A stock token. Only the tokens with the most trading on Uniswap are offered."), example: _t("Example: TSLA, Tesla's stock token.") });
  const fPrice = (up) => ({ key: "price", type: "price", label: _t("Level, in dollars"), help: _t("For one token, by Chainlink's price."), example: up ? _t("Example: 450, a little over today's price.") : _t("Example: 380, a little under today's price.") });
  const fAgent = (help) => ({ key: "agent", type: "agent", label: _t("Agent"), help, example: _t("Example: your agent research-desk #7310.") });
  const sel = (key, label, help, example, options) => ({ key, type: "select", label, help, example, options });
  const NODES = {
    schedule: { kind: "trigger", title: () => _t("On a timer"), help: () => _t("Starts its path again and again: first at the executor's next pass after you turn it on (it passes every 10 minutes), then once each period."), example: () => _t("Example: once a week."),
      fields: () => [sel("every", _t("How often it starts"), _t("The time between two starts."), _t("Example: every 7 days."), EVERY.map((h) => [h, everyWords(h)]))] },
    price_up: { kind: "trigger", title: () => _t("Price rises to"), help: () => _t("Starts its path when a stock token's price is at or above a level you choose, by Chainlink's price, which is fresh only while the markets are open. At most once an hour."), example: () => _t("Example: TSLA at $450 or more."),
      fields: () => [fToken(), fPrice(true)] },
    price_down: { kind: "trigger", title: () => _t("Price falls to"), help: () => _t("Starts its path when a stock token's price is at or below a level you choose, by Chainlink's price, which is fresh only while the markets are open. At most once an hour."), example: () => _t("Example: TSLA at $380 or less."),
      fields: () => [fToken(), fPrice(false)] },
    loan_due: { kind: "trigger", title: () => _t("Loan due soon"), help: () => _t("Starts its path when a loan your account took for your agent is due within the hours you choose."), example: () => _t("Example: 24 hours before the due date."),
      fields: () => [fAgent(_t("The agent whose loans it watches: the loans your account takes for it.")), sel("hours", _t("How long before it is due"), _t("With 6 hours it is what Repay on time does today, so it can run now."), _t("Example: 24 hours before it is due."), DUE.map((h) => [h, _t("{n} hours before it is due", { n: h })]))] },
    tick: { kind: "trigger", title: () => _t("Every pass"), help: () => _t("Starts its path at each of the executor's passes, every 10 minutes. Put an If after it, so it acts only when that holds."), example: () => _t("Example: check a price at every pass."),
      fields: () => [] },
    if: { kind: "if", title: () => _t("If"), help: () => _t("Checks one thing the executor reads on chain, then follows Yes or No. Both need a next node: use Stop to end one."), example: () => _t("Example: if TSLA is at $400 or more."),
      fields: (v) => {
        const test = sel("test", _t("What it checks"), _t("Read on chain at each pass, nothing else."), _t("Example: a price is at or above a level."), TESTS.map((t) => [t, TEST_WORDS[t]()]));
        const t = v && TESTS.includes(v.test) ? v.test : "price_above";
        const more = {
          price_above: () => [fToken(), fPrice(true)], price_below: () => [fToken(), fPrice(false)], holds: () => [fToken()],
          usdg_min: () => [{ key: "usd", type: "usd", label: _t("USDG at least"), help: _t("In dollars: the USDG your account holds when it checks."), example: _t("Example: 10.") }],
          loan_open: () => [fAgent(_t("The agent whose loans it reads: the loans your account takes for it."))],
          loan_due: () => [fAgent(_t("The agent whose loans it reads: the loans your account takes for it.")), sel("hours", _t("Due within"), _t("Counted from the moment it checks."), _t("Example: within 24 hours."), WITHIN.map((h) => [h, _t("Within {n} hours", { n: h })]))],
          time: () => [sel("from", _t("From (UTC)"), _t("The executor's clock, in UTC."), _t("Example: 14:00 UTC."), HOURS.map((h) => [h, hourWords(h)])), sel("to", _t("Until (UTC)"), _t("Up to this hour, not included. Before the start, it runs past midnight."), _t("Example: 20:00 UTC."), HOURS.map((h) => [h, hourWords(h)])),
            { key: "weekdays", type: "check", label: _t("Weekdays only"), help: _t("Monday to Friday, the days the stock markets open."), example: _t("Example: on.") }],
        }[t]();
        return [test, ...more];
      } },
    borrow: { kind: "action", title: () => _t("Borrow on your agent's line"), help: () => _t("Opens a loan of your agent, through its line key (LineKey), paid to your account. It is a loan that must be repaid: Repay on time marks it in the same operation, and it counts in the key's limits."), example: () => _t("Example: borrow $5 for 7 days."),
      note: () => _t("Opens a loan of your agent that must be repaid."),
      fields: () => [fAgent(_t("The agent whose line it borrows on. Its line key must be set up for your account.")), { key: "usd", type: "usd", label: _t("Amount to borrow"), help: _t("In dollars of USDG: at least $5, the pool's smallest loan, and at most $10, the most per trade."), example: _t("Example: $5.") },
        sel("days", _t("Loan term"), _t("When the loan is due. A loan repaid late counts against your agent's record."), _t("Example: 7 days."), TERMS.map((d) => [d, daysWords(d)]))] },
    buy: { kind: "action", title: () => _t("Buy a token"), help: () => _t("Buys a stock token on Uniswap, paid to your account. It pays with your account's USDG, or with the USDG a Borrow before it opened."), example: () => _t("Example: buy $5 of TSLA with the loan."),
      fields: () => [fToken(), { key: "usd", type: "usd", label: _t("Amount to spend"), help: _t("In dollars of USDG: $1 or more, and no more than the most per trade in Limits."), example: _t("Example: $5.") },
        sel("from", _t("Pays with"), _t("With the borrowed USDG, a Borrow must come before this buy on its path."), _t("Example: the USDG borrowed before it."), Object.keys(FROM).map((k) => [k, FROM[k]()]))] },
    sell: { kind: "action", title: () => _t("Sell a share of a token"), help: () => _t("Sells some of a stock token your account holds, for USDG paid to your account. This strategy must buy that token before it."), example: () => _t("Example: sell all the TSLA it holds."),
      fields: () => [fToken(), sel("pct", _t("Share to sell"), _t("A share of what your account holds of it when this runs."), _t("Example: 100% of what it holds."), PCT.map((p) => [p, pctWords(p)]))] },
    repay: { kind: "action", title: () => _t("Repay your agent's loan"), help: () => _t("Your account repays the open loan of your agent from its USDG: what was borrowed and its fee."), example: () => _t("Example: up to $6 for a $5 loan."),
      fields: () => [fAgent(_t("The agent whose loan it repays.")), { key: "cap", type: "usd", label: _t("Most it repays for one loan"), help: _t("What was borrowed and its fee: at least the amount its Borrow opens."), example: _t("Example: $6, for a $5 loan and its fee.") }] },
    stop: { kind: "action", title: () => _t("Stop here"), help: () => _t("Ends this path: nothing more happens on it until its trigger starts it again."), example: () => _t("Example: on an If's No, do nothing."),
      fields: () => [] },
  };
  const LIMIT_FIELDS = () => [
    { key: "perTrade", type: "usd", label: _t("Most a trade spends"), help: _t("No buy, sell or borrow spends more than this. At most $10 for now."), example: _t("Example: $5.") },
    { key: "total", type: "usd", label: _t("Most the key spends"), help: _t("Everything the key may spend, borrowed USDG included. At most $50 for now."), example: _t("Example: $20.") },
    { key: "keep", type: "usd", label: _t("USDG always kept"), help: _t("Buys stop before your account's USDG falls under this, so loans can still be repaid."), example: _t("Example: $5.") },
    sel("days", _t("How long the key lasts"), _t("After this the key stops by itself."), _t("Example: for 14 days."), KEY_DAYS.map((d) => [d, daysWords(d)])),
  ];
  const TRIGGERS = Object.freeze(["schedule", "price_up", "price_down", "loan_due", "tick"]);
  const ACTIONS = Object.freeze(["borrow", "buy", "sell", "repay", "stop"]);
  const KIND = { trigger: () => _t("Trigger"), if: () => _t("If"), action: () => _t("Action") };
  const kindOf = (type) => (own(NODES, type) ? NODES[type].kind : null);
  /** A node's words in the reader's language, its fields as they are for `values` (an If's depend on what it checks). */
  function node(type, values) {
    const b = NODES[type]; if (!b) throw new Error("no such node: " + type);
    const out = { type, kind: b.kind, kindLabel: KIND[b.kind](), title: b.title(), help: b.help(), example: b.example(), fields: b.fields(values || {}) };
    if (b.note) out.note = b.note();
    return out;
  }
  const outputs = (type) => (kindOf(type) === "if" ? ["yes", "no"] : type === "stop" || !own(NODES, type) ? [] : ["out"]);
  const hasInput = (type) => own(NODES, type) && kindOf(type) !== "trigger";

  // ---- the graph ----
  let gseq = 0;
  const newId = () => "s" + Date.now().toString(36) + (++gseq).toString(36) + Math.floor(Math.random() * 1e6).toString(36);
  const newGraph = (name) => ({ v: 1, id: newId(), name: String(name || ""), seq: 0, nodes: [], edges: [], limits: { ...LIMITS } });
  const byId = (g, id) => g.nodes.find((n) => n.id === id) || null;
  const nid = (id) => { const m = /^n(\d+)$/.exec(id); return m ? Number(m[1]) : Infinity; };
  const order = (a, b) => nid(a.id) - nid(b.id) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const triggers = (g) => g.nodes.filter((n) => kindOf(n.type) === "trigger").sort(order);
  const portOf = (e) => e.branch || "out";
  const next = (g, id, port = "out") => { const e = g.edges.find((x) => x.from === id && portOf(x) === port); return e ? e.to : null; };
  const tradable = (ctx) => ((ctx && ctx.assets) || []).filter((a) => LIQUID.includes(a.symbol));
  const tokenOf = (ctx, sym) => { const a = tradable(ctx).find((x) => x.symbol === sym); return a ? a.token : ""; };
  const symOf = (ctx, token) => { const a = ((ctx && ctx.assets) || []).find((x) => String(x.token).toLowerCase() === String(token || "").toLowerCase()); return a ? a.symbol : null; };
  const same = (a, b) => !!a && String(a).toLowerCase() === String(b || "").toLowerCase();
  function near(ctx, token, pct) {
    const s = symOf(ctx, token), p = s && ctx && ctx.prices ? Number(ctx.prices[s]) : NaN;
    if (!(p > 0)) return "";
    const cents = Math.round(p * 100) * (100 + pct), out = pct > 0 ? Math.ceil(cents / 100) : Math.floor(cents / 100);
    return dec((out / 100).toFixed(2));
  }
  /** A new node's values: the token the graph last used (else TSLA), a level 10% from the price now, the first agent. */
  function defaults(g, type, ctx) {
    const last = g.nodes.slice().reverse().find((n) => n.values && n.values.token);
    const token = last ? last.values.token : tokenOf(ctx, "TSLA");
    const ag = ((ctx && ctx.agents) || [])[0], agent = ag ? String(ag.id) : "";
    switch (type) {
      case "schedule": return { every: 168 };
      case "price_up": return { token, price: near(ctx, token, 10) };
      case "price_down": return { token, price: near(ctx, token, -10) };
      case "loan_due": return { agent, hours: 24 };
      case "if": return { test: "price_above", token, price: near(ctx, token, 5), usd: "10", agent, hours: 24, from: 14, to: 20, weekdays: true };
      case "borrow": return { agent, usd: "5", days: 7 };
      case "buy": return { token, usd: "3", from: "usdg" };
      case "sell": return { token, pct: 100 };
      case "repay": return { agent, cap: ag && ag.cap ? dec(String(ag.cap)) || "6" : "6" };
      default: return {};
    }
  }
  function addNode(g, type, at, ctx) {
    if (!own(NODES, type)) throw new Error("no such node: " + type);
    if (g.nodes.length >= MAX_NODES) throw new Error(_t("A strategy holds at most {n} nodes.", { n: MAX_NODES }));
    let n = (g.seq || 0) + 1;
    while (byId(g, "n" + n)) n++;
    g.seq = n;
    const x = { id: "n" + n, type, values: defaults(g, type, ctx), x: Math.max(0, Math.round((at && at.x) || 0)), y: Math.max(0, Math.round((at && at.y) || 0)) };
    g.nodes.push(x);
    return x;
  }
  /** null, or why `from`'s output `branch` can't link to `to`. */
  function canConnect(g, from, to, branch) {
    const a = byId(g, from), b = byId(g, to);
    if (!a || !b) return _t("That node isn't there any more.");
    if (from === to) return _t("A node can't link to itself.");
    const port = branch || "out";
    if (!outputs(a.type).includes(port)) return a.type === "stop" ? _t("Stop ends its path: it has no output.") : _t("Pick Yes or No: an If has two outputs.");
    if (!hasInput(b.type)) return _t("A trigger starts a path: nothing links into it.");
    return null;
  }
  /** Links `from`'s output (an If's: branch "yes" or "no") to `to`, in place of the link that output had. */
  function connect(g, from, to, branch) {
    const why = canConnect(g, from, to, branch); if (why) return why;
    const port = branch || "out";
    g.edges = g.edges.filter((e) => !(e.from === from && portOf(e) === port));
    g.edges.push(kindOf(byId(g, from).type) === "if" ? { from, to, branch: port } : { from, to });
    return null;
  }
  function disconnect(g, from, branch) { const port = branch || "out"; g.edges = g.edges.filter((e) => !(e.from === from && portOf(e) === port)); return g; }
  function removeNode(g, id) { g.nodes = g.nodes.filter((n) => n.id !== id); g.edges = g.edges.filter((e) => e.from !== id && e.to !== id); return g; }
  function moveNode(g, id, x, y) { const n = byId(g, id); if (n) { n.x = Math.max(0, Math.round(x)); n.y = Math.max(0, Math.round(y)); } return g; }
  function setValue(g, id, key, value) { const n = byId(g, id); if (n) n.values[key] = value; return g; }
  // every node `id` leads to (not itself, unless a loop comes back to it)
  function reach(g, id) {
    const seen = new Set(), todo = [id];
    while (todo.length) { const x = todo.pop(); for (const e of g.edges) if (e.from === x && !seen.has(e.to)) { seen.add(e.to); todo.push(e.to); } }
    return seen;
  }
  /** What "add after" offers on a phone: a trigger to start (from = null), else an If or an action. */
  const insertable = (g, from) => (from == null ? TRIGGERS.slice() : ["if", ...ACTIONS]);
  /** Adds a `type` node after `from`'s output (null: a new trigger), between it and what that output led to. */
  function insertAfter(g, from, branch, type, ctx) {
    const a = from == null ? null : byId(g, from);
    if (from != null && !a) throw new Error("no such node: " + from);
    if (!insertable(g, from).includes(type)) throw new Error(`a ${type} node can't go there`);
    const port = branch || "out", was = a ? next(g, from, port) : null;
    const at = a ? { x: a.x + 260, y: a.y } : { x: 40, y: g.nodes.length ? Math.max(...g.nodes.map((n) => n.y)) + 160 : 40 };
    if (was) for (const id of new Set([was, ...reach(g, was)])) { const m = byId(g, id); if (m && id !== from) m.x += 260; }
    const n = addNode(g, type, at, ctx);
    if (a) connect(g, from, n.id, kindOf(a.type) === "if" ? port : undefined);
    if (was && outputs(type).length) connect(g, n.id, was, kindOf(type) === "if" ? "yes" : undefined);
    return n;
  }
  /** Places the cards in columns: each trigger's paths left to right, an If's Yes above its No. */
  function layout(g) {
    const COL = 260, ROW = 128, X0 = 40, Y0 = 40, placed = new Set();
    let row = 0;
    const place = (id, depth) => {
      const n = byId(g, id); if (!n || placed.has(id)) return; placed.add(id);
      n.x = X0 + depth * COL; n.y = Y0 + row * ROW;
      const kids = outputs(n.type).map((p) => next(g, id, p)).filter((k) => k && !placed.has(k));
      if (!kids.length) { row++; return; }
      kids.forEach((k) => place(k, depth + 1));
    };
    for (const t of triggers(g)) { place(t.id, 0); row += 0.25; }
    for (const n of g.nodes.slice().sort(order)) if (!placed.has(n.id)) place(n.id, 0);
    for (const n of g.nodes) n.y = Math.round(n.y);
    return g;
  }

  // ---- the templates (the Buildout's three) ----
  const TEMPLATES = Object.freeze([
    { key: "buy_schedule", name: () => _t("Buy on a schedule"), line: () => _t("Buys $3 of a stock token every week with your account's USDG.") },
    { key: "borrow_dip", name: () => _t("Borrow to buy when the price falls, sell when it rises, repay"), line: () => _t("When the price falls, borrows $5 on your agent's line and buys with it; when it rises, sells and repays the loan; a loan due within a day is repaid first. A borrow is a loan of your agent that must be repaid.") },
    { key: "repay_due", name: () => _t("Repay before the due date"), line: () => _t("Repays your agent's loans from your account's USDG in the 6 hours before each is due.") },
  ]);
  const template = (key) => { const t = TEMPLATES.find((x) => x.key === key); if (!t) throw new Error("no such template: " + key); return { key, name: t.name(), line: t.line() }; };
  function fromTemplate(key, ctx) {
    const T = template(key), g = newGraph(T.name); g.template = key;
    const add = (type, values) => { const n = addNode(g, type, {}, ctx); Object.assign(n.values, values || {}); return n.id; };
    const link = (a, b, branch) => { const why = connect(g, a, b, branch); if (why) throw new Error(why); };
    const tsla = tokenOf(ctx, "TSLA");
    if (key === "buy_schedule") link(add("schedule", { every: 168 }), add("buy", { token: tsla, usd: "3", from: "usdg" }));
    else if (key === "repay_due") link(add("loan_due", { hours: 6 }), add("repay", {}));
    else {
      const down = add("price_down", { token: tsla, price: near(ctx, tsla, -10) }), open = add("if", { test: "loan_open" });
      const borrow = add("borrow", { usd: "5", days: 7 }), buy = add("buy", { token: tsla, usd: "5", from: "loan" }), wait = add("stop");
      link(down, open); link(open, wait, "yes"); link(open, borrow, "no"); link(borrow, buy);
      const up = add("price_up", { token: tsla, price: near(ctx, tsla, 10) }), held = add("if", { test: "holds", token: tsla });
      const sell = add("sell", { token: tsla, pct: 100 }), repay = add("repay", { cap: "6" }), none = add("stop");
      link(up, held); link(held, sell, "yes"); link(held, none, "no"); link(sell, repay);
      const due = add("loan_due", { hours: 24 }), pay = add("repay", { cap: "6" });
      link(due, pay);
    }
    return layout(g);
  }

  // ---- refusals: one sentence that names the fix ----
  const capsOf = (ctx) => {
    const c = (ctx && ctx.caps) || {};
    const lower = (a, b) => (b != null && Number(b) > 0 && Number(b) < a ? Number(b) : a);
    return { perTrade: lower(STAGE.perTradeUsd, c.perTradeUsd), total: lower(STAGE.totalUsd, c.totalUsd), days: lower(STAGE.days, c.days) };
  };
  const limitsOf = (g) => ({ ...LIMITS, ...((g && g.limits) || {}) });
  const titleOf = (n) => (n && own(NODES, n.type) ? NODES[n.type].title() : "");
  const choice = (list, v) => list.some((x) => x === Number(v));
  /** null, or the sentence that refuses `value` for field `key` of a `type` node (`values`: the node's others; `ctx.limits`:
   *  the strategy's limits). */
  function fieldError(type, key, value, ctx, values) {
    const caps = capsOf(ctx), L = { ...LIMITS, ...((ctx && ctx.limits) || {}) };
    const str = value == null ? "" : String(value).trim(), d = dec(str);
    if (type === "limits") {
      if (key === "perTrade") {
        if (!str) return _t("Type the most a trade spends, like 5.");
        if (!usdOk(d)) return _t("{value} isn't an amount in dollars: type one like {like}.", { value: quoted(value), like: "5" });
        if (units(d, 6) < 1_000_000n) return _t("{value} is under $1: a trade spends at least $1.", { value: money(d) });
        if (units(d, 6) > BigInt(caps.perTrade) * 1_000_000n) return _t("{value} is over {max}, the most a trade spends for now: type {max} or less.", { value: money(d), max: money(caps.perTrade) });
        return null;
      }
      if (key === "total") {
        if (!str) return _t("Type the most the key spends in all, like 20.");
        if (!usdOk(d)) return _t("{value} isn't an amount in dollars: type one like {like}.", { value: quoted(value), like: "20" });
        const per = usd6(L.perTrade);
        if (per != null && units(d, 6) < per) return _t("{value} is less than the most per trade: the key spends at least one trade.", { value: money(d) });
        if (units(d, 6) > BigInt(caps.total) * 1_000_000n) return _t("{value} is more than {max}, the most a key spends for now: type {max} or less.", { value: money(d), max: money(caps.total) });
        return null;
      }
      if (key === "keep") return !str ? _t("Type the USDG to keep at all times, like 5 (0 keeps none).") : usdOk(d) ? null : _t("{value} isn't an amount in dollars: type one like {like}.", { value: quoted(value), like: "5" });
      if (key === "days") return KEY_DAYS.some((x) => x === Number(value) && x <= caps.days) ? null : _t("Pick the key's length from the list.");
      return null;
    }
    if (key === "token") return str && tradable(ctx).some((a) => same(a.token, str)) ? null : _t("Pick a token from the list.");
    if (key === "agent") {
      const agents = (ctx && ctx.agents) || [];
      if (!agents.length) return _t("Your account has no agent yet: create one in Agents, then come back.");
      return agents.some((a) => String(a.id) === str) ? null : _t("Pick an agent of yours from the list.");
    }
    if (key === "price") {
      if (!str) return _t("Type the level in dollars, like 450.");
      if (!priceOk(d)) return _t("{value} isn't a level: type dollars for one token, like 450 or 412.50.", { value: quoted(value) });
      return units(d, 8) === 0n ? _t("$0 is not a level a price reaches: type the price for one token, like 450.") : null;
    }
    if (key === "usd") {
      if (!str) return _t("Type an amount in dollars, like 5.");
      if (!usdOk(d)) return _t("{value} isn't an amount in dollars: type one like {like}.", { value: quoted(value), like: "5" });
      if (type === "buy") {
        if (units(d, 6) < BigInt(STAGE.minTradeUsd) * 1_000_000n) return _t("{value} is under $1, the smallest buy: type $1 or more.", { value: money(d) });
        const per = usd6(L.perTrade) != null ? dec(String(L.perTrade)) : String(caps.perTrade);
        if (units(d, 6) > units(per, 6)) return _t("{value} is over {max}, this strategy's most per trade: type {max} or less, or raise it in Limits.", { value: money(d), max: money(per) });
      }
      if (type === "borrow") {
        const per = usd6(L.perTrade) != null ? dec(String(L.perTrade)) : String(caps.perTrade), max = units(per, 6) < BigInt(BORROW.maxUsd) * 1_000_000n ? per : String(BORROW.maxUsd);
        if (units(d, 6) < BigInt(BORROW.minUsd) * 1_000_000n || units(d, 6) > units(max, 6)) return _t("{value} is outside what a Borrow takes: from $5, the pool's smallest loan, to {max}, the most per trade.", { value: money(d), max: money(max) });
      }
      return null;
    }
    if (key === "cap") {
      if (!str) return _t("Type the most it repays on one loan, like 6.");
      if (!usdOk(d)) return _t("{value} isn't an amount in dollars: type one like {like}.", { value: quoted(value), like: "6" });
      if (units(d, 6) === 0n) return _t("$0 repays nothing: type the most it repays on one loan, like 6.");
      const max = ctx && Number(ctx.repayCap) > 0 ? Number(ctx.repayCap) : REPAY_CAP;
      return units(d, 6) > units(dec(String(max)), 6) ? _t("{value} is more than {max}, the most repaid for one loan for now: type {max} or less.", { value: money(d), max: money(max) }) : null;
    }
    if (key === "every") return choice(EVERY, value) ? null : _t("Pick how often it starts from the list.");
    if (key === "pct") return choice(PCT, value) ? null : _t("Pick the share to sell from the list.");
    if (key === "days") return choice(TERMS, value) ? null : _t("Pick the loan's term from the list.");
    if (key === "hours") return choice(type === "loan_due" ? DUE : WITHIN, value) ? null : _t("Pick the hours from the list.");
    if (key === "from" && type === "if") return choice(HOURS, value) ? null : _t("Pick an hour from the list.");
    if (key === "to") {
      if (!choice(HOURS, value)) return _t("Pick an hour from the list.");
      return values && Number(values.from) === Number(value) ? _t("The window starts and ends at the same hour: pick another end.") : null;
    }
    if (key === "from") return own(FROM, str) ? null : _t("Pick what it pays with from the list.");
    if (key === "test") return TESTS.includes(str) ? null : _t("Pick what it checks from the list.");
    return null;
  }

  const CODES = Object.freeze(["empty", "no_trigger", "bad_edge", "unconnected", "cycle", "if_branch", "field", "limits", "borrow_caps", "no_funding", "sell_unbought", "too_many_buys", "too_many_sells", "repay_cap", "borrow_buy", "borrow_agents"]);
  /** What keeps a graph from running, in order: each { code, node (an id, "limits", or null), field (or null), text }. */
  function problems(g, ctx) {
    const out = [], push = (code, node, field, text) => out.push({ code, node, field, text });
    const nodes = g.nodes.slice().sort(order), ids = new Set(nodes.map((n) => n.id));
    const cx = { ...(ctx || {}), limits: limitsOf(g) };
    if (!nodes.length) { push("empty", null, null, _t("Add a trigger to start: a timer, a price, a loan due soon or every pass.")); return out; } // check:empty
    if (!nodes.some((n) => kindOf(n.type) === "trigger")) push("no_trigger", null, null, _t("Nothing starts this strategy: add a trigger.")); // check:no_trigger
    for (const e of g.edges) {
      const a = byId(g, e.from), b = byId(g, e.to);
      if (!a || !b || !outputs(a.type).includes(portOf(e)) || !hasInput(b.type) || (kindOf(a.type) === "if") !== !!e.branch) push("bad_edge", a ? a.id : null, null, _t("A link goes to or from a node that can't take it: remove it.")); // check:bad_edge
    }
    for (const n of nodes) {
      if (!own(NODES, n.type)) { push("bad_edge", n.id, null, _t("This node isn't one this page knows: remove it.")); continue; } // check:bad_edge
      const ins = g.edges.filter((e) => e.to === n.id && ids.has(e.from)), outs = g.edges.filter((e) => e.from === n.id && ids.has(e.to));
      if (!ins.length && !outs.length) push("unconnected", n.id, null, _t("{title} is not connected: link it into a path, or remove it.", { title: titleOf(n) })); // check:unconnected
      else if (kindOf(n.type) === "trigger" && !outs.length) push("unconnected", n.id, null, _t("{title} starts nothing: link its output to the next node.", { title: titleOf(n) })); // check:unconnected
      else if (kindOf(n.type) !== "trigger" && !ins.length) push("unconnected", n.id, null, _t("Nothing leads to {title}: link another node's output to it.", { title: titleOf(n) })); // check:unconnected
    }
    // loops: a path that comes back to a node it went through
    const state = new Map(), seenLoops = new Set();
    const visit = (id, path) => {
      state.set(id, 1); path.push(id);
      for (const e of g.edges.filter((x) => x.from === id).sort((a, b) => (portOf(a) < portOf(b) ? 1 : -1))) {
        if (!ids.has(e.to)) continue;
        if (state.get(e.to) === 1) {
          const loop = path.slice(path.indexOf(e.to)), key = loop.slice().sort().join(",");
          if (!seenLoops.has(key)) { seenLoops.add(key); push("cycle", e.to, null, _t("These nodes go round in a loop ({path}): a path must end. Remove one of its links.", { path: loop.map((x) => titleOf(byId(g, x))).join(" → ") })); } // check:cycle
        } else if (!state.get(e.to)) visit(e.to, path);
      }
      path.pop(); state.set(id, 2);
    };
    for (const n of nodes) if (!state.get(n.id)) visit(n.id, []);
    for (const n of nodes) if (kindOf(n.type) === "if") for (const [p, w] of [["yes", _t("Yes")], ["no", _t("No")]]) if (!next(g, n.id, p) || !ids.has(next(g, n.id, p))) push("if_branch", n.id, null, _t("{title} has nothing after {branch}: link it to a next node, or add a Stop.", { title: titleOf(n), branch: w })); // check:if_branch
    // each field's value, then the limits
    for (const n of nodes) {
      if (!own(NODES, n.type)) continue;
      for (const f of NODES[n.type].fields(n.values)) {
        const e = fieldError(n.type, f.key, n.values[f.key], cx, n.values);
        if (!e) continue;
        const over = n.type === "borrow" && f.key === "usd" && usdOk(dec(String(n.values.usd == null ? "" : n.values.usd)));
        if (over) push("borrow_caps", n.id, "usd", e); // check:borrow_caps
        if (!over) push("field", n.id, f.key, e); // check:field
      }
    }
    for (const f of LIMIT_FIELDS()) { const e = fieldError("limits", f.key, cx.limits[f.key], cx); if (e) push("limits", "limits", f.key, e); } // check:limits
    // funding: a buy that pays with borrowed USDG needs that much borrowed before it on every path to it
    // (paths are walked one by one: a budget keeps a graph of many Ifs that meet again from taking long)
    const unfunded = new Map();
    let budget = 20000;
    const walk = (id, left, borrowed, onPath) => {
      const n = byId(g, id); if (!n || onPath.has(id) || --budget < 0) return;
      onPath.add(id);
      if (n.type === "borrow") { const u = usd6(n.values.usd); if (u != null) { left += u; borrowed = true; } }
      if (n.type === "buy" && n.values.from === "loan" && !unfunded.has(id)) {
        const u = usd6(n.values.usd);
        if (!borrowed) unfunded.set(id, _t("This buy pays with borrowed USDG, but no Borrow comes before it on a path to it: add a Borrow before it, or pay with your account's USDG."));
        else if (u != null && u > left) unfunded.set(id, _t("This buy spends {usd} of borrowed USDG, but the Borrow before it opens only {left}: borrow more, or buy less.", { usd: money6(u), left: money6(left) }));
        else if (u != null) left -= u;
      }
      for (const p of outputs(n.type)) { const k = next(g, id, p); if (k) walk(k, left, borrowed, onPath); }
      onPath.delete(id);
    };
    for (const t of triggers(g)) walk(t.id, 0n, false, new Set());
    for (const n of nodes) if (n.type === "buy" && n.values.from === "loan" && g.edges.some((e) => e.to === n.id) && unfunded.has(n.id)) push("no_funding", n.id, "from", unfunded.get(n.id)); // check:no_funding
    // a sell of a token the strategy buys before it (on its path, or on another trigger's: never only after it)
    for (const n of nodes) {
      if (n.type !== "sell" || !n.values.token) continue;
      const after = reach(g, n.id), sym = symOf(ctx, n.values.token) || _t("that token");
      if (!nodes.some((b) => b.type === "buy" && same(b.values.token, n.values.token) && !after.has(b.id))) push("sell_unbought", n.id, "token", _t("This sells {sym}, which this strategy never buys before it: add a Buy of {sym} first, or sell a token it buys.", { sym })); // check:sell_unbought
    }
    const count = (t) => nodes.filter((n) => n.type === t);
    if (count("buy").length > STAGE.buys) push("too_many_buys", count("buy").at(-1).id, null, _t("This strategy has {n} buys: one key takes {max} at most. Remove a buy.", { n: count("buy").length, max: STAGE.buys })); // check:too_many_buys
    if (count("sell").length > STAGE.sells) push("too_many_sells", count("sell").at(-1).id, null, _t("This strategy has {n} sells: one key takes {max} at most. Remove a sell.", { n: count("sell").length, max: STAGE.sells })); // check:too_many_sells
    // a repayment that can't cover what its agent's Borrow opens
    for (const n of count("repay")) {
      const cap = usd6(n.values.cap), most = count("borrow").filter((b) => String(b.values.agent) === String(n.values.agent)).map((b) => usd6(b.values.usd)).filter((u) => u != null).reduce((a, b) => (b > a ? b : a), 0n);
      if (cap != null && most > 0n && cap < most) push("repay_cap", n.id, "cap", _t("This repays at most {cap}, less than the {usd} its agent's Borrow opens: make it at least {usd} and its fee.", { cap: money6(cap), usd: money6(most) })); // check:repay_cap
    }
    // a Borrow and the Buy it pays for run as one operation (the executor's borrow and buy: it buys exactly what it
    // borrows): right after each Borrow whose amount is right, one Buy paying with the borrowed USDG, for the same amount
    for (const n of count("borrow")) {
      if (fieldError("borrow", "usd", n.values.usd, cx, n.values)) continue;
      const b = byId(g, next(g, n.id, "out")), d = dec(String(n.values.usd));
      if (!b || b.type !== "buy" || b.values.from !== "loan" || dec(String(b.values.usd == null ? "" : b.values.usd)) !== d) push("borrow_buy", n.id, "usd", _t("This Borrow runs together with the Buy it pays for: link it straight to one Buy that pays with the borrowed USDG, for the same {usd}.", { usd: money(d) })); // check:borrow_buy
    }
    // one key borrows for one agent: every Borrow of a strategy on the same agent's line
    const lines = [...new Set(count("borrow").map((b) => String(b.values.agent || "")).filter(Boolean))];
    if (lines.length > 1) push("borrow_agents", count("borrow").find((b) => String(b.values.agent) === lines[1]).id, "agent", _t("This strategy borrows on {n} agents' lines, and its key borrows for one agent: keep every Borrow on the same agent.", { n: lines.length })); // check:borrow_agents
    return out;
  }

  // ---- compiling ----
  const whenOf = (n) => {
    const v = n.values || {};
    switch (n.type) {
      case "schedule": return { on: "schedule", everyHours: Number(v.every) };
      case "price_up": return { on: "price_up", token: String(v.token || ""), above: dec(String(v.price == null ? "" : v.price)) };
      case "price_down": return { on: "price_down", token: String(v.token || ""), below: dec(String(v.price == null ? "" : v.price)) };
      case "loan_due": return { on: "loan_due", agent: String(v.agent || ""), withinHours: Number(v.hours) };
      default: return { on: "tick" };
    }
  };
  const testOf = (v) => {
    const t = v.test, price = () => dec(String(v.price == null ? "" : v.price));
    if (t === "price_above") return { is: "price_above", token: String(v.token || ""), price: price() };
    if (t === "price_below") return { is: "price_below", token: String(v.token || ""), price: price() };
    if (t === "holds") return { is: "holds", token: String(v.token || "") };
    if (t === "usdg_min") return { is: "usdg_at_least", usd: dec(String(v.usd == null ? "" : v.usd)) };
    if (t === "loan_open") return { is: "loan_open", agent: String(v.agent || "") };
    if (t === "loan_due") return { is: "loan_due_within", agent: String(v.agent || ""), hours: Number(v.hours) };
    return { is: "time_between", fromHour: Number(v.from), toHour: Number(v.to), weekdays: !!v.weekdays };
  };
  function stepsFrom(g, id, onPath) {
    const out = [];
    for (let cur = id; cur;) {
      const n = byId(g, cur); if (!n || onPath.has(cur)) break;
      const v = n.values || {};
      if (n.type === "if") {
        const inner = new Set([...onPath, cur]);
        out.push({ op: "if", node: n.id, test: testOf(v), yes: stepsFrom(g, next(g, cur, "yes"), inner), no: stepsFrom(g, next(g, cur, "no"), inner) });
        break;
      }
      if (n.type === "stop") { out.push({ op: "stop", node: n.id }); break; }
      if (n.type === "borrow") out.push({ op: "borrow", node: n.id, agent: String(v.agent || ""), usd: dec(String(v.usd == null ? "" : v.usd)), days: Number(v.days) });
      else if (n.type === "buy") out.push({ op: "buy", node: n.id, token: String(v.token || ""), usd: dec(String(v.usd == null ? "" : v.usd)), from: v.from === "loan" ? "loan" : "usdg" });
      else if (n.type === "sell") out.push({ op: "sell", node: n.id, token: String(v.token || ""), pct: Number(v.pct) });
      else if (n.type === "repay") out.push({ op: "repay", node: n.id, agent: String(v.agent || ""), capUsd: dec(String(v.cap == null ? "" : v.cap)) });
      else break;
      onPath = new Set([...onPath, cur]);
      cur = next(g, cur, "out");
    }
    return out;
  }
  const capsOfLimits = (L) => ({ perTradeUsd: dec(String(L.perTrade)) || String(L.perTrade), totalUsd: dec(String(L.total)) || String(L.total), keepUsd: dec(String(L.keep)) || String(L.keep) });
  /** The strategy rules (the schema above): every trigger by its id, and the steps its links lead to. */
  function compile(g) {
    const L = limitsOf(g);
    return { kind: SCHEMA, v: VERSION, caps: capsOfLimits(L), days: Number(L.days), rules: triggers(g).map((t) => ({ id: t.id, when: whenOf(t), do: stepsFrom(g, next(g, t.id, "out"), new Set([t.id])) })) };
  }
  /** Today's executors' form, for a graph they run unchanged (each trigger with one action: a timer's buy with the
   *  account's USDG, a price's sell of that token, a loan due within 6 hours' repayment of that agent's loan; a Stop after
   *  it changes nothing), or null. */
  function toAutomationRules(g) {
    const buys = [], sells = [], plans = [], ts = triggers(g);
    if (!ts.length) return null;
    for (const t of ts) {
      const chain = [];
      for (let cur = next(g, t.id, "out"); cur && chain.length < 3; cur = next(g, cur, "out")) { const n = byId(g, cur); if (!n) return null; chain.push(n); if (n.type === "stop") break; }
      if (chain.length === 2 && chain[1].type !== "stop") return null;
      if (chain.length > 2 || !chain.length) return null;
      const a = chain[0], v = t.values || {}, w = a.values || {};
      if (t.type === "schedule" && a.type === "buy" && w.from !== "loan") buys.push({ token: w.token, usd: dec(String(w.usd)), everyHours: Number(v.every) });
      else if ((t.type === "price_up" || t.type === "price_down") && a.type === "sell" && same(w.token, v.token)) sells.push({ token: v.token, [t.type === "price_up" ? "above" : "below"]: dec(String(v.price)), sellPct: Number(w.pct) });
      else if (t.type === "loan_due" && Number(v.hours) === 6 && a.type === "repay" && String(w.agent) === String(v.agent)) plans.push({ agent_id: Number(v.agent), cap_usd: Number(dec(String(w.cap))), use_savings: false, late: true });
      else return null;
    }
    if (g.nodes.some((n) => n.type === "if" || n.type === "borrow" || n.type === "tick")) return null;
    const L = limitsOf(g);
    return { rules: buys.length || sells.length ? { buys, sells, caps: capsOfLimits(L), days: Number(L.days) } : null, plans };
  }
  const needsExecutor = (g) => g.nodes.length > 0 && toAutomationRules(g) === null;

  // ---- Copy into Go mode: a published strategy back as a draft graph ----
  const isAddr = (s) => typeof s === "string" && /^0x[0-9a-fA-F]{40}$/.test(s);
  const isAgent = (s) => typeof s === "string" && /^\d{1,12}$/.test(s);
  const amount = (s) => (typeof s === "string" && usdOk(dec(s)) ? dec(s) : null);
  function fromPublished(x) {
    const rec = x && x.kind === SCHEMA ? { strategy: x } : x || {}, s = rec.strategy;
    const bad = () => new Error(_t("This isn't a strategy this page can read."));
    if (!s || s.kind !== SCHEMA || s.v !== VERSION || !Array.isArray(s.rules) || s.rules.length > MAX_NODES) throw bad();
    const g = newGraph(typeof rec.name === "string" && rec.name.trim() ? rec.name.trim().slice(0, 60) : _t("Copied strategy"));
    g.from = rec.id != null && /^[\w:-]{1,80}$/.test(String(rec.id)) ? "published:" + String(rec.id) : "published";
    const c = s.caps || {};
    g.limits = { perTrade: amount(c.perTradeUsd) || LIMITS.perTrade, total: amount(c.totalUsd) || LIMITS.total, keep: amount(c.keepUsd) || LIMITS.keep, days: KEY_DAYS.includes(Number(s.days)) ? Number(s.days) : LIMITS.days };
    // a node by the id the rules give it (the same id again: the same node, where two paths meet)
    const put = (id, type, values) => {
      const have = typeof id === "string" && /^n\d{1,4}$/.test(id) ? byId(g, id) : null;
      if (have) { if (have.type !== type) throw bad(); return have; }
      if (g.nodes.length >= MAX_NODES) throw bad();
      const n = { id: typeof id === "string" && /^n\d{1,4}$/.test(id) ? id : null, type, values: { ...defaults(g, type, null), ...values }, x: 0, y: 0 };
      if (!n.id) { let k = (g.seq || 0) + 1; while (byId(g, "n" + k)) k++; n.id = "n" + k; }
      g.seq = Math.max(g.seq || 0, nid(n.id) === Infinity ? 0 : nid(n.id));
      g.nodes.push(n);
      return n;
    };
    const tok = (t) => { if (!isAddr(t)) throw bad(); return t; };
    const ag = (a) => { if (!isAgent(a)) throw bad(); return a; };
    const lvl = (p) => { const d = typeof p === "string" ? dec(p) : null; if (!priceOk(d)) throw bad(); return d; };
    const trig = (w) => {
      if (!w || typeof w !== "object") throw bad();
      if (w.on === "schedule" && EVERY.includes(Number(w.everyHours))) return ["schedule", { every: Number(w.everyHours) }];
      if (w.on === "price_up") return ["price_up", { token: tok(w.token), price: lvl(w.above) }];
      if (w.on === "price_down") return ["price_down", { token: tok(w.token), price: lvl(w.below) }];
      if (w.on === "loan_due" && DUE.includes(Number(w.withinHours))) return ["loan_due", { agent: ag(w.agent), hours: Number(w.withinHours) }];
      if (w.on === "tick") return ["tick", {}];
      throw bad();
    };
    const test = (t) => {
      if (!t || typeof t !== "object") throw bad();
      if (t.is === "price_above" || t.is === "price_below") return { test: t.is, token: tok(t.token), price: lvl(t.price) };
      if (t.is === "holds") return { test: "holds", token: tok(t.token) };
      if (t.is === "usdg_at_least") { const u = amount(t.usd); if (u == null) throw bad(); return { test: "usdg_min", usd: u }; }
      if (t.is === "loan_open") return { test: "loan_open", agent: ag(t.agent) };
      if (t.is === "loan_due_within" && WITHIN.includes(Number(t.hours))) return { test: "loan_due", agent: ag(t.agent), hours: Number(t.hours) };
      if (t.is === "time_between" && HOURS.includes(Number(t.fromHour)) && HOURS.includes(Number(t.toHour))) return { test: "time", from: Number(t.fromHour), to: Number(t.toHour), weekdays: !!t.weekdays };
      throw bad();
    };
    const step = (s1) => {
      if (!s1 || typeof s1 !== "object") throw bad();
      const u = (v) => { const a = amount(v); if (a == null) throw bad(); return a; };
      if (s1.op === "if") return ["if", test(s1.test)];
      if (s1.op === "borrow" && TERMS.includes(Number(s1.days))) return ["borrow", { agent: ag(s1.agent), usd: u(s1.usd), days: Number(s1.days) }];
      if (s1.op === "buy" && (s1.from === "loan" || s1.from === "usdg")) return ["buy", { token: tok(s1.token), usd: u(s1.usd), from: s1.from }];
      if (s1.op === "sell" && PCT.includes(Number(s1.pct))) return ["sell", { token: tok(s1.token), pct: Number(s1.pct) }];
      if (s1.op === "repay") return ["repay", { agent: ag(s1.agent), cap: u(s1.capUsd) }];
      if (s1.op === "stop") return ["stop", {}];
      throw bad();
    };
    const chain = (from, port, steps, depth) => {
      if (!Array.isArray(steps) || depth > MAX_NODES) throw bad();
      let prev = from, p = port;
      for (const s1 of steps) {
        const [type, values] = step(s1), n = put(s1.node, type, values);
        if (connect(g, prev, n.id, kindOf(byId(g, prev).type) === "if" ? p : undefined)) throw bad();
        if (type === "if") { chain(n.id, "yes", s1.yes, depth + 1); chain(n.id, "no", s1.no, depth + 1); return; }
        if (type === "stop") return;
        prev = n.id; p = "out";
      }
    };
    for (const r of s.rules) { if (!r || typeof r !== "object") throw bad(); const [type, values] = trig(r.when), t = put(r.id, type, values); chain(t.id, "out", r.do, 0); }
    layout(g);
    // the cards where the published graph had them, when it holds the same nodes
    const pub = rec.graph && Array.isArray(rec.graph.nodes) ? rec.graph.nodes : [];
    for (const n of pub) { const m = n && byId(g, n.id); if (m && m.type === n.type && Number.isFinite(n.x) && Number.isFinite(n.y)) { m.x = Math.max(0, Math.min(4000, Math.round(n.x))); m.y = Math.max(0, Math.min(4000, Math.round(n.y))); } }
    return g;
  }

  // ---- in a few words, for a card's face ----
  function summary(n, ctx) {
    const v = n.values || {}, sym = (t) => symOf(ctx, t) || "—", lvl = (p) => (dec(String(p == null ? "" : p)) ? money(dec(String(p))) : "—");
    const agent = () => { const a = ((ctx && ctx.agents) || []).find((x) => String(x.id) === String(v.agent)); return a ? a.label : v.agent ? "#" + v.agent : "—"; };
    switch (n.type) {
      case "schedule": return choice(EVERY, v.every) ? everyWords(Number(v.every)) : "—";
      case "price_up": return _t("{sym} at {price} or more", { sym: sym(v.token), price: lvl(v.price) });
      case "price_down": return _t("{sym} at {price} or less", { sym: sym(v.token), price: lvl(v.price) });
      case "loan_due": return _t("{agent} · {n} h before due", { agent: agent(), n: Number(v.hours) || "—" });
      case "tick": return _t("Every 10 minutes");
      case "if": {
        const t = v.test;
        if (t === "price_above") return _t("{sym} at {price} or more", { sym: sym(v.token), price: lvl(v.price) });
        if (t === "price_below") return _t("{sym} at {price} or less", { sym: sym(v.token), price: lvl(v.price) });
        if (t === "holds") return _t("Holds {sym}", { sym: sym(v.token) });
        if (t === "usdg_min") return _t("USDG at {usd} or more", { usd: lvl(v.usd) });
        if (t === "loan_open") return _t("A loan of {agent} is open", { agent: agent() });
        if (t === "loan_due") return _t("A loan of {agent} due within {n} h", { agent: agent(), n: Number(v.hours) || "—" });
        return _t("{from} to {to}", { from: hourWords(Number(v.from) || 0), to: hourWords(Number(v.to) || 0) }) + (v.weekdays ? " · " + _t("weekdays") : "");
      }
      case "borrow": return _t("{usd} for {days} days · {agent}", { usd: lvl(v.usd), days: Number(v.days) || "—", agent: agent() });
      case "buy": return _t("{usd} of {sym}", { usd: lvl(v.usd), sym: sym(v.token) }) + " · " + (v.from === "loan" ? _t("borrowed USDG") : _t("your USDG"));
      case "sell": return _t("{pct}% of {sym}", { pct: Number(v.pct) || "—", sym: sym(v.token) });
      case "repay": return _t("{agent} · up to {cap}", { agent: agent(), cap: lvl(v.cap) });
      case "stop": return _t("Ends this path");
      default: return "";
    }
  }
  const limitsSentence = (L) => _t("At most {per} a trade and {total} in all, borrowed USDG included, always keeping {keep} in USDG, for {days} days.", { per: money(L.perTrade), total: money(L.total), keep: money(L.keep), days: Number(L.days) });

  root.PriorsTradeCore = {
    STAGE, BORROW, LIQUID, SCHEMA, VERSION, LIMITS, MAX_NODES, NODES, TRIGGERS, ACTIONS, TESTS, TEMPLATES, CODES, LIMIT_FIELDS,
    node, kindOf, outputs, hasInput, newGraph, addNode, canConnect, connect, disconnect, removeNode, moveNode, setValue, next, reach,
    insertable, insertAfter, layout, template, fromTemplate, tradable, fieldError, problems, compile, toAutomationRules, needsExecutor,
    fromPublished, summary, limitsSentence, limitsOf, money, dec, clone,
  };
})(typeof window !== "undefined" ? window : globalThis);
