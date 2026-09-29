# Priors Score v2

*2026-09-26, audited the same day (findings F1-F21 fixed below). Live since 2026-09-27: see "Where to read it".
In this repo: the scoring engine (`sdk/score-v2.mjs`), its inputs (`sdk/score-v2-inputs.mjs`), the weights
(`sdk/score-weights.v2.json`; 2.0.1 in `sdk/score-weights.v2.0.1.json`), x402 income read from the chain
(`sdk/x402-income.mjs`) and the tests (`scripts/test-score-v2.mjs`, `scripts/test-x402-income.mjs`,
`scripts/test-stocks.mjs`). Priors' clusters list is not published (see
"Clusters").*

## Why a v2

The on-chain score (`src/libraries/ScoreLib.sol`, "v1") has the right idea: every point costs money held at risk
for real time. An audit (2026-09-26) found what it can't see:

- **whose risk it was.** v1 counts a loan backed by the agent's own owner the same as one backed by a stranger;
- **lateness.** A loan repaid in the grace period counts like one repaid on time;
- **history.** Age resets at each migration, and a sold agent keeps its record;
- **income.** The next input (`docs/SCORE-x402.md`) has nowhere to go.

## Two layers

| layer | what | changes how | used by |
|---|---|---|---|
| **v1, on chain** | `ScoreLib`: simple, conservative | a new pool version, behind the 48 h timelock | contracts: treasury rules, seat gates |
| **v2, open and deterministic** | `scoreV2()`: a pure function of public data, with published weights | a new weights file and version, announced first (below) | people and apps: site, API, MCP; later attested on chain |

v2 moves fast and in the open; v1 stays the hard floor the contracts rely on. When a v2 component has proven itself
on data, it moves into the next on-chain version.

## The score (v2.0.0, max 1000)

| component | max | counts |
|---|---|---|
| **risk time** | 300 | USDG **someone else** put at risk × days actually held (capped at the term), on loans repaid on time. 1 point per 10 USDG-days. A loan the agent repaid from x402 income counts up to 25% more, in proportion to the share of it that counted income paid (income weighted like the income component, at most 20 USDG per payer per loan, each payment spent once). |
| **seasoned loans** | 200 | loans held 7+ days and repaid on time, backed by someone else. 20 each for a loan of 50 USDG or more; a smaller one counts in proportion (a 5 USDG loan: 2). |
| **backing** | 150 | money another party has at risk behind the agent now. 1 point per 5 USDG. |
| **age** | 100 | days since the agent's first loan on Priors, v1 included (an agent that never borrowed has none); restarts when the agent changes hands. |
| **recourse** | 100 | debts of vouched agents it paid itself. 50 each; dropped when the agent changes hands. |
| **income** | 150 | x402 payments (signed USDG, from any facilitator) to the agent's declared payment wallet from payers that aren't its own, last 30 days, net of anything the agent's side sent that payer. A payer counts once it has paid 1 USDG in the window; each payer is capped at 20 USDG and weighted by its own score (unknown wallets at half weight); plus 5 points per payer, up to 50. A payment to a wallet several agents declared is shared between them. |
| penalties | | −10 per late repayment (and it earns nothing); −75 per vouched agent that defaulted |
| **default** | | the score is 0, and so is every other agent of the wallet that defaulted: the loan's owner when it was taken, and the defaulted agent's declared payment wallet. Sending a defaulted agent to someone never harms them. (A v1 default, with no owner recorded, zeroes only the agent itself.) |

**Backers.** A loan is "backed by someone else" when its backer is another owner's agent that had been enrolled on
Priors for **30+ days** when the loan was issued (the protocol's treasury and seat vaults, V3 and the growth seat vault
V4, public ids in the snapshot, count from day one). A backer the record doesn't know counts as the agent's own. v1
loans take their backer from the repayment's `FeeSplit` event, not from today's sponsor. The same rule applies to
backing held now.

**Rungs** (the record side of the trust ladder): 0 unproven · 1 started (one repayment backed by
someone else) · 2 proven (3+, over 14+ days, none late) · 3 earned (proven, a record score of 300+ with income left
out, and 30+ days since the first backed loan) · 4 income-backed (earned, income 50+ from 3+ payers of 1 USDG or more).
Income can add points, but it can't lift a thin record to "earned". Every threshold is in the weights file.

Every result explains itself: the score, the rung, each component with its points and reason, penalties, and the
raw details (USDG-days, loans, payers).

## Clusters

A loan counts only if its backer is under **different control** from the borrower, and income only from payers that
aren't. An agent's cluster joins its owner, the payment wallet it declared in the ERC-8004 registry
(`getAgentWallet`: the wallet signs to accept it, so it is provably the same party), every agent and wallet linked
through those, and the links of Priors' clusters list: agents and wallets known to be under common control. That list
is **not published**, so a score that depends on it cannot be recomputed exactly from this repo alone (the engine takes
it as `links`; without it, only the on-chain links above apply). An agent backed by its owner's own root builds
nothing. Clusters shape the computation only; no output names them.

