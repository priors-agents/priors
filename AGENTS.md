# AGENTS.md

Instructions for any coding agent working in this repo — Codex, Claude Code, or anything else that reads this
file. Claude Code users: the same content is packaged as a skill at `skills/priors/SKILL.md`.

## What this repo is

Priors is an on-chain credit pool for [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) agents. An agent
borrows unsecured stablecoin, repays it, and earns a public trust score from that record. This repo holds the
contracts, the SDK, a CLI, and the skill that walks an agent through getting its own credit history.

## Giving an agent a credit history

**Read `skills/priors/SKILL.md` and follow it.** It is the canonical procedure: four steps, one CLI subcommand
each, with the failure modes spelled out. Short version:

```bash
npm install
npx priors doctor                 # which chain, what is deployed, can I sign
npm run quickstart                # no chain? this builds one and runs the whole flow
npx priors register               # -> agentId
npx priors first-line <agentId>   # the treasury vouches $5, by rule
npx priors borrow <agentId> 5 7   # -> loanId
npx priors repay <loanId>
npx priors score <agentId>
```

## Three things not to get wrong

1. **Check the chain before claiming anything.** Every tool resolves the pool from
   `deployments/<chainId>.json` and refuses to guess when there is no record for the chain you are pointed at.
   When that happens, say so — never invent a pool address, and never report an agent as registered when it is
   not.

2. **A lender-loss defect was found and fixed; it has not been independently reviewed.** `markDefault()` used to
   release an agent's whole delegated backing on its first default, so a second default from the same agent could
   cost lenders principal. It now consumes only the liable slice per loan. `forge test` is 74 passed, 0 failed.
   ⛔ Do not delete `test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure` or `test/DefaultAccounting.t.sol`
   — they are the evidence the fix works, and without them the guarantee is just a claim again. No independent
   review of the economics has happened, and the randomized invariants passed right through the original bug, so
   do not describe this as audited or as proven safe.

3. **A default is permanent.** Three days past due and anyone can mark a loan defaulted: score zero forever,
   the identity can never borrow or vouch again, and the sponsor eats the loss. Do not borrow for an agent that
   cannot repay on time.

## Working on the code

```bash
forge test                  # 74 tests, all green
npm run devnet              # local chain + deployed pool, bootstrapped so firstLine() works
npm run quickstart          # devnet + the full agent flow
bash scripts/check-public.sh  # fails if any credential reached a tracked file
```

- Solidity 0.8.26, Foundry, `optimizer_runs = 200`. Contracts are non-upgradeable: a source change only reaches
  users through a new deployment.
- `sdk/priors.mjs` is the contract surface (ABI included) and `sdk/env.mjs` resolves chain/deployment/signer.
  Use them rather than hand-rolling calls; the 6-decimal conversions and the USDG approval are easy to get
  subtly wrong.
- `scripts/devnet.mjs` must never point at a real chain — it deploys mocks and mints money, and refuses any
  chain that does not answer anvil cheat methods. Keep that refusal.
- Amounts are 6-decimal units on chain and whole dollars in the SDK. Money printed by the CLI is pinned to
  `en-US` so output is the same for everyone.
- Never commit a private key, a `.env`, or a deployment record for a chain you did not deploy to.
