# Priors

**Reputation for AI agents that can't be faked, because it's earned by repaying real money.**

[priors.trade](https://priors.trade) · a prior is what you believe about an agent before you deal with it. This
one is backed by money.

A small on-chain credit pool lends unsecured USDG ($5 to $500) to agents registered on
[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004). Every repayment and every default is a public event. From
those events you get a credit-backed trust score anyone can query before trusting an agent, and a public
leaderboard of which agents pay their debts back.

Reviews are cheap to fake. Repaid debt isn't.

> ### Status: what we found, and what we did about it
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
> reserve lock. **`forge test` is 74 passed, 0 failed**, invariants included.
>
> **What that does not buy:** no independent review of the economics has happened, and randomized invariants
> passed right through the original bug — a fuzzer that never defaults the same agent twice reports green forever.
> Launch caps stay small for exactly that reason. Read it, run it, integrate against it; size your exposure like
> someone who knows an audit hasn't happened.
>
> **The pool is live on Robinhood Chain mainnet** (chain 4663), seeded small on purpose: 150 USDG of lender
> liquidity, 75 in the first-loss reserve, 75 staked by the treasury. Addresses come from
> `deployments/<chainId>.json`, so `npx priors doctor` resolves it with no configuration. `npm run quickstart`
> still builds you a throwaway local chain in about thirty seconds if you would rather not touch mainnet.
>
> **Beta posture, and it is a real restriction:** a second defect was found in default accounting after launch —
> a *root* sponsor could vouch out capacity it had already borrowed against, because `vouch()` applies the
> earned-room rule only to non-roots while `markDefault()` charges a root's shortfall to the reserve. It is
> reproducible; the PoC is in the repo. Until the fix ships, **`minStake` is raised out of reach, so nobody new
> can become a root sponsor.** `isRoot` is assigned in exactly one place, so that closes the only door — but it
> also means the "operators stake and vouch" half of the sponsor tree is switched off for now, and the treasury
> is the only sponsor. `test/BetaMitigationMinStake.t.sol` holds that reasoning to account, control included.
>
> Practical consequence: **onboarding is finite.** The treasury vouches $5 per agent out of its own 75 USDG of
> stake, and a line it has given cannot be taken back, so the beta seats fifteen agents in total. Capacity grows
> only when $PRIORS creator fees are swept into the treasury — by hand during the beta. Don't trust that count
> once it is a day old: priors.trade shows how many first lines are left, read live from the chain, and so does
> `npx priors report 436` (`available` ÷ $5).

---

## Give your agent a credit history in one command

```bash
git clone --recurse-submodules https://github.com/priors-agents/priors && cd priors
npm install
npm run quickstart
```

That starts a local chain, deploys the real contracts, and walks one fresh ERC-8004 identity through the entire
record — register, take the treasury's $5 line, borrow, hold, repay, score:

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

## Hand it to your coding agent instead

This repo ships the procedure as an agent skill, so you don't have to read any of it:

```bash
# Claude Code
mkdir -p ~/.claude/skills && cp -r skills/priors ~/.claude/skills/priors
```

Then say: **"give my agent a credit history on Priors"**. The skill knows the four steps, which chain it is on,
what to do when the treasury's epoch cap is spent, and that it must not claim an agent is registered when it
isn't. Codex and other harnesses read [`AGENTS.md`](AGENTS.md) at the repo root, which carries the same
instructions.

## The four steps

| | | |
|---|---|---|
| **1** | **identity** | `register(uri)` on the ERC-8004 registry, once. Your NFT is your identity. Already have an id? Skip this. The pool never sees your keys, only the id. |
| **2** | **first line** | `treasury.firstLine(agentId)` → a $5 line, sponsored by the $PRIORS treasury, by rule, out of its own stake. **Anyone can call it for you.** Epoch cap spent? Wait 7 days, or ask a root sponsor to `vouch()` a bigger line. |
| **3** | **borrow, hold, repay** | `quote(5, 7)` → fee $0.011666. `borrow(id, 5, 7)` → USDG in your wallet. Do work. `repay(loanId)` → principal + fee. Under 7 days repays fine but does not count: dollar-days are the score. |
| **4** | **grow** | `treasury.raise(agentId)` → $50, after 3 qualified loans, 14 days and a clean record. Repaying earns capacity of your own, up to $250. `vouch(yours, other, amount)` backs someone from it — and their default becomes your recourse loan. |

Every step is one CLI subcommand:

```bash
npx priors doctor                 # which chain, what is deployed, can I sign, what do loans cost
npx priors register               # -> agentId
npx priors first-line <agentId>   # -> $5 line
npx priors quote 5 7              # -> fee, and whether it counts for the score
npx priors borrow <agentId> 5 7   # -> loanId
npx priors repay <loanId>
npx priors score <agentId>        # 0..1000
npx priors report <agentId>       # every input the score is computed from
npx priors raise <agentId>        # -> $50 once the record qualifies
npx priors flow                   # all of the above on one fresh agent
```

Or from JavaScript — six methods on ethers v6:

```js
import { Priors } from "priors";
const s = new Priors({ rpc, pool, treasury, signer });
await s.firstLine(agentId);
const loanId = await s.borrow(agentId, 5, 7);
await s.repay(loanId);
await s.score(agentId);   // 0..1000
```

[`docs/AGENTS.md`](docs/AGENTS.md) is the full guide for agent builders.

## What ends it

Miss a due date by more than **three days** and anyone can mark the loan defaulted. The score goes to zero,
forever. The identity can never borrow or vouch again. Your sponsor eats the loss — a root sponsor is slashed; a
sub-sponsor gets a recourse loan for the liable amount, due in 14 days. Your branch burns in the grove on
[priors.trade](https://priors.trade), in public, and stays burnt.

There is no appeal. That is why the score means something.

## How it works

- **Sponsor tree.** A new agent can only get credit through a sponsor: its operator, or another agent with a
  good record. Roots post USDG stake; everyone else vouches only with capacity they earned by repaying. Losses
  flow back up to whoever vouched, and so do fees: a sponsor earns 25% of every fee its agents pay.
  ⚠ **During the beta the root half of this is off** — `minStake` is raised out of reach, so the treasury is the
  only sponsor and no one else can enrol as a root. See Status above for why.
- **One money loop.** Loan fees split 60 / 25 / 15 between lenders, sponsors, and the first-loss reserve. The
  reserve is what lets agents earn credit lines nobody in the tree had to back. The $PRIORS token's creator fees
  feed the same reserve through `ReserveFunder` and `TreasurySponsor`. The pool is deployed and the treasury is
  staked; the one remaining hop is pointing the token's creator-fee recipient on Pons at the `TreasurySponsor`
  address below, which only the token's creator can do. Until that happens the fees sit in the Pons escrow.
- **Growth that can't be gamed cheaply.** Repaying grows an agent's own line, but at most $25 per week, $250 in
  total, and only while a first-loss reserve covers every unbacked dollar in the system.
- **A score that is a pure function of the record.** `score(agentId)` on-chain, `creditReport(agentId)` for
  everything behind it, and every input is an event you can recompute yourself.
- **Score v1 is dollar-days.** Principal × how long you actually held it (capped at the contracted term),
  summed over repaid loans — up to 400 points. Plus qualified loans (term ≥ 7 days, 20 points each, up to 200),
  backing at risk (up to 150), age (up to 150), recourse honored (up to 100), minus 75 for each vouched agent
  that defaulted. Your own default is 0, always. The cheapest path to a high score is the honest one: borrow a
  meaningful amount, hold it for weeks, repay.

[`docs/DESIGN.md`](docs/DESIGN.md) has the math, the attacks and the parameters.

## The parameters, as the contract sets them

| | |
|---|---|
| Loan size | $5 – $500 |
| Term | 1 – 30 days |
| Fee | 1% per 30 days, pro rata |
| Fee split | 60% lenders · 25% sponsor · 15% first-loss reserve |
| Grace before anyone can default you | 3 days |
| Counts as a qualified loan at | 7 days |
| Treasury first line | $5 · raised to $50 once qualified |
| Treasury vouching cap | $100 per 7-day epoch |
| Earned capacity | 50% of repaid principal · max $25 per epoch · max $250 |
| Minimum stake to enroll as a root sponsor | $10 by default — **raised out of reach during the beta**, see Status |
| Recourse term for a sponsor covering a default | 14 days |

## Robinhood Chain

The target chain is [Robinhood Chain](https://docs.robinhood.com/chain/) mainnet (id 4663). Everything the pool
depends on is already there.

| | Address |
|---|---|
| ERC-8004 Identity Registry | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| USDG (Robinhood's 6-decimal dollar, the pool asset) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| $PRIORS token (Pons V2) | `0xedbf91223639800bcd5756815caf908df3b890be` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| **CreditPool** (live) | `0xd970472b2904D5923882af034cea4067AF0AaC95` |
| **TreasurySponsor** (live, sponsor `#436`) | `0x5eDF7b2375D434B09c784e28917CB3D6714F5d60` |
| ReserveFunder | `0x43d6E0e5aF75e63F1c1e6D340B6d511385Ba06cB` |

## Repository

```
src/CreditPool.sol           the pool, credit lines, sponsor tree, default waterfall, reserve
src/TreasurySponsor.sol      the $PRIORS treasury as a sponsor: vouches by rule, not by judgement
src/ReserveFunder.sol        creator-fee recipient: sweeps token fees into the first-loss reserve
src/libraries/ScoreLib.sol   the trust score
src/mocks/                   MockUSDC (6 decimals), MockIdentityRegistry, MockPonsFeeEscrow
test/                        74 tests: units, default accounting, TreasurySponsor, ReserveFunder, invariants
script/Deploy.s.sol          deploys (mocks on dev chains), writes deployments/<chainId>.json
sdk/priors.mjs               the whole agent flow in six methods on ethers v6, ABI included
sdk/env.mjs                  resolves chain, deployment record and signer
bin/priors.mjs               the CLI
scripts/devnet.mjs           local chain, deployed and bootstrapped so firstLine() actually works
scripts/quickstart.mjs       devnet + one agent through the entire record
skills/priors/SKILL.md       the agent skill
docs/AGENTS.md               guide for agent builders
docs/DESIGN.md               the math, the attacks, the parameters
```

## Working on it

```bash
forge test                     # 74 tests, all green (see Status)
npm run devnet                 # local chain + deployed, bootstrapped pool
npm run quickstart             # devnet + the full agent flow
bash scripts/check-public.sh   # fails if a credential ever reached a tracked file
```

Contracts are non-upgradeable: a source change only reaches users through a new deployment.

## Honest risks

- **Demand is early.** Agents mostly need money for inference and API calls. Volumes are real but small.
- **The reserve is meant to be spent.** That is what it is for. Size it as a marketing and data budget; the
  contract will not grant more unbacked credit than it holds.
- **This is not an audit.** No independent review of the economics has been done. The default-accounting defect
  above is fixed and covered, but it got in there in the first place, and the randomized invariants did not catch
  it. Assume there is another one.

## License

MIT
