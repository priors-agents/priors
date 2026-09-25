# @priors/x402

x402 on Robinhood Chain (`eip155:4663`) in USDG, on top of the official `@x402/*` 2.27 packages, plus credit:
when an agent is short, it can borrow the gap from its [Priors](https://priors.trade) line.

- `registerUsdg(scheme)`: `price: "$0.05"` on `eip155:4663` means USDG (6 decimals, EIP-712 domain "Global Dollar" v1).
- `priorsFacilitator({ apiKey })`: config for the official `HTTPFacilitatorClient`, pointed at
  `https://facilitator.priors.trade`, with your merchant key as `Authorization: Bearer …` on verify/settle/supported.
- `createPayer({ signer, … }).pay(url, init)`: a fetch that pays x402 USDG (v2, and legacy v1 `robinhood` bodies)
  and borrows the gap when you allow it.
- `robinhood`: the constants (network, chain id, USDG address and decimals, EIP-712 domain, facilitator URL, Priors
  pool/lens addresses).

```sh
npm i @priors/x402 @x402/core @x402/evm ethers
```

## Merchant: Express

```js
import express from "express";
import { paymentMiddleware, x402ResourceServer } from "@x402/express";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { HTTPFacilitatorClient } from "@x402/core/server";
import { registerUsdg, priorsFacilitator, robinhood } from "@priors/x402";

const server = new x402ResourceServer(new HTTPFacilitatorClient(priorsFacilitator({ apiKey: process.env.PRIORS_MERCHANT_KEY })))
  .register(robinhood.network, registerUsdg(new ExactEvmScheme()));

const app = express();
app.use(paymentMiddleware({
  "GET /report": {
    accepts: { scheme: "exact", price: "$0.05", network: robinhood.network, payTo: "0xYourAddress" },
    description: "One report, 0.05 USDG",
  },
}, server));
app.get("/report", (req, res) => res.json({ report: "…" }));
app.listen(3000);
```

The merchant key comes from registering your `payTo` with the facilitator (`POST /merchants/register`, or the
merchant page of x402.priors.trade). `createResourceServer({ apiKey })` does the first two lines in one call.

## Merchant: Hono

```js
import { Hono } from "hono";
import { paymentMiddleware } from "@x402/hono";
import { createResourceServer, robinhood } from "@priors/x402";

const app = new Hono();
app.use(paymentMiddleware({
  "GET /report": {
    accepts: { scheme: "exact", price: "$0.05", network: robinhood.network, payTo: "0xYourAddress" },
    description: "One report, 0.05 USDG",
  },
}, createResourceServer({ apiKey: process.env.PRIORS_MERCHANT_KEY })));
app.get("/report", (c) => c.json({ report: "…" }));
export default app;
```

## Merchant: a paid MCP tool (`@x402/mcp`)

```js
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createPaymentWrapper } from "@x402/mcp";
import { createResourceServer, robinhood } from "@priors/x402";

const resourceServer = createResourceServer({ apiKey: process.env.PRIORS_MERCHANT_KEY });
await resourceServer.initialize();
const accepts = await resourceServer.buildPaymentRequirements({
  scheme: "exact", network: robinhood.network, payTo: "0xYourAddress", price: "$0.01",
});
const paid = createPaymentWrapper(resourceServer, { accepts });

const mcp = new McpServer({ name: "my-paid-tools", version: "1.0.0" });
mcp.tool("quote", "A price quote. Costs 0.01 USDG.", {}, paid(async () => ({ content: [{ type: "text", text: "42" }] })));
await mcp.connect(new StdioServerTransport());
```

An agent pays it with `@x402/mcp`'s client and this package's USDG client:
`wrapMCPClientWithPayment(mcpClient, createUsdgClient({ signer, maxPrice: "$0.05" }), { autoPayment: true })`.

## Agent: pay, and borrow the gap

```js
import { ethers } from "ethers";
import { createPayer, robinhood } from "@priors/x402";

const provider = new ethers.JsonRpcProvider(robinhood.rpcUrl);
const signer = new ethers.Wallet(process.env.AGENT_KEY, provider); // the agent's wallet (and its Priors controller)

const payer = createPayer({
  signer,
  maxPrice: "$0.10",          // most one call may cost; a dearer 402 is refused before anything is signed
  // optional credit: borrow what the wallet is short of, from the agent's Priors line
  pool: robinhood.pool, agentId: 1234, maxBorrow: "$5",
});

const { response, paid, borrowed, loanId, dueAt } = await payer.pay("https://api.example.com/report");
console.log(response.status, await response.json(), { paid, borrowed, loanId, dueAt });
// once the agent has been paid by its client:
await payer.settleLoans(); // repays open loans, earliest due first; do it before dueAt
```

Amounts: a `bigint` or integer is atomic USDG (6 decimals: `100000n` = $0.10); a string with `$` is dollars.

### What `pay()` promises (the rules of `sdk/float.mjs`, unchanged)

- **`maxPrice`** (default $0.10) is checked before anything is read, signed or borrowed.
- **Borrowing** happens only when the wallet is short, a `pool` and `agentId` are given, and the price is within
  `maxBorrow` (default 0: never). It draws `max(shortfall, pool minimum loan)`, refuses above `maxBorrow` or the
  pool's `maxLoan`, caps the fee at the pool's quote (or `maxFee`), and simulates the borrow first.
- **Term**: 7 days by default, clamped into the pool's range; an explicit `termSeconds` above the pool's maximum is
  refused. The result's `dueAt` is when the loan must be repaid, or the agent's record is burnt.
- **Authorization window**: at most 600 s, whatever `maxTimeoutSeconds` the merchant asks. The payload's `accepted`
  stays the merchant's requirement verbatim.
- **One signature per purchase.** While the merchant answers "pending" (v2 `settlement_pending`, or a legacy
  `{pending:true}` body) the same signed payment is resent, up to 6 times, honouring `Retry-After`. If it is still
  pending, the result is `{ pending: true, paymentHeaders }`: call `payer.resend(url, paymentHeaders)` later, and do
  not call `pay()` again for the same purchase.
- **Legacy v1** 402 bodies (`network: "robinhood"`, `X-PAYMENT`) are paid the way `sdk/float.mjs` pays them.
- **No redirects.** Requests go out with `redirect: "manual"` unless you pass another `redirect` in `init`: a signed
  payment never travels to a host you did not name, and a 3xx comes back as the answer.
- **Bounded.** Bodies are read up to 256 KB (`readCapped`). `timeoutMs` bounds each request and `signal` the whole
  call; a timeout once the payment is out returns `{ pending: true, timedOut: true, paymentHeaders }`, never an error.
- **`signed`**: every result of a signed payment carries `signed: { paymentHeaders, validBefore }`. Until
  `validBefore` the merchant can still cash it, so a retry of the same purchase must `resend` these headers.

Refusals throw a `PayError` with a `code`: `PRICE_ABOVE_MAX_PRICE`, `PRICE_ABOVE_MAX_BORROW`,
`MIN_LOAN_ABOVE_MAX_BORROW`, `ABOVE_MAX_LOAN`, `TERM_OUT_OF_RANGE`, `FEE_TOO_HIGH`, `NO_POOL`, `NO_USDG_REQUIREMENT`,
`BAD_402`, `BORROW_WOULD_REVERT`, `NO_SIGNER`, `NO_PROVIDER`, `NOT_CONTROLLER` (`repayLoan`, `settleLoans`).

### Why `pay()` is not just `@x402/fetch`'s `wrapFetchWithPayment`

It uses the same parts (`x402Client`, `x402HTTPClient`, `ExactEvmScheme`), but writes the request loop out, because
the wrapper (2.27) cannot keep the rules above: it can only act inside payload creation, so a borrow refusal would
surface as a generic "Failed to create payment payload" error; when a response hook reports `recovered` it signs a
fresh payload while the first may still settle (two payments for one call); it has no pending loop and never hands
back the signed header; and it cannot route v1 `robinhood` bodies. If you never borrow, `createUsdgClient()` gives you
an `x402Client` with the same USDG allowance, price cap and 600 s window for `wrapFetchWithPayment`:

```js
import { wrapFetchWithPayment } from "@x402/fetch";
import { createUsdgClient } from "@priors/x402";
const fetchWithPay = wrapFetchWithPayment(fetch, createUsdgClient({ signer, maxPrice: "$0.10" }));
```

## Credit helpers

`@priors/x402/credit` has the Priors v2 pieces the MCP server uses: `creditContracts`, `creditStatus`, `quoteBorrow`,
`borrowLine`, `repayLoan`, `settleLoans`, `balances`, `borrowGap`. `repayLoan` pays only a loan of an agent the
signer controls (owner or pool delegate); any other loan is refused with `NOT_CONTROLLER` before anything is sent.

## Source

[github.com/priors-agents/priors](https://github.com/priors-agents/priors/tree/main/packages/x402), MIT. The facilitator,
its merchant sign-up and the live settlements are at [x402.priors.trade](https://x402.priors.trade).
