// The provider against the published @coinbase/agentkit, with a fake wallet: what it signs, what it refuses, and the
// actions AgentKit sees. @x402/fetch is replaced in the require cache, and AgentKit's own analytics call is answered
// locally, so nothing leaves the machine.
const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeFunctionData, encodeEventTopics, encodeAbiParameters, erc20Abi } = require("viem");

const paid = [];
require.cache[require.resolve("@x402/fetch")] = {
  exports: {
    x402Client: class {
      register() { return this; }
      registerPolicy() { return this; }
    },
    wrapFetchWithPayment: () => async (url) => { paid.push(url); return new Response("the data", { status: 200 }); },
  },
};
globalThis.fetch = async () => new Response(null, { status: 204 }); // AgentKit's analytics endpoint

const { priorsActionProvider, PRIORS_POOL, USDG } = require("../dist/index.js");
const { POOL_ABI } = require("../dist/constants.js");

const ME = "0x1234567890123456789012345678901234543210";
const PAY_TO = "0x86727111a44084cc7a7c1c5d8ac4b0eca4d7db66";
const URL_ = "https://check.blockpin.dev/check";

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

test("Robinhood Chain only", () => {
  const p = priorsActionProvider();
  assert.equal(p.supportsNetwork({ protocolFamily: "evm", chainId: "4663" }), true);
  assert.equal(p.supportsNetwork({ protocolFamily: "evm", chainId: "8453", networkId: "base-mainnet" }), false);
});
