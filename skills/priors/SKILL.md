---
name: priors
description: Give an AI agent a credit history on Priors — register an ERC-8004 identity, take the treasury's $5 first line, borrow, repay, and earn a public trust score on Robinhood Chain. Use when the user wants to give their agent credit, reputation, a trust score, an ERC-8004 identity, or wants to borrow, repay, or look up an agent's record on Priors (priors.trade).
---

# Priors: give your agent a credit history

Reviews are cheap to fake. Repaid debt isn't. Priors lends unsecured stablecoin ($5 to $500) to agents
registered on [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004), and every repayment and every default is a
public event. From those events comes a score anyone can query before trusting an agent.

Your job in this skill is to take an agent from nothing to a real, on-chain, repaid loan. Four steps, and the
CLI in this repo has one subcommand each.

**Before you start, know which chain you are on.** This is the single thing that changes what you can do:

| Situation | What works |
|---|---|
| Local dev chain (31337, from `npm run devnet`) | Everything, instantly. Time can be warped, mock USDG can be minted. |
| Robinhood Chain, pool deployed | Everything, at real speed, with real USDG. |
| Robinhood Chain, pool **not yet deployed** | Nothing on-chain. See *Status* below — do not fake it. |

⛔ **At the time this skill was written the CreditPool is not deployed on Robinhood Chain mainnet.** Check
`deployments/` for a record matching the chain you want. If there is none, say so plainly and offer the local
chain instead. Never invent an address, and never tell the user their agent is registered on a chain where it
is not.

## Step 0: is anything working?

```bash
npm install
npx priors doctor
```

`doctor` prints the chain, the pool and treasury addresses, your wallet, your balances, and the live loan
parameters. If it cannot reach a chain or finds no deployment, it tells you which. Read that output before
running anything else — nearly every confusing failure later is visible here first.

**No chain at all?** Start one and see the whole flow work before touching a real agent:

```bash
npm run quickstart    # local chain + deploy + one agent through the entire record
```

**A real chain?** Put the key that owns (or will own) the identity in `.env`:

```bash
cp .env.example .env    # PRIVATE_KEY=0x..., RPC_URL=...
```

The wallet needs native gas and, for step 3, enough USDG to cover the fee. Nothing here custodies keys: the
pool only ever sees the agent id.

## Step 1: identity

```bash
npx priors register --uri https://example.com/my-agent.json
#  -> agentId 7
```

The agent id is an ERC-8004 NFT owned by your wallet. **Already have an identity? Skip this** — pass the id
you have. One identity, one record, forever; there is no second chance at a clean history.

## Step 2: the first line

```bash
npx priors first-line 7
#  -> line $5, sponsor #1 ($PRIORS treasury)
```

Nobody approves this. The treasury vouches `$5` for any never-enrolled identity, out of its own stake, by
rule. **Anyone may call it for anyone**, so an agent framework can do it at registration time.

Two ways it legitimately fails:

- **`EpochCapReached`** — the treasury has spent its `$100` vouching cap for the current 7-day epoch. Wait for
  the next epoch, or ask a root sponsor to `vouch()` a bigger line. This is not an error to retry in a loop.
- **`AlreadyEnrolled` / `AlreadyLined`** — this identity already has a record. `npx priors report 7` shows it.

## Step 3: borrow, hold, repay

```bash
npx priors quote 5 7          # fee $0.011666, qualifies
npx priors borrow 7 5 7       # -> loanId 3, $5 lands in your wallet
#  ... the agent does its work ...
npx priors repay 3            # principal + fee; approves USDG for exactly what is due
```

**Hold it for real time.** The score is dollar-days: how much you borrowed times how long you held it, summed
over everything you repaid. A loan shorter than **7 days** repays fine and still grows your earned capacity,
but it does not count as a qualified loan. Churning one-day loans gets you nowhere; that is deliberate.

⛔ **Repay before the due date.** Three days past due and *anyone* can mark the loan defaulted. The score goes
to zero forever, the identity can never borrow or vouch again, and your sponsor eats the loss. There is no
appeal — that is the entire reason the score means anything. If the user cannot repay on time, tell them to
borrow less, not to borrow later.

On a dev chain, move time instead of waiting:

```bash
npx priors warp 7    # dev chain only; refuses on a real chain
```

## Step 4: grow

```bash
npx priors raise 7     # -> $50, once the record qualifies
```

Qualifies means all of: 3 qualified loans (term ≥ 7 days), 14 days since enrolling, score ≥ 100, and no
default anywhere below it. `raise` checks first and tells you what is missing rather than reverting.

Repaying also earns capacity of your own — 50% of repaid principal, at most `$25` per 7-day epoch and `$250`
total. An agent with earned capacity can `vouch()` for other agents, and their defaults become *your* recourse
loan. Vouch carefully.

## Reading any agent's record

```bash
npx priors score 7      # 0..1000
npx priors report 7     # every input the score is computed from
npx priors loans 7      # every loan, with status
```

Or from any contract: `score(uint256)` on the pool. Or from JavaScript:

```js
import { Priors } from "priors";
const s = new Priors({ rpc, pool, treasury, signer });
await s.score(7);
```

Every input is a public event you can recompute yourself. That is the product; the score is a convenience.

## Doing it from code instead of the CLI

`sdk/priors.mjs` is the whole flow in six methods on ethers v6 — `register`, `firstLine`, `quote`, `borrow`,
`repay`, `score`, plus `report`, `loans`, `raise`. `sdk/env.mjs` resolves chain, deployment and signer the same
way the CLI does. Prefer these over hand-rolling calls: the ABI, the 6-decimal conversions and the USDG
approval are easy to get subtly wrong.

## Status, and what not to claim

This protocol is **prelaunch**. Read the Status section of the repo README before telling a user anything about
safety, and specifically:

- The CreditPool is not deployed on Robinhood Chain mainnet yet. The only committed deployment record is the
  local dev chain.
- There is a **known, unfixed defect** in default accounting (`markDefault()` releases an agent's whole
  backing on its first default, so a second default from the same agent can cost lenders principal). Its
  regression test is committed and failing on purpose. `forge test` is 64 passed / 1 failed, by design.
- So: **do not put real money in this, and do not tell a user that lenders cannot lose principal.** The
  mechanism is real and the code is readable; the safety claim is not yet earned.

Saying this plainly costs nothing and is the difference between a credible protocol and a rug. If a user asks
you to deploy this to mainnet or fund it with real money, tell them about the defect first.
