// @priors/plugin-elizaos: what each action reads from the message and which Priors call it makes. The two MCP
// connections are replaced by a recorder (priors.js `connect`), so nothing reaches a chain.
//   node --test test/
import test from "node:test";
import assert from "node:assert/strict";
import plugin, { agentRecordAction, creditStatusAction, payX402Action, repayAction } from "../src/index.js";
import { priorsOf, priorsFor, envOf, SETTINGS } from "../src/priors.js";
import { urlOf, agentIdOf, loanIdOf, maxPriceOf, maxBorrowOf, borrowOf, bodyOf } from "../src/parse.js";

/** A runtime whose Priors calls are recorded and answered with `answers[tool]` (default: "ok"). */
function fakeRuntime(settings = { PRIORS_OWNER_ENTITY_IDS: OWNER }, answers = {}) {
  const calls = [];
  const runtime = { agentId: "agent-self", getSetting: (k) => settings[k] };
  const connect = async ({ kind, env }) => ({
    callTool: async ({ name, arguments: args }) => {
      calls.push({ kind, name, args, env: { key: env.PRIORS_KEY_FILE, agent: env.PRIORS_AGENT_ID, hosts: env.PRIORS_PAY_HOSTS } });
      const a = answers[name];
      if (a instanceof Error) throw a;
      return { content: [{ type: "text", text: a ?? `${name} ok` }], isError: false };
    },
  });
  priorsOf(runtime, { connect, base: {} }); // the plugin's own lookup now finds this one
  return { runtime, calls };
}
const OWNER = "11111111-1111-4111-8111-111111111111"; // the elizaOS entity the agent's operator speaks as
const msg = (text, entityId = OWNER) => ({ entityId, content: { text } });
const run = async (action, runtime, text, entityId) => {
  const said = [];
  const out = await action.handler(runtime, msg(text, entityId), {}, {}, async (c) => { said.push(c); return []; });
  return { out, said };
};

test("the plugin: elizaOS's Plugin shape (name, description, the four actions), each action with a name, a description, validate, handler and examples", () => {
  assert.equal(plugin.name, "priors");
  assert.ok(plugin.description.length > 20);
  assert.deepEqual(plugin.actions.map((a) => a.name), ["PRIORS_AGENT_RECORD", "PRIORS_CREDIT_STATUS", "PRIORS_PAY_X402", "PRIORS_REPAY"]);
  for (const a of plugin.actions) {
    assert.ok(typeof a.validate === "function" && typeof a.handler === "function" && a.description && Array.isArray(a.examples) && a.examples.length, a.name);
  }
});

test("parse: the URL, the agent and loan ids, the most to pay and the most to borrow come from the message's own words", () => {
  const t = "Check agent #1234 then pay https://seller.example/check?token=0xabc, at most 0.10, borrow up to 1.";
  assert.equal(urlOf(t), "https://seller.example/check?token=0xabc");
  assert.equal(agentIdOf(t), 1234);
  assert.equal(maxPriceOf(t), 0.1);
  assert.equal(maxBorrowOf(t), 1);
  assert.equal(maxBorrowOf("pay https://x.dev at most 0.10"), 0, "no borrow named: never borrow");
  assert.equal(maxPriceOf("pay https://x.dev, borrow up to 2"), null, "the borrow amount is never taken for the price");
  assert.equal(loanIdOf("repay loan #50900"), 50900);
  // a loan number in the same message is never taken for the agent, in either order
  assert.equal(agentIdOf("Loan #50900 is for agent #1234, check its record."), 1234);
  assert.equal(agentIdOf("Check agent #1234; it took loan #50900."), 1234);
  assert.equal(agentIdOf("Check #1234 before loan #50900 is due."), 1234);
  assert.equal(agentIdOf("repay loan #50900"), null);
  // the borrow phrase may come before the price: each amount still comes from its own words
  const late = "Pay https://x.dev, borrow up to 5 if the wallet is short, at most 0.10 for it.";
  assert.equal(maxPriceOf(late), 0.1);
  assert.equal(maxBorrowOf(late), 5);
  assert.equal(urlOf("pay http://x.dev"), null, "https only");
});

