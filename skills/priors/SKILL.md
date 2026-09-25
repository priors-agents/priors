---
name: priors
description: Give an AI agent a credit history on Priors — register an ERC-8004 identity, get a $5 line (a treasury invite or a $PRIORS seat), borrow, repay, and earn a public trust score on Robinhood Chain. Use when the user wants to give their agent credit, reputation, a trust score, an ERC-8004 identity, wants to borrow, repay, pay x402 APIs on credit, or look up an agent's record on Priors (priors.trade).
---

# Priors: give your agent a credit history

Reviews are cheap to fake. Repaid debt isn't. Priors lends unsecured stablecoin ($5 to $500) to agents
registered on [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004). Every line is backed, dollar for dollar, by
someone who put money behind that agent, and every repayment and every default is a public event. From those
events comes a score anyone can query before trusting an agent.

Your job in this skill is to take an agent from nothing to a real, on-chain, repaid loan.

**Priors v2 is live on Robinhood Chain mainnet (chain 4663).** The v1 pool is paused. Know which one you are
talking to:

| Situation | What works |
|---|---|
| Robinhood Chain, v2 (`npx priors-v2`, `deployments/4663.v2.json`) | Everything, at real speed, with real USDG. **This is the one to use.** |
| Robinhood Chain, v1 (`npx priors`, `deployments/4663.json`) | Reading history only (`score`, `report`, `loans`). The pool is paused: new lines and loans revert. |
| Local dev chain (31337, from `npm run devnet`) | The v1 flow, instantly, with mock USDG and warped time. Good for a demo; nothing there is real. |
| A chain with no deployment record | Nothing on-chain. Say so — do not pretend otherwise. |

⛔ **Never invent a pool address, never send an agent to the paused v1 pool, and never tell a user their agent is
registered or has a line when it does not.** The tools resolve addresses from the deployment records and refuse to
guess; when they refuse, say it plainly.

## Step 0: a key, and a funded wallet

```bash
npm install
cp .env.example .env     # set PRIORS_KEY=0x... (the key that owns, or will own, the agent's identity)
npx priors-v2 status
```

⛔ **The key goes in the environment or `.env`, never on the command line.** The CLI refuses a key passed as an
argument (it would land in shell history) and never prints it.

The wallet needs a little native gas and, for step 3, enough USDG to pay the fee (about $0.012 on $5 for 7 days).
`RPC_URL` defaults to Robinhood Chain's official endpoint; it takes a comma-separated failover list.

## Step 1: identity

```bash
npx priors-v2 join
#  -> registered agent #6301 for 0x…
```

`join` registers an ERC-8004 identity for this key if it owns none, and prints its id. **Already have an
identity?** If it was minted before the v2 deploy (for example a v1 agent), set `PRIORS_AGENT_ID=<id>`; v1 records
were imported, so its history is already there.

⛔ **Use the id this command printed, not the one in these examples.** One identity, one record, forever.

## Step 2: a line

Three ways, and every one needs the agent owner's signature (the pool consent), which `join` signs for you:

```bash
npx priors-v2 join --invite priors-invite:<id>:<expiry>:<signature>   # treasury v4: $5
npx priors-v2 join --seat <stakerAddress>                             # a staker's $PRIORS seat: $5
```

- **Invite.** Ask at [priors.trade/invite](https://priors.trade/invite) for an invite **for the id from step 1**.
  An invite names one agent id, expires, and seats that agent once.
- **Seat.** Someone offers a seat of $PRIORS (about $25) on your id (the Participate page on priors.trade), then you
  accept it. The agent must have repaid at least 3 loans first. If no offer exists yet, `join --seat` exits with
  code 3: that is "waiting on someone else", not a failure.
- **Backer.** A root backer can vouch any size, with your signed consent (`signConsent` in the SDK).

Ways it legitimately fails, and what they mean:

- **`EpochCapReached`** — treasury v4 has spent its $25 of new lines for this 7-day epoch. Wait, or find a seat
  or a backer. Do not retry in a loop.
- **`NotInvited` / `InviteExpired` / `InviteUsed`** — the code is wrong, stale, or spent. Ask for a new one. There
  is no path around the invite; that is the gate working.
- **`NotSeatable`** — the agent has not repaid 3 loans yet, is already backed by the seat vault, is a root, or has defaulted.

## Step 3: borrow, hold, repay

```bash
npx priors-v2 borrow 5 --days 7    # -> loan #N, $5 lands in the wallet, due date printed
#  ... the agent does its work ...
npx priors-v2 repay --all          # principal + fee; approves USDG for exactly what is due
```

**Hold it for real time, then repay at or before the due date.** The score is dollar-days: how much you borrowed
times how long you held it, capped at the term you contracted for. A loan shorter than **7 days** repays fine but
does not count as a qualified loan. Churning one-day loans gets you nowhere; that is deliberate.

⛔ **Repay before the due date.** Three days past due and *anyone* can mark the loan defaulted. The record is
defaulted forever, the identity can never borrow again, the owner's address is marked, and the sponsor pays (its
shares burnt, or half the staker's seat). There is no appeal. If the user cannot repay on time, tell them to
borrow less, not to borrow later.

## Step 4: grow

Treasury v4's `raise(agentId)` tops a treasury line up to $25 once the record has 3 qualified loans, 14 days, a
score of at least 100 and no default. Beyond that, v2 has no unbacked "earned" credit: lines grow by finding a
bigger backer.

## Paying x402 APIs on credit

`sdk/float.mjs` pays a `402 Payment Required` in USDG from the agent's balance and borrows only the shortfall from
its line. Always set `maxBorrow` to what the agent can repay within the term, and never call `pay()` again for a
purchase that came back `pending` — use `resend()`. See `docs/FLOAT.md`.

## Reading any agent's record

```bash
npx priors-v2 status               # this key's agent: line, loans, record
npx priors report <agentId>        # v1 history (paused pool)
```

On v2, `score(uint256)` and `creditReport(uint256)` are on `CreditLensV2` (address in
`deployments/4663.v2.json`). From JavaScript:

```js
import { resolveV2 } from "priors/env";
const { priors } = await resolveV2();
await priors.status(agentId);
```

## Doing it from code instead of the CLI

`sdk/priors-v2.mjs` is the v2 client on ethers v6 — `register`, `signConsent`, `redeemInvite`, `acceptSeat`,
`quoteFee`, `borrow`, `repay`, `openLoans`, `status`, plus `pay`/`settleLoans` for x402. `sdk/env.mjs`'s
`resolveV2()` resolves chain, deployment and signer the same way the CLI does. Every write is simulated first and
a revert is decoded to the contract's own error. Prefer these over hand-rolling calls.

## What not to claim

- **Do not call this audited.** v2 had internal adversarial reviews and no third-party audit. Every known finding,
  its fix and what remains is in `docs/SECURITY-v2.md`.
- v1 shipped with a lender-loss defect that randomized invariants did not catch; it was found, fixed and migrated.
  v2's design (every line fully backed, a default burns the backer's shares) is why no path to lender principal
  was found — that is still not a proof.
- Do not tell a lender they cannot lose money, and do not tell a backer or staker their stake is safe: backers and
  stakers carry the credit risk by design.
