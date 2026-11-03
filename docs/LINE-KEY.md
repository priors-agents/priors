# LineKey: a spending key for an agent's credit line

LineKey (`src/LineKey.sol`) lets the owner of an ERC-8004 agent hand the agent a bounded key to its credit line
instead of a key that can draw the whole line. It is deployed on Robinhood Chain (chain 4663) since 2026-11-03 at
`0x1090Df1B8A4B3F1e7D9aeDaA06fd29f56B9214fB`, for pool v2 (`0x281210097f0de7A8FB6F87310AF0f089c9C8DE21`), its source
verified on the explorer; its deploy record is `deployments/4663.line-key.json`. It is opt-in: nothing changes for an
agent until its owner names it.

The owner names LineKey as the delegate of the agent's line on pool v2 (`setDelegate(agentId, lineKey)`) and sets the
terms on LineKey. The agent's hot key, the *operator*, then pays a listed payee straight from the line:
`spend(agentId, payee, amount, ref)` calls the pool's `borrow(agentId, amount, term, to = payee, maxFee)`, so the USDG
goes from the pool to the payee in one transaction and never passes through LineKey or the agent's wallet. Each payment
is an ordinary loan of the agent. LineKey holds nothing (no token, no approval, no ETH), has no admin, no pause and no
upgrade. It is called a key, not a card: it gives no credit, the line is the pool's, and the key only bounds who may draw
on it and where the money goes. It uses only `borrow` and `isController`, with ERC-8460's signatures, so it works with
any line that has them.

## Setting it up (the owner, two transactions)

1. `pool.setDelegate(agentId, lineKey)`. This replaces any earlier delegate: a hot key that stays the pool's delegate
   keeps its unbounded draw.
2. `lineKey.configure(agentId, terms, payees)`, by the registry's `ownerOf(agentId)`.

| Term | Meaning |
|---|---|
| `operator` | the only address that may call `spend` |
| `perPayment` | the most one payment may be (inclusive) |
| `perPeriod` | the most the payments of any trailing `period` may sum to (inclusive; at least `perPayment`) |
| `period` | the window, in seconds, at most 365 days; fixed for the life of a key |
| `expiresAt` | spends need `block.timestamp < expiresAt` |
| `term` | the loan term of every draw (pool v2 lends for 1 to 30 days) |
| `maxFeeBps` | the most fee a draw may cost, in basis points of its amount |
| payees | up to 32 addresses, each with an optional cap per period of its own (0: only the key's caps) |

A backer may add its own conditions. SeatVaultV5 draws only for the delegate it has noted: after step 1, anyone calls
`seatVaultV5.noteDelegate(agentId)`, and the key can draw one day later. To keep an x402 payer working (it pays from the
agent's own wallet), list that wallet as a payee with a low cap of its own.

Calling `configure` again on the owner's live key changes the terms in place (a new operator, a later expiry, other
caps, term or fee), and every payment already made still counts; the period cannot change. `setPayee` adds, re-caps or
removes one payee.

## The rules of a payment

`spend` checks these in order, and `check(agentId, operator, payee, amount, ref)` returns the same reason without
sending: `NoKey` (none, or revoked), `OwnerChanged` (the registry no longer names the owner that set the key, or does
not answer), `Expired`, `NotOperator`, `ZeroAmount`, `PayeeNotAllowed`, `OverPerPayment`, `RefUsed` (a nonzero `ref`
already paid to this payee for this agent), `TooManyPayments` (64 in the window), `OverPeriod`, `OverPayeePeriod`, and
from `check` only `NotDelegate`. `spend` reverts with `Refused(reason)`. When the key's rules pass and the pool still
refuses, the key reverts with `LineRefused(the pool's own revert data)`: `Paused()`, `WrongSponsor(id, 0)` (no line),
`InsufficientCapacity`, `BorrowBlockedByBacker`, `NotController`, `FeeTooHigh`, `TermOutOfRange` or
`LoanSizeOutOfRange` (pool v2 lends 5 to 500 USDG a loan). A refused payment changes nothing and uses no room.

The period is a trailing window, as in ERC-8427: a payment made at `s` counts while `block.timestamp < s + period`. A
reset at midnight would let a stolen operator key take two periods' caps in two seconds; a trailing window never lets
the payments of any span of one period add up to more than `perPeriod`.

## Revocation and changes of hands

- The owner calls `revoke(agentId)` at any time. The next `configure` starts a new generation: no payee, no usage, no
  operator carried over (references already paid stay paid). A new key starts with an empty window, so name a new
  operator when the old one is in doubt.
- Every spend reads the registry's `ownerOf`. When the agent changes hands the key stops at once, and the pool's own
  delegate lapses at the same moment; the new holder's first `configure` starts a new generation.
- If the agent comes back to the owner that set the key, the key works again, as the pool's delegate does (ERC-8004 has
  no transfer nonce). While the registry names another owner, anyone may `revoke` the key, which ends it for good: so
  moving the agent out of the owner's wallet even for a moment lets anyone end it. A registry that fails to answer is no
  ground for a stranger's revoke.

