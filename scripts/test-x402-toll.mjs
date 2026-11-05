#!/usr/bin/env node
// createPayer's `beforePay` and "@priors/x402/toll"'s tollCheck, network-free: a mock merchant answers 402 with a USDG
// requirement on Robinhood Chain, a mock Toll answers the check. What is pinned:
//   - beforePay sees the picked requirement (payTo, price, network, asset, resource, payer) after maxPrice, and a throw
//     refuses before anything is read or signed (the signer has no provider: a payment that went on would stop at
//     NO_PROVIDER, the first read; one refused stops before it);
//   - a PayError from beforePay is passed on as thrown; another error is BEFORE_PAY_REFUSED with it as `cause`;
//   - a 402 above maxPrice never reaches beforePay;
//   - tollCheck refuses BLOCK (TOLL_REFUSED, Toll's codes and link, never merchant text), passes ALLOW and WARN, refuses
//     WARN with refuse: ["BLOCK", "WARN"], fails closed on an answer it cannot read (TOLL_UNREAD) and open with
//     failOpen, and sends Toll only the requirement, the URL and the agentId it was given.
//   node scripts/test-x402-toll.mjs
import assert from "node:assert/strict";
import { ethers } from "ethers";
import { createPayer, robinhood } from "../packages/x402/index.mjs";
import { tollCheck, TOLL_CHECK_URL } from "../packages/x402/src/toll.mjs";
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
const REQ = { scheme: "exact", network: "eip155:4663", asset: ethers.getAddress(robinhood.usdg), amount: "50000", payTo: PAY_TO, maxTimeoutSeconds: 300 };
/** a merchant that answers 402 (v2, in the body) to everything */
const merchant = (req = REQ) => async () => new Response(JSON.stringify({ x402Version: 2, resource: { url: URL_BOUGHT }, accepts: [req] }), { status: 402, headers: { "content-type": "application/json" } });
const signer = ethers.Wallet.createRandom(); // no provider: the first read after beforePay is NO_PROVIDER
/** a Toll that answers `answer` and records what it was sent */
function toll(answer, status = 200) {
  const sent = [];
  const f = async (url, init) => { sent.push({ url, body: JSON.parse(init.body) }); return new Response(typeof answer === "string" ? answer : JSON.stringify(answer), { status }); };
  return { f, sent };
}
const BLOCK = { action: "BLOCK", warnings: [{ code: "x402-payee-mismatch", severity: "critical", message: "payTo 0x… is not the seller's wallet" }], "x-toll": { link: "https://t0ll.xyz/agents/census/20030" } };

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
await check("beforePay that is not a function is refused at createPayer", async () => {
  assert.throws(() => createPayer({ signer, fetchImpl: merchant(), beforePay: "yes" }), (e) => e.code === "BAD_BEFORE_PAY");
});

console.log("tollCheck");
await check("BLOCK refuses: TOLL_REFUSED with Toll's codes and link, never the warning's message text", async () => {
  const t = toll(BLOCK);
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: t.f }) });
  const e = await rejects(payer.pay(URL_BOUGHT), "TOLL_REFUSED");
  assert.equal(e.action, "BLOCK");
  assert.deepEqual(e.codes, ["x402-payee-mismatch"]);
  assert.equal(e.link, "https://t0ll.xyz/agents/census/20030");
  assert.doesNotMatch(e.message, /seller's wallet/);
  assert.equal(t.sent[0].url, TOLL_CHECK_URL);
  assert.deepEqual(t.sent[0].body, { x402: { x402Version: 2, resource: { url: URL_BOUGHT }, accepts: [REQ] } });
});
await check("ALLOW and WARN let the payment go on (to NO_PROVIDER here); onResult sees each answer", async () => {
  for (const action of ["ALLOW", "WARN"]) {
    const t = toll({ action, warnings: action === "WARN" ? [{ code: "x402-seller-unknown", severity: "low" }] : [] });
    const seen = [];
    const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: t.f, onResult: (r) => { seen.push(r); } }) });
    await rejects(payer.pay(URL_BOUGHT), "NO_PROVIDER");
    assert.equal(seen[0].action, action);
  }
});
await check("refuse: [BLOCK, WARN] refuses WARN; agentId is sent beside the requirement", async () => {
  const t = toll({ action: "WARN", warnings: [{ code: "x402-seller-unknown", severity: "low" }] });
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: t.f, refuse: ["BLOCK", "WARN"], agentId: 20030 }) });
  const e = await rejects(payer.pay(URL_BOUGHT), "TOLL_REFUSED");
  assert.deepEqual(e.codes, ["x402-seller-unknown"]);
  assert.equal(t.sent[0].body.agentId, 20030);
});
await check("an answer it cannot read fails closed (TOLL_UNREAD), or open with failOpen", async () => {
  for (const [answer, status] of [["oops", 200], [{ error: "x" }, 503], [{ nothing: true }, 200]]) {
    const closed = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: toll(answer, status).f }) });
    await rejects(closed.pay(URL_BOUGHT), "TOLL_UNREAD");
    const open = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: toll(answer, status).f, failOpen: true }) });
    await rejects(open.pay(URL_BOUGHT), "NO_PROVIDER");
  }
});
await check("a Toll that does not answer in timeoutMs is TOLL_UNREAD", async () => {
  const hang = (_u, init) => new Promise((_, no) => init.signal.addEventListener("abort", () => no(Object.assign(new Error("aborted"), { name: "AbortError" }))));
  const payer = createPayer({ signer, fetchImpl: merchant(), beforePay: tollCheck({ fetchImpl: hang, timeoutMs: 50 }) });
  const e = await rejects(payer.pay(URL_BOUGHT), "TOLL_UNREAD");
  assert.match(e.message, /no answer in 0\.05 s/);
});
await check("bad options are refused when the check is made", async () => {
  assert.throws(() => tollCheck({ refuse: ["ALLOW"] }), (e) => e.code === "BAD_TOLL_OPTION");
  assert.throws(() => tollCheck({ agentId: -1 }), (e) => e.code === "BAD_TOLL_OPTION");
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
