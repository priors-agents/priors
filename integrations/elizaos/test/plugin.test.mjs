// @priors/plugin-elizaos: what each action reads from the message and which Priors call it makes. The two MCP
// connections are replaced by a recorder (priors.js `connect`), so nothing reaches a chain.
//   node --test test/
import test from "node:test";
import assert from "node:assert/strict";
import plugin, { agentRecordAction, creditStatusAction, payX402Action, repayAction } from "../src/index.js";
import { priorsOf, priorsFor, envOf, SETTINGS } from "../src/priors.js";
import { urlOf, agentIdOf, loanIdOf, maxPriceOf, maxBorrowOf } from "../src/parse.js";

/** A runtime whose Priors calls are recorded and answered with `answers[tool]` (default: "ok"). */
function fakeRuntime(settings = {}, answers = {}) {
  const calls = [];
  const runtime = { getSetting: (k) => settings[k] };
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
const msg = (text) => ({ content: { text } });
const run = async (action, runtime, text) => {
  const said = [];
  const out = await action.handler(runtime, msg(text), {}, {}, async (c) => { said.push(c); return []; });
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
  const t = "Check agent #9233 then pay https://check.blockpin.dev/check?token=0xabc, at most 0.10, borrow up to 1.";
  assert.equal(urlOf(t), "https://check.blockpin.dev/check?token=0xabc");
  assert.equal(agentIdOf(t), 9233);
  assert.equal(maxPriceOf(t), 0.1);
  assert.equal(maxBorrowOf(t), 1);
  assert.equal(maxBorrowOf("pay https://x.dev at most 0.10"), 0, "no borrow named: never borrow");
  assert.equal(maxPriceOf("pay https://x.dev, borrow up to 2"), null, "the borrow amount is never taken for the price");
  assert.equal(loanIdOf("repay loan #50900"), 50900);
  assert.equal(urlOf("pay http://x.dev"), null, "https only");
});

test("PRIORS_AGENT_RECORD reads the record on the hosted read-only server, for the agent the message names", async () => {
  const { runtime, calls } = fakeRuntime({}, { agent_record: "Agent #9233: 2 loans repaid, no default." });
  assert.equal(await agentRecordAction.validate(runtime, msg("check agent #9233's record")), true);
  assert.equal(await agentRecordAction.validate(runtime, msg("check the record")), false, "no agent id");
  const { out, said } = await run(agentRecordAction, runtime, "check agent #9233's record");
  assert.deepEqual(calls.map(({ kind, name, args }) => ({ kind, name, args })), [{ kind: "read", name: "agent_record", args: { agent_id: 9233 } }]);
  assert.equal(out.success, true);
  assert.match(said[0].text, /2 loans repaid/);
});

test("PRIORS_CREDIT_STATUS reads the agent's own line on @priors/mcp, with the agent's settings", async () => {
  const { runtime, calls } = fakeRuntime({ PRIORS_KEY_FILE: "/k", PRIORS_AGENT_ID: "437" });
  assert.equal(await creditStatusAction.validate(runtime, msg("what is left on my credit line?")), true);
  await run(creditStatusAction, runtime, "what is left on my credit line?");
  assert.deepEqual(calls.map(({ kind, name, args, env }) => ({ kind, name, args, env })), [{ kind: "wallet", name: "credit_status", args: {}, env: { key: "/k", agent: "437", hosts: undefined } }]);
});

test("PRIORS_PAY_X402 pays the URL at most the price named, and borrows only up to the amount the message names; with no price named it pays nothing", async () => {
  const { runtime, calls } = fakeRuntime({}, { pay_url: "Paid 0.10 USDG; borrowed 0.10 (loan #50900)." });
  assert.equal(await payX402Action.validate(runtime, msg("pay https://check.blockpin.dev/check at most 0.10")), true);
  assert.equal(await payX402Action.validate(runtime, msg("what is https://check.blockpin.dev")), false);
  await run(payX402Action, runtime, "Pay https://check.blockpin.dev/check at most 0.10, borrow up to 1 if the wallet is short.");
  await run(payX402Action, runtime, "Pay https://check.blockpin.dev/check at most 0.10.");
  assert.deepEqual(calls.map((c) => c.args), [
    { url: "https://check.blockpin.dev/check", max_price_usd: 0.1, max_borrow_usd: 1 },
    { url: "https://check.blockpin.dev/check", max_price_usd: 0.1 },
  ]);
  const before = calls.length;
  const { out, said } = await run(payX402Action, runtime, "Pay https://check.blockpin.dev/check, borrow up to 1.");
  assert.equal(calls.length, before, "no price named: no call");
  assert.equal(out.success, false);
  assert.match(said[0].text, /Nothing was paid/);
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
  assert.ok(SETTINGS.includes("PRIORS_PAY_HOSTS") && SETTINGS.includes("PRIORS_KEY_FILE"));
});
