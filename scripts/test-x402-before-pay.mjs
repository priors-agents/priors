#!/usr/bin/env node
// createPayer's `beforePay`, network-free: a mock merchant answers 402 with a USDG requirement on Robinhood Chain. What
// is pinned:
//   - beforePay sees the picked requirement (payTo, price, network, asset, resource, payer) after maxPrice, and a throw
//     refuses before anything is read or signed (the signer has no provider: a payment that went on would stop at
//     NO_PROVIDER, the first read; one refused stops before it);
//   - a PayError from beforePay is passed on as thrown; another error is BEFORE_PAY_REFUSED with it as `cause`;
//   - a 402 above maxPrice never reaches beforePay; null and undefined are off; anything else not a function is
//     BAD_BEFORE_PAY;
//   - the requirement it is shown is a frozen deep copy (extra included), and it is given the caller's abort (`signal`);
//   - a hook that tries to write payTo or the amount changes nothing that is signed nor the result's `paid` (a mock
//     chain on 127.0.0.1 answers the balance read, so the payment is signed and sent: v2 and v1).
//   node scripts/test-x402-before-pay.mjs
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { ethers } from "ethers";
import { createPayer, robinhood } from "../packages/x402/index.mjs";
import { PayError } from "../packages/x402/src/credit.mjs";

let passed = 0, failed = 0;
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

const URL_BOUGHT = "https://seller.example/api/report";
const PAY_TO = "0x1111111111111111111111111111111111111111";
const THIEF = "0x9999999999999999999999999999999999999999";
const REQ = { scheme: "exact", network: "eip155:4663", asset: ethers.getAddress(robinhood.usdg), amount: "50000", payTo: PAY_TO, maxTimeoutSeconds: 300 };
/** a merchant that answers 402 (v2, in the body) to everything */
const merchant = (req = REQ) => async () => new Response(JSON.stringify({ x402Version: 2, resource: { url: URL_BOUGHT }, accepts: [req] }), { status: 402, headers: { "content-type": "application/json" } });
const signer = ethers.Wallet.createRandom(); // no provider: the first read after beforePay is NO_PROVIDER

console.log("createPayer beforePay");
await check("sees the picked requirement and the payer's reading of it; returning lets the payment go on", async () => {
  const seen = [];
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: (p) => { seen.push(p); } });
  await rejects(payer.pay(URL_BOUGHT), "NO_PROVIDER");
  assert.equal(seen.length, 1);
  assert.deepEqual(seen[0].requirement, REQ);
  assert.equal(seen[0].x402Version, 2);
  assert.equal(seen[0].resource, URL_BOUGHT);
  assert.equal(seen[0].price, 50000n);
  assert.equal(seen[0].payTo, PAY_TO);
  assert.equal(seen[0].network, "eip155:4663");
  assert.equal(seen[0].asset, ethers.getAddress(robinhood.usdg));
  assert.equal(seen[0].payer, signer.address);
});
await check("a throw refuses before anything is read: BEFORE_PAY_REFUSED with the caller's words and the error as cause", async () => {
  const boom = new Error("not on my allowlist");
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: () => { throw boom; } });
  const e = await rejects(payer.pay(URL_BOUGHT), "BEFORE_PAY_REFUSED");
  assert.match(e.message, /nothing was read, borrowed or signed \(not on my allowlist\)/);
  assert.equal(e.cause, boom);
});
await check("a PayError is passed on as thrown", async () => {
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: async () => { throw new PayError("MY_CODE", "mine"); } });
  const e = await rejects(payer.pay(URL_BOUGHT), "MY_CODE");
  assert.equal(e.message, "mine");
});
await check("a 402 above maxPrice is refused first: beforePay is never called", async () => {
  let called = 0;
  const payer = createPayer({ signer, maxPrice: 10000n, fetchImpl: merchant(), beforePay: () => { called++; } });
  await rejects(payer.pay(URL_BOUGHT), "PRICE_ABOVE_MAX_PRICE");
  assert.equal(called, 0);
});
await check("beforePay that is not a function is refused at createPayer; null and undefined are off", async () => {
  assert.throws(() => createPayer({ signer, fetchImpl: merchant(), beforePay: "yes" }), (e) => e.code === "BAD_BEFORE_PAY");
  assert.throws(() => createPayer({ signer, fetchImpl: merchant(), beforePay: false }), (e) => e.code === "BAD_BEFORE_PAY");
  for (const off of [null, undefined]) await rejects(createPayer({ signer, fetchImpl: merchant(), beforePay: off }).pay(URL_BOUGHT), "NO_PROVIDER");
});
await check("the requirement it is shown is a frozen deep copy, extra included, and it is given the caller's abort", async () => {
  const withExtra = { ...REQ, extra: { name: "Global Dollar", version: "1", deep: { n: 1 } } };
  const seen = [];
  const ac = new AbortController();
  const payer = createPayer({ signer, fetchImpl: merchant(withExtra), beforePay: (p) => { seen.push(p); } });
  await rejects(payer.pay(URL_BOUGHT, { signal: ac.signal }), "NO_PROVIDER");
  const r = seen[0].requirement;
  assert.ok(Object.isFrozen(seen[0]) && Object.isFrozen(r) && Object.isFrozen(r.extra) && Object.isFrozen(r.extra.deep));
  assert.throws(() => { r.payTo = THIEF; }, TypeError); // an ES module is strict: a write to a frozen object throws
  assert.ok(seen[0].signal instanceof AbortSignal && !seen[0].signal.aborted);
  ac.abort();
  assert.ok(seen[0].signal.aborted, "the hook's signal follows the caller's init.signal");
});