Next (v2.1): wallets funded from the same source, or paying each other's gas, join one cluster (`makeClusters` in
`score-v2-inputs.mjs` is the seam).

## How x402 income is read

An x402 `exact` payment in USDG is an EIP-3009 `transferWithAuthorization`: the payer signs, a facilitator submits,
and USDG emits `AuthorizationUsed(payer, nonce)` followed by `Transfer(payer, payTo, amount)`. `sdk/x402-income.mjs`
reads those two events from the chain, so every facilitator counts, not only Priors'. Signed USDG payments are common
on Robinhood Chain (apps move large amounts this way), so the scan lists the authorizations first and then asks only
for the transfers from those payers to agent wallets; the transfer must be the log right after its authorization.

- **Whose income.** A payment counts for the agents that declared the paid wallet as their payment wallet in the
  ERC-8004 registry. The registry sets it to the owner at registration, clears it when the agent changes hands, and
  changes it only with the wallet's signature, so agents sent to someone's address can't take a share of its income.
  A wallet that can't be read holds the scores back until it is read: a declared wallet links clusters, so scores are
  never published without one.
- **Netted.** USDG that any wallet of the agent's cluster sent to a payer (before or after, whole chain) is taken off
  that payer's payments: money that goes back where it came from is not income.
- **No dust.** A payer counts once it has paid 1 USDG in the window. Below that it adds nothing and costs no scan.
- **New payers wait, nobody else does.** A new payer's netting is read from the start of the chain on its own; until
  then its payments wait. Everyone else's scores keep publishing.
- **Repaid from income.** A loan that counts (backed by someone else, repaid on time by the agent's own wallets, since
  its last change of hands) and was repaid while counted income arrived is marked repaid from income, in proportion.
  Income is weighted like the income component, capped at 20 USDG per payer per loan, and each payment is spent once.
- **Kept for a year.** Payments are kept 365 days (less only if the index must shrink to fit its store); a loan's
  bonus comes from income inside that window. Income is read from pool v2's launch block on, which is when x402
  started on Robinhood Chain. Each published result names how its index was read (`index`: blocks, retention).
- **Not seen yet.** Gas funding in native ETH (no log), x402 through Permit2 instead of EIP-3009, payments to a wallet
  the agent hasn't declared, and a payer funded through an intermediary wallet (v2.1, funding-source clusters).

## How people will try to game it, and what stops them

| attack | stopped by |
|---|---|
| flip hundreds of small loans | risk time counts USDG × days: 300 half-hour loans of 8 USDG earn under 10 points (flips of hundreds of USDG do add up, but that money is really at risk, and flips never make seasoned loans) |
| many tiny week-long loans | a seasoned loan counts by size: ten 1 USDG loans are worth 4 points, not 200 |
| back yourself | loans backed by your own owner count for nothing |
| back yourself from a fresh second wallet, or buy an aged backer id | a backer counts only after 30 days on Priors, counted from when its current owner took the id (registry transfers); v2.1 adds funding-source clusters |
| pay yourself to fake income | payers in your cluster (owner, declared wallet, linked agents) are excluded; each payer is capped; unknown payers count half |
| fund a second wallet, then have it pay you | what your side sent that wallet directly is netted out of its payments; funding it through an intermediary is not caught yet (v2.1) |
| round-trip the same money | what goes straight back to the payer doesn't count; a round trip through a third wallet is v2.1 |
| send a defaulted agent to an honest owner | harmless: a default spreads only to the wallet that defaulted |
| push agents onto someone's address to dilute their income | only agents that declared the wallet share it, and a pushed agent's declaration is cleared by the registry |
| spam new tiny payers to stall the index | payers under 1 USDG are ignored, and new payers never hold other scores back |
| buy a loan's bonus with one big payment | at most 20 USDG per payer per loan, unknown payers at half weight |
| sock-puppet payers funded elsewhere | per-payer cap; unknown payers at half weight; breadth only from payers of 1 USDG+; the income rung also needs a 30-day earned record; v2.1 funding-source clusters |
| claim someone else's payments | only the agent's owner and a wallet that signed to be its payment wallet count |
| climb fast | rungs need time: proven needs 14+ days of backed repayments, earned 30+ days since the first |
| buy an aged agent | a change of hands restarts age, record and recourse |
| gift your root to a borrower's owner | makes them one party, so the borrower's backed record stops counting; it costs the gifted stake and is undone by moving the root away |
| repay late but eventually | late loans earn nothing and cost 10 points |
| behave, then take a big line and vanish | one default = 0 for that owner's agents; lines follow rungs, and rungs need time |

