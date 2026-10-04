// Lines sponsored by the V5 seat vault, network-free. V5 vouches nothing when it opens a line: the pool lends on it only
// after the borrower's own refresh(agentId) on V5, sent with gas = estimate x 1.5 + 150 000. Every v2 borrow path must
// send that refresh first when (and only when) its addresses name V5 and V5's root sponsors the agent:
// PriorsV2.borrow (and so `priors-v2 borrow`), float pay() and PriorsV2.pay, @priors/x402's borrowGap / createPayer /
// borrowLine, and @priors/mcp's borrow tool. A local JSON-RPC stub plays the pool, the registry, USDG and V5, and keeps
// every transaction sent; nothing reaches a real chain.
//
//   node scripts/test-v5-line.mjs
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { ethers } from "ethers";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { PriorsV2, POOL_V2_ABI } from "../sdk/priors-v2.mjs";
import { pay, refreshV5Line as sdkRefreshV5Line, SEAT_VAULT_V5_ABI } from "../sdk/float.mjs";
import { readDeploymentV2 } from "../sdk/env.mjs";
import * as credit from "../packages/x402/src/credit.mjs";
import { createPayer } from "../packages/x402/index.mjs";
import { createPriorsMcpServer } from "../packages/mcp/src/server.mjs";

let passed = 0, failed = 0;
async function check(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failed++;
    console.log(`  FAIL ${name}\n       ${String((e && e.stack) || e).split("\n").slice(0, 6).join("\n       ")}`);
  }
}

const REC = readDeploymentV2(4663);
// Today's record, whatever a later one adds: the "no V5" cases must not change when V5 is recorded.
const { seatVaultV5: _v5, seatVaultV5AgentId: _v5id, ...NO_V5 } = REC;
const POOL = REC.pool, REG = REC.registry, USDG = REC.usdg;
const V5 = ethers.getAddress("0x" + "5e".repeat(20)); // a stand-in: V5 is not deployed, and no real address is assumed
const V5_ROOT = 7001n;
const OTHER_ROOT = BigInt(REC.treasuryV4AgentId);
const AGENT = 77n;
const NOW = 1_900_000_000;
const BLOCK = 80_000_000;
const REFRESH_GAS = 200_000n, BORROW_GAS = 300_000n;
const MARGIN = (REFRESH_GAS * 3n) / 2n + 150_000n; // 450 000: estimate x 1.5 + 150 000

const owner = ethers.Wallet.createRandom();
const delegate = ethers.Wallet.createRandom();
const poolI = new ethers.Interface(POOL_V2_ABI);
const v5I = new ethers.Interface(SEAT_VAULT_V5_ABI);
const regI = new ethers.Interface(["function ownerOf(uint256) view returns (address)"]);
const erc20I = new ethers.Interface(["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"]);
const PARAMS = [1_000000n, 50_000000n, 86_400n, 30n * 86_400n, 3n * 86_400n, 7n * 86_400n, 100n, 0n, 0n, 0n, 9_000n, 0n];
const FEE = 11_666n;

/**
 * The chain an agent sees: its sponsor and line on the pool, its owner, the delegate V5 recorded, V5's root, and what
 * V5's refresh does (raise the vouch to `raiseTo` while its price is fresh; revert with `refreshRevert`).
 */
function world(over = {}) {
  return { sponsor: V5_ROOT, delegatedIn: 0n, principalOut: 0n, owner: owner.address, poolDelegate: delegate.address, noted: [ethers.ZeroAddress, 0n], root: V5_ROOT, raiseTo: 10_000000n, fresh: true, refreshRevert: null, balance: 0n, ...over };
}