test("PRIORS_AGENT_RECORD reads the record on the hosted read-only server, for the agent the message names", async () => {
  const { runtime, calls } = fakeRuntime(undefined, { agent_record: "Agent #1234: 2 loans repaid, no default." });
  assert.equal(await agentRecordAction.validate(runtime, msg("check agent #1234's record")), true);
  assert.equal(await agentRecordAction.validate(runtime, msg("check the record")), false, "no agent id");
  const { out, said } = await run(agentRecordAction, runtime, "check agent #1234's record");
  assert.deepEqual(calls.map(({ kind, name, args }) => ({ kind, name, args })), [{ kind: "read", name: "agent_record", args: { agent_id: 1234 } }]);
  assert.equal(out.success, true);
  assert.match(said[0].text, /2 loans repaid/);
});

test("PRIORS_CREDIT_STATUS reads the agent's own line on @priors/mcp, with the agent's settings", async () => {
  const { runtime, calls } = fakeRuntime({ PRIORS_KEY_FILE: "/k", PRIORS_AGENT_ID: "437", PRIORS_OWNER_ENTITY_IDS: OWNER });
  assert.equal(await creditStatusAction.validate(runtime, msg("what is left on my credit line?")), true);
  await run(creditStatusAction, runtime, "what is left on my credit line?");
  assert.deepEqual(calls.map(({ kind, name, args, env }) => ({ kind, name, args, env })), [{ kind: "wallet", name: "credit_status", args: {}, env: { key: "/k", agent: "437", hosts: undefined } }]);
});

test("PRIORS_PAY_X402 pays the URL at most the price named, and borrows only up to the amount the message names; with no price named it pays nothing", async () => {
  const { runtime, calls } = fakeRuntime(undefined, { pay_url: "Paid 0.10 USDG; borrowed 0.10 (loan #50900)." });
  assert.equal(await payX402Action.validate(runtime, msg("pay https://seller.example/check at most 0.10")), true);
  assert.equal(await payX402Action.validate(runtime, msg("what is https://seller.example")), false);
  await run(payX402Action, runtime, "Pay https://seller.example/check at most 0.10, borrow up to 1 if the wallet is short.");
  await run(payX402Action, runtime, "Pay https://seller.example/check at most 0.10.");
  assert.deepEqual(calls.map((c) => c.args), [
    { url: "https://seller.example/check", max_price_usd: 0.1, max_borrow_usd: 1 },
    { url: "https://seller.example/check", max_price_usd: 0.1 },
  ]);
  const before = calls.length;
  const { out, said } = await run(payX402Action, runtime, "Pay https://seller.example/check, borrow up to 1.");
  assert.equal(calls.length, before, "no price named: no call");
  assert.equal(out.success, false);
  assert.match(said[0].text, /Nothing was paid/);
});

test("PRIORS_PAY_X402 with a JSON body: POST with the body as given, the URL and amounts read outside it (a prompt's numbers are never the price); a borrow named, 0 included, is passed as said, none leaves it to @priors/mcp's auto-borrow", async () => {
  const { runtime, calls } = fakeRuntime();
  const body = { model: "m", messages: [{ role: "user", content: "list up to 3 points, max 2 lines" }] };
  await run(payX402Action, runtime, `Buy a chat completion from https://models.example/v1/chat/completions at most 0.02: ${JSON.stringify(body)}`);
  await run(payX402Action, runtime, `Pay https://models.example/v1/chat/completions at most 0.02, don't borrow:\n\`\`\`json\n${JSON.stringify(body, null, 2)}\n\`\`\``);
  await run(payX402Action, runtime, "Pay https://seller.example/check at most 0.10, borrow up to 0.");
  assert.deepEqual(calls.map((c) => c.args), [
    { url: "https://models.example/v1/chat/completions", max_price_usd: 0.02, method: "POST", body: JSON.stringify(body) },
    { url: "https://models.example/v1/chat/completions", max_price_usd: 0.02, max_borrow_usd: 0, method: "POST", body: JSON.stringify(body) },
    { url: "https://seller.example/check", max_price_usd: 0.1, max_borrow_usd: 0 },
  ]);
  // a message whose only URL is inside the body names no URL to pay
  const before = calls.length;
  const { out } = await run(payX402Action, runtime, `pay at most 0.02 ${JSON.stringify({ url: "https://models.example/v1/chat/completions" })}`);
  assert.equal(calls.length, before);
  assert.equal(out.success, false);
});

