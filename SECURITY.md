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
| `src/CreditPoolV2.sol`, `src/libraries/PoolV2Lib.sol` | the v2 pool: lenders, roots and backing, consent, handoff, fee lock, defaults, the reserve |
| `src/CreditLensV2.sol` | the score and credit-report views |
| `src/TreasurySponsorV4.sol` | the rule-based treasury root: invites, raises, reclaims, sweeps |
| `src/SeatVaultV2.sol` | $PRIORS seats: offers, acceptance, burns, fees, expiry |
| `sdk/`, `bin/` | the SDK, the x402 float client and the CLIs, including anything that could sign or broadcast wrongly |
| The live v2 deployment | addresses are in `deployments/4663.v2.json` and the README's *Robinhood Chain* table |
| `priors.trade` and `facilitator.priors.trade` | the site and the x402 facilitator are in scope even though their source is not in this repo |

**Out of scope**

- **The v1 contracts** (`CreditPool`, `TreasurySponsor` v2/v3, `ReserveFunder`), including the v1 pool at
  `0x0259889e6EBab1a18CeE7e62Bc5B9648FB6C44e5`, paused since the v2 cutover, and the older pools before it.
  They are kept in this repo and in the README as history. Findings against them are interesting only where
  they also apply to v2 — say so explicitly if they do.
- The ERC-8004 identity registry at `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`. Not ours.
- Third-party RPC endpoints. Their rate limits and archive policies are their business; how this SDK
  copes with them is ours, and that part is in scope.
- Anything requiring a compromised owner key, a malicious chain reorg beyond finality, or control of the
  Safe. Key handling itself is in scope; assuming the keys are already stolen is not.
- Gas optimisation, style, and "best practice" with no exploit path. Send those as ordinary issues.

## Already known, already fixed

So nobody spends time on ground that is already covered, and so a rediscovery is not mistaken for a new
finding:

**v2:** [`docs/SECURITY-v2.md`](docs/SECURITY-v2.md) lists every finding from the pre- and post-launch reviews of the v2
set, with its severity, its fix or its accepted residual, and the test that shows it. In short: the self-backing
yield loop (N-1) is fixed by the fee lock, with one residual path around it (SO-1, holding stake only while
marking a default; yield only); the utilization freeze (N-2) by a 100% cap; the farmable keeper bounty
(F-1) is mitigated by setting it to 0; the seat vault's stale offers (X-1) and idle seats (X-2) are fixed; the
self-seat loop (X-3) is gated by repaid history and closed economically by the seat's market value; the treasury's
invite-to-raise path (T10) is bounded by its epoch cap. None of these reaches lender principal.

**v1** (now paused; kept for the record):

- **A defaulting root sponsor's earned credit was not retired**, letting backing be counted twice and
  leaving lenders exposed. Fixed in the live pool. The proof-of-concept is committed as a permanent
  regression guard in `test/ReviewPoC_RootEarnedDoubleSpend.t.sol`, so you can read exactly what it was
  and confirm it is closed.
- **A parameter-only mitigation for that same issue** is documented and tested in
  `test/BetaMitigationMinStake.t.sol`: raising `minStake` beyond an attacker's budget closes the only
  door into rootness without a redeploy. It is kept because it is the lever available in a hurry.
- **A dead root sponsor's stake was not charged for a defaulted child**, so the first-loss reserve paid
  instead and lender principal was destroyed. `markDefault` left the sponsor liable for nothing once it
  was already defaulted itself. Fixed: liability is now `!s.defaulted || (s.isRoot && s.stake > 0)`.
  Pinned by `test_aDeadRootsEarmarkedStakeIsSlashedForItsChild` and
  `test_withAnEmptyReserveTheDeadRootsStakeStillProtectsLenders` in `test/SponsorLiability.t.sol`.
- **The same defect had a second door, in `vouch`.** A dead sponsor's child could be taken over with a
  dust vouch, and the takeover branch zeroed `delegatedIn` while the child's loan was still drawn —
  collapsing a stake-backed claim to dust just before the default, which is strictly worse than the first
  path. Fixed with a `principalOut == 0` gate on takeover; an orphan with a live loan now waits for that
  loan to close. Pinned by `test_aTakeoverCannotVoidBackingForADrawnLoan`, and by
  `invariant_exposureWithinCapacity`, which is what caught it at depth 400 after the first fix looked
  complete.
