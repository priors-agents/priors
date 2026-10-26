#!/usr/bin/env node
// GHSA-rh27-m4c4-p2c7 (kevin9327): a transaction whose first broadcast the node took, and whose retried copy it then
// refused for "insufficient funds", was read as one never sent. ethers 6.17's default transport sends a request again
// after an HTTP 429 (utils/fetch.js; after a 301/302/307/308 too), and the identical signed bytes then meet the node's
// answer for a transaction it already holds. @priors/x402's sendBorrow (borrow, pay_url, pay_gateway, fund_base's loan),
// fundBase and savings, and sdk/float.mjs's pay(), took that INSUFFICIENT_FUNDS for a refusal before broadcast: the loan
// was out and nothing counted it, so @priors/mcp's PRIORS_MAX_BORROW_TOTAL_USD and PRIORS_MAX_BORROW_DAY_USD let a second
// borrow through (in the session, and after a restart on the same PRIORS_STATE_DIR), and fund_base forgot its deposit.
// The rule since @priors/x402 0.8.2 and @priors/mcp 0.12.0 (docs/SECURITY-v2.md P-48): a refusal for funds on a
// broadcast is one only while the node does not know the hash of the signed bytes ethers keeps in the error; known, or a
// lookup that fails, is BORROW_UNCONFIRMED / DEPOSIT_UNCONFIRMED / UNCONFIRMED with that hash. A refused estimate
// (CALL_EXCEPTION, or INSUFFICIENT_FUNDS with nothing signed) and a mined revert stay as they were. And the MCP's own
// provider sends an eth_sendRawTransaction once (no retry after a 429); its reads keep ethers' retries.
// Network-free: a local HTTP JSON-RPC node that takes the first copy of each signed transaction and answers it HTTP 429,
// and answers any later copy with JSON-RPC -32000 "insufficient funds for gas * price + value".
//   node scripts/test-x402-send-retried.mjs
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import * as X from "../packages/x402/index.mjs";
import * as B from "../packages/x402/src/bridge.mjs";
import * as S from "../packages/x402/src/savings.mjs";
import { POOL_ABI, borrowGap, borrowLine } from "../packages/x402/src/credit.mjs";
import { pay as floatPay } from "../sdk/float.mjs";
import { createPriorsMcpServer } from "../packages/mcp/src/server.mjs";

let passed = 0, failed = 0;
/** Each case has 20 s: a wait that never settles is a failure, not a process that quietly exits. */
async function check(name, fn) {
  let timer;
  try {
    await Promise.race([fn(), new Promise((_, no) => { timer = setTimeout(() => no(new Error("no answer in 20 s")), 20_000); })]);
    passed++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failed++;
    console.log(`  FAIL ${name}\n       ${String((e && e.stack) || e).split("\n").slice(0, 6).join("\n       ")}`);
  } finally {
    clearTimeout(timer);
  }
}
async function rejects(p, code) {
  try { await p; } catch (e) { assert.equal(e?.code, code, `expected ${code}, got ${e?.code}: ${e?.message}`); return e; }
  assert.fail(`expected ${code}, and it resolved`);
}

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const DEP = JSON.parse(readFileSync(join(ROOT, "packages/mcp/deployments/4663.v2.json"), "utf8"));
const POOL = ethers.getAddress(DEP.pool), REGISTRY = ethers.getAddress(DEP.registry), USDG = ethers.getAddress(DEP.usdg);
const SPOKE = ethers.getAddress(X.ACROSS.spokes[4663]), DEST_SPOKE = X.ACROSS.spokes[8453], USDC = X.BASE_USDC.asset;
const VAULT = ethers.getAddress("0x" + "5a".repeat(20)); // a savings vault (only what unsave reads and sends)
const RELAYER = "0xFD03AbCAdaF3F930fA4E37Eb2f6ea3A44a41b7F0";
const PAY_TO = "0x1111111111111111111111111111111111111111";
const AGENT = 7n, LOAN = 25_000000n, WEEK = 7n * 86_400n;
const KEY = ethers.Wallet.createRandom().privateKey;
const OWNER = new ethers.Wallet(KEY).address; // the agent's owner: the key every case signs with
const FUNDS = "insufficient funds for gas * price + value";
const NOW = () => Math.floor(Date.now() / 1000);
const H = (n) => ethers.toBeHex(n);
const BLOCK_HASH = ethers.id("block 0x100");
const TMP = mkdtempSync(join(tmpdir(), "priors-rh27-"));
process.on("exit", () => rmSync(TMP, { recursive: true, force: true }));
const stateDir = () => mkdtempSync(join(TMP, "state-"));

