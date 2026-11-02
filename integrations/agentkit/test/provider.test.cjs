// The provider against the published @coinbase/agentkit, with a fake wallet: what it signs, what it refuses, and the
// actions AgentKit sees. @x402/fetch is replaced in the require cache, and AgentKit's own analytics call is answered
// locally, so nothing leaves the machine.
const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeFunctionData, encodeEventTopics, encodeAbiParameters, erc20Abi } = require("viem");

const paid = [];
const paidInits = [];
require.cache[require.resolve("@x402/fetch")] = {
  exports: {
    x402Client: class {
      register() { return this; }
      registerPolicy() { return this; }
    },
    wrapFetchWithPayment: () => async (url, init) => { paid.push(url); paidInits.push(init); return new Response("the data", { status: 200 }); },
  },
};
globalThis.fetch = async () => new Response(null, { status: 204 }); // AgentKit's analytics endpoint

const { priorsActionProvider, PRIORS_POOL, USDG } = require("../dist/index.js");
const { POOL_ABI } = require("../dist/constants.js");

const ME = "0x1234567890123456789012345678901234543210";
const PAY_TO = "0x86727111a44084cc7a7c1c5d8ac4b0eca4d7db66";
const URL_ = "https://seller.example/check";

function wallet(reads) {
  const sent = [];
  return {
    sent,
    getName: () => "fake",
    getAddress: () => ME,
    getNetwork: () => ({ protocolFamily: "evm", chainId: "4663" }),
    toSigner: () => ({ address: ME }),
    readContract: async ({ functionName }) => reads[functionName],
    sendTransaction: async (tx) => { sent.push(tx); return `0x${String(sent.length).padStart(64, "0")}`; },
    waitForTransactionReceipt: async () => ({
      logs: [{
        address: PRIORS_POOL,
        topics: encodeEventTopics({ abi: POOL_ABI, eventName: "Borrowed", args: { loanId: 50900n, agentId: 437n, sponsorId: 8646n } }),
        data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint64" }, { type: "address" }], [5000000n, 11666n, 1794000000n, ME]),
      }],
    }),
  };
}
const ask402 = (amount) => async () => new Response("{}", {
  status: 402,
  headers: { "payment-required": Buffer.from(JSON.stringify({ x402Version: 2, accepts: [{ scheme: "exact", network: "eip155:4663", asset: USDG, amount, payTo: PAY_TO }] })).toString("base64") },
});

test("AgentKit sees the five actions under the provider's name", () => {
  const names = priorsActionProvider().getActions(wallet({})).map((a) => a.name).sort();
  assert.deepEqual(names, ["PriorsActionProvider_borrow_from_priors", "PriorsActionProvider_get_priors_agent_record", "PriorsActionProvider_get_priors_credit_line", "PriorsActionProvider_pay_x402_with_priors_credit", "PriorsActionProvider_repay_priors_loan"]);
});

test("the credit line is read from the public hub API, its amounts atomic USDG", async () => {
  const asked = [];
  const fetchImpl = async (url) => { asked.push(url); return Response.json({ agent: { line: { limit: 5000000, drawn: 1000000, available: 4000000 }, activeLoans: 1 } }); };
  const out = await priorsActionProvider(fetchImpl).getCreditLine(wallet({}), { agentId: 437 });
  assert.deepEqual(asked, ["https://priors.trade/api/hub/agent?id=437"]);
  assert.equal(out, "Agent #437's Priors line: 5 USDG, drawn 1, available 4; open loans: 1.");
});

test("a price above maxPrice is refused before anything is signed or paid", async () => {
  paid.length = 0;
  const w = wallet({ balanceOf: 5000000n });
  const out = await priorsActionProvider(ask402("200000")).payX402WithCredit(w, { url: URL_, agentId: 437, maxPrice: "0.10", maxBorrow: "5", days: 7 });
  assert.match(out, /above maxPrice/);
  assert.deepEqual([w.sent, paid], [[], []]);
});

test("a short wallet borrows the pool's minimum loan with the quoted fee as its most, then pays; never past maxBorrow", async () => {
  paid.length = 0;
  const refused = wallet({ balanceOf: 0n, getParams: { minLoan: 5000000n } });
  assert.match(await priorsActionProvider(ask402("100000")).payX402WithCredit(refused, { url: URL_, agentId: 437, maxPrice: "0.10", maxBorrow: "1", days: 7 }), /Nothing was paid/);
  assert.deepEqual([refused.sent, paid], [[], []]);

  const w = wallet({ balanceOf: 0n, getParams: { minLoan: 5000000n }, quoteFee: [11666n, 0n, 0n, 0n] });
  const out = await priorsActionProvider(ask402("100000")).payX402WithCredit(w, { url: URL_, agentId: 437, maxPrice: "0.10", maxBorrow: "5", days: 7 });
  assert.deepEqual(w.sent, [{ to: PRIORS_POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "borrow", args: [437n, 5000000n, 604800n, ME, 11666n] }) }]);
  assert.deepEqual(paid, [URL_]);
  assert.match(out, /Borrowed 5 USDG first: loan #50900/);
});

