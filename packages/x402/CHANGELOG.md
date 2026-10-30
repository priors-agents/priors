# @priors/x402 changelog

## 0.8.4 (2026-10-30)

- **@x402/core, @x402/evm and @x402/fetch ^2.29.0 (from ^2.27.0), and the optional peers @x402/express and @x402/mcp
  with them: no zod 3 under them** ("Zod can exhaust memory while validating oversized constrained collections",
  GHSA-mrhx-c7xc-m3w5: every zod below 4.6.6, no fix in 3.x). @x402 2.27 and 2.28 depend on zod ^3.24.2, 2.29.0
  (2026-10-28) on zod ^4.6.6. With ^2.27.0 an install that already held 2.27 or 2.28 (a lockfile, or a project that
  uses them itself) kept them, each with zod 3.25 nested under it; with ^2.29.0 npm moves them. @x402/express 2.29 asks
  for express ^4.22.3 or ^5.3.0, and @x402/mcp 2.29 for @modelcontextprotocol/sdk ^1.32.0.
- **Nothing this package does changes.** Its own code is 0.8.3's, and the @x402 code it calls is the same in 2.27.0 and
  2.29.0 (compared from their published source maps): `x402Client`, `x402HTTPClient`, the header encoders and
  @x402/evm's exact client and server, so `createPayer`, `pay()`, `payViaGateway` and `registerUsdg` sign and pay as
  before, and `x402ResourceServer.verifyPayment`, where `recordGate`'s `onBeforeVerify` runs. What 2.29 changes around
  it, for a merchant on @x402's own middleware: `HTTPFacilitatorClient` refuses a facilitator answer over 1 MiB
  (`ResponseBodyTooLargeError`); @x402/express and @x402/hono charge a HEAD request as its GET route, no longer match
  an OPTIONS preflight with a route that names no method, and send an unpaid 402's reason as `{ error }` where the body
  was `{}`; an `afterSettle` hook can fail a settlement with `AfterSettleAbortError`. @x402/fetch's
  `wrapFetchWithPayment` refuses a 402 body over 1 MiB, and @x402/core/schemas are zod 4 schemas. 2.28 adds only USDC
  on Arc, Arc Testnet and Monad testnet to @x402/evm's default assets.

## 0.8.3 (2026-10-27)

- **A borrow on a SeatVaultV5 line for more than 10 days is refused before anything is sent** (GHSA-xccq-5ghg-w7mq,
  reported by hey-research-lab). SeatVaultV5 lends for at most 10 days (its `MAX_LOAN_TERM`, a constant), while the
  pool takes up to 30, but `v5BeforeBorrow` did not know the term: `borrowGap` (so `pay()` and `payViaGateway`) and
  `borrowLine` sent V5's `refresh` (the owner's) or `noteDelegate` (the agent's key's) and only then simulated the
  borrow, which reverted `BorrowBlockedByBacker`: a transaction signed and paid for on a loan that could not be made,
  where `borrowGap` says every refusal comes before any transaction.
  - `v5BeforeBorrow` takes the loan's `term` (seconds) instead of `amount`. On a V5 line it is required
    (`V5_TERM_REQUIRED` without it), and a term over 10 days throws `V5_TERM_TOO_LONG` (`term`, `maxTerm`), naming the
    limit, before V5 is asked anything. `borrowGap` and `borrowLine` pass theirs. New in `@priors/x402/credit`:
    `V5_MAX_TERM_S`.
- **The agent's key borrows nothing on a V5 line until 24 hours after V5 recorded it, whatever the line's room** (found
  while fixing the above). V5's `canBorrow` refuses any caller but the owner until then, and the pool asks it with the
  borrower as the caller, but `v5BeforeBorrow` let such a key's borrow go ahead "within the line's room", where it
  could only revert. A key V5 has not recorded is recorded (`noteDelegate`, which starts its 24 hours) and, like a key
  recorded under 24 hours ago, gets `V5_DELEGATE_WAIT` with `readyAt` (and `noted`); nothing else is sent, and the
  error no longer carries `room`. A borrow that goes through now always has `v5Noted: null`.
- **What a line can draw reads 0 when every loan would be refused** (GHSA-qcrq-x8xg-25vg, reported by
  hey-research-lab). `creditStatus`, `stockCollateral` and `stockPosition` gave the stock vault's `borrowRoom`, and
  `creditStatus` the pool's own figure, where the vault or the pool refuses every loan: the agent changed hands since
  its stock position opened (the vault lends only to the owner who opened it), the agent defaulted with another loan
  still open, or a default is marked on its owner's account (the pool's `ownerDefaults`, a custodian's skipped), this
  last on any line. Those figures are now 0 there, as for a frozen agent or an owner that can't be read, and the new
  `refused` (on `creditStatus` and on the stock collateral) says why. `stockCollateral` takes the caller's reads of the
  pool's agent and its owner as an optional fourth argument. The vault's own `borrowRoom` keeps its figure until its
  next implementation.

