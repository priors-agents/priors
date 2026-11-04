# Changelog

## 0.2.3 (2026-11-04)

Security fix from the private report of 2026-11-04 by @mr-hrydarie (GHSA-pr4v-mc2c-995x; published versions 0.1.0 to
0.2.2 are affected):

- `pay_x402_with_priors_credit` signs one payment per purchase. It paid through `@x402/fetch`'s
  `wrapFetchWithPayment` with nothing kept of the payment it signed, so a second call for the same purchase after an
  answer that was lost (a dropped connection, HTTP 500, a 402 on the paid round) signed a second authorization while the
  seller still held the first, and both could settle. It now pays with `@priors/x402`'s payer pieces: the payment is
  kept, per wallet and purchase (`purchaseKey`: the method, the URL as the seller reads it, the body), before it is
  sent, and while it may still settle a call for that purchase sends that same payment again (`resend`), never a new
  one, and borrows nothing more. Calls for one purchase run one after the other.
- Only a 2xx answer is reported as paid (an HTTP 500 was answered "Paid"); any other answer says the payment was signed
  and sent, until when the seller may still settle it, and not to call again before then.
- The authorization is valid at most 600 s, whatever `maxTimeoutSeconds` the seller names (it was the seller's value).
- It pays again on a fresh install: `@x402/core` 2.23.0 and later refuse every asset they do not list by default, USDG on
  Robinhood Chain among them, so 0.1.0 to 0.2.2 with the `@x402/*` npm installs today signed nothing. The client is
  `@priors/x402`'s `createUsdgClient` (USDG on Robinhood Chain, at most the probed price).
- The requirement is picked as `@priors/x402`'s payer picks it (exact, EIP-3009, on USDG's own EIP-712 domain), and x402
  is asked whether it signs it before anything is borrowed.
- Depends on `@priors/x402` 0.8.6 and `@x402/fetch` ^2.29.0 (no longer `@x402/evm` directly); Node 20 or later.

Kept in the process's memory, as `@priors/x402`'s `createPayer` keeps it: a restart while a payment may still settle
(at most 600 s) forgets it, and a call for the same purchase after the restart signs again.

## 0.2.2 (2026-11-03)

Security fixes from the private reports of 2026-10-31 (published versions 0.1.0 to 0.2.1 are affected):

- `repay_priors_loan` and `borrow_from_priors` (and the borrow `pay_x402_with_priors_credit` makes) act only for an
  agent this wallet controls at the pool and owns or is the declared ERC-8004 wallet of; `repay_priors_loan` pays only
  a loan its current owner took, and takes an optional `agentId` it checks the loan against (GHSA-62m7, GHSA-fg53,
  GHSA-2943).
- `pay_x402_with_priors_credit` signs only the requirement it probed (same `payTo`, same amount), pays public https
  hosts only and follows no redirect, reads `maxPrice` and `maxBorrow` exactly (more than 6 decimals is refused), keeps
  a loan taken for the gap in its answer when the payment then fails, and does not report a payment the seller answered
  402 as paid.
- The seller's body is returned inside `@priors/mcp`'s data fence (`src/fence.js`, a byte-for-byte copy of the
  repository's `sdk/fence.mjs`), its settlement header only as a transaction hash; an agent's name from Priors' API as
  one fenced line.
- A transaction whose receipt says it reverted is reported as reverted, never as done.

From the private reports of 2026-11-01 and 2026-11-02 (0.2.0 and 0.2.1 are affected):

- `autoBorrow` never borrows on a wallet plan of an agent whose declared wallet is its owner's own address: AutoRepayV2
  repays that address under the owner's plan only, so such a plan covers no loan (GHSA-65qg).
- An auto-borrow that stops before its transaction is sent, a read failing as well as a refusal, gives its room back to
  the day's limit; one whose sending began stays counted (GHSA-q4cg).
