#!/usr/bin/env node
// @priors/mcp: every money call answers within its time budget, and a money call made while one that ran out of time is
// still running does nothing (GHSA-rg79: pt_buy waited for its receipts past the MCP client's 60 s timeout, the model
// saw nothing, and its retry signed a second buy). Network-free: the real server and MCP client over an in-memory
// transport, a throwaway key, a mock chain that mines each transaction a fixed time after its broadcast.
//   node scripts/test-mcp-call-budget.mjs
// PRIORS_MCP_SERVER=/path/to/server.mjs runs the same tests against another copy of the server (before/after a fix).
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { ethers } from "ethers";
import { decodeFunctionData, encodeFunctionResult } from "viem";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { PT_USDG } from "../sdk/pt-usdg.mjs";
import { ORACLE_ABI, PT_ABI } from "../sdk/pendle-pt.mjs";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const { createPriorsMcpServer } = await import(pathToFileURL(process.env.PRIORS_MCP_SERVER || join(ROOT, "packages/mcp/src/server.mjs")).href);

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log("  ok  ", name); } catch (e) { failed++; console.log("  FAIL", name, "\n       ", e?.stack?.split("\n").slice(0, 4).join("\n        ") || e); }
}
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
const KEY = ethers.Wallet.createRandom().privateKey;

/** PT-USDG's contracts behind an ethers provider (as scripts/test-packages.mjs's PtChain), except that a transaction's
 *  receipt appears only `mineMs` after its broadcast; every broadcast is kept in `st.sent` as "approve" or "swap". */
class SlowPtChain extends ethers.JsonRpcProvider {
  constructor(st, mineMs) { super("http://127.0.0.1:1", ethers.Network.from(4663), { staticNetwork: true, cacheTimeout: -1, batchMaxCount: 1 }); this.st = st; this.mineMs = mineMs; this.nonce = 0; this.minedAt = new Map(); }
  answer(method, params) {
    const st = this.st, lc = (a) => String(a).toLowerCase();
    if (method === "eth_chainId") return "0x1237";
    if (method === "eth_blockNumber") return "0x100";
    if (method === "eth_getBlockByNumber") return { number: "0x100", hash: "0x" + "ab".repeat(32), parentHash: "0x" + "cd".repeat(32), timestamp: "0x" + st.now.toString(16), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: "0x1c9c380", gasUsed: "0x0", miner: ethers.ZeroAddress, extraData: "0x", baseFeePerGas: "0x5f5e100", transactions: [] };
    if (method === "eth_getTransactionCount") return ethers.toBeHex(this.nonce);
    if (method === "eth_estimateGas") return "0x40000";
    if (method === "eth_gasPrice") return "0x5f5e100";
    if (method === "eth_maxPriorityFeePerGas") return "0x1";
    if (method === "eth_sendRawTransaction") {
      const tx = ethers.Transaction.from(params[0]); this.nonce++;
      st.sent.push(lc(tx.to) === lc(PT_USDG.router) ? "swap" : "approve");
      this.minedAt.set(tx.hash, Date.now() + this.mineMs);
      this.lastSend = Date.now();
      return tx.hash;
    }
    if (method === "eth_getTransactionReceipt") return Date.now() >= (this.minedAt.get(params[0]) ?? Infinity) ? { status: "0x1" } : null;
    if (method !== "eth_call") throw new Error("mock: " + method);
    const { to, data } = params[0];
    if (lc(to) === lc(PT_USDG.router)) return "0x";
    if (lc(to) === lc(PT_USDG.oracle)) return encodeFunctionResult({ abi: ORACLE_ABI, functionName: "getPtToAssetRate", result: st.rate });
    const d = decodeFunctionData({ abi: PT_ABI, data });
    if (d.functionName === "balanceOf") return encodeFunctionResult({ abi: PT_ABI, functionName: "balanceOf", result: st.usdg });
    if (d.functionName === "allowance") return encodeFunctionResult({ abi: PT_ABI, functionName: "allowance", result: 0n });
    if (d.functionName === "approve") return encodeFunctionResult({ abi: PT_ABI, functionName: "approve", result: true });
    throw new Error("mock: unexpected call");
  }
  async _send(payload) {
    return (Array.isArray(payload) ? payload : [payload]).map((p) => { try { return { id: p.id, result: this.answer(p.method, p.params) }; } catch (e) { return { id: p.id, error: { code: -32000, message: e.message } }; } });
  }
}

/** A server and a client whose requests time out after `clientTimeoutMs` (an MCP client's 60 s, scaled like the budget). */
async function connect(env, deps, clientTimeoutMs) {
  const server = await createPriorsMcpServer({ env: { PRIORS_KEY: KEY, PRIORS_STATE_DIR: mkdtempSync(join(tmpdir(), "priors-mcp-budget-")), ...env }, deps });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: "test", version: "1" });
  await client.connect(b);
  /** { timedOut } when the client gave up, else { error, text } */
  return (name, args) => client.callTool({ name, arguments: args }, undefined, { timeout: clientTimeoutMs }).then(
    (r) => ({ timedOut: false, error: !!r.isError, text: r.content.map((c) => c.text).join("\n") }),
    (e) => { if (/timed out/i.test(String(e?.message))) return { timedOut: true, text: String(e.message) }; throw e; });
}
/** Until every transaction sent is mined and none was sent for 2 s (longer than the 1.5 s between receipt polls): what
 *  the server still runs, a trade past its budget or a queued call, has finished by then. */
