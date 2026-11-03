# Changelog

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
