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
verified or settled: no money moves, and the client gets the usual 402 with the reason (`priors_payer_defaulted`,
`priors_record_too_short`, `priors_score_too_low`, `priors_price_not_entitled`, `priors_record_unavailable`).

```js
import { createResourceServer, recordGate } from "@priors/x402";

const server = createResourceServer({ apiKey: process.env.PRIORS_FACILITATOR_KEY });
recordGate({ refuseDefaulted: true, minRepaid: 1 }).attach(server); // then paymentMiddleware(routes, server) as above
```

| option | default | |
|---|---|---|
| `refuseDefaulted` | `true` | refuse a payer whose agent defaulted on a Priors loan |
| `minRepaid` | `0` | repaid Priors loans the payer must have |
| `minScore` | none | Priors Score v2 the payer must have (on-chain score with `source: "chain"`) |
| `source` | `"api"` | `"api"`: `https://priors.trade/api/check` by the payer's address (every agent it owns or declared as its payment wallet; no key). `"chain"`: Priors pool v2 read over `rpc`, for the agent the payer names in the `X-Priors-Agent` header, after checking the paying address controls it; a payer the pool marked for a default (or the named agent's owner, if marked) counts as defaulted whatever agent it names, or none. Use it on a fork, or to depend on no Priors service |
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
const { open } = await payer.settleLoans(); // repays open loans, earliest due first, as far as the wallet covers; before dueAt. `open` lists what it could not pay
```

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

## Savings (`@priors/x402/savings`)

An agent's spare USDG in a Morpho vault (Morpho Vault V2, ERC-4626; Steakhouse USDG by default), taken back out when
it has to pay or repay:

```js
import { savingsContracts, savingsOf, save, unsave, topUpFromSavings } from "@priors/x402/savings";
const c = await savingsContracts({ runner: provider });            // refused unless there is a contract whose asset is USDG
await save(c, signer, 20_000_000n);                                 // 20 USDG in (checks the deposit gate first)
const s = await savingsOf(c, signer.address);                       // { saved, withdrawable, reachable, wallet, shares, ... }
await unsave(c, signer, { all: true });

// pay and repay from savings before borrowing
const payer = createPayer({ signer, pool: robinhood.pool, agentId, maxBorrow: "$1", topUp: (need) => topUpFromSavings(c, signer, need) });
const r = await payer.pay(url);          // r.savings: what the top-up did
const { open } = await payer.settleLoans();  // tops up to what all open loans need first; check `open`
```

- `withdrawable` is what a plain withdrawal pays now (idle, then the vault's liquidity market), found by simulating it
  (Morpho Vault V2 answers 0 to `maxWithdraw` by design). `reachable` adds the in-kind exit: `unsave` and
  `topUpFromSavings` move money out of the vault's other penalty-free markets and withdraw it in one transaction
  (`forceDeallocate` + `withdraw` in `multicall`) when the plain path falls short.
- Every vault transaction is sent with a gas margin. Refused before any transaction: `SHORT`, `ZERO`,
  `NOTHING_SAVED`, `MORE_THAN_SAVED` (each deposit is worth one base unit less than paid in), `VAULT_ILLIQUID` (with
  `withdrawable` and `reachable`), `EXIT_FAILED`, `EXIT_BLOCKED`, `DEPOSITS_CLOSED`, `NO_GAS`, `BAD_VAULT`,
  `NOT_USDG`. `VAULT_FULL` comes after the approval, which is then put back (`allowanceReset`). After sending:
  `REVERTED` (on chain) and `UNCONFIRMED` (sent, confirmation not read; check before retrying), both with the `hash`.
  A node failure is thrown as is.
- The in-kind exit uses only markets other than the liquidity market, with a penalty of 0, charged to an address that
  holds nothing: a penalty switched on before the transaction lands makes it revert rather than cost the saver.
- Every function takes an optional `{ signal, sent }`: the signal stops it before it sends a transaction, and `sent`
  is the hash once one is sent. A `topUp` whose error has `pending: true` (or code `UNCONFIRMED`) makes `pay` stop
  with `SAVINGS_PENDING` before any loan or signature.
- The money is the agent's own and the vault's risks are the agent's; Priors never holds it.

## Autopay (`@priors/x402/autopay`)

The agent's own wallet repays its loans on time through AutoRepay v2:
it approves a budget and enrolls once, and Priors' keeper (or anyone) repays each loan in the 6 hours before it is due,
from that wallet, while it holds enough. AutoRepay has no owner and no upgrade; it sends the wallet's USDG only to the
pool, for the agent's own loans. A plan lasts while the agent keeps the owner and the wallet it was set under: after a
new key or a sale, `autopayStatus` says `stale` and `autopayOn` is needed again. From 0.5.0 `autopayOn` refuses
AutoRepay v1 (retired before use) with `AUTOREPAY_V1`.

```js
import { autopayContracts, autopayOn, autopayStatus, autopayOff, defaultCap } from "@priors/x402/autopay";
const c = autopayContracts({ runner: provider, address: AUTOREPAY, registry, usdg, savingsVault, pool });
await autopayOn(c, wallet, agentId, { cap: defaultCap(line) }); // approves 4 x cap, then enroll(agentId, cap, false, true)
const st = await autopayStatus(c, wallet.address, agentId);     // plan, budget, next loan and its window, shortfall
```

- `createPayer({ reserve })`: a payment that would cut into what `reserve()` returns (e.g. `autopayReserve(status)`,
  what loans whose window opens in the next 24 h pull) is refused with `RESERVE` before anything is signed or borrowed.
- `settleLoans({ onlyInWindow: true })` (and `payer.settleLoans({ onlyInWindow: true })`): repay only the loans whose
  window (`repayWindow`, AutoRepay's own rule, never in a loan's first hour) is open, or that are past due; the others
  come back in `waiting`.

## SeatVaultV5 lines (`@priors/x402/credit`)

A line backed by SeatVaultV5 has no room until it is refreshed: V5 vouches nothing at the open and raises the pool's
vouch only on `refresh`, by the agent's owner or by the agent's pool delegate that V5 recorded (`noteDelegate`) at least
24 hours before. With `createPayer({ v5, v5Root })` (and `creditContracts({ addresses: { seatVaultV5,
seatVaultV5AgentId } })` for `borrowLine`), a borrow on such a line first calls `v5BeforeBorrow`: the owner, or a key
V5 recorded a day ago, refreshes the line; a key V5 has not recorded is recorded now, and while its 24 hours run the
borrow goes ahead only within the line's room, else it stops with `V5_DELEGATE_WAIT`, saying when it can borrow (the
owner can borrow from Go mode meanwhile, which refreshes first).

## Tests

`npm run test:packages` in the Priors repository: unit tests with mocks, and, with `RPC_URL` set, an anvil fork of
chain 4663 where a standard `@x402/express` server priced with `registerUsdg` is paid by `createPayer`.