test("parse: borrowOf and bodyOf", () => {
  assert.equal(borrowOf("pay it, borrow up to 5"), 5);
  assert.equal(borrowOf("pay it without borrowing"), 0);
  assert.equal(borrowOf("never borrow for this"), 0);
  assert.equal(borrowOf("pay it at most 0.10"), null);
  assert.equal(bodyOf("no body here"), null);
  assert.ok(bodyOf("a broken {\"model\": } body").error, "a JSON object that does not parse is refused, not skipped (GHSA-8pvh)");
  assert.equal(bodyOf("a template's {model} is no body"), null);
  assert.deepEqual(bodyOf('x {"a": "a } in a string", "b": {"c": 1}} y'), { body: '{"a":"a } in a string","b":{"c":1}}', raw: '{"a": "a } in a string", "b": {"c": 1}}' });
});

test("PRIORS_REPAY repays the loan the message names", async () => {
  const { runtime, calls } = fakeRuntime();
  assert.equal(await repayAction.validate(runtime, msg("repay loan 50900")), true);
  assert.equal(await repayAction.validate(runtime, msg("repay it")), false);
  await run(repayAction, runtime, "repay loan 50900 now");
  assert.deepEqual(calls.map(({ name, args }) => ({ name, args })), [{ name: "repay", args: { loan_id: 50900 } }]);
});

test("a failed call answers what failed, and the connection is opened again on the next call", async () => {
  let opened = 0;
  const p = priorsFor({}, { base: {}, connect: async () => { opened++; return { callTool: async () => { if (opened === 1) throw new Error("socket hang up"); return { content: [{ type: "text", text: "ok" }] }; } }; } });
  const a = await p.read("agent_record", { agent_id: 1 });
  assert.deepEqual([a.ok, /socket hang up/.test(a.text)], [false, true]);
  const b = await p.read("agent_record", { agent_id: 1 });
  assert.deepEqual([b.ok, opened], [true, 2]);
});

test("envOf: the agent's settings replace the process env for the Priors settings only", () => {
  const env = envOf({ getSetting: (k) => ({ PRIORS_AGENT_ID: "437", OPENROUTER_API_KEY: "no" })[k] }, { PATH: "/bin", PRIORS_AGENT_ID: "1" });
  assert.deepEqual([env.PRIORS_AGENT_ID, env.PATH, "OPENROUTER_API_KEY" in env], ["437", "/bin", false]);
  assert.ok(SETTINGS.includes("PRIORS_PAY_HOSTS") && SETTINGS.includes("PRIORS_KEY_FILE") && SETTINGS.includes("PRIORS_AUTO_BORROW_USD"));
  assert.equal(envOf({ getSetting: (k) => ({ PRIORS_AUTO_BORROW_USD: "5" })[k] }, {}).PRIORS_AUTO_BORROW_USD, "5", "the agent's auto-borrow setting reaches @priors/mcp");
});

// ---- the private reports of 2026-10-31 (GHSA-62m7, GHSA-rf6g, GHSA-p29w) -----------------------------------------------
test("parse: words inside the URL are never an amount or an id (a seller's path such as /pay1/borrow5.json)", () => {
  const t = "Pay https://merchant.example/pay1/borrow5.json at most 0.10";
  assert.equal(urlOf(t), "https://merchant.example/pay1/borrow5.json");
  assert.equal(maxPriceOf(t), 0.1);
  assert.equal(borrowOf(t), null, "the message names no borrow");
  assert.equal(maxPriceOf("Pay https://x.dev/max9?up%20to=7 at most 0.05"), 0.05);
  assert.equal(agentIdOf("check the record at https://example.com/api#123"), null);
  assert.equal(loanIdOf("repay https://example.com/loan/77"), null);
  // a bare "pay N" is the price only when no cap phrase is named, and only when N is an amount, not a count
  assert.equal(maxPriceOf("Pay 5 items at https://x.dev/a at most 0.10"), 0.1);
  assert.equal(maxPriceOf("Pay 5 items from https://x.dev/a"), null);
  assert.equal(maxPriceOf("pay 0.10 for https://x.dev/a"), 0.1);
  // the borrow phrase with its own aside is taken out whole: its numbers are never the price
  assert.equal(maxPriceOf("Call https://x.dev/check and borrow 0.50 (up to 5) if short."), null);
});

