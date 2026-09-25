// SDK v2 and x402 float, network-free: the deployment record, amounts, the CLI's refusals, and every pay() guard
// that must hold before anything is signed or borrowed. A local in-process JSON-RPC stub answers the two reads pay()
// makes (chainId, USDG balanceOf); nothing reaches a real chain and no transaction is ever built.
//
//   node scripts/test-sdk-v2.mjs
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { ethers } from "ethers";
import { PriorsV2, toUnits, fmtUsdg, extendPriorsV2 } from "../sdk/priors-v2.mjs";
import { pay, resend, signPayment, pickRequirement, FloatError, DEFAULT_MAX_PRICE } from "../sdk/float.mjs";
import { USDG_MAINNET, TRANSFER_WITH_AUTHORIZATION_TYPES, domainFor, decodePaymentHeader, FACILITATOR_URL } from "../sdk/x402.mjs";
import { readDeploymentV2, readDeployment } from "../sdk/env.mjs";

let passed = 0, failed = 0;
async function check(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failed++;
    console.log(`  FAIL ${name}\n       ${String(e && e.message || e).split("\n").join("\n       ")}`);
  }
}

console.log("deployment records");
await check("the v2 record is live on 4663 and names every contract the SDK and CLI need, checksummed", () => {
  const d = readDeploymentV2(4663);
  assert.ok(d, "deployments/4663.v2.json is missing");
  assert.equal(d.chainId, 4663);
  assert.equal(d.status, "live");
  for (const k of ["pool", "lens", "timelock", "treasuryV4", "seatVault", "seatVaultV2", "inviteBond", "usdg", "registry", "priors", "safe", "v1Pool"]) {
    assert.ok(ethers.isAddress(d[k]), `${k} is not an address`);
    assert.equal(ethers.getAddress(d[k]), d[k], `${k} is not checksummed`);
  }
  assert.equal(d.pool, "0x281210097f0de7A8FB6F87310AF0f089c9C8DE21");
  assert.equal(d.usdg, USDG_MAINNET);
  assert.equal(d.treasuryV4AgentId, 6228);
  // the seat vault is SeatVaultV3 since 2026-09-25 (audit V-2); V2 stays in the record, retired
  assert.equal(d.seatVault, "0x59D155C42A9263fA7596867b992bB3e84dF680a9");
  assert.equal(d.seatVaultAgentId, 6234);
  assert.equal(d.seatVaultV2, "0x6D934C07a33E7285cE691A9B258cdB53F18e6B5F");
  assert.equal(d.seatVaultV2AgentId, 6229);
});
await check("the v1 record is kept for history, marked paused, and points at the v2 record", () => {
  const v1 = readDeployment(4663);
  const v2 = readDeploymentV2(4663);
  assert.equal(v1.status, "paused");
  assert.equal(v1.supersededBy, "4663.v2.json");
  assert.equal(v1.creditPool, v2.v1Pool, "the v2 record's v1Pool is not the pool the v1 record names");
});
await check("a record for a chain with no v2 deployment is null, not a guess", () => {
  assert.equal(readDeploymentV2(31337), null);
});

console.log("amounts");
await check("toUnits: whole USDG as number or string, raw units as bigint, exact to 6 decimals", () => {
  assert.equal(toUnits(5), 5_000000n);
  assert.equal(toUnits("12.5"), 12_500000n);
  assert.equal(toUnits("0.000001"), 1n);
  assert.equal(toUnits(7n), 7n);
  assert.equal(fmtUsdg(11666n), "0.011666");
});
await check("toUnits refuses what is not an amount rather than rounding it", () => {
  for (const bad of ["-1", "1.0000001", "abc", "", -5, NaN]) assert.throws(() => toUnits(bad), /not an amount/, `accepted ${bad}`);
});

console.log("client");
await check("PriorsV2 needs a pool and a provider, and refuses writes without a signer", async () => {
  assert.throws(() => new PriorsV2({ addresses: {} }), /addresses.pool is required/);
  assert.throws(() => new PriorsV2({ addresses: { pool: USDG_MAINNET } }), /signer connected to a provider/);
  const p = new PriorsV2({ provider: new ethers.JsonRpcProvider("http://127.0.0.1:1", 4663, { staticNetwork: true }), addresses: readDeploymentV2(4663) });
  await assert.rejects(() => p.deposit(5), /needs a signer/);
  assert.throws(() => p.pay("https://example.invalid"), /needs a signer/);
});
await check("extendPriorsV2 refuses to overwrite a method, so float's pay() cannot be replaced silently", () => {
  assert.throws(() => extendPriorsV2({ pay() {} }), /already exists/);
  assert.throws(() => extendPriorsV2({ borrow() {} }), /already exists/);
});