const poolI = new ethers.Interface(POOL_ABI);
const regI = new ethers.Interface(["function ownerOf(uint256) view returns (address)", "function getAgentWallet(uint256) view returns (address)"]);
const erc20I = new ethers.Interface(["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"]);
const spokeI = new ethers.Interface(B.ACROSS_SPOKE_ABI);
const vaultI = new ethers.Interface(S.VAULT_ABI);

/**
 * Robinhood Chain (4663) on 127.0.0.1, which real ethers talks to over HTTP: agent #7 of OWNER on the pool, USDG, the
 * Across spoke and a savings vault.
 *   send: "retried"       the first copy of a signed transaction is taken (a borrow opens its loan, a deposit or a
 *                         withdrawal moves the money) and answered HTTP 429; every later copy of those bytes is answered
 *                         JSON-RPC -32000 "insufficient funds for gas * price + value";
 *         "noGas"         every copy is refused that way and none is taken (a wallet with no ETH for gas);
 *         "receiptError"  taken and answered with its hash; every receipt read for it answers an in-band JSON-RPC error
 *   lookup: "fail"        eth_getTransactionByHash answers an in-band error
 *   throttleFirstRead     the first eth_call is answered HTTP 429 (a throttled read, which ethers retries)
 *   usdg                  OWNER's USDG (allowances are unlimited)
 * `copies` holds the hash of every eth_sendRawTransaction request that reached it, `taken` what it took. `provider` is
 * ethers' own transport on it (a 429 is retried), as an embedder, a script or the SDK's callers use it.
 */