console.log("what is signed");
/**
 * Robinhood Chain on 127.0.0.1: the chain id, and every eth_call answered with a large uint256 (the payer's USDG balance
 * read). Enough for a payment that needs no loan to be signed and sent.
 */
async function chain() {
  const srv = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      const p = JSON.parse(raw);
      const one = (q) => ({ jsonrpc: "2.0", id: q.id, ...(q.method === "eth_chainId" ? { result: "0x1237" }
        : q.method === "eth_blockNumber" ? { result: "0x100" }
        : q.method === "eth_call" ? { result: ethers.toBeHex(10n ** 12n, 32) }
        : { error: { code: -32601, message: `no ${q.method}` } }) });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(Array.isArray(p) ? p.map(one) : one(p)));
    });
  });
  await new Promise((ok) => srv.listen(0, "127.0.0.1", ok));
  const provider = new ethers.JsonRpcProvider(`http://127.0.0.1:${srv.address().port}`, ethers.Network.from(4663), { staticNetwork: true, batchMaxCount: 1 });
  return { provider, close: () => new Promise((ok) => { provider.destroy(); srv.closeAllConnections?.(); srv.close(ok); }) };
}
/** a merchant that answers 402 until it is sent a payment, then 200; it keeps each decoded payment it was sent */
function paidMerchant(version) {
  const got = [];
  const extra = { name: "Global Dollar", version: "1" };
  const v1 = { scheme: "exact", network: robinhood.network, asset: REQ.asset, maxAmountRequired: REQ.amount, payTo: PAY_TO, resource: URL_BOUGHT, description: "", mimeType: "application/json", maxTimeoutSeconds: 300, extra };
  const f = async (input, init) => {
    const h = new Headers(input instanceof Request ? input.headers : init?.headers);
    if (init?.headers) for (const [k, v] of new Headers(init.headers)) h.set(k, v);
    const sent = h.get("payment-signature") ?? h.get("x-payment");
    if (sent) { got.push(JSON.parse(Buffer.from(sent, "base64").toString("utf8"))); return new Response("{}", { status: 200 }); }
    const body = version === 2 ? { x402Version: 2, resource: { url: URL_BOUGHT }, accepts: [{ ...REQ, extra }] } : { x402Version: 1, accepts: [v1] };
    return new Response(JSON.stringify(body), { status: 402, headers: { "content-type": "application/json" } });
  };
  return { f, got };
}
for (const version of [2, 1]) {
  await check(`v${version}: a hook that tries to write payTo or the amount changes nothing signed, nor what the result says was paid`, async () => {
    const c = await chain();
    try {
      const m = paidMerchant(version);
      const wrote = [];
      const payer = createPayer({ signer: signer.connect(c.provider), fetchImpl: m.f, beforePay: (p) => {
        for (const [k, v] of [["payTo", THIEF], ["amount", "90000000"], ["maxAmountRequired", "90000000"]]) {
          try { p.requirement[k] = v; wrote.push(k); } catch (_) { /* frozen */ }
        }
        try { p.requirement.extra.name = "EVIL"; wrote.push("extra"); } catch (_) { /* frozen */ }
        const mine = structuredClone(p.requirement); // the hook's own unfrozen copy: writing it reaches nothing
        mine.payTo = THIEF;
        mine.amount = mine.maxAmountRequired = "90000000";
      } });
      const r = await payer.pay(URL_BOUGHT);
      assert.equal(r.response.status, 200);
      assert.deepEqual(wrote, [], "every write to the requirement it was shown throws");
      assert.equal(m.got.length, 1);
      const auth = m.got[0].payload.authorization;
      assert.equal(ethers.getAddress(auth.to), ethers.getAddress(PAY_TO));
      assert.equal(BigInt(auth.value), 50000n);
      assert.equal(r.paid, 50000n);
    } finally { await c.close(); }
  });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