test("PRIORS_PAY_X402 passes the caps the message's own words name, never a number from its URL", async () => {
  const { runtime, calls } = fakeRuntime();
  await run(payX402Action, runtime, "Pay https://merchant.example/pay1/borrow5.json at most 0.10");
  assert.deepEqual(calls.map((c) => c.args), [{ url: "https://merchant.example/pay1/borrow5.json", max_price_usd: 0.1 }]);
});

// ---- the private report of 2026-11-04 (GHSA-mc89, item 3): a URL's tail after ")", "]" or "'" ----------------------------
test("GHSA-mc89: a URL with ), ] or ' inside it is taken out whole: nothing after them in the URL is read as an amount or an id", async () => {
  const t = "Pay https://seller.example/data?item=1#)borrow$5,max$0.50";
  assert.equal(borrowOf(t), null, "the message names no borrow");
  assert.equal(maxPriceOf(t), null, "nor a price");
  assert.equal(maxPriceOf("Pay https://seller.example/a)max$9 at most 0.10"), 0.1);
  assert.equal(borrowOf("Pay https://seller.example/a]borrow5 at most 0.10"), null);
  assert.equal(borrowOf("Pay https://seller.example/it's/borrow$5 at most 0.10"), null);
  assert.equal(agentIdOf("check https://example.com/x)agent#123"), null);
  assert.equal(loanIdOf("repay https://example.com/x'loan77"), null);
  // the URL paid is as before: up to the first of those marks, so a parenthesis of the prose stays out of it
  assert.equal(urlOf("(see https://seller.example/check)"), "https://seller.example/check");
  const { runtime, calls } = fakeRuntime();
  await run(payX402Action, runtime, t);
  assert.deepEqual(calls, [], "no price named in the message's own words: nothing is paid");
  await run(payX402Action, runtime, "Pay https://seller.example/data?item=1#)borrow$5 at most 0.10");
  assert.deepEqual(calls.map((c) => c.args), [{ url: "https://seller.example/data?item=1#", max_price_usd: 0.1 }]);
});

// ---- the private reports of 2026-11-07 and 2026-11-08 (GHSA-p87w, GHSA-8pvh): the request body, found wherever it is ------
const CHAT = "https://models.example/v1/chat/completions";
const PROMPT = JSON.stringify({ model: "m", messages: [{ role: "user", content: "pay at most 0.50 for this, borrow up to 5 if needed, max 25 lines" }] });