console.log("x402 float");
const wallet = ethers.Wallet.createRandom();
const merchant = ethers.Wallet.createRandom().address;
const requirement = (over = {}) => ({ scheme: "exact", network: "robinhood", maxAmountRequired: "10000", payTo: merchant, asset: USDG_MAINNET, maxTimeoutSeconds: 60, resource: "https://m.example/x", ...over });
const json402 = (body) => new Response(JSON.stringify(body), { status: 402, headers: { "content-type": "application/json" } });

await check("pickRequirement takes only exact USDG on Robinhood Chain", () => {
  assert.equal(pickRequirement({ accepts: [requirement({ network: "base" }), requirement({ asset: ethers.ZeroAddress })] }), null);
  assert.equal(pickRequirement({ accepts: [requirement({ scheme: "upto" }), requirement()] }).scheme, "exact");
  assert.ok(pickRequirement({ accepts: [requirement({ network: "eip155:4663" })] }));
});
await check("signPayment signs EIP-3009 on USDG's Global Dollar domain, recoverable to the payer", async () => {
  const now = 1_800_000_000;
  const header = await signPayment(wallet, requirement(), { now });
  const p = decodePaymentHeader(header);
  assert.equal(p.x402Version, 1);
  assert.equal(p.scheme, "exact");
  const a = p.payload.authorization;
  assert.equal(a.from, wallet.address);
  assert.equal(a.to, merchant);
  assert.equal(a.value, "10000");
  const who = ethers.verifyTypedData(domainFor(USDG_MAINNET), TRANSFER_WITH_AUTHORIZATION_TYPES, a, p.payload.signature);
  assert.equal(who, wallet.address);
  assert.equal(Number(a.validBefore), now + 60, "window should be the merchant's 60 s");
});
await check("an authorization never outlives 600 s, whatever the merchant or the caller asks", async () => {
  const now = 1_800_000_000;
  for (const [req, opt] of [[requirement({ maxTimeoutSeconds: 86400 }), {}], [requirement({ maxTimeoutSeconds: 86400 }), { maxValiditySeconds: 99999 }]]) {
    const a = decodePaymentHeader(await signPayment(wallet, req, { now, ...opt })).payload.authorization;
    assert.equal(Number(a.validBefore), now + 600);
  }
});
await check("a non-402 answer is returned as-is, with nothing signed or borrowed", async () => {
  const r = await pay("https://m.example/free", { signer: wallet, fetchImpl: async () => new Response("hi", { status: 200 }) });
  assert.equal(r.response.status, 200);
  assert.equal(r.paid, 0n);
  assert.equal(r.borrowed, 0n);
});
await check("a price above maxPrice is refused before anything is signed or read", async () => {
  let calls = 0;
  const fetchImpl = async () => { calls++; return json402({ accepts: [requirement({ maxAmountRequired: String(DEFAULT_MAX_PRICE + 1n) })] }); };
  await assert.rejects(() => pay("https://m.example/x", { signer: wallet, fetchImpl, asset: USDG_MAINNET }), (e) => e instanceof FloatError && e.code === "PRICE_ABOVE_MAX_PRICE");
  assert.equal(calls, 1, "it retried with a payment");
});
await check("a 402 that does not accept USDG on Robinhood Chain is refused", async () => {
  const fetchImpl = async () => json402({ accepts: [requirement({ network: "base" })] });
  await assert.rejects(() => pay("https://m.example/x", { signer: wallet, fetchImpl, asset: USDG_MAINNET }), (e) => e.code === "NO_USDG_REQUIREMENT");
});
await check("resend() repeats the SAME X-PAYMENT while the merchant answers pending, and never signs a new one", async () => {
  const seen = [];
  let n = 0;
  const fetchImpl = async (_u, init) => {
    seen.push(new Headers(init.headers).get("X-PAYMENT"));
    return ++n < 3 ? json402({ pending: true }) : new Response("ok", { status: 200 });
  };
  const r = await resend("https://m.example/x", "HEADER", { fetchImpl, sleep: async () => {} });
  assert.equal(r.response.status, 200);
  assert.equal(r.pending, false);
  assert.deepEqual(seen, ["HEADER", "HEADER", "HEADER"]);
});
await check("still pending after the retries: handed back as pending with the header, for a later resend", async () => {
  const fetchImpl = async () => json402({ pending: true });
  const r = await resend("https://m.example/x", "HEADER", { fetchImpl, retries: 2, sleep: async () => {} });
  assert.equal(r.pending, true);
  assert.equal(r.paymentHeader, "HEADER");
});

