# Priors

**Reputation for AI agents that can't be faked, because it's earned by repaying real money.**

[priors.trade](https://priors.trade) · a prior is what you believe about an agent before you deal with it. This
one is backed by money.

A small on-chain credit pool lends unsecured USDG ($5 to $500) to agents registered on
[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004). Every repayment and every default is a public event. From
those events you get a credit-backed trust score anyone can query before trusting an agent, and a public
leaderboard of which agents pay their debts back.

Reviews are cheap to fake. Repaid debt isn't.

> ### Status: prelaunch. Do not put real money in this.
>
> - **There is no mainnet deployment.** The CreditPool is not deployed on Robinhood Chain mainnet (4663) or
>   testnet (46630). The only chain you can run this on today is a local one, which `npm run quickstart` builds
>   for you in about thirty seconds.
> - **There is a known, unfixed defect in default accounting.** `CreditPool.markDefault()` releases an agent's
>   entire delegated backing when processing its first default, so a second default from the same agent can cost
>   lenders principal. The regression test that proves it is committed and **failing on purpose**:
>
>   ```bash
>   forge test --match-test test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure -vv
>   ```
>
>   `forge test` is **64 passed, 1 failed**, and that one failure is this. It is not skipped and its expectation
>   is not weakened, because a green suite would be a lie. The exposure accounting gets fixed first, with
>   independent review of the economics, before anything holds real funds.
> - So: the mechanism is real and the code is readable, but **the safety claim is not yet earned.** Treat this
>   as a working prototype to read, run and integrate against — not as a place to deposit.

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
- **One money loop.** Loan fees split 60 / 25 / 15 between lenders, sponsors, and the first-loss reserve. The
  token's creator fees go into the same reserve. The reserve is what lets agents earn credit lines nobody in the
  tree had to back.
- **Growth that can't be gamed cheaply.** Repaying grows an agent's own line, but at most $25 per week, $250 in
  total, and only while a first-loss reserve covers every unbacked dollar in the system.
- **A score that is a pure function of the record.** `score(agentId)` on-chain, `creditReport(agentId)` for
  everything behind it, and every input is an event you can recompute yourself.
- **Score v1 is dollar-days.** Principal × term, summed over repaid loans (up to 400 points), plus qualified
  loans (term ≥ 7 days, 20 points each up to 200), backing at risk, age and recourse honored, minus 75 per
  vouched defaulter. The cheapest path to a high score is the honest one: borrow a meaningful amount, hold it
  for weeks, repay.

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
| Minimum stake to enroll as a root sponsor | $10 |
| Recourse term for a sponsor covering a default | 14 days |

## Robinhood Chain

The target chain is [Robinhood Chain](https://docs.robinhood.com/chain/) mainnet (id 4663). Everything the pool
needs is already deployed there — the pool itself is not, yet.

| | Address |
|---|---|
| ERC-8004 Identity Registry | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| USDG (Robinhood's 6-decimal dollar, the pool asset) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| $PRIORS token (Pons V2) | `0xedbf91223639800bcd5756815caf908df3b890be` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` |
| CreditPool | **not deployed yet** |

## Repository

```
src/CreditPool.sol           the pool, credit lines, sponsor tree, default waterfall, reserve
src/TreasurySponsor.sol      the $PRIORS treasury as a sponsor: vouches by rule, not by judgement
src/ReserveFunder.sol        creator-fee recipient: sweeps token fees into the first-loss reserve
src/libraries/ScoreLib.sol   the trust score
src/mocks/                   MockUSDC (6 decimals), MockIdentityRegistry, MockPonsFeeEscrow
test/                        65 tests: units, TreasurySponsor, ReserveFunder, handler-based invariants
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
forge test                     # 65 tests: 64 pass, 1 fails by design (see Status)
npm run devnet                 # local chain + deployed, bootstrapped pool
npm run quickstart             # devnet + the full agent flow
bash scripts/check-public.sh   # fails if a credential ever reached a tracked file
```

Contracts are non-upgradeable: a source change only reaches users through a new deployment.

## Honest risks

- **Demand is early.** Agents mostly need money for inference and API calls. Volumes are real but small.
- **The reserve is meant to be spent.** That is what it is for. Size it as a marketing and data budget; the
  contract will not grant more unbacked credit than it holds.
- **The default-accounting defect above is unfixed.** Nothing else in this list matters until it is.
- **This is not an audit.** No independent review of the economics has been done.

## License

MIT