## What the live record shows (2026-09-26)

Over the live record (income read from the chain): 133 agents, v2 max 5 (age only), **no agent above
rung 0**. Quick round-trip loans build nothing, by design; the record builds from loans backed by someone else, held
for real time. On income: one signed USDG payment has reached an agent's wallets since pool v2, and it is netted out
(the agent's side had sent that payer USDG). No agent earns x402 income yet; the first real client payments will be
the first income points.

Scores are computed by Priors from public data: the on-chain record and x402 payments on Robinhood Chain.

## Where to read it

Live since 2026-09-27:

- `GET https://priors.trade/api/score-v2` (every agent; `?agent=<id>` for one): recomputed at most every 10 minutes;
  a result older than an hour is not served. Free.
- The paid API (`api.priors.trade`, x402): `/v1/score/:id` adds `v2` with the breakdown.
- The hosted MCP (`mcp.priors.trade`) and the npm `@priors/mcp` (0.1.7 and later): `score_of` adds the v2 line.

When a v2 result is not available, each of them answers without it (`v2: null`) rather than failing.

## Changing it (future intervention)

- **Versioned.** The weights file carries a version. A change is a new weights file with its own version, a line in
  the changelog below, and a note on X at least **7 days before** it becomes the default. Old versions stay in the
  repo, so any past score can be recomputed.
- **Pinned outputs.** Every published score names its version; apps can pin a version. The engine computes with
  the version it is given (`weightsFor` in `sdk/score-v2.mjs`; 2.0.0 when none is given).
- **No hidden levers.** No per-agent overrides. Protecting the pool from a bad actor uses the existing on-chain tools
  (freeze, pause), which are public events.
- **The clusters list changes only by commit** (in Priors' own repository; it is not published).

## Rollout

| phase | what | status |
|---|---|---|
| 1 | engine, weights, clusters, tests | **done** |
| 2 | show it: API (`/v1/score` adds `v2` with the breakdown), MCP `score_of` (hosted and npm), agent page (breakdown and rung; every agent shown the same way) | **live** 2026-09-27 (API, MCP); the agent page with the next site deploy |
| 4 | income from any facilitator (USDG `AuthorizationUsed` events), declared payment wallets, netting, loans repaid from income | **built** (with phase 2) |
| 4b | v2.1: funding-source clusters (gas and first USDG), payer graph weights, Permit2 x402 | after launch |
| 5 | on chain: attest v2 scores to the ERC-8004 reputation registry with version and input hash; treasury rules read the rung from a signed attestation; stable components move into the next `ScoreLib` | after a month of data |

## Changelog

- **inputs, 2026-09-29** (all versions): a backer's 30 days count from when its current owner took the id, read
  from the identity registry's transfers, not from its enrolment: a bought aged id is a new backer (private report
  GHSA-6f8j). No published score changed: no backer id had changed hands after enrolling.
- **2.0.1** (2026-09-28): a loan backed by the stock vault's root (`meta.stockVaultAgentId`) counts as the borrower's
  own money, since its own tokens stand behind it, not as someone else's risk (`sdk/score-weights.v2.0.1.json`,
  `backers.ownCollateralRoots`; found by the stocks readiness review of 2026-09-28). No weight changes. A
  self-collateralised agent at day 30 scores 29 under it, 519 under 2.0.0. 2.0.0 stays the engine's default (the
  version `weightsFor` returns when none is named) until 2.0.1's note on X, 7 days ahead. While the stock vault is
  live, Priors publishes v2 scores under 2.0.1 only: 2.0.0 scores (or any score while the vault's agent is unknown)
  are withheld rather than published inflated.
- **2.0.0** (2026-09-26): first version, never published before the audit fixes were folded in: seasoned loans
  weighted by size; backers need 30 days on Priors (or are the protocol's treasury or seat vault) and unknown ones
  fail closed; v1 backers from `FeeSplit`; rungs 2 and 3 need 14 and 30 days; dust payers add no breadth; income
  shared across an owner's agents; a default zeroes the owner's other agents; a change of hands is read from the
  loans' owner and drops recourse; age from the first loan; inputs validated, `now` required, risk time summed as an
  integer. Then x402 income from the chain, whoever settled it; clusters joined through declared payment wallets;
  money sent back to a payer netted out; loans repaid from income earn up to 25% more risk time; unreadable loans
  and ownerless agents fail closed. Then the income audit: a default spreads only to the wallet that defaulted
  (never to whoever is sent the NFT); income matched on declared wallets only; the earned rung judged on the record
  without income; the loan bonus weighted, capped per payer and spent only on loans that count; payers under 1 USDG
  ignored; new payers and wallets backfilled on their own; a failed wallet read keeps the wallet known before; hard
  time limits; stale scores not served.