Once the key is the pool's delegate, the hot key is no longer the agent's controller where `pool.isController` is
read: the calls allowed to "the owner or its pool delegate" (StockVault's opening, SeatVaultV4's `accept`, the
treasury's `firstLine`, a delegate's SeatVaultV5 `refresh`, the pool's `leave`) are the owner's alone. AgentLease
refuses a renter that `isController` names; it cannot see a key's operator, so an owner renting the agent out should
revoke the key or name another operator for the lease.

## Repayment is not the key's

Each payment is a loan of the agent, recorded with the owner at the draw, repaid by anyone (the agent's own
`pool.repay(loanId, agentId, maxDue)`, AutoRepay v2, IncomeRouter), and defaulted as any other loan three days past due.
The key's window counts payments, not debt: repaying does not refill it. The key does not refuse while one of the
agent's loans is past due, and neither does the pool: pool v2 keeps due times per loan only, so the check would be an
unbounded loop on every payment. There is no lifetime cap; the expiry and the period cap bound a key's total.

## Events and views

| Event | When |
|---|---|
| `KeySet(agentId, owner, generation, terms)` | each `configure` |
| `PayeeSet(agentId, generation, payee, allowed, perPeriod)` | each payee listed, re-capped or removed |
| `KeyRevoked(agentId, generation, by, ownerChanged)` | a revoke, or a new holder's `configure` replacing a stale key |
| `Paid(agentId, payee, ref, amount, loanId, operator, generation)` | each payment; `agentId`, `payee` and `ref` indexed |

Views: `keyOf`, `payeesOf`, `payeeRule`, `spentInPeriod(agentId, payee or 0)` (sum, count, when the oldest payment
leaves the window), `remaining` and `maxPayment` (what the key's own rules allow now; the pool may still refuse),
`check`, `isActive` (set, held by its owner, not expired, and the pool's controller for the agent), `refUsed`, and
`line`, `registry`, `asset`.

## How a payee verifies a payment

One transaction, three logs: USDG's `Transfer(from = pool, to = payee, value = amount)` (the money), the pool's
`Borrowed(loanId, agentId, sponsorId, amount, fee, dueAt, to = payee)`, and `Paid(agentId, payee, ref, amount, loanId,
operator, generation)` from `0x1090Df1B8A4B3F1e7D9aeDaA06fd29f56B9214fB` (any contract can emit an event named `Paid`:
check its address). To find a payment for an invoice, filter `Paid` on topic 1 (the agent the invoice was for), topic 2
(the payee) and topic 3 (the reference), then check the receipt's transfer and the amount. Nothing in the key can be
reversed after the transaction: the USDG is the payee's, the loan is the agent's.

For invoice reconciliation, use a nonzero `ref`. Verify chain 4663 and a successful receipt for the direct `spend`,
then match all three logs against the invoice's agent, payee, reference and raw integer amount. Match
`Paid.loanId` to the pool's `Borrowed.loanId`, check each log's emitting contract, and require distinct log indices.
Keep the chain ID, transaction hash and log index
when deduplicating; a matching receipt still needs your application's confirmation and reorg policy.

A [read-only Node.js example](https://docs.blockvectra.com/en/guides/verify-agent-payments/) hosted by BlockVectra
implements these checks for direct LineKey spends, including strict ABI encoding checks. It reads the chain ID and
one receipt using a BlockVectra RPC key; it needs no wallet key, sends no transaction and makes no automatic retries.

## Bounds and what it does not do

- A stolen operator key pays only listed payees, within `perPayment` and `perPeriod` per trailing period, until
  `expiresAt`; the owner rotates the operator or revokes. A listed own wallet is drawable up to its own cap: keep it low.
- Every loop is bounded (32 payees, 64 payments a window). A spend on pool v2 costs about 600,000 gas, the pool's
  borrow included, and about 815,000 in the worst case: a sponsor of the operator's gas should allow 900,000.
- `spend` is `nonReentrant`, and the payment is counted before the pool pays out: a payee or backer hook that re-enters
  is refused and sees the payment already counted.
- It does not repay, collect or handle defaults; it is not a bank card (no network, no issuer, no card number); a
  standard x402 seller verifying the payer's EIP-3009 signature cannot take a pool transfer (use the own-wallet
  allowance); the operator sends `spend` itself; it pays the line's asset only.
- It had two independent reviews before the deploy, both by AI agents, the second adversarial, and its tests and fork
  rehearsals; there is no outside audit yet, so keep caps small.

## The deployment

LineKey was deployed through the CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the salt
`keccak256("priors.LineKey")`, so its address is fixed by its creation code and its one constructor argument, pool v2.
Transaction `0x4f6fce5934489120110ee60271966cfe2e3235adc6ac0a58b947d7ef49216f52`, block 105,368,973, 2026-11-03.
`deployments/4663.line-key.json` holds the address, the block to read its logs from (`lineKeyBlock`), the code hashes
and the source's sha256. `src/LineKey.sol` here is byte-identical to the source verified on chain: with OpenZeppelin's
own submodules checked out too (`git submodule update --init --recursive`; forge records their remappings in the
metadata) and solc 0.8.26, optimizer 200 runs, cancun, `forge build src/LineKey.sol` gives the deployed creation code
(`initcodeHash` in the record).