/** A JSON-RPC stub for world `w`. `asked`: every eth_call / eth_estimateGas as "Contract.fn"; `sent`: every transaction. */
function chain(w) {
  const asked = [], sent = [], receipts = new Map(), nonces = new Map();
  let loans = 0;
  const q = (n) => ethers.toQuantity(n);
  const H = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
  const agentTuple = () => [true, false, false, false, false, 1n, 0n, 0n, w.sponsor, w.delegatedIn, 0n, w.principalOut, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  /** One call: { result } or { revert } (hex), and its gas; `send` applies its effects (and returns logs). */
  function exec({ to, data, from }, send) {
    const name = (c, fn) => asked.push(`${c}.${fn}`);
    if (same(to, POOL)) {
      const f = poolI.parseTransaction({ data });
      name("pool", f.name);
      const ok = (vals) => ({ result: poolI.encodeFunctionResult(f.name, vals), gas: f.name === "borrow" ? BORROW_GAS : 50_000n });
      switch (f.name) {
        case "getAgent": return ok([agentTuple()]);
        case "registry": return ok([REG]);
        case "usdg": return ok([USDG]);
        case "getParams": return ok([PARAMS]);
        case "quoteFee": return ok([FEE, 0n, 0n, 0n]);
        case "isController": return ok([same(f.args[1], w.owner) || same(f.args[1], w.poolDelegate)]);
        case "borrow": {
          const [id, amount, term, recipient] = f.args;
          const avail = w.delegatedIn > w.principalOut ? w.delegatedIn - w.principalOut : 0n;
          if (amount > avail) return { revert: poolI.encodeErrorResult("InsufficientCapacity", [id, amount, avail]) };
          if (!send) return ok([BigInt(loans + 1)]);
          w.principalOut += amount;
          const loanId = BigInt(++loans);
          const log = poolI.encodeEventLog("Borrowed", [loanId, id, w.sponsor, amount, FEE, BigInt(NOW) + term, recipient]);
          return { ...ok([loanId]), logs: [{ address: POOL, ...log }] };
        }
      }
    }
    if (same(to, V5)) {
      const f = v5I.parseTransaction({ data });
      name("v5", f.name);
      const ok = (vals) => ({ result: v5I.encodeFunctionResult(f.name, vals), gas: f.name === "refresh" ? REFRESH_GAS : 50_000n });
      switch (f.name) {
        case "rootId": return ok([w.root]);
        case "delegateOf": return ok(w.noted);
        case "refresh":
          if (w.refreshRevert) return { revert: v5I.encodeErrorResult(w.refreshRevert, []) };
          if (send && w.fresh && w.raiseTo > w.delegatedIn) w.delegatedIn = w.raiseTo;
          return ok([]);
      }
    }
    if (same(to, REG)) { const f = regI.parseTransaction({ data }); name("registry", f.name); return { result: regI.encodeFunctionResult(f.name, [w.owner]), gas: 50_000n }; }
    if (same(to, USDG)) { const f = erc20I.parseTransaction({ data }); name("usdg", f.name); return { result: erc20I.encodeFunctionResult(f.name, [f.name === "balanceOf" ? w.balance : 0n]), gas: 50_000n }; }
    return { unknown: `no contract here answers ${to} ${String(data).slice(0, 10)} (from ${from})` };
  }
  const block = () => ({ number: q(BLOCK), hash: H(1), parentHash: H(0), timestamp: q(NOW), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: q(30_000_000), gasUsed: "0x0", miner: ethers.ZeroAddress, extraData: "0x", baseFeePerGas: q(1_000_000_000), transactions: [] });
  function answer(r) {
    const ok = (result) => ({ jsonrpc: "2.0", id: r.id, result });
    const err = (code, message, data) => ({ jsonrpc: "2.0", id: r.id, error: { code, message, ...(data ? { data } : {}) } });
    switch (r.method) {
      case "eth_chainId": return ok("0x1237");
      case "net_version": return ok("4663");
      case "eth_blockNumber": return ok(q(BLOCK));
      case "eth_getBlockByNumber": return ok(block());
      case "eth_gasPrice": case "eth_maxPriorityFeePerGas": return ok(q(1_000_000_000));
      case "eth_getTransactionCount": return ok(q(nonces.get(String(r.params[0]).toLowerCase()) || 0));
      case "eth_call": case "eth_estimateGas": {
        const x = exec(r.params[0], false);
        if (x.unknown) return err(-32601, x.unknown);
        if (x.revert) return err(3, "execution reverted", x.revert);
        return ok(r.method === "eth_call" ? x.result : q(x.gas));
      }
      case "eth_sendRawTransaction": {
        const tx = ethers.Transaction.from(r.params[0]);
        const x = exec({ to: tx.to, data: tx.data, from: tx.from }, true);
        if (x.unknown) return err(-32601, x.unknown);
        const contract = same(tx.to, V5) ? "v5" : same(tx.to, POOL) ? "pool" : tx.to;
        let fn = String(tx.data).slice(0, 10);
        try { fn = (same(tx.to, V5) ? v5I : poolI).parseTransaction({ data: tx.data })?.name ?? fn; } catch (_) { /* another contract: its selector */ }
        sent.push({ to: contract, fn, gasLimit: tx.gasLimit, from: tx.from });
        nonces.set(tx.from.toLowerCase(), (nonces.get(tx.from.toLowerCase()) || 0) + 1);
        const logs = (x.logs || []).map((l, i) => ({ ...l, blockNumber: q(BLOCK), blockHash: H(1), transactionHash: tx.hash, transactionIndex: "0x0", logIndex: q(i), removed: false }));
        receipts.set(tx.hash, { transactionHash: tx.hash, blockHash: H(1), blockNumber: q(BLOCK), transactionIndex: "0x0", from: tx.from, to: tx.to, contractAddress: null, cumulativeGasUsed: q(x.gas || 21_000n), gasUsed: q(x.gas || 21_000n), effectiveGasPrice: q(1_000_000_000), logs, logsBloom: "0x" + "00".repeat(256), status: x.revert ? "0x0" : "0x1", type: "0x2" });
        return ok(tx.hash);
      }
      case "eth_getTransactionReceipt": return ok(receipts.get(r.params[0]) || null);
      default: return err(-32601, `unexpected ${r.method}`);
    }
  }
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const msg = JSON.parse(body);
      const out = [].concat(msg).map(answer);
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(Array.isArray(msg) ? out : out[0]));
    });
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => {
    const url = `http://127.0.0.1:${server.address().port}`;
    const provider = new ethers.JsonRpcProvider(url, 4663, { staticNetwork: true, cacheTimeout: -1 });
    ok({ url, provider, asked, sent, close: () => { provider.destroy(); server.closeAllConnections(); server.close(); } });
  }));
}
/** Run `fn(c)` against a fresh chain for world `over`; the chain is closed whatever happens. */
async function onChain(over, fn) {
  const c = await chain(world(over));
  try { return await fn(c); } finally { c.close(); }
}
const asSent = (c) => c.sent.map((s) => `${s.to}.${s.fn}`);
const noV5Asked = (c) => assert.ok(!c.asked.some((a) => a.startsWith("v5.")) && !c.sent.some((s) => s.to === "v5"), `V5 was asked: ${c.asked.join(", ")}`);
/** The refresh, then the borrow; the refresh with exactly the V5 margin, sent by `from`. */
function refreshThenBorrow(c, from = owner.address) {
  assert.deepEqual(asSent(c), ["v5.refresh", "pool.borrow"]);
  assert.equal(c.sent[0].gasLimit, MARGIN, `refresh gas ${c.sent[0].gasLimit}, want estimate x 1.5 + 150 000 = ${MARGIN}`);
  assert.equal(c.sent[0].from, from);
}
const rejectsWith = async (p, code, re) => {
  const e = await p.then(() => null, (x) => x);
  assert.ok(e, `no error, want ${code}`);
  assert.equal(e.code, code, `got ${e.code}: ${e.message}`);
  if (re) assert.match(e.message, re);
  assert.doesNotMatch(e.message, /InsufficientCapacity/);
  return e;
};
const sdk = (c, key = owner, addresses = { ...NO_V5, seatVaultV5: V5 }) => new PriorsV2({ signer: key.connect(c.provider), addresses });

