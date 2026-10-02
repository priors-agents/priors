# @priors/x402

x402 on Robinhood Chain (`eip155:4663`) in USDG, on top of the official `@x402/*` 2.27 packages, plus credit:
when an agent is short, it can borrow the gap from its [Priors](https://priors.trade) line.

- `registerUsdg(scheme)`: `price: "$0.05"` on `eip155:4663` means USDG (6 decimals, EIP-712 domain "Global Dollar" v1).
- `priorsFacilitator({ apiKey })`: config for the official `HTTPFacilitatorClient`, pointed at
  `https://facilitator.priors.trade`, with your merchant key as `Authorization: Bearer …` on verify/settle/supported.
- `createPayer({ signer, … }).pay(url, init)`: a fetch that pays x402 USDG (v2, and legacy v1 `robinhood` bodies)
  and borrows the gap when you allow it.
- `robinhood`: the constants (network and its legacy v1 name, chain id, USDG address and decimals, EIP-712 domain,
  facilitator URL, public RPC URL, Priors pool, lens, identity registry and stock vault addresses).

```sh
npm i @priors/x402 @x402/core @x402/evm ethers
```

The examples below also use optional packages: `@x402/express` (Express), `@x402/hono` (Hono), and `@x402/mcp` with
`@modelcontextprotocol/sdk` (the paid MCP tool). Install the ones you use.

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

## Merchant: check who is paying (record gate)

The payer's Priors record is what it has borrowed and repaid on Robinhood Chain, and whether it ever defaulted.
`recordGate` reads it before the facilitator sees the payment. A payment the merchant's policy refuses is never
verified or settled: no money moves, and the client gets the usual 402. The reason (`priors_payer_defaulted`,
`priors_record_too_short`, `priors_score_too_low`, `priors_price_not_entitled`, `priors_record_unavailable`) is the
`error` field of its `PAYMENT-REQUIRED` header (base64 JSON), not the body.

```js
import { createResourceServer, recordGate } from "@priors/x402";

const server = createResourceServer({ apiKey: process.env.PRIORS_MERCHANT_KEY });
recordGate({ refuseDefaulted: true, minRepaid: 1 }).attach(server); // then paymentMiddleware(routes, server) as above
```

**On a local fork.** Read the record from the fork, not mainnet, and settle on the fork: `facilitator.priors.trade`
only settles on Robinhood Chain itself. `createResourceServer` takes any x402 v2 facilitator client as
`facilitatorClient`; agent001's sandbox runs one that pays the gas from a fork-only wallet
([`src/facilitator-local.mjs`](https://github.com/priors-agents/agent001/blob/main/src/facilitator-local.mjs)).

```js
const server = createResourceServer({ facilitatorClient: myForkFacilitator });
recordGate({ source: "chain", rpc: "http://127.0.0.1:8545", minRepaid: 1 }).attach(server);
```

| option | default | |
|---|---|---|
| `refuseDefaulted` | `true` | refuse a payer whose agent defaulted on a Priors loan |
| `minRepaid` | `0` | repaid Priors loans the payer must have |
| `minScore` | none | Priors Score v2 the payer must have (on-chain score with `source: "chain"`) |
| `source` | `"api"` | `"api"`: `https://priors.trade/api/check` by the payer's address (every agent it owns or declared as its payment wallet; no key). `"chain"`: Priors pool v2 read over `rpc`, for the agent the payer names in the `X-Priors-Agent` header, after checking the paying address controls it. Use it on a fork, or to depend on no Priors service |
| `rpc`, `pool` | public RPC, the published pool | for `source: "chain"` |
| `tiers`, `basePrice` | none | prices by record: `tiers: [{ minRepaid: 3, price: "$0.01" }]`, `basePrice: "$0.02"` |
| `cacheSeconds` | `60` | how long a payer's record is reused |
| `onDecision` | none | called with `{ payer, record, ok, reason }` for each payment |

A record that cannot be read refuses rather than serves on a guess.

**Prices by record.** Give the route `price: gate.tierPrice()`. A client states its address in `X-Payer` (and its
agent in `X-Priors-Agent` with `source: "chain"`) to be quoted its tier. That statement is only a request: when the
payment arrives, the gate reads the record of the address that actually signed it. It refuses a payment below that
payer's own price, so claiming someone else's record gets nothing.

```js
const gate = recordGate({ basePrice: "$0.02", tiers: [{ minRepaid: 3, price: "$0.01" }] }).attach(server);
// routes: { "GET /report": { accepts: { scheme: "exact", price: gate.tierPrice(), network: "eip155:4663", payTo } } }
```

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

To a merchant whose record gate reads the chain, name the agent the wallet controls:
`payer.pay(url, { headers: { "x-priors-agent": "1234" } })`. A refusal comes back as a 402 whose reason is the
`error` field of the `PAYMENT-REQUIRED` header.

Amounts: a `bigint` or integer is atomic USDG (6 decimals: `100000n` = $0.10); a string with `$` is dollars.

A result also carries the `requirement` it paid, its `x402Version` and, on success, the decoded `settlement`
(`PAYMENT-RESPONSE`) when the merchant sent one. Other `createPayer` options: `maxValiditySeconds` (at most 600, the
default), `asset` (a USDG address for a fork or test token; default the pool's `usdg()`, else mainnet USDG),
`fetchImpl`, `pendingRetries` (default 6), `maxSleepMs` (longest wait between resends, default 30 s) and `sleep`.

### What `pay()` promises (the rules of `sdk/float.mjs`, unchanged)

- **`maxPrice`** (default $0.10) is checked before anything is read, signed or borrowed.
- **Borrowing** happens only when the wallet is short, a `pool` and `agentId` are given, and the price is within
  `maxBorrow` (default 0: never). It draws `max(shortfall, pool minimum loan)`, refuses above `maxBorrow` or the
  pool's `maxLoan`, caps the fee at the pool's quote (or `maxFee`), and simulates the borrow first. A borrow that was
  sent and whose answer was lost (the broadcast's or the receipt's) may have mined: it throws `BORROW_UNCONFIRMED` with
  `borrowed` set, `loanId: null`, `unconfirmed: true` and the tx `hash` when known. Count it, check the agent's loans,
  and repay before the due date.
- **Term**: 7 days by default, clamped into the pool's range; an explicit `termSeconds` above the pool's maximum is
  refused. The result's `dueAt` is when the loan is due; three days later anyone can mark it defaulted, and the
  agent's record is burnt.
- **Authorization window**: at most 600 s, whatever `maxTimeoutSeconds` the merchant asks. The payload's `accepted`
  stays the merchant's requirement verbatim.
- **One signature per purchase.** While the merchant answers "pending" (v2 `settlement_pending`, or a legacy
  `{pending:true}` body) the same signed payment is resent, up to 6 times, honouring `Retry-After`. If it is still
  pending, the result is `{ pending: true, paymentHeaders }`: call `payer.resend(url, paymentHeaders)` later, and do
  not call `pay()` again for the same purchase. A payer also remembers its unsettled payments: a later `pay()` for the
  same purchase (the method; the URL as the merchant reads it: without its fragment, query fields in name order, `+`
  and `%20` alike, escapes in one case; and the body: a JSON body by its value, so key order, whitespace and how a
  number is written do not count, and a urlencoded or multipart form by its fields; `purchaseKey(request)` gives it)
  resends that one (`resent: true`) until it expires, plus `SKEW_SECONDS` (60 s, exported) for a chain clock behind
  this machine's. That memory is per payer and per process: pass `onSigned(s)` to `createPayer` to record each payment
  before it leaves (`s.paymentHeaders`, `s.validBefore`, `s.price`, `s.purchase`), so a new process can resend it
  instead of signing again. If `onSigned` throws, the payment is not sent: `pay()` rejects with `NOT_RECORDED` and
  nothing can be settled. `@priors/mcp` does this with a state file.
- **Legacy v1** 402 bodies (`network: "robinhood"`, `X-PAYMENT`) are paid the way `sdk/float.mjs` pays them.
- **No redirects.** Requests go out with `redirect: "manual"` unless you pass another `redirect` in `init` (`redirect:
  undefined` counts as none): a signed payment never travels to a host you did not name, and a 3xx comes back as the
  answer.
- **Bounded.** Bodies are read up to 256 KB (`readCapped`). `timeoutMs` (60 s by default; 0 = none) bounds each request and `signal` the whole
  call; a timeout once the payment is out returns `{ pending: true, timedOut: true, paymentHeaders }`, and a dropped
  connection `{ pending: true, transportError: true, error, paymentHeaders }`: never an error once the payment may be
  out. An error thrown after a loan or a signature carries `borrowed`, `loanId`, `dueAt` and `signed`.
- **One payment at a time** per payer: two concurrent `pay()` calls on a short wallet do not both borrow the gap.
- **`signed`**: every result of a signed payment carries `signed: { paymentHeaders, validBefore }`. Until
  `validBefore` the merchant can still cash it, so a retry of the same purchase must `resend` these headers.

Refusals throw a `PayError` with a `code`: `PRICE_ABOVE_MAX_PRICE`, `PRICE_ABOVE_MAX_BORROW`,
`MIN_LOAN_ABOVE_MAX_BORROW`, `ABOVE_MAX_LOAN`, `TERM_OUT_OF_RANGE`, `FEE_TOO_HIGH`, `NO_POOL`, `NO_USDG_REQUIREMENT`,
`BAD_402`, `BORROW_WOULD_REVERT`, `BORROW_UNCONFIRMED` (not a refusal: the borrow was sent, and may have opened a
loan), `NO_SIGNER`, `NO_PROVIDER`, `NO_FETCH`, `UNSUPPORTED_TRANSFER_METHOD` (a requirement that is not EIP-3009),
`NOT_CONTROLLER` (`repayLoan`, `settleLoans`). The credit helpers add
`LOAN_SIZE_OUT_OF_RANGE` (`quoteBorrow`, `borrowLine`), `LOAN_NOT_ACTIVE`, `INSUFFICIENT_USDG`, `REPAY_WOULD_REVERT`
(`repayLoan`) and `NO_STOCK_VAULT` (`stockPosition`, `stockAssets`).

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
`borrowLine`, `repayLoan`, `settleLoans`, `balances`, `borrowGap`, plus `poolContract`, `explainRevert` (a revert as
`Name(args)`), `LOAN_STATUS` and the ABIs (`POOL_ABI`, `LENS_ABI`, `ERC20_ABI`, `STOCK_VAULT_ABI`). `repayLoan` pays
only a loan of an agent the signer controls (owner or pool delegate); any other loan is refused with `NOT_CONTROLLER`
before anything is sent.

Stock lines (the Priors stock vault, `robinhood.stockVault`, backs a line with the agent's own stock tokens;
`creditContracts` reads it unless `addresses.stockVault` says otherwise): `creditStatus` carries `collateral` {
`token`, `amount`, `value` (what the vault prices them at, null while it will not), `ltvBps`, `borrowRoom`, `hold`
(0, or why new loans wait: `STOCK_HOLDS`), `holdReason`, `status`, `closing` } for a stock line (null for any other),
and its `available` is the smaller of the pool's figure and `borrowRoom` (`stockCollateral(c, id, sponsor)` reads that
object on its own). `stockPosition(c, id, assets?)` and
`stockAssets(c, assets)` read one position and the accepted tokens (price, whether the vault lends now, LTV).

## Source

[github.com/priors-agents/priors](https://github.com/priors-agents/priors/tree/main/packages/x402), MIT. The facilitator,
its merchant sign-up and the live settlements are at [x402.priors.trade](https://x402.priors.trade).
