# Priors for agent builders

Three calls give an agent a credit history nobody can forge. The SDK is a thin ethers v6 wrapper in
`sdk/priors.mjs`, the raw ABI is in the same file if you would rather call the contract, and the CLI in
`bin/priors.mjs` is one subcommand per step.

Everything below is the same procedure the skill (`skills/priors/SKILL.md`) hands to a coding agent. This page
is for you reading it yourself.

## 0. A chain, and a wallet

```bash
npm install
npm run quickstart      # local chain, deployed pool, one agent taken through the whole record
```

That is the fastest way to see what you are integrating with: it starts anvil, deploys the pool with its mocks,
lends it money, funds the first-loss reserve, stakes the treasury, and then registers an agent, takes its first
line, borrows, repays and prints the score.

Against a real chain, set `RPC_URL` and `PRIVATE_KEY` in `.env` and run `npx priors doctor` first. The wallet
needs native gas and enough USDG to cover loan fees. **The pool never sees your keys — only the agent id.**

## 1. Get a first line

Any ERC-8004 identity that has never been enrolled can ask the treasury for a first line of `$5`. Anyone may
make the call for any agent, so an agent framework can do it on registration.

```js
import { Priors } from "priors";
const s = new Priors({ rpc, pool, treasury, signer }); // signer owns the ERC-8004 id (or is its delegate)
await s.firstLine(agentId);
```

The treasury vouches by rule, out of its own stake, capped at `$100` per 7-day epoch. If the epoch cap is
spent, wait for the next one or find a sponsor: any root sponsor can `vouch()` for you with a larger line.

No identity yet? `await s.register(uri)` mints one on registries that expose `register(string)`.

## 2. Borrow, hold, repay

```js
const { fee, qualifiesForScore } = await s.quote(5, 7);   // 1% per 30 days, pro rata
const loanId = await s.borrow(agentId, 5, 7);             // $5 for 7 days, USDG lands in your wallet
// ... do work ...
await s.repay(loanId);                                    // principal + fee
```

Loans shorter than the minimum scoring term (7 days) are real loans, but they do not count as qualified loans
for the score. The score rewards dollar-days: how much you borrowed, times how long you held it, summed over
everything you repaid. Churning one-day loans gets you nowhere. Holding real money for real time does.

## 3. Grow

After three qualified loans, fourteen days on the ledger and a clean record, anyone can call `raise(agentId)`
and the treasury lifts the line to `$50`. Repaying also earns capacity of your own — 50% of repaid principal,
at most `$25` per epoch and `$250` in total — and an agent with earned capacity can vouch for other agents.
Losses flow up the tree, so vouch carefully.

## Reading the score

```js
await s.score(agentId);   // 0..1000
await s.report(agentId);  // every input the score is computed from
await s.loans(agentId);   // every loan, with status
```

Or from any contract: `score(uint256)` on the pool. Every input is a public event you can recompute yourself.

## What ends it

Miss a due date by more than three days and anyone can mark the loan defaulted. The score goes to zero forever,
the identity can never borrow or vouch again, and the sponsor eats the loss. There is no appeal, which is the
point.

## Before you integrate for real

A lender-loss defect in default accounting was found and fixed, and no independent review of the economics has
happened yet. Read the Status section of the [README](../README.md) first — it explains both.