// ---------------------------------------------------------------------------------------------------------------
console.log("PriorsV2.borrow (sdk/priors-v2.mjs, and so `priors-v2 borrow`)");

await check("a record without seatVaultV5: only the borrow is sent, and neither V5 nor the pool's getAgent is asked (today's behaviour)", () =>
  onChain({ delegatedIn: 10_000000n }, async (c) => {
    const r = await sdk(c, owner, NO_V5).borrow(AGENT, 5, 7 * 86400);
    assert.equal(r.loanId, 1);
    assert.deepEqual(asSent(c), ["pool.borrow"]);
    noV5Asked(c);
    assert.ok(!c.asked.includes("pool.getAgent"), `getAgent was read: ${c.asked}`);
  }));

await check("V5's root sponsors the agent: refresh(agentId) goes to V5 first with gas = estimate x 1.5 + 150 000 and is waited for, then the borrow", () =>
  onChain({}, async (c) => {
    const r = await sdk(c).borrow(AGENT, 5, 7 * 86400);
    refreshThenBorrow(c);
    assert.equal(r.loanId, 1);
    assert.equal(r.principal, 5_000000n);
    assert.ok(c.asked.includes("v5.rootId"), "V5's root is read from rootId() when the record gives none");
  }));

await check("another root sponsors the agent: no refresh, only the borrow", () =>
  onChain({ sponsor: OTHER_ROOT, delegatedIn: 5_000000n }, async (c) => {
    await sdk(c).borrow(AGENT, 5, 7 * 86400);
    assert.deepEqual(asSent(c), ["pool.borrow"]);
  }));

