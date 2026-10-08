#!/usr/bin/env node
// sdk/float.mjs reads a merchant's "pending" (the settlement was broadcast, not confirmed: send the same payment again)
// in every form x402 gives it, as @priors/x402's payer does (GHSA-wvxm): a 402 whose PAYMENT-RESPONSE or
// X-PAYMENT-RESPONSE header carries errorReason "settlement_pending" (what @x402/core's server writes, body {}), and a
// body with errorReason "settlement_pending", besides the legacy {pending: true}. Network-free: a stub signer and fetch.
//   node scripts/test-float-pending.mjs
// PRIORS_FLOAT=/path/to/float.mjs runs it against another copy (before/after a fix).
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resend as x402Resend } from "../packages/x402/src/payer.mjs";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const { pay, resend } = await import(pathToFileURL(process.env.PRIORS_FLOAT || join(ROOT, "sdk/float.mjs")).href);

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log("  ok  ", name); } catch (e) { failed++; console.log("  FAIL", name, "\n       ", e?.stack?.split("\n").slice(0, 4).join("\n        ") || e); }
}

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const PAY_TO = "0x1111111111111111111111111111111111111111";
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64");
const settle = (errorReason) => b64({ success: false, errorReason, transaction: "0x" + "ab".repeat(32), network: "eip155:4663" });
const json402 = (body, headers = {}) => () => new Response(body === undefined ? null : JSON.stringify(body), { status: 402, headers: { "content-type": "application/json", ...headers } });
const first402 = json402({ x402Version: 1, accepts: [{ scheme: "exact", network: "robinhood", asset: USDG, maxAmountRequired: "100000", payTo: PAY_TO, maxTimeoutSeconds: 600 }] });
const stubProvider = { async call() { return "0x" + (1000000n).toString(16).padStart(64, "0"); }, async getNetwork() { return { chainId: 4663n, name: "robinhood" }; } };
const signer = { provider: stubProvider, async getAddress() { return "0x2222222222222222222222222222222222222222"; }, async signTypedData() { return "0x" + "11".repeat(65); } };

/** pay() against a merchant that answers `answer` to the signed payment `pendingFor` times, then 200. */
async function payThrough(answer, pendingFor) {
  const signed = [];
  const fetchImpl = async (url, init) => {
    const h = new Headers(init?.headers || {}).get("X-PAYMENT");
    if (!h) return first402();
    signed.push(h);
    return signed.length <= pendingFor ? answer() : new Response("ok", { status: 200 });
  };
  const r = await pay("https://merchant.example/resource", { signer, maxPrice: 1_000_000n, fetchImpl, sleep: async () => {} });
  return { r, signed };
}

const PENDING = {
  "a PAYMENT-RESPONSE header with errorReason settlement_pending (body {})": json402({}, { "PAYMENT-RESPONSE": settle("settlement_pending") }),
  "an X-PAYMENT-RESPONSE header with errorReason settlement_pending (no body)": json402(undefined, { "X-PAYMENT-RESPONSE": settle("settlement_pending") }),
  "a body with errorReason settlement_pending": json402({ errorReason: "settlement_pending" }),
  "a body {pending: true} (as before)": json402({ pending: true }),
};

console.log("sdk/float.mjs: a pending settlement in every x402 form (GHSA-wvxm)");

for (const [name, answer] of Object.entries(PENDING)) {
  await test(`pay(): ${name} is pending: the same payment is sent again until it settles`, async () => {
    const { r, signed } = await payThrough(answer, 2);
    assert.equal(new Set(signed).size, 1, "one signature");
    assert.equal(signed.length, 3, `the same payment sent again while pending (sent ${signed.length} times)`);
    assert.equal(r.paid, 100_000n, `paid once it settled (status ${r.response.status}, pending ${r.pending})`);
  });
  await test(`pay(): ${name}, still pending after the resends: pending: true, with the header for resend()`, async () => {
    const { r, signed } = await payThrough(answer, 99);
    assert.equal(new Set(signed).size, 1, "one signature");
    assert.equal(r.paid, 0n);
    assert.equal(r.pending, true, `pending reported (status ${r.response.status})`);
    assert.equal(r.paymentHeader, signed[0]);
  });
}

await test("pay(): a 402 that is not pending (another errorReason, or none) is not read as pending; the header is still returned", async () => {
  for (const answer of [json402({}, { "PAYMENT-RESPONSE": settle("insufficient_funds") }), json402({ error: "payment required" })]) {
    const { r, signed } = await payThrough(answer, 99);
    assert.equal(signed.length, 1, "sent once");
    assert.equal(r.pending, false);
    assert.equal(r.paymentHeader, signed[0], "F4: the signed header comes back on every result");
  }
});

await test("resend(): sdk/float.mjs and @priors/x402 agree, case by case, on what is pending", async () => {
  const cases = {
    ...PENDING,
    "a header with another errorReason": json402({}, { "PAYMENT-RESPONSE": settle("insufficient_funds") }),
    "a header that is not base64 JSON": json402({}, { "PAYMENT-RESPONSE": "%%%not-base64%%%" }),
    "a plain 402": json402({ error: "payment required" }),
    "a 200 with a settlement_pending header": () => new Response("ok", { status: 200, headers: { "PAYMENT-RESPONSE": settle("settlement_pending") } }),
    "a 500": () => new Response("boom", { status: 500 }),
  };
  for (const [name, answer] of Object.entries(cases)) {
    let nf = 0, nx = 0;
    const f = await resend("https://merchant.example/resource", "aGVhZGVy", { fetchImpl: async () => { nf++; return answer(); }, sleep: async () => {}, retries: 3 });
    const x = await x402Resend("https://merchant.example/resource", { "X-PAYMENT": "aGVhZGVy" }, { fetchImpl: async () => { nx++; return answer(); }, sleep: async () => {}, retries: 3 });
    assert.equal(f.pending, x.pending, `${name}: float pending=${f.pending}, @priors/x402 pending=${x.pending}`);
    assert.equal(nf, nx, `${name}: float sent ${nf} times, @priors/x402 ${nx}`);
  }
});

console.log(`\nfloat pending: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