async function node({ send = "retried", lookup = "ok", throttleFirstRead = false, usdg = 0n } = {}) {
  const st = { copies: [], taken: [], methods: [], throttled: false };
  const byHash = new Map();
  const take = (raw) => {
    const t = ethers.Transaction.from(raw);
    const to = t.to ? ethers.getAddress(t.to) : null;
    const x = { hash: t.hash, t, logs: [], kind: to === POOL ? "borrow" : to === SPOKE ? "deposit" : to === VAULT ? "withdrawal" : "other" };
    if (x.kind === "borrow") {
      const a = poolI.parseTransaction({ data: t.data }).args;
      const loanId = BigInt(st.taken.filter((y) => y.kind === "borrow").length + 1);
      x.logs.push({ ...poolI.encodeEventLog("Borrowed", [loanId, a[0], 6228n, a[1], 50_000n, BigInt(NOW() + 7 * 86_400), a[3]]), address: POOL });
    }
    st.taken.push(x);
    byHash.set(x.hash, x);
    return x;
  };
  const block = () => ({ hash: BLOCK_HASH, parentHash: ethers.id("block 0xff"), number: "0x100", timestamp: H(NOW()), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: H(30_000_000), gasUsed: "0x0", miner: ethers.ZeroAddress, extraData: "0x", baseFeePerGas: H(10_000_000), transactions: [], stateRoot: ethers.ZeroHash, receiptsRoot: ethers.ZeroHash, logsBloom: "0x" + "00".repeat(256), sha3Uncles: ethers.ZeroHash, transactionsRoot: ethers.ZeroHash, mixHash: ethers.ZeroHash, size: "0x0", uncles: [] });
  const receiptOf = (x) => ({ transactionHash: x.hash, transactionIndex: "0x0", blockHash: BLOCK_HASH, blockNumber: "0x100", from: x.t.from, to: x.t.to, cumulativeGasUsed: "0x30000", gasUsed: "0x30000", contractAddress: null, logsBloom: "0x" + "00".repeat(256), status: "0x1", effectiveGasPrice: H(10_000_000), type: "0x2",
    logs: x.logs.map((l, i) => ({ ...l, logIndex: H(i), transactionIndex: "0x0", transactionHash: x.hash, blockHash: BLOCK_HASH, blockNumber: "0x100", removed: false })) });
  const txOf = ({ t }) => ({ hash: t.hash, from: t.from, to: t.to, nonce: H(t.nonce), gas: H(t.gasLimit), input: t.data, value: H(t.value), type: H(t.type), chainId: H(t.chainId), maxFeePerGas: H(t.maxFeePerGas ?? 0n), maxPriorityFeePerGas: H(t.maxPriorityFeePerGas ?? 0n), gasPrice: H(t.maxFeePerGas ?? t.gasPrice ?? 0n), accessList: [],
    r: t.signature.r, s: t.signature.s, v: H(t.signature.v), yParity: H(t.signature.yParity), blockHash: BLOCK_HASH, blockNumber: "0x100", transactionIndex: "0x0" });
  const call = ({ to, data }) => {
    const at = ethers.getAddress(to);
    if (at === REGISTRY) return regI.encodeFunctionResult(regI.parseTransaction({ data }).name, [OWNER]);
    if (at === USDG) { const f = erc20I.parseTransaction({ data }); return erc20I.encodeFunctionResult(f.name, [f.name === "balanceOf" ? usdg : ethers.MaxUint256]); }
    if (at === SPOKE) { spokeI.parseTransaction({ data }); return "0x"; } // depositV3, simulated
    if (at === VAULT) { const f = vaultI.parseTransaction({ data }); return vaultI.encodeFunctionResult(f.name, [LOAN]); } // shares, their value, withdraw
    if (at !== POOL) throw new Error(`node: no contract at ${to}`);
    const f = poolI.parseTransaction({ data });
    if (f.name === "usdg") return poolI.encodeFunctionResult("usdg", [USDG]);
    if (f.name === "registry") return poolI.encodeFunctionResult("registry", [REGISTRY]);
    if (f.name === "getParams") return poolI.encodeFunctionResult("getParams", [[1_000000n, 500_000000n, 86_400n, 30n * 86_400n, 3n * 86_400n, WEEK, 100n, 0n, 0n, 0n, 9000n, 0n]]);
    if (f.name === "quoteFee") return poolI.encodeFunctionResult("quoteFee", [50_000n, 0n, 0n, 0n]);
    if (f.name === "isController") return poolI.encodeFunctionResult("isController", [true]);
    if (f.name === "borrow") return poolI.encodeFunctionResult("borrow", [BigInt(st.taken.length + 1)]);
    if (f.name === "getAgent") { // a treasury line (root #6228), not SeatVaultV5's
      const a = poolI.getFunction("getAgent").outputs[0].components.map((c) => (c.type === "bool" ? c.name === "enrolled" : c.name === "sponsor" ? 6228n : c.name === "delegatedIn" ? 100_000000n : 0n));
      return poolI.encodeFunctionResult("getAgent", [a]);
    }
    throw new Error(`node: no answer for the pool's ${f.name}`);
  };
  const answer = (q) => {
    const ok = (result) => ({ jsonrpc: "2.0", id: q.id, result });
    const no = (code, message) => ({ jsonrpc: "2.0", id: q.id, error: { code, message } });
    switch (q.method) {
      case "eth_chainId": return ok("0x1237");
      case "eth_blockNumber": return ok("0x100");
      case "eth_getBlockByNumber": return ok(block());
      case "eth_gasPrice": return ok(H(10_000_000));
      case "eth_maxPriorityFeePerGas": return ok("0x0");
      case "eth_estimateGas": return ok(H(300_000));
      case "eth_getBalance": return ok(H(10n ** 18n));
      case "eth_getTransactionCount": return ok(H(st.taken.length));
      case "eth_call": try { return ok(call(q.params[0])); } catch (e) { return no(-32000, e.message); }
      case "eth_sendRawTransaction": {
        const raw = q.params[0];
        if (send === "noGas" || byHash.has(ethers.keccak256(raw))) return no(-32000, FUNDS);
        return ok(take(raw).hash);
      }
      case "eth_getTransactionReceipt": {
        const x = byHash.get(q.params[0]);
        if (x && send === "receiptError") return no(-32603, "execution reverted: the receipt could not be read");
        return ok(x ? receiptOf(x) : null);
      }
      case "eth_getTransactionByHash": {
        if (lookup === "fail") return no(-32603, "internal error");
        const x = byHash.get(q.params[0]);
        return ok(x ? txOf(x) : null);
      }
      default: return no(-32601, `node: no ${q.method}`);
    }
  };
  const srv = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const reply = (status, out) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(out)); };
      let p;
      try { p = JSON.parse(body); } catch (_) { reply(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }); return; }
      const list = Array.isArray(p) ? p : [p];
      st.methods.push(...list.map((q) => q.method));
      const sent = list.find((q) => q.method === "eth_sendRawTransaction");
      if (sent) st.copies.push(ethers.keccak256(sent.params[0]));
      if (sent && send === "retried" && !byHash.has(ethers.keccak256(sent.params[0]))) {
        take(sent.params[0]); // taken, and its answer throttled
        reply(429, { jsonrpc: "2.0", id: sent.id, error: { code: -32005, message: "rate limited" } });
        return;
      }
      if (throttleFirstRead && !st.throttled && list.some((q) => q.method === "eth_call")) {
        st.throttled = true;
        reply(429, { jsonrpc: "2.0", id: null, error: { code: -32005, message: "rate limited" } });
        return;
      }
      const out = list.map(answer);
      reply(200, Array.isArray(p) ? out : out[0]);
    });
  });
  await new Promise((ok) => srv.listen(0, "127.0.0.1", ok));
  st.url = `http://127.0.0.1:${srv.address().port}`;
  st.provider = new ethers.JsonRpcProvider(st.url, ethers.Network.from(4663), { staticNetwork: true, cacheTimeout: -1, batchMaxCount: 1 });
  st.loans = () => st.taken.filter((x) => x.kind === "borrow");
  st.close = () => new Promise((ok) => { st.provider.destroy(); srv.closeAllConnections?.(); srv.close(ok); });
  return st;
}

