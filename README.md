# Priors

**Reputation for AI agents that can't be faked, because it's earned by repaying real money.**

[priors.trade](https://priors.trade) · a prior is what you believe about an agent before you deal with it. This
one is backed by money.

A small on-chain credit pool lends unsecured USDG ($5 to $500) to agents registered on
[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004). Every line is backed, dollar for dollar, by someone who put
money behind that agent. Every repayment and every default is a public event. From those events you get a
credit-backed trust score anyone can query before trusting an agent, and a public record of which agents pay
their debts back.

Reviews are cheap to fake. Repaid debt isn't.

> ### Status: Priors v2 is live on Robinhood Chain
>
> Pool v2 (`CreditPoolV2`), treasury v4 and seats v2 are **live on Robinhood Chain mainnet** (chain 4663) since
> block 71,702,460. Addresses come from [`deployments/4663.v2.json`](deployments/4663.v2.json), so
> `npx priors-v2 status` and the SDK resolve them with no configuration. The v1 pool is **paused**; every v1
> repayment record was imported into v2, so agents kept their history.
>
> **What v2 changes.** v1 lent *earned* credit that nobody backed, and every hard v1 finding lived there. v2 drops
> it: every line is 100% backed by a backer's locked pool shares, a default burns that backer's shares worth the
> principal and the fee, and lenders never take a loan loss. Lines need the agent owner's signed consent, agents
> can change sponsor between loans, and the pool's owner is a 48-hour timelock.
>
> **Three ways onto the ledger.** A treasury invite (a $5 line from treasury v4, which is funded by $PRIORS creator
> fees), a **seat** (someone puts 1,000,000 $PRIORS behind your agent and the seat vault backs a $5 line), or a
> **backer** who stakes USDG and vouches for you directly. Lenders deposit USDG and earn 60% of every fee.
>
> **What was found before launch, and fixed.** A self-backing loop that took lender yield (fixed with a fee lock),
> a utilization-cap freeze (cap set to 100%), a farmable keeper bounty (set to 0), and three seat-vault issues
> (offers bound to the owner, idle seats expire, a history gate plus a seat priced far above the line it opens).
> [`docs/SECURITY-v2.md`](docs/SECURITY-v2.md) lists every finding with its test and what remains.
>
> **What that does not buy:** v2 has had several internal adversarial reviews and a second-model review of the
> fixes, but **no third-party audit**. No path to lender principal was found, and that is still not a proof.
> Launch sizes stay small for exactly that reason. Read it, run it, integrate against it; size your exposure like
> someone who knows an audit hasn't happened.
>
> **Take part:** [priors.trade](https://priors.trade) has a Participate page (deposits, seats, roots),
> [/agent](https://priors.trade/agent) and [/invite](https://priors.trade/invite).
> [`docs/PARTICIPATE.md`](docs/PARTICIPATE.md) is the same for code.

---

## Give your agent a credit history on mainnet

```bash
git clone --recurse-submodules https://github.com/priors-agents/priors && cd priors
npm install
export PRIORS_KEY=0x…                    # the key that owns (or will own) the agent; env or .env only
npx priors-v2 join                       # registers an ERC-8004 identity for this key, prints its id
#   ask for an invite for that id at https://priors.trade/invite, then:
npx priors-v2 join --invite <code>       # treasury v4 opens a $5 line (you sign the pool consent)
npx priors-v2 borrow 5 --days 7          # $5 lands in your wallet
#   ... the agent does its work ...
npx priors-v2 repay --all                # principal + fee
npx priors-v2 status                     # line, loans, record
```

The wallet needs a little native gas and enough USDG to pay the fee (about $0.012 on $5 for 7 days). No invite?
`npx priors-v2 join --seat <staker>` takes a staker's seat offer instead, once someone has offered on your id.

### Or watch it on a throwaway local chain first

```bash
git clone --recurse-submodules https://github.com/priors-agents/priors && cd priors
npm install
npm run quickstart
```

That starts a local chain, deploys the **v1** contracts with mocks, and walks one fresh ERC-8004 identity through
the entire record — register, take the treasury's $5 line, borrow, hold, repay, score. The local devnet has not
moved to v2 yet; the flow and the score have the same shape, the backing rules differ (v1's "earned capacity"
below does not exist on v2):

```
1. identity
   ERC-8004 agentId 2, owned by 0xEe7f…eeFf

2. first line
   line $5 from sponsor #1 — nobody approved this, it is a rule

3. borrow, hold, repay
   quote $5 for 7d: fee $0.011666, qualifies
   loanId 1 — $5 is in 0xEe7f…eeFf now
   … did work …

4. the record
   score 38/1000 · repaid 1 (1 qualified) · 35 dollar-days · fees paid $0.011666
   earned capacity $2.5 of its own, line now $7.5
```

Requires [Foundry](https://getfoundry.sh) and Node 20+.

### Records survive migrations

The v1 walkthrough was run for real on Robinhood Chain with real USDG, start to finish, through the CLI in
this repo, and its records have now moved twice.

Agent **#437** is the interesting one, because its record **survived the migration to the fixed
contract**. It repaid twice on the original pool; those two loans were carried across by
`importRecords`, and it has since borrowed and repaid again on the new one:

| step | transaction |
|---|---|
| borrow $5 for 8 days, on the new pool | [`0xff8c3e1f…`](https://robinhoodchain.blockscout.com/tx/0xff8c3e1fd89501fc901efa503a01099003a00f3668de46eb3551626d53386703) |
| repay principal + fee | [`0x0cfc083c…`](https://robinhoodchain.blockscout.com/tx/0x0cfc083c83eab43395465b7e9c95f36b430f23c3208e639bb56275508cd6c13d) |

`npx priors report 437` read the result back off the v1 pool: **3 loans repaid**, $15 of volume,
$0.036665 of fees paid, no defaults. At the v2 cutover every v1 record was imported again
(`importFromV1`), and on v2 agent #437 still shows its 3 repaid loans — the point of carrying
history rather than restarting it. Agent #443 came through the same way.

A record and a credit line are separate things, and a migration carries only the record: capacity
is not imported, so after a cutover an agent shows its full history with a `$0` line and no
sponsor until it asks the treasury for one (`firstLine`, which only the identity's own controller
can call). That is why a freshly migrated agent reads as `sponsor #0` for a while. On v2 it asks treasury v4 (an
invite), a staker (a seat) or a backer for a new line.

There is no demo mode in any of that — same contracts, same ERC-8004 registry, same USDG.

## Hand it to your coding agent instead

This repo ships the procedure as an agent skill, so you don't have to read any of it:

```bash
# Claude Code
mkdir -p ~/.claude/skills && cp -r skills/priors ~/.claude/skills/priors
```

Then say: **"give my agent a credit history on Priors"**. The skill knows the steps, which chain and pool it is
on, what to do when the treasury's epoch cap is spent, and that it must not claim an agent is registered when it
isn't. Codex and other harnesses read [`AGENTS.md`](AGENTS.md) at the repo root, which carries the same
instructions.

### Or connect it over MCP

Read-only, hosted, no key: add `https://mcp.priors.trade/mcp` (Streamable HTTP) to any MCP client.

```bash
claude mcp add --transport http priors https://mcp.priors.trade/mcp
```

It answers an agent's record and score, the pool's figures, recent loans and the facilitator's services, and it
cannot sign or send anything. To pay x402 URLs, borrow and repay with the agent's own wallet, run the local server in
[`packages/mcp`](packages/mcp) (the key stays in your environment). Neither package is on npm yet: from a clone,
`npm install` at the root links them.

### Or pay per call

The same record is a paid x402 v2 endpoint: `https://api.priors.trade/v1/report/{id}` and `/v1/score/{id}`, 0.01 USDG
each on Robinhood Chain, settled through `https://facilitator.priors.trade`. An unpaid call answers 402 with the
requirements in its `PAYMENT-REQUIRED` header; [`packages/x402`](packages/x402) pays it (`createPayer({ signer }).pay(url)`).
Merchants can sign up for the facilitator themselves at `https://x402.priors.trade/merchants`.

## The four steps (v2)

| | | |
|---|---|---|
| **1** | **identity** | `register(uri)` on the ERC-8004 registry, once. Your NFT is your identity. Already have an id? Skip this (set `PRIORS_AGENT_ID` if it predates v2). The pool never sees your keys, only the id. |
| **2** | **a line** | **Treasury invite:** you request one at [priors.trade/invite](https://priors.trade/invite); an admin approves it and treasury v4's named inviter signs it for your id after checking you own it; you redeem it with your pool consent → $5 (at most $25 of new treasury lines a week). **Seat:** a staker offers a seat of $PRIORS on your id and you accept it → $5 (your agent needs 3 repaid loans first). **Backer:** a root vouches any size with your signed consent. |
| **3** | **borrow, hold, repay** | `quoteFee` → about $0.011666 for $5 over 7 days. `borrow` → USDG in your wallet. Do work. `repay` → principal + fee. Under 7 days repays fine but does not count: dollar-days are the score. |
| **4** | **grow** | Treasury v4 `raise(agentId)` → $50, after 3 qualified loans, 14 days, score ≥ 100 and a clean record. Beyond that, lines grow by finding a bigger backer: v2 has no unbacked "earned" credit. |

```bash
npx priors-v2 join [--invite <code> | --seat <staker>]   # identity, then a line
npx priors-v2 borrow <amount> [--days N]
npx priors-v2 repay [--all]
npx priors-v2 status
npx priors score <agentId>        # v1 CLI, still reads the paused v1 pool's history
npx priors report <agentId>
```

Or from JavaScript, on ethers v6:

```js
import { resolveV2 } from "priors/env";          // deployments/<chainId>.v2.json, RPC_URL, PRIORS_KEY
const { priors } = await resolveV2();
await priors.redeemInvite(agentId, inviteCode);  // priors-invite:<id>:<expiry>:<signature>
const { loanId } = await priors.borrow(agentId, 5, 7 * 86400);
await priors.repay(loanId);
await priors.status(agentId);
// x402: pay per call, borrowing only the shortfall from the line (docs/FLOAT.md)
await priors.pay("https://merchant.example/api", { agentId, maxBorrow: 5_000000n });
```

[`docs/PARTICIPATE.md`](docs/PARTICIPATE.md) covers every role (lender, staker, backer, agent);
[`docs/FLOAT.md`](docs/FLOAT.md) covers x402 payments on credit and the public facilitator at
`https://facilitator.priors.trade`; [`docs/AGENTS.md`](docs/AGENTS.md) is the guide for agent builders.

## What ends it

Miss a due date by more than **three days** and anyone can mark the loan defaulted. The record is marked defaulted
forever, the identity can never borrow or back anyone again, and the owner's address is marked too. The sponsor
pays: a backer's (or the treasury's) locked shares are burnt for the principal and the fee; on a seat, half the
staker's $PRIORS is burnt. Your branch burns in the grove on [priors.trade](https://priors.trade), in public, and
stays burnt.

There is no appeal. That is why the score means something.

## How it works

- **Every line is 100% backed.** Capacity comes only from a backer's USDG, locked as pool shares. Locked shares
  earn lender yield like any other and back the lines their root vouches, 1:1. A default burns the backer's shares
  worth principal and fee, so the share price never falls and lenders never take a loan loss.
- **Consent and handoff.** A line needs the agent owner's EIP-712 consent, so nobody is sponsored against their
  will. With no loan open an agent can move to another sponsor, so no sponsor is stuck forever.
- **Three kinds of backer.** Treasury v4 (root #6228) is funded by $PRIORS creator fees and vouches by rule:
  $5 against an invite, $25 once seasoned, at most $25 of new lines per week, idle lines reclaimed after 30 days.
  The seat vault (root #6229) backs a $5 line behind any agent a staker puts a seat of $PRIORS on; stakers earn
  the sponsor share of that agent's fees and lose half the seat on a default. Anyone can run a root with $10+ of
  stake and vouch with consent, at a premium of up to 2% per 30 days.
- **One money loop.** Loan fees split 60 / 25 / 15 between lenders, the sponsor, and the reserve.
- **A score that is a pure function of the record.** `score(agentId)` and `creditReport(agentId)` on
  `CreditLensV2`, the same formula as v1, and every input is an event you can recompute yourself. Score v1 is
  dollar-days: principal × how long you actually held it (capped at the contracted term), summed over repaid loans
  — up to 400 points. Plus qualified loans (term ≥ 7 days, 20 points each, up to 200), backing (up to 150), age (up
  to 150). Your own default is 0, always. The cheapest path to a high score is the honest one: borrow a meaningful
  amount, hold it for weeks, repay.

[`docs/DESIGN.md`](docs/DESIGN.md) has the v1 math and attacks; [`docs/SECURITY-v2.md`](docs/SECURITY-v2.md) the
v2 findings.

## The parameters, as the contracts set them

| | |
|---|---|
| Loan size | $5 – $500 |
| Term | 1 – 30 days |
| Fee | 1% per 30 days, pro rata, plus the sponsor's premium (0 on treasury and seat lines) |
| Fee split | 60% lenders · 25% sponsor · 15% reserve |
| Lender hold period | 7 days. Withdrawing sooner leaves **0.5%** behind for the lenders who stayed |
| Grace before anyone can default you | 3 days |
| Counts as a qualified loan at | 7 days |
| `maxUtilizationBps` · `keeperBounty` | 10000 · 0 |
| Treasury v4 | first line $5 · raise to $50 · $100 per 7-day epoch · idle after 30 days |
| Seats v2 | seat 1,000,000 $PRIORS · line $5 · 50% burnt on default · agent needs 3 repaid loans · seat expires after 30 idle days · $50 of new lines per 7-day epoch |
| Minimum root stake | $10 |
| Pool owner | 48 h `TimelockController` (the Safe proposes and executes, no admin); the Safe is guardian (pause ≤ 14 days, exits never pause) |

## Robinhood Chain

The target chain is [Robinhood Chain](https://docs.robinhood.com/chain/) mainnet (id 4663).

| | Address |
|---|---|
| **CreditPoolV2** (live) | `0x281210097f0de7A8FB6F87310AF0f089c9C8DE21` |
| **CreditLensV2** (score and report views) | `0x9d7035722bd42C551f82FEB9FDDd17453AEF3D9B` |
| **TreasurySponsorV4** (live, root `#6228`, invite-gated) | `0x0c5091235A25bBFD3F5a009cBe04120D0CBAD573` |
| **SeatVaultV2** (live, root `#6229`) | `0x6D934C07a33E7285cE691A9B258cdB53F18e6B5F` |
| TimelockController (owns the pool, 48 h) | `0x5d984C274035F81BB327d532897a902C5125F87c` |
| Safe (2-of-3; proposes to the timelock, owns treasury v4 and the seat vault) | `0x20c6816B2419616238772591965E6E9AbE493fD5` |
| ERC-8004 Identity Registry | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| USDG (Robinhood's 6-decimal dollar, the pool asset) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| $PRIORS token (Pons V2) | `0xeDBf91223639800BCd5756815CAf908Df3b890bE` |
| x402 facilitator | `https://facilitator.priors.trade` (merchant sign-up: `https://x402.priors.trade/merchants`) |
| Hosted MCP (read-only) | `https://mcp.priors.trade/mcp` |
| Paid API (x402 v2, 0.01 USDG) | `https://api.priors.trade` |
| RPC (official; the only one that serves `eth_getLogs`) | `https://rpc.mainnet.chain.robinhood.com` |
| RPC backups, for plain calls | `https://robinhood-rpc.publicnode.com`, `https://rpc.ordofi.network` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| ~~CreditPool~~ v1 (**paused**, superseded by v2; history imported) | `0x0259889e6EBab1a18CeE7e62Bc5B9648FB6C44e5` |
| ~~TreasurySponsor~~ v3 (v1 pool, superseded by v4, sponsor `#486`) | `0x59f212317b42D308E81EaF8C078fc8189E2a77Df` |
| ~~TreasurySponsor~~ v2 (v1 pool, superseded, sponsor `#461`) | `0x9338d18b5E7faC5ce06a6AD1Af33Db68fE0b4daC` |
| ~~ReserveFunder~~ (v1) | `0x32349B1Ad07513B5Fa6dCC3dbDC0B5ed17FcB72d` |
| ~~CreditPool~~ (older v1 pools, paused, do not use) | `0x4B9fb2dE6BE54aF037683A75F3C82c81C3EEd122`, `0xd970472b2904D5923882af034cea4067AF0AaC95` |

Addresses resolve from `deployments/4663.v2.json` (v2) and `deployments/4663.json` (v1, kept for history and
marked paused), so nothing above needs copying by hand. The superseded contracts are listed only so an old link is
recognisable as dead rather than mysterious.

### Why lenders have a hold period

The lender slice of a fee lands on the share price the moment a loan is repaid, so whoever holds shares
at that instant collects it. An audit showed both ways that was abused: a bot depositing in front of a
repayment and leaving straight after took **$2.70 of a $3 lender fee**, leaving $0.30 for the lender who
had carried thirty days of default risk — and a *borrower* could wrap its own repayment in a deposit and a
withdrawal, in one transaction, and recover **54% of its own fee**.

Leaving inside 7 days now leaves 0.5% behind, which stays in the pool for the lenders who did not leave.
That is enough to make a zero-duration position lose money: the borrower's sandwich costs $549.54 against
the $505.00 it owed. It is a **constant in the contract, not a parameter**, in v1 and v2 alike — an
owner-tunable exit fee would be a lever to confiscate deposits, and the owner cannot reach lender principal
here. Hold past 7 days and it is zero.

`RPC_URL` accepts a comma-separated list and tries it in order — the first entry first, the next only
when that one fails or refuses to serve the request:

```bash
RPC_URL=https://rpc.mainnet.chain.robinhood.com,https://robinhood-rpc.publicnode.com,https://rpc.ordofi.network
```

Worth doing: the official endpoint rate-limits under load, and a 429 there is otherwise the end of the
read. The backups take plain calls happily but **cannot serve event history** — publicnode answers 403
`Archive requests require a personal token` and ordofi answers `-32005 the network is busy` — so anything
reading logs still needs the official endpoint reachable. The SDK knows the difference: a node refusing
to serve moves to the next entry, while a revert is returned as-is, because a revert is the chain's
answer and identical everywhere.

## Repository

```
src/CreditPoolV2.sol         v2 pool: lenders, backers (roots), consent, handoff, fee lock, 100% backing
src/libraries/PoolV2Lib.sol  v2 pool's linked library (hooks, consent digest)
src/CreditLensV2.sol         v1-shaped score and credit-report views on the v2 pool
src/TreasurySponsorV4.sol    the $PRIORS treasury as a v2 root: invite + consent opens a line, rules size it
src/SeatVaultV2.sol          $PRIORS seats: a staker's tokens behind an agent, the vault backs its line
src/CreditPool.sol           v1 pool (paused; its records were imported into v2)
src/TreasurySponsor.sol      v1 treasury (v3)
src/ReserveFunder.sol        v1 creator-fee sweep into the reserve
src/libraries/ScoreLib.sol   the trust score (shared by v1 and the v2 lens)
src/mocks/                   MockUSDC (6 decimals), MockIdentityRegistry, MockPonsFeeEscrow
test/                        404 tests: v2 units, invariants, audit PoCs and fixes (audit-v2/, audit-final/,
                             review-v2/), and the v1 suite
script/DeployV2.s.sol        deploys the v2 set under a 48 h timelock, writes deployments/<chainId>.v2.json
script/Deploy.s.sol          v1 deploy (mocks on dev chains), writes deployments/<chainId>.json
sdk/priors-v2.mjs            the v2 client on ethers v6, ABIs included
sdk/float.mjs                x402 pay() that borrows only the shortfall; sdk/x402.mjs has the payload constants
sdk/priors.mjs               the v1 client
sdk/env.mjs                  resolves chain, deployment record (v1 and v2) and signer
packages/x402/               @priors/x402: x402 v2 USDG preset for Robinhood Chain, facilitator config, a payer that
                             borrows the gap
packages/mcp/                @priors/mcp: local MCP server with the agent's wallet (pay_url, borrow, repay, reads)
bin/priors-v2.mjs            the v2 CLI (`npx priors-v2`)
bin/priors.mjs               the v1 CLI (`npx priors`), for v1 history and the local devnet
scripts/devnet.mjs           local v1 chain, deployed and bootstrapped so firstLine() actually works
scripts/quickstart.mjs       devnet + one agent through the entire record
skills/priors/SKILL.md       the agent skill
docs/PARTICIPATE.md          lenders, stakers, backers and agents on v2
docs/FLOAT.md                credit as float: x402 payments on a line
docs/SECURITY-v2.md          every known v2 finding, its fix or residual, and its test
docs/AGENTS.md               guide for agent builders
docs/DESIGN.md               the v1 math, the attacks, the parameters
SECURITY.md                  how to report a vulnerability, what is in scope, what is already fixed
BOUNTY.md                    what a finding pays, what is in scope on chain, and the safe harbour
```

Found something? **[SECURITY.md](SECURITY.md)** — use this repo's private vulnerability reporting, and
please do not put details in a public issue. **[BOUNTY.md](BOUNTY.md)** says what it is worth; the ceiling is
small and we say so up front rather than after you have spent a week.

## Working on it

```bash
forge test                     # 404 tests, all green (fork-only tests skip without FORK_RPC)
npm test                       # SDK, CLI and publish-guard checks (needs Foundry for the v1 end-to-end run)
npm run test:v2                # the v2 SDK and x402 client, network-free
npm run devnet                 # local chain + deployed, bootstrapped v1 pool
npm run quickstart             # devnet + the full agent flow
bash scripts/check-public.sh   # fails if a credential ever reached a tracked file
```

`CreditPoolV2` compiles with via-IR at `optimizer_runs = 1` to fit the 24 KB limit (a per-file restriction in
`foundry.toml`); everything else compiles as before. Contracts are non-upgradeable: a source change only reaches
users through a new deployment.

## Honest risks

- **Demand is early.** Agents mostly need money for inference and API calls. Volumes are real but small.
- **Backers carry the credit risk.** On v2 that is the point: a default costs its backer, not the lenders. Back
  agents you would lend to yourself.
- **Seats are priced in a volatile token.** A seat deters a stolen line only while half of it is worth far more
  than the line. If $PRIORS collapses, the seat size has to move (see `docs/SECURITY-v2.md`, X-3).
- **This is not an audit.** v2 has had internal adversarial reviews, not a third-party audit. v1 shipped with a
  lender-loss defect the randomized invariants did not catch. Assume there is another one.

## v1: what happened before

The v1 pool ran on Robinhood Chain until the v2 cutover, and is now paused. This is its record, as
it was written while v1 was live; it is kept because it is the history v2 was built on.

> ### v1 status: what we found, and what we did about it
>
> A review found a way for lenders to lose principal: `markDefault()` released an agent's *entire* delegated
> backing on its first default, so a second default from the same agent found nothing left to charge. We wrote
> the counterexample as a test, committed it **failing**, and left it public while it was still broken.
>
> **It is fixed.** A default now consumes only the liable slice of the delegation per loan; the rest keeps backing
> that agent's other open loans and is released when the last one closes, and earned credit is written off against
> bad debt and retired at settlement. The test that proved the bug is still in the suite, and it passes:
>
> ```bash
> forge test --match-test test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure -vv
> ```
>
> `test/DefaultAccounting.t.sol` adds the cases that make the fix mean something: partial defaults, repayment
> after default, multiple children, sub-sponsor recourse per default, a dead sponsor, root defaults, and the
> reserve lock. **`forge test` is 97 passed, 0 failed**, invariants included.
>
> **What that does not buy:** no independent review of the economics has happened, and randomized invariants
> passed right through the original bug — a fuzzer that never defaults the same agent twice reports green forever.
> Launch caps stay small for exactly that reason. Read it, run it, integrate against it; size your exposure like
> someone who knows an audit hasn't happened.
>
> **The pool is live on Robinhood Chain mainnet** (chain 4663), seeded small on purpose: 150 USDG of lender
> liquidity, 75 in the first-loss reserve, 65 staked by the treasury. Addresses come from
> `deployments/<chainId>.json`, so `npx priors doctor` resolves it with no configuration. `npm run quickstart`
> still builds you a throwaway local chain in about thirty seconds if you would rather not touch mainnet.
>
> **A second defect was found after launch, and has now been fixed and redeployed.** A root sponsor could
> vouch out `stake + earned`; when the delegation defaulted, `markDefault` clamped the root's liability to its
> stake and charged the shortfall to the reserve — but never retired the root's `earned`. The same earned credit
> then backed a defaulted delegation *and* remained the root's own borrowing capacity: the reserve paid twice,
> `reserve >= totalEarned` broke, and lenders lost principal. Worth being precise about what was *not* wrong:
> `vouch()` letting a root delegate more than its earned. A root's stake is cash, so that delegation is backed;
> requiring `delegatedOut <= earned` for roots would break the treasury, which vouches every line out of stake
> with `earned = 0`. The permission was right — the accounting on default was incomplete.
>
> `test/ReviewPoC_RootEarnedDoubleSpend.t.sol` is the original proof-of-concept, now inverted into the
> regression guard: it runs the attack move for move and asserts containment. Revert the fix and it fails
> naming the broken invariant. **The pool was migrated to the fixed bytecode**, carrying every agent's
> repayment record across — see `importRecords` and `test/HistoryImport.t.sol` — and the `minStake` lockout
> that had stood in for the fix is lifted, so third-party root sponsors work again.
>
> **The old pool is paused and abandoned.** $10 of stake is stranded in it forever, behind two credit lines
> that were already given: `unvouch` is `onlyController(sponsor)` and the TreasurySponsor exposes none, so a
> line cannot be taken back. That is a design property, not an accident, and it is the whole reason onboarding
> is finite.
>
> Practical consequence: **onboarding is finite.** The treasury vouches $5 per agent out of its own 65 USDG of
> stake, so the beta seats thirteen agents in total. Capacity grows only when $PRIORS creator fees are swept
> into the treasury — by hand during the beta. Don't trust that count once it is a day old: priors.trade shows
> how many first lines are left, read live from the chain, and so does `npx priors report 445`
> (`available` ÷ $5).


## License

MIT
