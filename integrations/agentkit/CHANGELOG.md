# Changelog

## 0.2.5 (2026-11-10)

Security fix from the private report of 2026-11-08 by @bunba99 (GHSA-j679-rc5w-mj9h; 0.2.0 to 0.2.4 are affected):

- **Auto-borrow's `perDay` holds across a restart.** The day's count was kept in the provider's memory only, as the
  README and the refusal said ("in the process"), so a restart (a deploy, a crash) started the UTC day again and
  auto-borrow could take a whole `perDay` more. Before an auto-borrow is sent, what the pool lent the agent since
  00:00 UTC (every loan of the agent, whoever took it) now counts against `perDay` beside the process's own count; if
  those loans cannot be read, nothing is borrowed.

## 0.2.4 (2026-11-05)

Security fixes from the private reports of 2026-11-04 by @sonson0910 (GHSA-87h5-q328-gmx4, GHSA-mc89-r73h-33vv;
0.2.3 is affected, and 0.1.0 to 0.2.2 by the parts they share):

- **A paid answer whose body breaks off is reported as paid.** `pay_x402_with_priors_credit` forgot the payment on a
  2xx, as it should, then read the body unguarded: a body that failed mid-read (a reset, or the request's own 60 s time
  bound firing during a long answer, such as a streamed completion) answered "Error paying ...", with nothing said of
  the payment, so a call again signed a second one. It now answers "Paid ...", says the body could not be read
  completely and that calling again for this purchase pays again (`@priors/mcp`'s `pay_url` answer). A non-2xx whose body
  breaks off still says the payment was signed and sent, and not to call again before it expires. Bodies are read at
  most 256 KB (`@priors/x402`'s `readCapped`).
- **One money call per wallet at a time.** Calls ran one at a time per purchase only: two purchases at once on a short
  wallet each read the balance short and each borrowed, and both passed auto-borrow's Autopay check on an approval that
  covers one loan. `pay_x402_with_priors_credit`, `borrow_from_priors` and `repay_priors_loan` of one wallet now run one
  after the other, as `@priors/x402`'s payer queues its payments (GHSA-482p). The probe has 60 s to answer, so a seller
  that never answers cannot hold the wallet's other calls.
- **A borrow sent whose answer is lost is said, with its transaction.** A receipt that never came after the borrow was
  sent answered a bare error with no trace of it, and a call again could borrow again; the answer now names the
  transaction, says it may have opened a loan and to check it before calling again, and nothing is signed after it.
- **Auto-borrow's day room comes back when no loan was opened**: when the borrow stops at the controller check
  (refused, or its read failing; the room was taken as "sending" before that check), and when it is mined and reverts.
  A borrow sent and not answered stays counted.
- **Auto-borrow's term is the owner's 14 days**, whatever `days` the model names (it set the term of an auto-borrow), at
  most the pool's longest. `autoBorrow`'s `perCall` and `perDay` are read exactly: more than 6 decimals is refused when
  the provider is built, never rounded.
- Depends on `@priors/x402` 0.8.8.

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