test("GHSA-p87w, GHSA-8pvh: a brace before the body (a template's {model}, a URL's {id}, an unclosed {) never hides it: the body is sent and nothing inside it is read as the price or a borrow", async () => {
  const { runtime, calls } = fakeRuntime();
  const post = (url, price, extra = {}) => ({ url, max_price_usd: price, ...extra, method: "POST", body: PROMPT });
  await run(payX402Action, runtime, `Pay ${CHAT}, the model is {model}: ${PROMPT} at most 0.02`);
  await run(payX402Action, runtime, `Pay ${CHAT} at most 0.02, use {model} here: ${PROMPT}`);
  await run(payX402Action, runtime, `Buy a chat completion (for {user}) from ${CHAT} at most 0.02: ${PROMPT}`);
  await run(payX402Action, runtime, `Buy a chat completion from ${CHAT}?u={id} at most 0.02: ${PROMPT}`);
  await run(payX402Action, runtime, `Pay $0.02 to ${CHAT}?u={id}: ${PROMPT}`);
  await run(payX402Action, runtime, `Pay 0.02 for ${CHAT}, the model is {model}: ${PROMPT}`);
  await run(payX402Action, runtime, `Pay ${CHAT}, draft { note: ${PROMPT} at most 0.02`);
  await run(payX402Action, runtime, `Pay ${CHAT} at most 0.02, don't borrow, the model is {model}: ${PROMPT}`);
  assert.deepEqual(calls.map((c) => c.args), [
    post(CHAT, 0.02), post(CHAT, 0.02), post(CHAT, 0.02), post(`${CHAT}?u={id}`, 0.02), post(`${CHAT}?u={id}`, 0.02),
    post(CHAT, 0.02), post(CHAT, 0.02), post(CHAT, 0.02, { max_borrow_usd: 0 }),
  ]);
  assert.equal(bodyOf(`the model is {model}: ${PROMPT}`).body, PROMPT);
  // a ``` inside one of the body's strings does not end its block
  const code = JSON.stringify({ model: "m", messages: [{ role: "user", content: "explain ```x = 1``` in a line" }] });
  assert.deepEqual(bodyOf("Pay " + CHAT + " at most 0.02:\n```json\n" + code + "\n```"), { body: code, raw: "```json\n" + code + "\n```" });
  assert.equal(maxPriceOf(`Pay ${CHAT}, the model is {model}: ${PROMPT}`), null, "the body's 0.50 is never the price");
  assert.equal(borrowOf(`Pay ${CHAT} at most 0.02, use {model} here: ${PROMPT}`), null, "nor its borrow");
});

test("GHSA-p87w: braces inside a seller's URL are the URL's: they are never taken for the body, so the URL is taken out whole and nothing after them in it is read", async () => {
  const { runtime, calls } = fakeRuntime();
  await run(payX402Action, runtime, "Pay https://seller.example/data?item=1#{}borrow$25,max$5 at most 0.10");
  assert.deepEqual(calls.map((c) => c.args), [{ url: "https://seller.example/data?item=1#{}borrow$25,max$5", max_price_usd: 0.1 }]);
  assert.equal(bodyOf("Pay https://seller.example/data?item=1#{}borrow$25,max$5 at most 0.10"), null);
  const none = await run(payX402Action, runtime, "Pay https://seller.example/data?item=1#{}borrow$25,max$5");
  assert.equal(none.out.success, false, "the message names no price: nothing is paid");
  // a JSON object glued to a URL: the body is not told apart from the URL, so nothing is paid
  const glued = await run(payX402Action, runtime, 'Pay https://seller.example/data?item=1#{"a":1}borrow$25,max$5 at most 0.10: {"a":1}');
  const gluedBody = await run(payX402Action, runtime, `Pay ${CHAT}:${PROMPT} at most 0.02`);
  assert.deepEqual([glued.out.success, gluedBody.out.success, calls.length], [false, false, 1]);
  assert.match(glued.said[0].text, /Nothing was paid/);
});

test("GHSA-8pvh: more than one JSON object in the message (an example before the body, a config object), or one that does not parse: nothing is paid, nothing is guessed", async () => {
  const { runtime, calls } = fakeRuntime();
  const fence = (s) => "```json\n" + s + "\n```";
  const msgs = [
    `Pay ${CHAT} like this example:\n${fence('{"model":"example"}')}\nnow the real one:\n${fence(PROMPT)} at most 0.02`,
    `Pay ${CHAT} with config {"temperature":0} and this body: ${PROMPT} at most 0.02`,
    `Pay ${CHAT} at most 0.02: {"model": "m", "messages": }`,
    `Pay ${CHAT} at most 0.02:\n${fence('{"model": "m",')}`,
    `Pay ${CHAT} at most 0.02, the request is { body: ${PROMPT} }`,
    `Pay ${CHAT} at most 0.02:\n\`\`\`\nhere it is: ${PROMPT}\n\`\`\``,
  ];
  for (const m of msgs) {
    const { out, said } = await run(payX402Action, runtime, m);
    assert.equal(out.success, false, m);
    assert.match(said[0].text, /Nothing was paid/);
  }
  assert.deepEqual(calls, []);
  assert.ok(bodyOf(msgs[0]).error && bodyOf(msgs[1]).error && bodyOf(msgs[2]).error);
  assert.equal(maxPriceOf(msgs[0]), 0.02, "a fence's words are never the price");
});