/** Across's API as a fetch: a live-shaped suggested-fees answer for the amount asked (test-x402-base.mjs's). */
function across() {
  return async (input) => {
    const u = new URL(typeof input === "string" ? input : input.url);
    if (u.pathname !== "/api/suggested-fees") return new Response("{}", { status: 404 });
    const amount = BigInt(u.searchParams.get("amount")), fee = 3_500n + (amount * 6n) / 10_000n, now = NOW();
    return new Response(JSON.stringify({
      estimatedFillTimeSec: 2, timestamp: String(now - 20), isAmountTooLow: false, exclusiveRelayer: RELAYER, exclusivityDeadline: 3, spokePoolAddress: SPOKE, destinationSpokePoolAddress: DEST_SPOKE,
      limits: { minDeposit: "500194", maxDeposit: "972502725625" }, fillDeadline: String(now - 20 + 7200), outputAmount: String(amount - fee),
      inputToken: { address: USDG, symbol: "USDG", decimals: 6, chainId: 4663 }, outputToken: { address: USDC, symbol: "USDC", decimals: 6, chainId: 8453 },
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
}
/** An x402 v1 merchant asking `price` USDG on Robinhood Chain. */
const merchant = (price) => async (url) => new Response(JSON.stringify({ x402Version: 1, accepts: [{ scheme: "exact", network: "robinhood", asset: USDG, maxAmountRequired: String(price), payTo: PAY_TO, maxTimeoutSeconds: 600, resource: String(url) }] }), { status: 402, headers: { "content-type": "application/json" } });

/** @priors/mcp with `env`, over an in-memory MCP transport; `deps.provider` replaces the server's own provider. */
async function mcp(env, deps = {}) {
  const server = await createPriorsMcpServer({ env: { PRIORS_KEY: KEY, PRIORS_AGENT_ID: String(AGENT), PRIORS_SAVINGS_VAULT: "off", ...env }, deps });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: "test", version: "1" });
  await client.connect(b);
  return async (name, args = {}) => {
    const r = await client.callTool({ name, arguments: args });
    return { error: !!r.isError, text: r.content.map((c) => c.text).join("\n") };
  };
}
const gap = (w) => borrowGap({ signer: w, pool: POOL, agentId: AGENT, price: LOAN, balance: 0n, maxBorrow: LOAN, me: w.address });
const lineOf = (provider) => ({ pool: new ethers.Contract(POOL, POOL_ABI, provider), registry: new ethers.Contract(REGISTRY, regI.fragments, provider) });

console.log("GHSA-rh27-m4c4-p2c7: a broadcast the node took, then refused on ethers' retried copy, is never read as not sent");

await check("1. the trigger: ethers sends the signed borrow twice after a 429, the node takes one, and the error is INSUFFICIENT_FUNDS with those bytes", async () => {
  const n = await node();
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    let e = null;
    try { await new ethers.Contract(POOL, POOL_ABI, w).borrow(AGENT, LOAN, WEEK, w.address, 50_000n); } catch (x) { e = x; }
    assert.equal(e?.code, "INSUFFICIENT_FUNDS", `the error: ${e?.code} ${e?.message}`);
    assert.equal(n.copies.length, 2, `ethers sent the signed borrow ${n.copies.length} times`);
    assert.equal(new Set(n.copies).size, 1, "the same bytes both times");
    assert.equal(n.loans().length, 1, "the node took one: the loan exists");
    assert.equal(ethers.keccak256(e.transaction), n.loans()[0].hash, "the error carries the signed bytes the node took");
  } finally { await n.close(); }
});

await check("2. borrowGap (pay_url, pay_gateway, fund_base's loan) and borrowLine (borrow): BORROW_UNCONFIRMED with borrowed = 25 USDG and the hash the node took", async () => {
  for (const viaLine of [false, true]) {
    const n = await node();
    try {
      const w = new ethers.Wallet(KEY, n.provider);
      const e = await rejects(viaLine ? borrowLine(lineOf(n.provider), w, AGENT, LOAN, WEEK) : gap(w), "BORROW_UNCONFIRMED");
      const what = viaLine ? "borrowLine" : "borrowGap";
      assert.equal(n.loans().length, 1, `${what}: the node took the borrow`);
      assert.equal(e.borrowed, LOAN, `${what}: borrowed`);
      assert.equal(e.unconfirmed, true, `${what}: unconfirmed`);
      assert.equal(e.hash, n.loans()[0].hash, `${what}: the hash of the loan taken`);
      assert.equal(e.cause?.code, "INSUFFICIENT_FUNDS", `${what}: the node's answer is kept as the cause`);
    } finally { await n.close(); }
  }
});

await check("3. control: a genuine no-gas refusal (the node never took it) still says nothing was sent: borrowGap, borrowLine and float pay() INSUFFICIENT_FUNDS, fundBase NO_GAS (moved: false)", async () => {
  const n = await node({ send: "noGas", usdg: 5_000000n });
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    const e1 = await rejects(gap(w), "INSUFFICIENT_FUNDS");
    assert.equal(e1.borrowed, undefined, "borrowGap: nothing borrowed");
    const e2 = await rejects(borrowLine(lineOf(n.provider), w, AGENT, LOAN, WEEK), "INSUFFICIENT_FUNDS");
    assert.equal(e2.borrowed, undefined, "borrowLine: nothing borrowed");
    const e3 = await rejects(floatPay("https://merchant.example/data", { signer: w, pool: POOL, agentId: AGENT, maxBorrow: LOAN, maxPrice: LOAN, fetchImpl: merchant(LOAN) }), "INSUFFICIENT_FUNDS");
    assert.equal(e3.borrowed, undefined, "float: nothing borrowed");
    const e4 = await rejects(B.fundBase({ signer: w, amount: 5_000000n, fetchImpl: across() }), "NO_GAS");
    assert.equal(e4.moved, false, "fundBase: nothing moved");
    assert.equal(n.taken.length, 0, "the node took nothing");
  } finally { await n.close(); }
});