/* A two-method JSON-RPC stub: enough for pay() to read the payer's USDG balance, nothing more. Any other method
   (a send, a gas estimate) fails the test, which is how "short of USDG and maxBorrow 0 opens no loan" is proven. */
function stub(balance) {
  const methods = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const reqs = [].concat(JSON.parse(body));
      const out = reqs.map((r) => {
        methods.push(r.method);
        if (r.method === "eth_chainId") return { jsonrpc: "2.0", id: r.id, result: "0x1237" };
        if (r.method === "eth_call") return { jsonrpc: "2.0", id: r.id, result: ethers.toBeHex(balance, 32) };
        return { jsonrpc: "2.0", id: r.id, error: { code: -32601, message: `unexpected ${r.method}` } };
      });
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(Array.isArray(JSON.parse(body)) ? out : out[0]));
    });
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok({ server, methods, url: `http://127.0.0.1:${server.address().port}` })));
}

await check("funded agent: pays from its balance, one signed header, no loan", async () => {
  const s = await stub(1_000000n);
  try {
    const signer = wallet.connect(new ethers.JsonRpcProvider(s.url, 4663, { staticNetwork: true }));
    let paidWith = null;
    const fetchImpl = async (_u, init = {}) => {
      const h = new Headers(init.headers || {}).get("X-PAYMENT");
      if (!h) return json402({ accepts: [requirement()] });
      paidWith = decodePaymentHeader(h);
      return new Response("data", { status: 200 });
    };
    const r = await pay("https://m.example/x", { signer, fetchImpl, asset: USDG_MAINNET });
    assert.equal(r.response.status, 200);
    assert.equal(r.paid, 10000n);
    assert.equal(r.borrowed, 0n);
    assert.equal(r.loanId, null);
    assert.equal(paidWith.payload.authorization.to, merchant);
    assert.ok(!s.methods.some((m) => /send|estimate/i.test(m)), `unexpected methods: ${s.methods}`);
  } finally {
    s.server.close();
  }
});
await check("short of USDG with maxBorrow 0: refused before any transaction, no loan opened", async () => {
  const s = await stub(0n);
  try {
    const signer = wallet.connect(new ethers.JsonRpcProvider(s.url, 4663, { staticNetwork: true }));
    const fetchImpl = async () => json402({ accepts: [requirement()] });
    await assert.rejects(() => pay("https://m.example/x", { signer, fetchImpl, asset: USDG_MAINNET, pool: readDeploymentV2(4663).pool, agentId: 1, maxBorrow: 0n }), (e) => e.code === "PRICE_ABOVE_MAX_BORROW");
    assert.ok(!s.methods.some((m) => /send|estimate/i.test(m)), `unexpected methods: ${s.methods}`);
  } finally {
    s.server.close();
  }
});
await check("the facilitator URL the docs name is the one the SDK exports", () => {
  assert.equal(FACILITATOR_URL, "https://facilitator.priors.trade");
});

console.log("priors-v2 CLI");
const cli = (args, env = {}) => spawnSync(process.execPath, ["bin/priors-v2.mjs", ...args], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env }, timeout: 30_000 });
await check("a private key on the command line is refused, and not echoed back", () => {
  const key = ethers.Wallet.createRandom().privateKey;
  const r = cli(["status", key]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /private key was passed on the command line/);
  assert.ok(!(r.stdout + r.stderr).includes(key.slice(2)), "the key was printed");
});
await check("no key configured: a usage error, before any network call", () => {
  // Empty, not absent: a maintainer's own .env must not fill them in (env.mjs never overrides a set variable).
  const r = cli(["status"], { RPC_URL: "http://127.0.0.1:1", PRIORS_KEY: "", PRIVATE_KEY: "" });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /PRIORS_KEY is not set/);
});
await check("an unknown command is a usage error", () => {
  const r = cli(["frobnicate"]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /unknown command/);
});
await check("the v2 CLI is declared as a package bin, next to the v1 one", () => {
  const pkg = JSON.parse(readFileSync("package.json", "utf8"));
  assert.equal(pkg.bin["priors-v2"], "bin/priors-v2.mjs");
  assert.equal(pkg.bin.priors, "bin/priors.mjs");
});

console.log(failed ? `\ntest-sdk-v2: ${failed} failed, ${passed} passed` : `\ntest-sdk-v2: all ${passed} good`);
process.exit(failed ? 1 : 0);
