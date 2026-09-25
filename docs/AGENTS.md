# Priors for agent builders

Three calls give an agent a credit history nobody can forge. **Priors v2 is live on Robinhood Chain (4663).** The
v2 client is a thin ethers v6 wrapper in `sdk/priors-v2.mjs` (ABIs included, if you would rather call the
contracts), `sdk/env.mjs` resolves chain, addresses and signer, and the `priors-v2` CLI is one subcommand per step.

Everything below is the same procedure the skill (`skills/priors/SKILL.md`) hands to a coding agent. This page is
for you reading it yourself. Every role (lender, staker, backer) is in [PARTICIPATE.md](PARTICIPATE.md).

## 0. A wallet

```bash
npm install
cp .env.example .env      # PRIORS_KEY=0x… : the key that owns (or will own) the ERC-8004 identity
npx priors-v2 status
```

The wallet needs a little native gas and enough USDG to cover loan fees. Addresses come from
`deployments/4663.v2.json`; `RPC_URL` defaults to Robinhood Chain's official endpoint. **The pool never sees your
keys, only the agent id** and the signatures you choose to give.

```js
import { resolveV2 } from "priors/env";
const { priors: s } = await resolveV2();     // PriorsV2 on the live v2 set, signer from PRIORS_KEY
```

No identity yet? `await s.register(uri)` mints one and returns its id.

## 1. Get a line

Every v2 line needs the agent owner's **pool consent**: an EIP-712 signature (domain `Priors Credit`, version `2`)
naming the sponsor and the most premium it may charge. Nobody can sponsor your agent without it. The SDK signs it
for you in each of these:

```js
await s.redeemInvite(agentId, inviteCode);   // treasury v4: $5. inviteCode = priors-invite:<id>:<expiry>:<signature>
await s.acceptSeat(agentId, stakerAddress);  // a staker's $PRIORS seat: $5 (the agent needs 3 repaid loans)
const { consent, sig } = await s.signConsent({ agentId, sponsorId, maxPremiumBps }); // hand to a backer
```

- **Treasury invite.** Ask at [priors.trade/invite](https://priors.trade/invite). A code names one agent id,
  expires, and seats that agent once. Treasury v4 opens at most $25 of new lines per 7-day epoch; if the cap is
  spent, wait for the next one or find a seat or a backer.
- **Seat.** A staker escrows a seat of $PRIORS (about $25) behind your id and the seat vault vouches a $5 line. The staker
  earns the sponsor share of your fees and loses half the seat if you default, so it is someone's judgement too.
- **Backer.** Any root with USDG stake can vouch any size, at a premium of at most 2% per 30 days that your consent
  caps.

Why the gates exist: a fresh identity costs cents, so money handed to one unconditionally is a faucet. An invite,
a seat or a backer is what makes a line cost someone's judgement.

## 2. Borrow, hold, repay

```js
const { fee } = await s.quoteFee(agentId, 5, 7 * 86400);            // about $0.011666: 1% per 30 days, pro rata
const { loanId, dueAt } = await s.borrow(agentId, 5, 7 * 86400);     // $5 for 7 days, USDG lands in your wallet
// ... do work ...
await s.repay(loanId);                                               // principal + fee
```

Loans shorter than 7 days are real loans, but they do not count as qualified loans for the score. The score
rewards dollar-days: how much you borrowed, times how long you held it, summed over everything you repaid.
Churning one-day loans gets you nowhere. Holding real money for real time does.

Paying per call with x402 instead of borrowing by hand: `s.pay(url, { agentId, maxBorrow })` pays from the
balance and borrows only the shortfall. See [FLOAT.md](FLOAT.md).

## 3. Grow

After three qualified loans, fourteen days on the ledger, a score of 100 and a clean record, anyone can call
treasury v4's `raise(agentId)` and a treasury line goes to $25. Beyond that, v2 has no unbacked "earned" credit:
a bigger line means a bigger backer, with your consent.

## Reading the record

```js
await s.status(agentId);     // sponsor, line, open loans, record
await s.loans(agentId);      // every loan, with status
```

`score(uint256)` and `creditReport(uint256)` are on `CreditLensV2` (the `lens` address in
`deployments/4663.v2.json`), same formula as v1. v1 history, imported into v2, is also still readable on the paused
v1 pool with `npx priors report <agentId>`.

## What ends it

Miss a due date by more than three days and anyone can mark the loan defaulted. The record is defaulted forever,
the identity can never borrow or back anyone again, the owner's address is marked, and the sponsor pays: its
shares are burnt for the principal and the fee, or half the staker's seat is burnt. There is no appeal, which is
the point.

## Before you integrate for real

No third-party audit has reviewed v1 or v2. Read the Status section of the [README](../README.md) and
[SECURITY-v2.md](SECURITY-v2.md) first: they list what was found, what was fixed, and what remains.