## 0.8.2 (2026-10-26)

- **A transaction the node took is never read as one it refused** (GHSA-rh27-m4c4-p2c7, reported by kevin9327).
  ethers 6 sends a JSON-RPC request again after an HTTP 429 (and after a 301/302/307/308), and a node that took the
  first copy of a signed transaction can answer the identical retried bytes "insufficient funds for gas * price +
  value". `borrowLine` and `borrowGap` (so `pay()` and `payViaGateway` too) rethrew that `INSUFFICIENT_FUNDS` as a
  refusal before anything was sent, though the loan was open; `fundBase` answered `NO_GAS` with `moved: false` for a
  deposit that may have left; `save`, `unsave` and `topUpFromSavings` answered `NO_GAS` for a transaction that may
  have landed. A caller then counted nothing: @priors/mcp's session and daily borrowing limits let a second loan
  through.
  - An `INSUFFICIENT_FUNDS` from the broadcast is now a refusal only while the node does not know the hash of the
    signed bytes ethers keeps in the error (`getTransaction` on the signer's provider, at most 10 s). One the node
    knows, a lookup that fails or times out, or no provider to ask, is `BORROW_UNCONFIRMED` (`borrowed`,
    `unconfirmed: true`), `DEPOSIT_UNCONFIRMED` (`moved: true`) or the savings' `UNCONFIRMED`, each with that `hash`
    (and the savings' `o.sent`).
  - Unchanged: a refused estimate (`CALL_EXCEPTION`, or `INSUFFICIENT_FUNDS` with nothing signed) and a mined revert
    (`CALL_EXCEPTION` with its receipt) are rethrown as before, and a lost answer was already unconfirmed. A
    `CALL_EXCEPTION` without a receipt after the hash came back, which ethers 6 does not raise, is unconfirmed too.
  - New in `@priors/x402/credit`: `refusedUnsent(err, runner)` and `refusedTxHash(err)`, the rule above.
  - What is left: behind a load balancer, the lookup can reach a backend that has not seen the transaction yet, and a
    transaction that was taken then still reads as refused. Signing first and sending the signed bytes once, as the
    repository's SDK does, closes that; @priors/mcp 0.12.0 no longer sends its own copy again after a 429.
- **A 402 that asks for USDG by Permit2 says so.** `NO_USDG_REQUIREMENT` for an exact requirement in USDG on Robinhood
  Chain whose `extra.assetTransferMethod` is `permit2` now says this payer signs USDG's own EIP-3009 transfer only,
  instead of "does not accept exact USDG on Robinhood Chain". No merchant text is quoted.

## 0.8.1 (2026-10-23)

- **Borrowing and repaying both need the agent's owner or its declared ERC-8004 wallet.** CreditPoolV2 lets an owner
  name any address its pool delegate without that address's consent, so `isController` was no proof the signer acts
  for the agent's owner: a buyer of an agent the signer once held (or was the key of) could name it delegate, borrow,
  and have a stale `agentId` repay the buyer's loans from the signer's USDG and savings. A signer that is not the
  owner must now be the agent's declared wallet (set only by that wallet's own `AgentWalletSet` signature naming the
  owner, cleared by a transfer: AutoRepay v2's rule); otherwise `NOT_AGENTS_WALLET`.
  - `repayLoan` and `settleLoans` refuse before any top-up, approval or repayment.
  - `borrowGap` (`pay()`'s borrow-the-gap) and `borrowLine` refuse before the pool is read, a fee quoted, a
    SeatVaultV5 line refreshed or anything sent. **The two halves are deliberately symmetric:** a key that may not
    repay here may not borrow here either, so no caller can draw a loan this package would then refuse to settle.
  - `settleLoans` and `borrowGap` take an optional `agentWalletOf(agentId)` beside `ownerOf`, for a caller that
    already holds the registry (the MCP server passes both).
- **Breaking for a delegate-only key.** A key the owner named with `setDelegate` but never declared as the agent's
  wallet now borrows and repays nothing through this package. Its owner declares it once — the key signs
  `AgentWalletSet` (`priors-mcp link-wallet` prints the signature) and the owner sends the registry's
  `setAgentWallet` — or the owner's own key acts. Every error says exactly that.

## 0.8.0 (2026-10-15)

- **`payViaGateway`: buy from a seller in Vantis' Keyring catalog with one USDG payment on Robinhood Chain.** Off
  unless `createPayer({ gateway })` names it (`{}` is https://keyring.vantis.sh). Most of these sellers are paid in
  USDC on Base. Keyring pays the seller and relays the answer, so the agent's Priors line can cover such a seller
  with no Base float.
  - Before anything is signed or borrowed:
    - the seller's record must name the resource and method asked for (not marked suspicious or testnet, with a
      listed price);
    - Keyring's quote must be armed, in USDG on Robinhood Chain, within `maxPrice` and within `gateway.maxFeeBps`
      (default 1000) over the seller's listed price;
    - the gateway's 402 must ask no more than the quote, on Robinhood Chain only, and pay `gateway.payTo` when set.
  - Then it is paid as `pay()` pays any Robinhood Chain merchant (balance, `topUp`, a loan of only the shortfall
    within `maxBorrow`, one signature), in the same one-at-a-time queue.
  - New codes: `GATEWAY_OFF`, `BAD_GATEWAY`, `BAD_GATEWAY_SERVICE`, `GATEWAY_NO_SERVICE`, `GATEWAY_REFUSED`,
    `GATEWAY_UNAVAILABLE`, `GATEWAY_FEE_TOO_HIGH`, `GATEWAY_PRICE_ABOVE_QUOTE`, `GATEWAY_PAYTO_MISMATCH`.
  - Tested against a mock gateway only. Its 402 shape and `payTo` are not yet seen live: see `docs/X402-ROUTES.md`.
- No new names in the package's exports (`createPayer` takes a new option; the payer has a new method).

## 0.7.1 (2026-10-13)

- **Fix: a check API answer with no record in it no longer passes a payer.** With the API source, an HTTP 200 whose
  body was not a check API answer (`{}`, `{"error": …}`, `{"agents": null}`, `{"agents": {}}`, an entry without its
  `record`) read as a payer Priors does not know: an empty, non-defaulted record, which the default policy accepts. A
  degraded or changed record service would then have served a defaulted payer through `@priors/x402/check`, failing
  closed or not, and through `recordGate`. Such a body is now a record that cannot be read: `@priors/x402/check`
  answers `503` with `Retry-After` (or serves, with `failOpen: true`), and `recordGate` refuses the payment
  (`priors_record_unavailable`). Only an answer's own `agents: []` is a payer Priors does not know, as before.
  `recordFromCheck` throws on such a body instead of returning an empty record.
- Fix, chain source: when the registry read of the named agent's owner fails, the record is unreadable (refused, or
  `503` from `@priors/x402/check`). It was judged without that owner's default mark, so an agent key of a marked
  owner's agent could pass `refuseDefaulted`.

## 0.7.0 (2026-10-12)

- **`@priors/x402/check`: refuse a payer with a bad Priors record in one line, whatever runs the x402 paywall.**
  `requireRecord(opts)` (Express, Connect, `node:http`), `honoRecord(opts)` (Hono) and `withRecord(handler, opts)`
  (a `fetch` handler: Cloudflare Workers, Next route handlers, Bun) go in front of the paywall; `checkRequest(request,
  opts)` gives the decision for any other stack. The payer comes from the payment header (v2 `PAYMENT-SIGNATURE`, v1
  `X-PAYMENT`) through `payerOf`, its record through `recordGate`'s own cached reader, and the policy is `judge`'s
  (`refuseDefaulted`, default true, `minRepaid`, `minScore`). No payment header: the request goes on and the paywall
  answers 402 as before. A refused payer: `403` `{ error, message }` (`priors_payer_defaulted`,
  `priors_record_too_short`, `priors_score_too_low`; `priors_payer_unknown` for a header naming no single payer, two
  headers naming two payers, or one that does not decode). A record that cannot be read: `503` with `Retry-After`
  (`failOpen: true` serves). It runs before the paywall's verification on purpose: it can only refuse, and a forged
  payer cannot pass the verification that follows. Demo: `examples/check-record` (in the repository).
- `recordGate`, `judge`, `payerOf` and the rest of the package are unchanged.

## Earlier versions

- 0.6.5: `robinhood.seatVaultV5`; `creditContracts` knows SeatVaultV5 by default.
- 0.6.4: `recordGate`'s cache is bounded (`cacheMax`), and `X-Priors-Agent` adds no entry with the API source
  (GHSA-vjcp-qx2h-gr2q).
- 0.6.3: `repayLoan` and `settleLoans` repay only loans the agent's owner now took (GHSA-mmp8-g8jw-7gqp).
- 0.6.2: `pay()` keeps the caller's `signal` and signs nothing once it aborts (GHSA-868j).
- 0.6.1: a requirement x402 core will not sign is refused before anything is borrowed (GHSA-f35g).
- 0.6.0: `@priors/x402/bridge` and the Base network exports (`networks`, off unless asked for).