test("GHSA-p87w: a cap phrase's number is a price only when it is an amount, not a count (up to 50 items), and a borrow's aside after its unit is the borrow's", async () => {
  assert.equal(maxPriceOf("Pay $0.05 to https://api.example/v1/search for up to 50 items"), 0.05);
  assert.equal(maxPriceOf("Fetch up to 20 items from https://api.example/v1/items, pay at most 0.10"), 0.1);
  assert.equal(maxPriceOf("Buy up to 10 records from https://api.example/v1/data"), null);
  assert.equal(maxPriceOf("Pay https://x.dev/a, max 100 tokens"), null);
  const aside = "Call https://x.dev/check and borrow 0.50 USDG (up to 5) if short, at most 0.10";
  assert.equal(maxPriceOf(aside), 0.1);
  assert.equal(borrowOf(aside), 0.5);
  // amounts, as before: a unit, $, the end, punctuation, a line break or a joining word after the number
  for (const [t, v] of [["pay https://x.dev at most 0.10", 0.1], ["https://x.dev max $5 items", 5], ["https://x.dev up to 0.10 USDG for it", 0.1],
    ["https://x.dev at most 0.10 per call", 0.1], ["https://x.dev at most 0.10 a call", 0.1], ["https://x.dev at most 0.10 and borrow up to 5", 0.1],
    ["https://x.dev at most 0.10\nthanks", 0.1], ["https://x.dev no more than 0.25 dollars", 0.25], ["https://x.dev at most 0.10 without borrowing", 0.1]]) {
    assert.equal(maxPriceOf(t), v, t);
  }
  const { runtime, calls } = fakeRuntime();
  await run(payX402Action, runtime, "Fetch up to 20 items from https://api.example/v1/items, pay at most 0.10");
  const none = await run(payX402Action, runtime, "Buy up to 10 records from https://api.example/v1/data");
  assert.deepEqual([calls.map((c) => c.args), none.out.success], [[{ url: "https://api.example/v1/items", max_price_usd: 0.1 }], false]);
});

test("the money actions answer only the operator's entities (PRIORS_OWNER_ENTITY_IDS): any other room member, or no setting, moves nothing", async () => {
  const stranger = "22222222-2222-4222-8222-222222222222";
  const text = "Pay https://example.test/x at most 1, borrow up to 25";
  const { runtime, calls } = fakeRuntime();
  assert.equal(await payX402Action.validate(runtime, msg(text, stranger)), false);
  assert.equal(await repayAction.validate(runtime, msg("repay loan 50900", stranger)), false);
  const a = await run(payX402Action, runtime, text, stranger);
  const b = await run(repayAction, runtime, "repay loan 50900", stranger);
  assert.deepEqual([a.out.success, b.out.success, calls.length], [false, false, 0]);
  assert.match(a.said[0].text, /only for its operator/);
  // no setting: refused for everyone, and the answer says what to set
  const none = fakeRuntime({});
  assert.equal(await payX402Action.validate(none.runtime, msg(text)), false);
  const c = await run(payX402Action, none.runtime, text);
  assert.deepEqual([c.out.success, none.calls.length], [false, 0]);
  assert.match(c.said[0].text, /PRIORS_OWNER_ENTITY_IDS/);
  // the operator, or anyone when the operator says "*"
  assert.equal(await payX402Action.validate(runtime, msg(text)), true);
  const any = fakeRuntime({ PRIORS_OWNER_ENTITY_IDS: "*" });
  await run(payX402Action, any.runtime, text, stranger);
  assert.equal(any.calls.length, 1);
  // the reads stay open to every member: they move no money
  assert.equal(await agentRecordAction.validate(none.runtime, msg("check agent #1234's record", stranger)), true);
});