await check("4. a receipt read that answers an in-band JSON-RPC error (even one that says reverted) is a lost answer: BORROW_UNCONFIRMED with the hash, never CALL_EXCEPTION", async () => {
  const n = await node({ send: "receiptError" });
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    const e = await rejects(gap(w), "BORROW_UNCONFIRMED");
    assert.equal(n.copies.length, 1, "sent once (answered 200)");
    assert.equal(n.loans().length, 1);
    assert.equal(e.borrowed, LOAN);
    assert.equal(e.hash, n.loans()[0].hash);
    assert.notEqual(e.cause?.code, "CALL_EXCEPTION");
  } finally { await n.close(); }
});

await check("5. fundBase: a deposit the node took is DEPOSIT_UNCONFIRMED with moved: true and its hash (fund_base keeps its record in flight), not NO_GAS", async () => {
  const n = await node({ usdg: 5_000000n });
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    let recorded = 0;
    const e = await rejects(B.fundBase({ signer: w, amount: 5_000000n, fetchImpl: across(), onDepositSending: () => { recorded++; } }), "DEPOSIT_UNCONFIRMED");
    const dep = n.taken.filter((x) => x.kind === "deposit");
    assert.equal(dep.length, 1, "the node took the deposit");
    assert.equal(recorded, 1, "the record was written before the broadcast");
    assert.equal(e.moved, true, "moved: true (the USDG may be out)");
    assert.equal(e.unconfirmed, true);
    assert.equal(e.hash, dep[0].hash);
  } finally { await n.close(); }
});