async function quiet(chain) {
  while (![...chain.minedAt.values()].every((t) => t <= Date.now()) || Date.now() - (chain.lastSend ?? 0) < 2_000) await sleep(200);
}
const ptState = () => ({ now: PT_USDG.expiry - 100 * 86400, rate: 980_000_000_000_000_000n, usdg: 1_000_000_000n, sent: [] });
// Budget 2 s (the server's 45 s, scaled) under a client timeout of 2.65 s (an MCP client's 60 s); each transaction is mined
// 1 s after its broadcast and receipts are polled every 1.5 s, so a buy (an approval, then the swap) takes about 3.1 s.
const BUDGET = 2_000, CLIENT_TIMEOUT = 2_650, MINE = 1_000;

console.log("@priors/mcp money calls within their time budget (GHSA-rg79)");

await test("pt_buy outlasting its budget: the model, retrying as it would after a client timeout or a 'try again', signs one buy", async () => {
  const st = ptState(), chain = new SlowPtChain(st, MINE);
  const call = await connect({}, { provider: chain, callBudgetMs: BUDGET }, CLIENT_TIMEOUT);
  const answers = [];
  for (let i = 0; i < 3; i++) {
    const r = await call("pt_buy", { amount_usdg: 50 });
    answers.push(r);
    if (!r.timedOut && !/try again/i.test(r.text)) break; // the model retries only when it saw nothing, or was told to
  }
  await quiet(chain);
  assert.equal(st.sent.filter((s) => s === "swap").length, 1, `one authorized pt_buy signed ${st.sent.filter((s) => s === "swap").length} buys (${st.sent.join(", ")}); answers: ${answers.map((a) => (a.timedOut ? "client timeout" : a.text.slice(0, 90))).join(" | ")}`);
  assert.ok(!answers[0].timedOut, "the first call answered before the client's timeout");
  assert.ok(answers[0].error && /did not finish within 2 s and is still running/.test(answers[0].text) && /Do NOT call it again/.test(answers[0].text), answers[0].text);
});

await test("a pt_buy made while an earlier one that ran out of time is still running signs nothing, and says so", async () => {
  const st = ptState(), chain = new SlowPtChain(st, MINE);
  const call = await connect({}, { provider: chain, callBudgetMs: BUDGET }, CLIENT_TIMEOUT);
  await call("pt_buy", { amount_usdg: 50 });
  const again = await call("pt_buy", { amount_usdg: 50 }); // made at once: the first buy confirms while this one waits
  await quiet(chain);
  assert.deepEqual(st.sent, ["approve", "swap"], `one buy only: ${st.sent.join(", ")}`);
  assert.ok(!again.timedOut && again.error && /Nothing was done by this call/.test(again.text), again.text);
  const later = await call("pt_buy", { amount_usdg: 1 }); // once it is over, a new call is a new purchase, as before
  assert.ok(!later.timedOut && !/Nothing was done by this call/.test(later.text), later.text);
});

await test("borrow too: a borrow outlasting its budget answers in time; one made meanwhile borrows nothing, even once the first lands", async () => {
  const rec = [];
  let land;
  const landed = new Promise((ok) => { land = ok; });
  const now = Math.floor(Date.now() / 1000);
  const credit = {
    isController: async () => true,
    quote: async (id, amount, term) => ({ amount, term, fee: 50_000n, due: amount + 50_000n }),
    borrow: async (id, amount, term) => { rec.push(amount); if (rec.length === 1) await landed; return { hash: "0x" + "11".repeat(32), loanId: 41n + BigInt(rec.length), principal: amount, fee: 50_000n, dueAt: now + Number(term) }; },
  };
  const call = await connect({ PRIORS_AGENT_ID: "7" }, { credit, callBudgetMs: 1_000 }, 1_500);
  const first = await call("borrow", { amount_usd: 5, days: 7 });
  assert.ok(!first.timedOut && first.error && /did not finish within 1 s/.test(first.text) && /Do NOT call it again/.test(first.text), first.text);
  const again = call("borrow", { amount_usd: 5, days: 7 });
  await sleep(200);
  land(); // the first borrow confirms while the second waits for it
  const r = await again;
  assert.ok(!r.timedOut && r.error && /Nothing was done by this call/.test(r.text), r.text);
  assert.equal(rec.length, 1, "one borrow sent");
  const later = await call("borrow", { amount_usd: 5, days: 7 });
  assert.ok(!later.error && /Borrowed 5\.00 USDG/.test(later.text), later.text);
});

console.log(`\nmcp call budget: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
