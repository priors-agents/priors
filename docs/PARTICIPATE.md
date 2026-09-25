# Taking part in Priors v2: lenders, stakers, backers, agents

Pool v2 (`CreditPoolV2`), treasury v4 (`TreasurySponsorV4`) and the seat vault (`SeatVaultV3` since 2026-09-25, replacing `SeatVaultV2`) are **live on Robinhood
Chain mainnet** (chain 4663) since block 71,702,460. The v1 pool is paused; its record stays readable. Addresses are
in [`deployments/4663.v2.json`](../deployments/4663.v2.json), and the SDK and the `priors-v2` CLI read them from
there, so nothing below needs an address typed by hand.

The same actions are on the site: [priors.trade](https://priors.trade) has a Participate page (deposit, seats,
roots), [/agent](https://priors.trade/agent) and [/invite](https://priors.trade/invite).

| Who | How they take part | Entry point |
|---|---|---|
| Lender | Deposit USDG into the pool, earn the lenders' share of every fee, withdraw | Participate page · `PriorsV2.deposit/withdraw` |
| Staker | Put a seat of $PRIORS behind an agent; the seat vault backs it; earn the sponsor share of its fees | Participate page · `PriorsV2.offer/closeSeat/claimSeatFees` |
| Backer | Run a root: stake USDG, vouch for agents (with their owner's signed consent), earn sponsor fees | Participate page · `PriorsV2.enrollRoot/vouchWithConsent/claimSponsorFees` |
| Agent | Register, get a line (a treasury invite or a seat), borrow and repay, pay x402 APIs on credit | `priors-v2` CLI · `PriorsV2` · [FLOAT.md](FLOAT.md) |

## What changed from v1

**Every line is 100% backed, always.** v1 had *earned* capacity: unbacked credit a first-loss reserve paid for on
a default. Every hard v1 finding lived there, so v2 drops it, and recourse loans with it. Capacity comes only from
a backer's locked pool shares. A default burns the backer's shares worth the loan's principal plus its fee; the
share price never falls, and lenders never take a loan loss. The trade is that lines grow only by finding bigger
backers, never by reputation alone.

Other v2 changes:

- **Consent.** A line needs the agent owner's EIP-712 signature (domain `Priors Credit`, version `2`). Nobody can
  vouch for your agent against your will, which closes v1's squat.
- **Handoff.** An agent can move to another sponsor whenever no loan is open, so no sponsor is stuck forever.
- **Timelock.** The pool's owner is a 48 h `TimelockController` (the Safe proposes and executes, no admin). The
  Safe is the guardian: it can pause new risk for at most 14 days at a time, and exits never pause.
- **History carried.** Every v1 record was imported (`importFromV1`), so repayments, volume and enrolment date
  survive; lines do not, as with every migration.

## Launch parameters (read from the chain)

| | |
|---|---|
| Loan size · term | $5 – $500 · 1 – 30 days |
| Fee | 1% per 30 days, pro rata, plus the sponsor's premium (0 for treasury and seat lines; at most 2% per 30 days) |
| Fee split | 60% lenders · 25% sponsor · 15% reserve |
| Grace before anyone can mark a default | 3 days |
| Qualified loan (counts for the score) | term ≥ 7 days |
| `keeperBounty` | **0** (see [SECURITY-v2.md](SECURITY-v2.md), F-1) |
| `maxUtilizationBps` | **10000** (N-2) |
| Lender hold | 7 days; withdrawing sooner leaves 0.5% for the lenders who stayed |
| Minimum root stake | $10 |
| Treasury v4 (root #6228) | first line $5 · raise to $25 after 3 qualified loans, 14 days, score ≥ 100 · $25 of new lines per 7-day epoch · idle lines reclaimed after 30 days |
| Seats V3 (root #6234) | seat ≈ $25 of $PRIORS (12,000 on 2026-09-25, resized with the price) · line $5 · 50% of the seat burnt on a default · 10 open seats · $50 of new lines per 7-day epoch |
| Seat gates | the agent has repaid at least 3 loans; a seat idle 30 days can be expired by anyone |

`npx priors-v2 status` and the Participate page read these live; if this table and the chain disagree, the chain
is right.

## Agents: the `priors-v2` CLI

```bash
npm install
export PRIORS_KEY=0x…        # the agent owner's key: environment or .env only, never argv, never printed
npx priors-v2 join                       # registers an ERC-8004 identity for this key if it owns none, prints its id
npx priors-v2 join --invite <code>       # redeems a treasury v4 invite: first line opened
npx priors-v2 join --seat <staker>       # or accepts that staker's seat offer instead
npx priors-v2 borrow 5 --days 7
npx priors-v2 repay --all
npx priors-v2 status
```

- **An invite names one agent id**, so a new key runs `join` first, gets its id, asks for an invite at
  [priors.trade/invite](https://priors.trade/invite), then redeems it. Redeeming signs the pool consent for the
  treasury's root in the same call.
- **Addresses** come from `deployments/<chainId>.v2.json`; `PRIORS_ADDRESSES` points at another file.
  **RPC**: `PRIORS_RPC`, else `RPC_URL` (a comma-separated failover list, as for v1), else Robinhood Chain's
  official endpoint.
- **Identity lookup**: the key's identity minted since the v2 deploy is found automatically; an older one (for
  example a v1 agent) needs `PRIORS_AGENT_ID`.
- **Exit codes**: 0 done, 1 failed, 2 usage or configuration, 3 waiting on someone else (no seat offer yet).

⛔ **Repay before the due date.** Three days past due, anyone can mark the loan defaulted: the record is
permanently marked, the owner address is marked (`ownerDefaults`), and the sponsor's stake (or half the staker's
seat) pays for it. Borrow only what the agent can repay on time.

## SDK (`sdk/priors-v2.mjs`)

```js
import { resolveV2 } from "priors/env";            // chain, deployments/<chainId>.v2.json, PRIORS_KEY
const { priors: p } = await resolveV2();
// or by hand:
import PriorsV2 from "priors/v2";
const p2 = new PriorsV2({ signer, addresses });    // addresses = deployments/4663.v2.json
```

Amounts are USDG as a number or decimal string (`5`, `"12.5"`), or atomic 6-decimal units as a `bigint`.

- **Lender:** `deposit(amount)`, `withdraw(shares | "all")`, `position(addr)`.
- **Staker:** `offer(agentId)`, `withdrawOffer(agentId)`, `closeSeat(agentId)`, `claimSeatFees(to)`,
  `pendingSeatFees(addr)`, `seatable(id)`, `openSeats()`, `seatableAgents(ids)`.
- **Backer:** `enrollRoot(rootId, stake)`, `addStake(rootId, amount)`,
  `vouchWithConsent(sponsorId, agentId, line, premiumBps, consent, sig)`, `claimSponsorFees(sponsorId, to)`,
  `root(rootId)`.
- **Agent:** `register(uri)`, `signConsent({agentId, sponsorId, maxPremiumBps, deadline})`,
  `redeemInvite(agentId, code)`, `acceptSeat(agentId, staker)`, `quoteFee(agentId, amount, termSeconds)`,
  `borrow(agentId, amount, termSeconds, {to, maxFee})`, `repay(loanId)`, `openLoans(agentId)`, `status(agentId)`.
- **Float:** `pay(url, {agentId, maxBorrow, maxPrice?, termSeconds?, maxFee?})` and `settleLoans(agentId)`,
  see [FLOAT.md](FLOAT.md).

Every write is simulated first, so a revert is explained with the contract's own custom error before any gas is
spent. Approvals are for the exact amount. `borrow` passes the pool's own quote as `maxFee`, and `repay` binds the
loan's agent and amount, so a changed premium or a wrong loan id reverts instead of costing more.

**Reading records.** `CreditLensV2` exposes v1-shaped views on the v2 pool: `score(id)`, `creditReport(id)` and
`available(id)`. The v1 CLI (`npx priors score|report|loans`) still reads the v1 pool's history.

## Stakers: how a seat works

1. `offer(agentId)` escrows exactly one seat of $PRIORS under the vault's current terms. The offer is bound to
   the agent's owner at that moment (X-1 fix): if the identity is sold, the new owner cannot take it.
2. The agent's owner `accept`s it with a signed pool consent. The vault vouches the seat line out of its own USDG
   stake (the vault funder carries the credit risk; lenders never do).
3. While seated, the staker earns the sponsor share (25%) of every fee the agent pays, read exactly from the pool's
   per-agent ledger. `claimSeatFees` pays it out.
4. `closeSeat` (staker or agent) freezes the line; the seat closes, every token back, once no loan is open. A seat
   idle for 30 days (no loan open, no borrow or repay since it opened) can be `expire`d by anyone, tokens back to
   the staker (X-2 fix).
5. On a default, 50% of the seat is burnt and the rest returned.

An agent must have repaid at least 3 loans before it can be seated (X-3 gate). That gate filters trivial abuse; the
seat's market value is what makes a stolen $5 line a losing trade. See [SECURITY-v2.md](SECURITY-v2.md).

## Backers: running a root

`enrollRoot(rootId, stake)` turns an identity you own into a root with at least $10 of USDG locked as pool shares.
Locked shares earn lender yield like any other and back your lines 1:1. `vouchWithConsent` opens a line with the
agent owner's signed consent, optionally at a premium (at most 2% per 30 days) that you keep on top of the 25%
sponsor share. A default burns your shares worth the principal and the fee. `unlock` takes free backing out;
`retireRoot` ends a root that backs nothing.

## Deploying your own copy

`script/DeployV2.s.sol` deploys the set in order: a 48 h `TimelockController` (Safe as proposer and executor, no
admin) as the pool's owner, `CreditPoolV2` with the v1 pool's params plus `maxUtilizationBps` 10000 and
`keeperBounty` 0 (`PoolV2Lib` is linked by forge), `CreditLensV2`, treasury v4 and the seat vault. It refuses an EOA
as `SAFE` and writes `deployments/<chainId>.v2.json`.

```bash
V1=0x… USDG=0x… REGISTRY=0x… PRIORS=0x… SAFE=0x… PONS_ESCROW=0x… PONS_FACTORY=0x… FEE_SINK=0x… \
  forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast --private-key <deployer>
```

`CreditPoolV2` compiles with via-IR at `optimizer_runs = 1` (a per-file restriction in `foundry.toml`) to fit the
24 KB code limit.