await check("seatVaultV5AgentId in the record is V5's root: rootId() is not read", () =>
  onChain({ root: 1n }, async (c) => {
    await sdk(c, owner, { ...NO_V5, seatVaultV5: V5, seatVaultV5AgentId: Number(V5_ROOT) }).borrow(AGENT, 5, 7 * 86400);
    refreshThenBorrow(c);
    assert.ok(!c.asked.includes("v5.rootId"), `rootId was read: ${c.asked}`);
  }));

await check("a delegate key V5 has not recorded: refused before anything is sent, naming noteDelegate and the owner's key", () =>
  onChain({}, async (c) => {
    await rejectsWith(sdk(c, delegate).borrow(AGENT, 5, 7 * 86400), "V5_DELEGATE_NOT_NOTED", /noteDelegate\(77\).*owner's key/s);
    assert.deepEqual(c.sent, []);
  }));

await check("a delegate key V5 recorded under 24 h ago: refused before anything is sent, with the time it may borrow", () =>
  onChain({ noted: [delegate.address, BigInt(NOW - 3600)] }, async (c) => {
    const e = await rejectsWith(sdk(c, delegate).borrow(AGENT, 5, 7 * 86400), "V5_DELEGATE_WAITING", /24 h/);
    assert.equal(e.readyAt, NOW - 3600 + 86400);
    assert.match(e.message, new RegExp(new Date((NOW - 3600 + 86400) * 1000).toISOString().replace(/[.]/g, "\\.")));
    assert.deepEqual(c.sent, []);
  }));

await check("a delegate key V5 recorded 24 h ago: refresh from the delegate, then the borrow", () =>
  onChain({ noted: [delegate.address, BigInt(NOW - 86400)] }, async (c) => {
    await sdk(c, delegate).borrow(AGENT, 5, 7 * 86400);
    refreshThenBorrow(c, delegate.address);
  }));

await check("a refresh that would revert (NoPrice): a V5 error that says to wait for V5's keeper, nothing sent, not the pool's InsufficientCapacity", () =>
  onChain({ refreshRevert: "NoPrice" }, async (c) => {
    await rejectsWith(sdk(c).borrow(AGENT, 5, 7 * 86400), "V5_REFRESH_FAILED", /NoPrice.*keeper syncs.*Nothing was borrowed/s);
    assert.deepEqual(c.sent, []);
  }));

await check("a refresh that raises nothing (a stale price): V5_LINE_SHORT after the refresh, and the borrow is never sent", () =>
  onChain({ fresh: false }, async (c) => {
    const e = await rejectsWith(sdk(c).borrow(AGENT, 5, 7 * 86400), "V5_LINE_SHORT", /45 minutes.*keeper syncs/s);
    assert.equal(e.available, 0n);
    assert.deepEqual(asSent(c), ["v5.refresh"]);
  }));

// ---------------------------------------------------------------------------------------------------------------
console.log("float pay() (sdk/float.mjs) and PriorsV2.pay");
const merchant = ethers.Wallet.createRandom().address;
const requirement = { scheme: "exact", network: "robinhood", maxAmountRequired: "10000", payTo: merchant, asset: USDG, maxTimeoutSeconds: 60, resource: "https://m.example/x" };
/** A merchant that asks 0.01 USDG and serves the call once paid. */
const merchantFetch = (body = { x402Version: 1, accepts: [requirement] }) => async (_u, init = {}) =>
  new Headers(init.headers || {}).get("X-PAYMENT") || new Headers(init.headers || {}).get("PAYMENT-SIGNATURE")
    ? new Response("data", { status: 200 })
    : new Response(JSON.stringify(body), { status: 402, headers: { "content-type": "application/json" } });
const payOpts = (c, over = {}) => ({ signer: owner.connect(c.provider), pool: POOL, agentId: AGENT, maxBorrow: 5_000000n, asset: USDG, fetchImpl: merchantFetch(), ...over });

await check("pay() with seatVaultV5, V5's root sponsors the agent: refresh with the margin, then the borrow, then the payment", () =>
  onChain({}, async (c) => {
    const r = await pay("https://m.example/x", payOpts(c, { seatVaultV5: V5 }));
    refreshThenBorrow(c);
    assert.equal(r.borrowed, 1_000000n);
    assert.equal(r.paid, 10000n);
  }));
await check("pay() with seatVaultV5, another root sponsors the agent: no refresh", () =>
  onChain({ sponsor: OTHER_ROOT, delegatedIn: 5_000000n }, async (c) => {
    await pay("https://m.example/x", payOpts(c, { seatVaultV5: V5 }));
    assert.deepEqual(asSent(c), ["pool.borrow"]);
  }));
await check("pay() without seatVaultV5: the borrow only, nothing asked of V5", () =>
  onChain({ delegatedIn: 5_000000n }, async (c) => {
    await pay("https://m.example/x", payOpts(c));
    assert.deepEqual(asSent(c), ["pool.borrow"]);
    noV5Asked(c);
    assert.ok(!c.asked.includes("pool.getAgent"), `getAgent was read: ${c.asked}`);
  }));
await check("PriorsV2.pay() hands the record's seatVaultV5 to pay(): refresh, then the borrow; without it, the borrow only", async () => {
  await onChain({}, async (c) => {
    await sdk(c).pay("https://m.example/x", { agentId: AGENT, maxBorrow: 5_000000n, asset: USDG, fetchImpl: merchantFetch() });
    refreshThenBorrow(c);
  });
  await onChain({ delegatedIn: 5_000000n }, async (c) => {
    await sdk(c, owner, NO_V5).pay("https://m.example/x", { agentId: AGENT, maxBorrow: 5_000000n, asset: USDG, fetchImpl: merchantFetch() });
    assert.deepEqual(asSent(c), ["pool.borrow"]);
    noV5Asked(c);
  });
});
await check("pay() with a delegate key V5 has not recorded: refused, no loan, nothing signed", () =>
  onChain({}, async (c) => {
    let signed = 0;
    const fetchImpl = async (u, init = {}) => { if (new Headers(init.headers || {}).get("X-PAYMENT")) signed++; return merchantFetch()(u, init); };
    await rejectsWith(pay("https://m.example/x", payOpts(c, { signer: delegate.connect(c.provider), seatVaultV5: V5, fetchImpl })), "V5_DELEGATE_NOT_NOTED");
    assert.deepEqual(c.sent, []);
    assert.equal(signed, 0);
  }));

// ---------------------------------------------------------------------------------------------------------------
console.log("@priors/x402 (packages/x402/src/credit.mjs, createPayer) and @priors/mcp's borrow tool");
const gap = (c, over = {}) => credit.borrowGap({ signer: owner.connect(c.provider), pool: POOL, agentId: AGENT, price: 10000n, balance: 0n, maxBorrow: 5_000000n, ...over });

await check("borrowGap: with seatVaultV5 and V5's root, refresh then borrow; another root, no refresh; without seatVaultV5, nothing asked of V5", async () => {
  await onChain({}, async (c) => { const r = await gap(c, { seatVaultV5: V5 }); refreshThenBorrow(c); assert.equal(r.loanId, 1n); });
  await onChain({ sponsor: OTHER_ROOT, delegatedIn: 5_000000n }, async (c) => { await gap(c, { seatVaultV5: V5 }); assert.deepEqual(asSent(c), ["pool.borrow"]); });
  await onChain({ delegatedIn: 5_000000n }, async (c) => { await gap(c); assert.deepEqual(asSent(c), ["pool.borrow"]); noV5Asked(c); });
});
await check("borrowGap: a delegate V5 has not recorded, or under 24 h ago, is refused before anything is sent (PayError)", async () => {
  await onChain({}, async (c) => {
    const e = await rejectsWith(gap(c, { signer: delegate.connect(c.provider), seatVaultV5: V5 }), "V5_DELEGATE_NOT_NOTED");
    assert.equal(e.name, "PayError");
    assert.deepEqual(c.sent, []);
  });
  await onChain({ noted: [delegate.address, BigInt(NOW - 60)] }, async (c) => {
    await rejectsWith(gap(c, { signer: delegate.connect(c.provider), seatVaultV5: V5 }), "V5_DELEGATE_WAITING");
    assert.deepEqual(c.sent, []);
  });
});
await check("createPayer: seatVaultV5 given, refresh then borrow; not given, the borrow only (robinhood names no V5 yet)", async () => {
  const body = { x402Version: 1, accepts: [requirement] };
  await onChain({}, async (c) => {
    const r = await createPayer({ signer: owner.connect(c.provider), pool: POOL, agentId: AGENT, maxBorrow: 5_000000n, asset: USDG, fetchImpl: merchantFetch(body), seatVaultV5: V5 }).pay("https://m.example/x");
    refreshThenBorrow(c);
    assert.equal(r.borrowed, 1_000000n);
  });
  await onChain({ delegatedIn: 5_000000n }, async (c) => {
    await createPayer({ signer: owner.connect(c.provider), pool: POOL, agentId: AGENT, maxBorrow: 5_000000n, asset: USDG, fetchImpl: merchantFetch(body) }).pay("https://m.example/x");
    assert.deepEqual(asSent(c), ["pool.borrow"]);
    noV5Asked(c);
  });
});
await check("borrowLine: creditContracts with seatVaultV5, refresh then borrow; another root, no refresh; without it, the borrow only", async () => {
  const line = (c, addresses) => credit.borrowLine(credit.creditContracts({ runner: c.provider, addresses: { ...NO_V5, ...addresses } }), owner.connect(c.provider), AGENT, 5_000000n, 7n * 86400n);
  await onChain({}, async (c) => { await line(c, { seatVaultV5: V5 }); refreshThenBorrow(c); });
  await onChain({ sponsor: OTHER_ROOT, delegatedIn: 5_000000n }, async (c) => { await line(c, { seatVaultV5: V5 }); assert.deepEqual(asSent(c), ["pool.borrow"]); });
  await onChain({ delegatedIn: 5_000000n }, async (c) => { await line(c, {}); assert.deepEqual(asSent(c), ["pool.borrow"]); noV5Asked(c); });
});

/** @priors/mcp on the stub, with the deployments file it bundles, plus `addresses`. */
async function mcpBorrow(c, addresses) {
  const server = await createPriorsMcpServer({ env: { PRIORS_KEY: owner.privateKey, PRIORS_RPC: c.url, PRIORS_AGENT_ID: String(AGENT), PRIORS_STATE_DIR: "off" }, fetchImpl: async () => new Response("{}", { status: 404 }), deps: { addresses } });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: "test", version: "1" });
  await client.connect(b);
  try {
    const r = await client.callTool({ name: "borrow", arguments: { amount_usd: 5, days: 7 } });
    return { error: !!r.isError, text: r.content.map((x) => x.text).join("\n") };
  } finally { await client.close(); }
}
await check("@priors/mcp borrow: seatVaultV5 in its addresses, refresh then borrow; the bundled deployments file as it is, the borrow only", async () => {
  await onChain({}, async (c) => {
    const r = await mcpBorrow(c, { seatVaultV5: V5 });
    assert.ok(!r.error, r.text);
    assert.match(r.text, /Borrowed 5\.00 USDG for agent #77 as loan #1/);
    refreshThenBorrow(c);
  });
  await onChain({ delegatedIn: 5_000000n }, async (c) => {
    const r = await mcpBorrow(c, {});
    assert.ok(!r.error, r.text);
    assert.deepEqual(asSent(c), ["pool.borrow"]);
    noV5Asked(c);
  });
});
await check("@priors/mcp borrow on a stale V5 price: the V5 error, not InsufficientCapacity", () =>
  onChain({ fresh: false }, async (c) => {
    const r = await mcpBorrow(c, { seatVaultV5: V5 });
    assert.ok(r.error, r.text);
    assert.match(r.text, /V5_LINE_SHORT/);
    assert.doesNotMatch(r.text, /InsufficientCapacity/);
    assert.deepEqual(asSent(c), ["v5.refresh"]);
  }));

// ---------------------------------------------------------------------------------------------------------------
console.log("the two implementations and the deployment records");
await check("sdk/float.mjs and @priors/x402 refreshV5Line agree case by case: the same transactions, gas and error codes", async () => {
  const cases = [
    [{}, owner], [{ sponsor: OTHER_ROOT }, owner], [{ sponsor: 0n }, owner], [{}, delegate],
    [{ noted: [delegate.address, BigInt(NOW - 100)] }, delegate], [{ noted: [delegate.address, BigInt(NOW - 86400)] }, delegate],
    [{ refreshRevert: "BookNotOpen" }, owner], [{ fresh: false }, owner],
  ];
  for (const [over, key] of cases) {
    const runs = [];
    for (const fn of [sdkRefreshV5Line, credit.refreshV5Line]) {
      runs.push(await onChain(over, async (c) => {
        const out = await fn({ signer: key.connect(c.provider), pool: POOL, seatVaultV5: V5, agentId: AGENT, amount: 5_000000n }).then((r) => (r ? "sent" : "nothing"), (e) => e.code);
        return { out, sent: c.sent.map((s) => `${s.to}.${s.fn}@${s.gasLimit}`) };
      }));
    }
    assert.deepEqual(runs[1], runs[0], `case ${JSON.stringify(over, (_k, v) => (typeof v === "bigint" ? String(v) : v))}`);
  }
});
await check("@priors/mcp's bundled deployments file is the repository's, byte for byte, and any seatVaultV5 in it is a checksummed address", () => {
  const root = readFileSync(new URL("../deployments/4663.v2.json", import.meta.url), "utf8");
  const bundled = readFileSync(new URL("../packages/mcp/deployments/4663.v2.json", import.meta.url), "utf8");
  assert.equal(bundled, root);
  if (REC.seatVaultV5 !== undefined) assert.equal(ethers.getAddress(REC.seatVaultV5), REC.seatVaultV5);
});

console.log(failed ? `\ntest-v5-line: ${failed} failed, ${passed} passed` : `\ntest-v5-line: all ${passed} good`);
process.exit(failed ? 1 : 0);
