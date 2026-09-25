# Credit as float: x402 payments on a Priors line

Not leverage. Float.

An agent pays for data, APIs and compute per call now, and gets paid by its own client later. Without credit it
needs a human to top up its wallet first. A small Priors v2 line covers the gap: the $5 that pays for the call that
earns the next ten.

`sdk/float.mjs` is an [x402](https://github.com/x402-foundation/x402) client for USDG on Robinhood Chain that pays
from the agent's balance and, only when that is short, borrows the difference from the agent's Priors v2 line.

## Using it

```js
import { resolveV2 } from "priors/env";
const { priors } = await resolveV2();                  // PRIORS_KEY = the agent's owner (or pool delegate)

const r = await priors.pay("https://merchant.example/api/thing", {
  agentId,                  // the agent whose line may be drawn
  maxBorrow: 5_000000n,     // most this call may borrow, atomic USDG (0 = never borrow)
  maxPrice: 100_000n,       // most this call may pay (default 0.1 USDG)
});
// r.response is the merchant's answer; r.paid, r.borrowed, r.loanId, r.dueAt say what happened

await priors.settleLoans(agentId);                     // later, once the agent has been paid: repay, earliest due first
```

The functional form is `pay(url, { signer, pool, agentId, ... })` and `settleLoans({ signer, pool, agentId })`
from `priors/float`.

## What `pay()` does

1. Fetches the URL. Anything but a `402 Payment Required` is returned untouched.
2. Picks the first x402 v1 `exact` requirement for USDG on network `robinhood` (or `eip155:4663`).
3. **Refuses a price above `maxPrice`** (default 0.1 USDG) before signing or borrowing anything. The merchant
   writes the 402; without a cap a funded agent would sign whatever it asks.
4. If the balance covers the price, pays from it. If not, borrows `max(shortfall, pool minLoan)` from the agent's
   line, never above `maxBorrow` (a price above `maxBorrow` is refused before any transaction). The default term is
   7 days, clamped into the pool's range; `r.dueAt` is the deadline to have `settleLoans()` run by.
5. Signs an EIP-3009 `TransferWithAuthorization` on USDG's `Global Dollar` v1 domain, valid for at most 600 s
   whatever the merchant asks, and retries with it in `X-PAYMENT`.
6. If the merchant answers 402 `{pending: true}` (the settlement was broadcast but not yet confirmed), it resends
   the **same** header, honouring `Retry-After`, up to 6 times. Still pending: it returns
   `{pending: true, paymentHeader}` for `resend(url, paymentHeader)` later.

⛔ **Never call `pay()` again for a purchase that came back pending.** That signs a second payment while the first
can still land. Use `resend()` with the header you were given.

The borrowed USDG lands in the agent's own wallet, because EIP-3009 needs the payer to hold the funds. A router
that draws straight to the merchant would be stricter, and is not built.

## The facilitator

Priors runs an x402 facilitator for USDG on Robinhood Chain: **`https://facilitator.priors.trade`**. It is not
the only one on the chain (Canopy, r0x and Verge run facilitators too). The merchant picks its facilitator;
`pay()` only signs the payment the merchant's 402 asks for.

- `GET /health` is open.
- `POST /verify` checks a payment without moving anything. Like `/settle`, it needs a merchant API key.
- `POST /settle` submits the transfer and pays the gas. It needs a merchant API key (`Authorization: Bearer
  <key>`), and it settles only for the merchant's registered `payTo`, above a minimum value (0.01 USDG), never
  payer-to-self. Merchants sign up for a key at
  [x402.priors.trade/merchants](https://x402.priors.trade/merchants).
- A settlement whose receipt did not arrive in time is answered as `pending`, not failed. The merchant must treat
  it as not yet paid, must not ask the client for a new payment, and retries `/settle` with the same `X-PAYMENT`;
  the facilitator never submits one authorization twice.

Payload format and reason codes follow the x402 reference facilitator (v1, `exact`, EVM). The constants are in
`sdk/x402.mjs`. Only 65-byte EOA signatures are accepted for now; smart-contract payers (EIP-1271) are not.

## The rules do not bend for float

A float loan is an ordinary v2 loan. Miss its due date by more than three days and anyone can mark it defaulted,
with the same permanent consequences as any other. Set `maxBorrow` to what the agent can repay within the term.

Tests: `npm run test:v2` covers the client guards network-free (price caps, authorization lifetime, the pending
resend, no loan when `maxBorrow` is 0).