test("repay approves exactly what is due, then repays it", async () => {
  const w = wallet({ getLoan: { agentId: 437n, principal: 5000000n, fee: 11666n, status: 1 }, balanceOf: 6000000n, allowance: 0n });
  const out = await priorsActionProvider().repay(w, { loanId: 50900 });
  assert.deepEqual(w.sent, [
    { to: USDG, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [PRIORS_POOL, 5011666n] }) },
    { to: PRIORS_POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "repay", args: [50900n, 437n, 5011666n] }) },
  ]);
  assert.match(out, /5\.011666 USDG/);
});

// ---- autoBorrow (0.2.0): the owner's option, never the model's -------------------------------------------------
const CHAT = "https://agent402.tools/v1/chat/completions";
const AUTO = { autoBorrow: { perCall: "6", perDay: "10", hosts: ["agent402.tools"] } };
/** The reads of a short wallet whose Autopay covers a 5 USDG loan: declared wallet, plan on under the owner, limit 25. */
const covered = (o = {}) => ({
  balanceOf: 0n, getParams: { minLoan: 5000000n, maxTerm: 30n * 86400n }, quoteFee: [11666n, 0n, 0n, 0n],
  getAgentWallet: ME, ownerOf: ME, planOf: [25000000, ME, true, false, false, 3], epochOf: [3, false], held: false, pausedUntil: 0n, allowance: 100000000n, loansOf: [], ...o,
});
const borrowTx = (amount, term) => ({ to: PRIORS_POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "borrow", args: [437n, amount, term, ME, 11666n] }) });

test("autoBorrow: the option is checked at construction (an amount per call above 0, a day limit at least that, the hosts)", () => {
  assert.throws(() => priorsActionProvider(undefined, { autoBorrow: { perCall: "0", perDay: "10", hosts: ["agent402.tools"] } }), /perCall/);
  assert.throws(() => priorsActionProvider(undefined, { autoBorrow: { perCall: "6", perDay: "5", hosts: ["agent402.tools"] } }), /perDay/);
  assert.throws(() => priorsActionProvider(undefined, { autoBorrow: { perCall: "6", perDay: "10", hosts: [] } }), /hosts/);
  assert.throws(() => priorsActionProvider(undefined, { autoBorrow: { perCall: "6", perDay: "10", hosts: ["https://agent402.tools/v1"] } }), /hosts/);
});