await check("6. sdk/float.mjs pay(): BORROW_UNCONFIRMED with borrowed = 25 USDG and the hash, and nothing signed for the merchant", async () => {
  const n = await node();
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    let signs = 0;
    w.signTypedData = async () => { signs++; throw new Error("not expected: no payment once the borrow is unconfirmed"); };
    const e = await rejects(floatPay("https://merchant.example/data", { signer: w, pool: POOL, agentId: AGENT, maxBorrow: LOAN, maxPrice: LOAN, fetchImpl: merchant(LOAN) }), "BORROW_UNCONFIRMED");
    assert.equal(n.loans().length, 1);
    assert.equal(e.borrowed, LOAN);
    assert.equal(e.unconfirmed, true);
    assert.equal(e.hash, n.loans()[0].hash);
    assert.equal(signs, 0, "no payment signed");
  } finally { await n.close(); }
});

await check("7. @priors/mcp borrow: the loan the node took counts against PRIORS_MAX_BORROW_TOTAL_USD (25), so a second borrow of 25 is refused and the node holds one loan", async () => {
  const n = await node();
  try {
    const call = await mcp({ PRIORS_STATE_DIR: stateDir(), PRIORS_MAX_BORROW_TOTAL_USD: "25" }, { provider: n.provider });
    const first = await call("borrow", { amount_usd: 25, days: 7 });
    const second = await call("borrow", { amount_usd: 25, days: 7 });
    assert.equal(n.loans().length, 1, `the node holds ${n.loans().length} loans of 25 USDG against a 25 USDG session cap (answers: ${first.text} | ${second.text})`);
    assert.ok(first.error && /A borrow of 25\.00 USDG for agent #7 was sent/.test(first.text) && /may have opened a loan/.test(first.text) && first.text.includes(n.loans()[0].hash), first.text);
    assert.ok(second.error && /PRIORS_MAX_BORROW_TOTAL_USD/.test(second.text), second.text);
  } finally { await n.close(); }
});

await check("8. @priors/mcp borrow after a restart on the same PRIORS_STATE_DIR: the day's count holds the loan, so PRIORS_MAX_BORROW_DAY_USD (25) refuses a second", async () => {
  const n = await node();
  try {
    const env = { PRIORS_STATE_DIR: stateDir(), PRIORS_MAX_BORROW_DAY_USD: "25" };
    const first = await (await mcp(env, { provider: n.provider }))("borrow", { amount_usd: 25, days: 7 });
    // a new process: its session count starts at 0, the day's count is on file
    const again = await (await mcp(env, { provider: n.provider }))("borrow", { amount_usd: 25, days: 7 });
    assert.equal(n.loans().length, 1, `the node holds ${n.loans().length} loans of 25 USDG against a 25 USDG daily cap (answers: ${first.text} | ${again.text})`);
    assert.ok(first.error && /may have opened a loan/.test(first.text), first.text);
    assert.ok(again.error && /PRIORS_MAX_BORROW_DAY_USD/.test(again.text) && /25\.00 USDG was borrowed today/.test(again.text), again.text);
  } finally { await n.close(); }
});

await check("9. a hash lookup that fails is not proof nothing was sent: BORROW_UNCONFIRMED with the hash", async () => {
  const n = await node({ lookup: "fail" });
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    const e = await rejects(gap(w), "BORROW_UNCONFIRMED");
    assert.equal(n.loans().length, 1);
    assert.equal(e.hash, n.loans()[0].hash);
  } finally { await n.close(); }
});