- **A sponsor could withdraw delegation that was underwriting a live loan.** `unvouch` is now bounded by
  `delegatedIn - principalOut`. Pinned by `test_unvouchCannotReleaseDelegationBackingALiveLoan`.
- **A defaulted root's residual stake was stranded forever**, because `_capacity` returns 0 for a
  defaulted agent and `withdrawStake` measured against it. A settled defaulted agent that owes nothing
  and backs nothing can now recover it. Pinned by
  `test_aSettledDefaultedRootCanRecoverItsResidualStake` and its negative case.

All four were live on v1 as of the 2026-09-21 cutover. Because these contracts are not upgradeable, "fixed in
`src/`" and "fixed on chain" are different claims with a migration between them, and for about ten hours
they were not the same thing here — see **Credits**. `scripts/verify-migration.mjs` checks the deployed
runtime bytecode against the compiled artifact, so you can confirm which one you are looking at rather
than trusting this file.

An independent rediscovery of a fixed issue is still worth telling us about, and we will say so and
credit the work. It is not a new finding.

## Credits

People who have found something real, or told us something we needed to hear.

- **llen** (`@yossweh`) — GHSA-4j38-23rc-qmv9, 2026-09-20. Reported that the dead-root accounting defect
  and its `vouch` takeover variant were still present in the **deployed** bytecode, with two
  proof-of-concepts executed against the live contract and the live USDG at a fork anchor. We had found
  and fixed both in `src/` about an hour earlier — the advisory cites our own `d2f0019` and `fb1a0e5` as
  the patched versions — so this was not a new defect. It was something more useful and easier to miss: a
  published fix is not a deployed fix, and for ten hours the live pool ran pre-fix code with real deposits
  behind it while the repository looked patched. The report is the reason the cutover was not left to
  drift. Also correctly flagged that `deposit` reverts `ZeroAmount` for an amount smaller than one share
  once the share price passes 1:1 (see below), and proposed a stronger invariant than the two we had:
  assert that a defaulted root's stake is either charged or explicitly released, never left where
  `withdrawStake` reverts forever.

**Not fixed, deliberately:** the `ZeroAmount` revert on a sub-share deposit. `convertToShares` rounds
down, in the pool's favour, which is the correct direction for an ERC-4626-style vault; the effect is that
the smallest depositable amount becomes one share's worth rather than one unit. It cannot be aimed at a
third party and it costs nothing but a retry, so it stays. Reported for completeness and recorded here so
it is not re-reported as new.

## Rewards

**There is a bounty programme now: [BOUNTY.md](BOUNTY.md).** It says what each severity is worth, which
addresses are in scope, and what is explicitly not.

This page used to say there was no programme and nothing was promised. That was the honest position while
nothing was funded; it is no longer the position. Two things carried over from it unchanged, because they
were right: the ceiling is small and stated in public rather than implied, and a report still gets a
straight answer, a fix, and public credit whether or not it pays. Do not make disclosure conditional on a
figure we have not agreed to — we will decline, and fix it anyway.

## Please test on a fork

The live v2 pool holds real deposits. Reproduce against a local Anvil fork or a testnet deployment, never
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
credit line, and claim every unclaimed sponsor fee. On v2 that is still true of roots' stake and open lines,
while lenders' deposits stay whole (`test_X5_registryUpgradeAdminTakesEveryRootStake`).

Findings *in* that registry are out of scope because we cannot fix them. Findings about **how this pool
trusts it** are very much in scope, and we would rather hear them.

The levers we do hold, and how fast they move:

- **Fast:** the pool's guardian (the 2-of-3 Safe) can `pause` new risk for at most 14 days at a time; exits
  never pause. The Safe owns treasury v4 (`setRules`, `setInviter`, `freeze`, `retire`) and the seat vault
  (`setParams`, `setGates`, `pauseSeats`, `retire`) directly, so those need two signatures and no delay.
- **Slow on purpose:** the pool's owner is a 48-hour `TimelockController` (the Safe proposes and executes, no
  admin). `setParams`, `withdrawReserve` and the other owner calls are visible on chain for two days before they
  can run. No owner call reaches lender deposits or a backer's locked shares.

Expect a pause first and a migration later.