test("autoBorrow, Autopay covering: a short wallet borrows the minimum loan for 14 days with no maxBorrow named, then pays", async () => {
  paid.length = 0;
  const w = wallet(covered());
  const out = await priorsActionProvider(ask402("20000"), AUTO).payX402WithCredit(w, { url: CHAT, agentId: 437, maxPrice: "0.02" });
  assert.deepEqual(w.sent, [borrowTx(5000000n, 14n * 86400n)]);
  assert.deepEqual(paid, [CHAT]);
  assert.match(out, /Borrowed 5 USDG first: loan #50900.*Auto-borrow: Autopay repays it/);
});

test("autoBorrow, no Autopay covering the loan: nothing is borrowed or paid, and the answer says to turn Autopay on", async () => {
  for (const [reads, why] of [
    [{ planOf: [25000000, ME, false, false, false, 3] }, /Autopay is off/],
    [{ getAgentWallet: PAY_TO }, /not agent #437's declared wallet/],
    [{ epochOf: [4, true] }, /earlier owner or key/],
    [{ held: true }, /on hold/],
    [{ pausedUntil: 4000000000n }, /paused by the Safe/],
    [{ planOf: [5000000, ME, true, false, false, 3] }, /limit is 5 USDG per loan/],
    [{ allowance: 1000000n }, /may pull 1 USDG/],
    // an open loan of 5.05 within the limit already takes most of a 6 USDG approval
    [{ allowance: 6000000n, loansOf: [7n], getLoan: { principal: 5000000n, fee: 50000n, status: 1 } }, /may pull 6 USDG.*already need 5\.05 USDG/],
  ]) {
    paid.length = 0;
    const w = wallet(covered(reads));
    const out = await priorsActionProvider(ask402("20000"), AUTO).payX402WithCredit(w, { url: CHAT, agentId: 437, maxPrice: "0.02" });
    assert.match(out, why);
    assert.match(out, /Turn Autopay on .* at least 5\.011666 USDG per loan/);
    assert.deepEqual([w.sent, paid], [[], []], Object.keys(reads).join());
  }
});

test("autoBorrow: only for its hosts; the model's maxBorrow only lowers it; the day's limit holds in the process; the term is brought to the pool's maxTerm", async () => {
  const p = priorsActionProvider(ask402("20000"), AUTO);
  const other = wallet(covered());
  assert.match(await p.payX402WithCredit(other, { url: URL_, agentId: 437, maxPrice: "0.10", maxBorrow: "5" }), /borrows only to pay agent402\.tools/);
  assert.deepEqual(other.sent, []);
  const low = wallet(covered());
  assert.match(await p.payX402WithCredit(low, { url: CHAT, agentId: 437, maxPrice: "0.02", maxBorrow: "1" }), /above the most this call may borrow, 1/);
  assert.deepEqual(low.sent, []);
  const high = wallet(covered());
  await p.payX402WithCredit(high, { url: CHAT, agentId: 437, maxPrice: "0.02", maxBorrow: "50" });
  assert.deepEqual(high.sent, [borrowTx(5000000n, 14n * 86400n)], "a higher maxBorrow is the owner's 6, which covers 5");
  const second = wallet(covered()); // 5 of the 10 a day are used
  await p.payX402WithCredit(second, { url: CHAT, agentId: 437, maxPrice: "0.02" });
  assert.equal(second.sent.length, 1);
  const third = wallet(covered());
  assert.match(await p.payX402WithCredit(third, { url: CHAT, agentId: 437, maxPrice: "0.02" }), /limit of 10 USDG a day has 0 left/);
  assert.deepEqual(third.sent, []);
  const short = wallet(covered({ getParams: { minLoan: 5000000n, maxTerm: 10n * 86400n } }));
  await priorsActionProvider(ask402("20000"), AUTO).payX402WithCredit(short, { url: CHAT, agentId: 437, maxPrice: "0.02" });
  assert.deepEqual(short.sent, [borrowTx(5000000n, 10n * 86400n)]);
});

test("autoBorrow: two calls at once never both pass the day's limit, and a refused borrow gives its room back", async () => {
  const p = priorsActionProvider(ask402("20000"), { autoBorrow: { perCall: "6", perDay: "6", hosts: ["agent402.tools"] } });
  const [a, b] = [wallet(covered()), wallet(covered())];
  const outs = await Promise.all([a, b].map((w) => p.payX402WithCredit(w, { url: CHAT, agentId: 437, maxPrice: "0.02" })));
  assert.equal(a.sent.length + b.sent.length, 1, outs.join(" | "));
  assert.ok(outs.some((o) => /limit of 6 USDG a day/.test(o)), outs.join(" | "));
  const q = priorsActionProvider(ask402("20000"), { autoBorrow: { perCall: "6", perDay: "6", hosts: ["agent402.tools"] } });
  const refused = wallet(covered({ held: true }));
  assert.match(await q.payX402WithCredit(refused, { url: CHAT, agentId: 437, maxPrice: "0.02" }), /on hold/);
  const after = wallet(covered());
  await q.payX402WithCredit(after, { url: CHAT, agentId: 437, maxPrice: "0.02" });
  assert.equal(after.sent.length, 1, "the refused borrow's room came back");
});

test("method and body: a POST with a JSON body is probed and paid with that body; a GET with a body is refused", async () => {
  paid.length = 0; paidInits.length = 0;
  const probes = [];
  const fetchImpl = async (_url, init) => { probes.push(init); return ask402("20000")(); };
  const body = JSON.stringify({ model: "m", messages: [{ role: "user", content: "hi" }] });
  const out = await priorsActionProvider(fetchImpl).payX402WithCredit(wallet({ balanceOf: 1000000n }), { url: CHAT, agentId: 437, maxPrice: "0.02", body });
  assert.match(out, /Paid 0\.02 USDG/);
  for (const init of [probes[0], paidInits[0]]) assert.deepEqual(init, { method: "POST", body, headers: { "content-type": "application/json" } });
  assert.match(await priorsActionProvider(fetchImpl).payX402WithCredit(wallet({}), { url: CHAT, agentId: 437, maxPrice: "0.02", method: "GET", body }), /cannot carry a body/);
});

test("Robinhood Chain only", () => {
  const p = priorsActionProvider();
  assert.equal(p.supportsNetwork({ protocolFamily: "evm", chainId: "4663" }), true);
  assert.equal(p.supportsNetwork({ protocolFamily: "evm", chainId: "8453", networkId: "base-mainnet" }), false);
});
