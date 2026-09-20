# Security

This pool lends real money to agents with no collateral. A bug here costs lenders their deposits, so a
report is welcome even if you are not sure it is exploitable.

## Reporting

**Use GitHub's private vulnerability reporting** — the *Report a vulnerability* button under this repo's
**Security** tab. It is private, it timestamps your report, and it keeps the thread in one place.

If that button is not available to you, open a public issue that says only that you have something and
asks for a channel. **Do not put details in a public issue.** We will answer with somewhere private to
send them.

We do not publish an email address for this, because an address nobody watches is worse than none.

## What makes a report actionable

You do not need to write a report before you hear from us. But the more of this you can say up front,
the faster it moves — and none of it requires exposing an exploit:

- **Which function**, in which contract, at which address or commit.
- **What an attacker gets**: whose money, how much, under what preconditions.
- **A test or a trace.** This repo is Foundry — a failing `forge test` against `src/` is the clearest
  thing you can send. A fork PoC is just as good.
- **Whether it applies to the live deployment** or only to an older one.

If you would rather not share specifics before agreeing terms, we understand — but please at least name
the affected function and your own severity assessment. We cannot evaluate, prioritise, or credit
"a few real issues" with no category attached.

## What we commit to

- An acknowledgement within **3 working days**.
- An assessment — confirmed, not reproducible, or out of scope, with reasoning — within **14 days**.
- Credit in the fix commit and release notes, under whatever name or handle you choose, unless you ask
  us not to.
- We will tell you plainly if we think you are wrong, and why. We would rather argue than go quiet.

## Scope

**In scope**

| | |
|---|---|
| `src/CreditPool.sol` | credit lines, the sponsor tree, the default waterfall, the reserve |
| `src/TreasurySponsor.sol` | the rule-based treasury sponsor |
| `src/ReserveFunder.sol` | creator-fee sweep into the reserve |
| `sdk/`, `bin/priors.mjs` | the SDK and CLI agents run, including anything that could sign or broadcast wrongly |
| The live deployment | addresses are listed in the README's *Robinhood Chain mainnet* table |
| `priors.trade` | the site is in scope even though its source is not in this repo |

**Out of scope**

- **The superseded pool** at `0xd970472b2904D5923882af034cea4067AF0AaC95`. It is paused and drained, and
  it is listed in the README only so an old link is recognisable as dead. Findings against it are
  interesting only where they also apply to the live pool — say so explicitly if they do.
- The ERC-8004 identity registry at `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`. Not ours.
- Third-party RPC endpoints. Their rate limits and archive policies are their business; how this SDK
  copes with them is ours, and that part is in scope.
- Anything requiring a compromised owner key, a malicious chain reorg beyond finality, or control of the
  Safe. Key handling itself is in scope; assuming the keys are already stolen is not.
- Gas optimisation, style, and "best practice" with no exploit path. Send those as ordinary issues.

## Already known, already fixed

So nobody spends time on ground that is already covered, and so a rediscovery is not mistaken for a new
finding:

- **A defaulting root sponsor's earned credit was not retired**, letting backing be counted twice and
  leaving lenders exposed. Fixed in the live pool. The proof-of-concept is committed as a permanent
  regression guard in `test/ReviewPoC_RootEarnedDoubleSpend.t.sol`, so you can read exactly what it was
  and confirm it is closed.
- **A parameter-only mitigation for that same issue** is documented and tested in
  `test/BetaMitigationMinStake.t.sol`: raising `minStake` beyond an attacker's budget closes the only
  door into rootness without a redeploy. It is kept because it is the lever available in a hurry.

An independent rediscovery of a fixed issue is still worth telling us about, and we will say so and
credit the work. It is not a new finding.

## Rewards

**There is no bounty programme, and no payment is promised.** This is a beta protocol, and we are not
going to advertise a reward we cannot guarantee. What you will get is a straight answer, a fix, and
public credit.

If a report is serious enough that we think it warrants more than that, we will raise it ourselves. Do
not make disclosure conditional on a figure we have not agreed to — we will decline, and fix it anyway.

## Please test on a fork

The live pool holds real deposits. Reproduce against a local Anvil fork or a testnet deployment, never
against mainnet:

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com
```

We will not pursue anyone for good-faith research that stays within this scope, tests on a fork, avoids
touching other people's funds or data, and gives us a reasonable chance to fix things before going
public. Draining the live pool to prove a point is not good-faith research.

## One thing worth knowing before you report

**Our own contracts are not upgradeable.** No proxy, no initialiser, no admin hatch in anything under
`src/`. Fixing a real bug there means deploying a new pool and migrating state, which has been done once
and is not cheap — so a confirmed finding may take longer to close than a proxy-based protocol would
need. The delay is the architecture, not us ignoring you.

**The identity registry we depend on is a different story, and an earlier version of this file was
misleading about it.** `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` is not ours and it is **not
immutable**: 130 bytes of code, an EIP-1967 implementation pointer, an empty admin slot — a UUPS proxy —
and `owner()` is `0x547289319C3e6aedB179C0b8e8aF0B5ACd062603`, an address with **no code at all**. A
single ordinary key can change what that registry says about who owns which agent, and this pool
believes the registry completely. Whoever holds it could withdraw every root's stake, draw every open
credit line, and claim every unclaimed sponsor fee.

Findings *in* that registry are out of scope because we cannot fix them. Findings about **how this pool
trusts it** are very much in scope, and we would rather hear them.

The levers we do hold, and that move quickly: `setParams` and `pause` on the pool, and `setRules`,
`retire` and `setFeeSink` on the TreasurySponsor — all owner-only, so all needing two signatures on the
2-of-3 Safe. Expect a pause first and a migration later.