await check("10. savings: a withdrawal the node took is UNCONFIRMED with its hash (pay_url and repay then wait for it), not NO_GAS", async () => {
  const n = await node();
  try {
    const w = new ethers.Wallet(KEY, n.provider);
    const c = { vault: new ethers.Contract(VAULT, S.VAULT_ABI, n.provider), usdg: new ethers.Contract(USDG, erc20I.fragments, n.provider), address: VAULT, provider: n.provider };
    const o = {};
    const e = await rejects(S.unsave(c, w, { amount: 5_000000n }, o), "UNCONFIRMED");
    const out = n.taken.filter((x) => x.kind === "withdrawal");
    assert.equal(out.length, 1, "the node took the withdrawal");
    assert.equal(e.hash, out[0].hash);
    assert.equal(o.sent, out[0].hash, "o.sent names it");
  } finally { await n.close(); }
});

await check("11. @priors/mcp's own provider (PRIORS_RPC) sends the signed borrow once: no copy after the 429, BORROW_UNCONFIRMED; a throttled read is still retried", async () => {
  const n = await node({ throttleFirstRead: true });
  try {
    const call = await mcp({ PRIORS_STATE_DIR: stateDir(), PRIORS_RPC: n.url });
    const r = await call("borrow", { amount_usd: 25, days: 7 });
    assert.ok(n.throttled, "a read was answered 429");
    assert.equal(n.copies.length, 1, `the signed borrow reached the node ${n.copies.length} times (answer: ${r.text})`);
    assert.equal(n.loans().length, 1);
    assert.ok(r.error && /A borrow of 25\.00 USDG for agent #7 was sent/.test(r.text) && /may have opened a loan/.test(r.text), r.text);
    const again = await call("borrow", { amount_usd: 25, days: 7 });
    assert.equal(n.loans().length, 1, `the node holds ${n.loans().length} loans (answer: ${again.text})`);
    assert.ok(again.error && /PRIORS_MAX_BORROW_TOTAL_USD/.test(again.text), again.text);
  } finally { await n.close(); }
});

console.log(`\nx402 send retried (GHSA-rh27-m4c4-p2c7): ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
