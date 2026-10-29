# Priors Score v2

*2026-09-26, audited the same day (findings F1-F21 fixed below). Live since 2026-09-27: see "Where to read it".
In this repo: the scoring engine (`sdk/score-v2.mjs`), its inputs (`sdk/score-v2-inputs.mjs`), the weights
(`sdk/score-weights.v2.json`; 2.0.1 in `sdk/score-weights.v2.0.1.json`, 2.0.2 in `sdk/score-weights.v2.0.2.json`,
2.0.3 in `sdk/score-weights.v2.0.3.json`, 2.0.4 in `sdk/score-weights.v2.0.4.json`), x402 income read from the chain
(`sdk/x402-income.mjs`) and the tests
(`scripts/test-score-v2.mjs`, `scripts/test-x402-income.mjs`, `scripts/test-stocks.mjs`,
`scripts/test-score-v2-priors-stake.mjs`, `scripts/test-score-v2-late-window.mjs`). Priors' clusters list is not
published (see "Clusters").*

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
| **v1, on chain** | `ScoreLib`: simple, conservative | a new pool version, behind the timelock (48 h; no delay from 2026-10-11 19:49 UTC) | contracts: treasury rules (a raise needs a score of 100); seat gates count repaid loans, not the score |
| **v2, open and deterministic** | `scoreV2()`: a pure function of public data, with published weights | a new weights file and version, announced on the dev log (priors.trade/updates) 7 days ahead (below) | people and apps: site, API, MCP; later attested on chain |

v2 moves fast and in the open; v1 stays the hard floor the contracts rely on. When a v2 component has proven itself
on data, it moves into the next on-chain version.

## The score (v2.0.0 to 2.0.4, the same numbers; max 1000)

| component | max | counts |
|---|---|---|
| **risk time** | 300 | USDG **someone else** put at risk × days actually held (capped at the term), on loans repaid on time. 1 point per 10 USDG-days. A loan the agent repaid from x402 income counts up to 25% more, in proportion to the share of it that counted income paid (income weighted like the income component, at most 20 USDG per payer per loan, each payment spent once). |
| **seasoned loans** | 200 | loans held 7+ days and repaid on time, backed by someone else. 20 each for a loan of 50 USDG or more; a smaller one counts in proportion (a 5 USDG loan: 2). |
| **backing** | 150 | money another party has at risk behind the agent now. 1 point per 5 USDG. |
| **age** | 100 | days since the agent's first loan on Priors, v1 included (an agent that never borrowed has none); restarts when the agent changes hands (from 2.0.4, not when by a sale on Priors' agent market: "A sale on Priors' market"). A change of hands is read from the owners its loans record and, after a v1 loan or for an agent with no loan before it, from its last registry transfer (one before its enrolment, such as its mint, changes nothing). An agent back with the owner whose v2 loans it holds keeps them. |
| **recourse** | 100 | debts of vouched agents it paid itself. 50 each; dropped when the agent changes hands (from 2.0.4, kept at a sale on Priors' market). |
| **income** | 150 | x402 payments (signed USDG, from any facilitator) to the agent's declared payment wallet (from 2.0.4, and for 30 days after a sale on Priors' market to the wallet it declared at the sale: "A sale on Priors' market") from payers that aren't its own, last 30 days, net of anything the agent's side sent that payer. A payer counts once it has paid 1 USDG in the window; each payer is capped at 20 USDG and weighted by its own score (unknown wallets at half weight); plus 5 points per payer, up to 50. A payment to a wallet several agents declared is shared between them. |
| penalties | | −10 per late repayment (and it earns nothing); −75 per vouched agent that defaulted. Late: repaid after the due time; from 2.0.3, more than 24 hours after it |
| **default** | | the score is 0, and so is every other agent of the wallet that defaulted: the loan's owner when it was taken, and the defaulted agent's declared payment wallet. Sending a defaulted agent to someone never harms them. (A v1 default, with no owner recorded, zeroes only the agent itself.) |

**Backers.** A loan is "backed by someone else" when its backer is another owner's agent that had been on Priors for
**30+ days** when the loan was issued, counted from its enrolment or, if later, from when its current owner took the
id (registry transfers). The protocol's treasury (and treasury v5, once the snapshot names its root) and seat vaults
(V3 and the growth seat vault V4, public ids in the snapshot) count from day one, and from 2.0.3 so does the Ethos
lane's root (#8823, the snapshot's `meta.ethosRootAgentId`; a snapshot that does not name it leaves it an ordinary
backer). A backer the record doesn't know counts as the agent's own, and so, under 2.0.1 to 2.0.4, does the stock
vault's root: the agent's own tokens stand behind that loan. Under 2.0.2 to 2.0.4, so do SeatVaultV5's roots (#8762,
and the retired #8641; the snapshot's `meta.seatVaultV5AgentId`, without which 2.0.2 to 2.0.4 build no inputs, and
`meta.seatVaultV5RetiredAgentId`): V5 sizes the
line by the owner's own $PRIORS behind the agent and burns 75% of it on a default, so a stake never changes a score.
v1 loans take their backer from the repayment's `FeeSplit` event, not from today's sponsor. The same rule applies to
backing held now.

**Rungs** (the record side of the trust ladder): 0 unproven · 1 started (one repayment backed by
someone else) · 2 proven (3+, over 14+ days, none late) · 3 earned (proven, a record score of 300+ with income left
out, and 30+ days since the first backed loan) · 4 income-backed (earned, income 50+ from 3+ payers of 1 USDG or more).
Income can add points, but it can't lift a thin record to "earned". Every threshold is in the weights file.

Every result explains itself: the score, the rung, each component with its points and reason, penalties, and the
raw details (USDG-days, loans, payers, and `incomeUsdg`: the x402 USDG of the payers that count, before caps and
weights). `receiptsUsdg` and `receiptPayers` show what the agent was paid by payers outside its cluster in the window,
net of what its side sent back but before caps and weights, dust and fresh wallets included: a customer's payment is
shown even when it doesn't count toward the score, once that payer's netting is read (a new payer, or a payment to a new
agent's cluster, waits until then: "New payers and new agents wait" below).

Each result also has `next` (since 2026-10-16): the next rung and how far the agent is on each of its conditions,
`{ rung, name, needs: [{ key, have, need, met }], blocked }`, from the same figures the rung is judged on:
`backedRepaid` (repayments backed by someone else), `spanDays` (days from the first such repayment to the last) and
`late` (need 0) for proven; `recordScore` (income left out) and `daysSinceFirst` for earned; `incomePoints` and
`payers` for income-backed. `blocked` is `"late"` when a late repayment keeps proven closed for good. `next` is null at
rung 4 and after a default. It changes nothing in the score or the rung. Go mode's Scores section and the board's agent
sheet show it; `/api/board` counts per rung the agents one condition short of it (`near`).

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

## A sale on Priors' market (2.0.4)

*Built 2026-10-27: weights `2.0.4` (`sdk/score-weights.v2.0.4.json`, `changeOfHands.keepAtMarketSale`), the rule
(`keptOwnership` in `sdk/score-v2-inputs.mjs`, which takes the market's sales as `sales`) and the income window carried
across the sale (the inputs' income routes, `soldWallets` in `sdk/x402-income.mjs`). Announced on the dev log
(priors.trade/updates) on 2026-10-28; Priors' scores use it from 2026-11-05 00:00 UTC.*

The owner's rule (2026-10-26, restated 2026-10-27): an agent's score does not change because it was sold, and a sale on
the market is as seamless as an NFT's. Under 2.0.0 to 2.0.3 any change of hands restarts age, record and recourse. Under
2.0.4 a change of hands that was a sale on Priors' agent market keeps them, as if no change of hands had happened, and
its new owner's loans add to that record. Everything carries, income included: the record, age, recourse, the rungs'
day counts, the income window and the income bonus of the loans the sale carries are what they were, so the score the
second after the sale is the score the second before, byte for byte but the flag that says so (`flags.keptSale`,
"Outputs"). Three rules hold it: the seller's side of the sale is judged as it was the second before (below: the wallet
at the sale, and for an agent the clusters list names, its listing); a payer's weight leaves out the agent it pays; and
after the sale, the agent's owner paying the wallet at the sale is the owner paying its own agent. One effect is not
held, under any version: an agent the clusters list names takes its listing to its buyer, so the buyer's other agents,
and with them the buyer's weight as a payer, can score differently from the sale on (the list's wallets are the
buyer's own from then).

- **Which sales.** A `Sold` log of AgentMarket (v1, `0xe5C8b3FacD7802099C1DfB88c0C818Cd0ebA7B19`) or AgentMarketV2
  (once deployed), or an accepted bid on V2 (`BidTaken`, its maker the buyer), read from those addresses only, with the
  payment wallet the agent declared at the sale (the registry's `getAgentWallet` at the block before it). A sale on any
  other contract is a plain transfer. Every hop between the owner the loans name and the next must be such a sale,
  seller to buyer in turn.
- **What stops gaming.** A sale is public, pays the market's fee in force (1%, at least 1 USDG today; the market's
  timelock can change it, so the score counts on no fee) and starts its 14-day hold, and the market refuses it while
  the agent has a loan open or has defaulted on either pool, is a root, or while either side is marked by a default
  (`ownerDefaults`). On top of that the score keeps nothing when: the change was a plain transfer (it restarts as
  before); a sale follows a plain transfer (A sends the agent to X, X sells it to B, or back to A: the oldest sale must
  be the loans' owner's, GHSA-jjxq-7r68-44m5) or a plain transfer follows a sale (A sells to X, X sends it to B); the seller, or the payment wallet the agent declared at the sale, was already in
  default when it sold (one of its loans past its defaultable time, marked or not, or the declared payment wallet of
  such a loan's agent), so a default the pool hasn't marked yet can't be carried to a fresh wallet; or that wallet is
  not read yet (fails closed). Each of these restarts the record exactly as 2.0.3 does, on agents with v1 loans too.
- **The payment wallet at the sale** stays in the seller's cluster. The registry clears an agent's payment wallet at
  every transfer; without this, a sale (to anyone, the seller's own second wallet included) would unlink the seller
  from the wallet it had declared, and the seller's loans backed by a root that wallet owns would start counting as
  someone else's risk. With it, the seller's loans are judged against the same cluster after the sale as before. Its
  wallets declared earlier and changed before the sale are not read. An agent the clusters list names takes its
  listing with it (the list names the agent), so for such an agent the seller's side is built again as it was the
  second before the sale: the agent owned by the seller and declaring the wallet it declared then, the list's wallets
  with it. Its seller's loans and the payments to the wallet at the sale are judged against that cluster
  (`sdk/score-v2-inputs.mjs`, the routes' `judgeOf`): a wash sale to a fresh wallet never turns the list's wallets into
  the agent's customers, nor the seller's own root into someone else's risk.
- **Recourse** (paid by the seller): kept. Debts the agent paid for agents it vouched for are its record as much as
  the loans it repaid, which the seller also paid; a plain transfer still drops it. Rare in practice: the market refuses
  roots, and roots do most of the vouching.
- **Income**: the window carries. Income is read on the payment wallet the agent declared in the ERC-8004 registry,
  which the registry clears at every transfer. For the income window's length (30 days) after the sale, payments to the
  wallet the agent declared at the sale keep counting for it, as they did: judged against the seller's side as it was
  the second before the sale (that wallet stays in the seller's cluster, and a listed agent's listing is counted in,
  above), so the seller and its own wallets paying it are still paying themselves; netted against what that side sends
  a payer back; shared with any other agent that declares it; with the 1-USDG floor, the 20-USDG cap per payer, half
  weight for unknown payers and the 150-point cap, as any income. A payment to it made after the sale by whoever owned
  the agent then (the buyer, or a wash sale's second wallet) counts nothing: that is the owner paying its own agent. A
  payer's weight (its own score) leaves out the agent it pays, so a buyer that was the agent's customer before the sale
  weighs what it weighed then. Payments to the wallet the new owner declares count from the sale on (`incomeSince`),
  never one from before it (the new owner's other business), judged against the agent's cluster now; a payment both
  reach (the new owner declared the seller's wallet again) counts once. Each payment counts in the 30-day window as
  always, so a payment to the wallet at the sale made up to 30 days after the sale counts for its own 30 days: the
  seller's customers are out of the score 60 days after the sale, as the new owner's come in. A chain of sales carries
  each seller's wallet, from its seller's start to 30 days after its own sale. A carried loan keeps its income bonus
  (up to 25% more for a loan repaid from x402 income) as the seller earned it: each loan draws only on what was paid to
  its own owner's wallet, so the new owner's loans never draw on the seller's. The income index keeps reading the
  wallet at each sale (`soldWallets`, below). A sale that keeps nothing carries no income: the agent's income restarts
  with its record, as under 2.0.3.
- **Defaults**: a default after the sale is the new owner's. A default zeroes the wallet that owned the defaulted loan
  (and the defaulted agent's declared wallet), so the buyer's default on the agent zeroes the buyer's other agents and
  never the seller's, and the seller's later default on another agent never reaches the agent it sold (it can't have had
  a loan open on it: the market refuses the sale). A seller in default when it sold carries nothing (above).
- **The rungs' day counts** run across the sale: proven's 14 days between the first and the last backed repayment,
  earned's 30 days since the first backed loan, and age, all count from the agent's own first loans, the seller's
  included. `next` reads the same figures.
- **Each loan stays as it was counted**: judged against the cluster of its owner when it was taken (the payment wallet
  at the sale included, and for a listed agent its listing, above), late or on time, with its child defaults. Backing
  is what is at risk behind the agent now, as always: a line from a root the market follows (the treasury's) stays on
  the agent; any other line the seller left before listing.
- **v1 loans** carry no owner, and an agent with no loan has none to read. For a sold agent Priors also reads its
  registry transfers since pool v2's launch: a transfer that was no sale restarts the record, as before
  (`plainTransferAt`), after a v1 loan or, for an agent with no loan before it, after its enrolment, and so does a sale
  that can't keep it (above). Until they are read, its last transfer counts, which is the sale: the record restarts
  until the read catches up. (Until 2026-10-28 only the sold agents with v1 loans were read: GHSA-4x5r-f6w5-fhhc.)
- **What is read.** The markets' sales, from each market's deploy block on, each timed by its block, with the wallet
  each sale's agent declared at the block before it, and never a price. A sale not read yet, or whose wallet is not
  read yet, counts as a plain transfer until it is (fails closed), and nobody else's score waits. The income index reads
  the wallet at each sale of the last 365 days (the index's retention) as if still declared (`soldWallets` in
  `sdk/x402-income.mjs`): its payments, what it or its seller (who may own no agent any more) sends a payer back, and
  the repayers of its agent's loans. A wallet of a sale made before 2026-11-05 is read again from the index's start on
  the first runs, so its carried income can read low until then, never high.
- **Outputs.** One flag, only on a sold agent: `flags.keptSale` true when its current owner took it by a sale on
  Priors' market that kept its record (every other score has no such key, so with no sale 2.0.4 is 2.0.3 byte for
  byte). A kept sale leaves `flags.ownershipChanged` false (nothing restarted, so the pages say no change of owner) and
  `version` names 2.0.4; an agent whose record restarted at an earlier plain transfer and was then sold on the market
  keeps `ownershipChanged` true, with `keptSale` saying the restart was an earlier owner's. Every owner-change word keys
  on both under 2.0.4: the attester posts its owner note (`OWNER_CHANGED`, "Its Priors score counts the record from the
  new owner", `sdk/attestation.mjs`) only when `ownershipChanged` is true and `keptSale` is not, and for a kept sale
  posts a plain note that names the new owner, with no owner words, so the live note never names the seller
  (`docs/ATTESTATION-v2.md`); the paid API's `ownership-changed` flag and Go mode's owner note key on the same flags.
  The scores also say how far their sales read is (`sales: { behind, unread, pending }` in `/api/score-v2`): while any
  is not 0, a sale may count there as a plain transfer, and the attester posts nothing for a change of owner until it
  sees them all at 0 (a note on chain is permanent).

## How x402 income is read

An x402 `exact` payment in USDG is an EIP-3009 `transferWithAuthorization`: the payer signs, a facilitator submits,
and USDG emits `AuthorizationUsed(payer, nonce)` followed by `Transfer(payer, payTo, amount)`. `sdk/x402-income.mjs`
reads those two events from the chain, so every facilitator counts, not only Priors'. Signed USDG payments are common
on Robinhood Chain (apps move large amounts this way), so the scan lists the authorizations first and then asks only
for the transfers from those payers to agent wallets; the transfer must be the log right after its authorization.

An x402 payment can also be settled through Permit2 (the `upto` scheme, and `exact` on a token without EIP-3009):
Permit2 moves the USDG, then the x402 proxy that called it emits `Settled()` or `SettledWithPermit()`
(`x402ExactPermit2Proxy` `0x402085…0001`, `x402UptoPermit2Proxy` `0x4020A4…0002`, the same address on every chain).
The scan lists those events too (four queries per window, one address and one topic each) and, only around them, the
transfers to agent wallets; the transfer must be the log right before the event. Both routes count the same way:
same wallets, same netting, same filters. An index read before this re-reads Permit2 alone over what it had read,
once, without holding scores back; the published `index.permit2Backfill` is `null` once it is done.

- **Whose income.** A payment counts for the agents that declared the paid wallet as their payment wallet in the
  ERC-8004 registry. The registry sets it to the owner at registration, clears it when the agent changes hands, and
  changes it only with the wallet's signature, so agents sent to someone's address can't take a share of its income.
  A wallet that can't be read holds the scores back until it is read: a declared wallet links clusters, so scores are
  never published without one.
- **Netted.** USDG that any wallet of the agent's cluster sent to a payer (before or after, whole chain) is taken off
  that payer's payments: money that goes back where it came from is not income.
- **No dust.** A payer counts once it has paid 1 USDG in the window. Below that it adds nothing and costs no scan.
- **New payers and new agents wait, nobody else does.** A new payer's netting is read from the start of the chain;
  until then its payments wait (they show nowhere, receipts included). A new agent's owner and declared wallet are read
  the same way, and until then payments to every agent of its cluster wait. The reads waiting to start are made
  together, one pass for the new payers and one for the new wallets, each taking only its own transfers and stopping
  its wait once its own part of the chain is read. A pass in progress goes first, all of them before a new wallet's
  past payments, 100,000 blocks a request (10,000 on a node that answers no more), and each step goes on from where the
  last one stopped. Everyone else's scores keep publishing.
- **Repaid from income.** A loan that counts (backed by someone else, repaid on time by the agent's own wallets, since
  its last change of hands) and was repaid while counted income arrived is marked repaid from income, in proportion.
  Income is weighted like the income component, capped at 20 USDG per payer per loan, and each payment is spent once.
  Only payers whose payments in the index add up to 1 USDG fund it: the index nets those alone, so what the agent's
  side sends a smaller payer is never read (GHSA-4x5r-f6w5-fhhc).
- **Kept for a year.** Payments are kept 365 days (less only if the index must shrink to fit its store); a loan's
  bonus comes from income inside that window. Income is read from pool v2's launch block on, which is when x402
  started on Robinhood Chain. Each published result names how its index was read (`index`: blocks, retention).
- **Not seen yet.** Gas funding in native ETH (no log), x402 batch settlement (payment channels,
  `x402BatchSettlement`), payments to a wallet the agent hasn't declared, and a payer funded through an intermediary
  wallet (v2.1, funding-source clusters).

## How people will try to game it, and what stops them

| attack | stopped by |
|---|---|
| flip hundreds of small loans | risk time counts USDG × days: 300 half-hour loans of 8 USDG earn under 10 points (flips of hundreds of USDG do add up, but that money is really at risk, and flips never make seasoned loans) |
| many tiny week-long loans | a seasoned loan counts by size: ten 1 USDG loans are worth 4 points, not 200 |
| back yourself | loans backed by your own owner count for nothing |
| put more of your own $PRIORS behind your agent's SeatVaultV5 line | 2.0.2's rule, kept in 2.0.3 (Priors' published scores from 2026-11-02 00:00 UTC): V5's roots count as the owner's own collateral, so its loans and its line build nothing, whatever the stake. 2.0.1 (published until then) would not catch it once V5's root is 30 days old, from 2026-11-10 15:06 UTC: a bigger stake opens a bigger line, and its loans count as someone else's risk (`scripts/test-score-v2-priors-stake.mjs`) |
| back yourself from a fresh second wallet, or buy an aged backer id | a backer counts only after 30 days on Priors, counted from when its current owner took the id (registry transfers); v2.1 adds funding-source clusters |
| pay yourself to fake income | payers in your cluster (owner, declared wallet, linked agents) are excluded; each payer is capped; unknown payers count half |
| fund a second wallet, then have it pay you | what your side sent that wallet directly is netted out of its payments; funding it through an intermediary is not caught yet (v2.1) |
| round-trip the same money | what goes straight back to the payer doesn't count; a round trip through a third wallet is v2.1 |
| send a defaulted agent to an honest owner | harmless: a default spreads only to the wallet that defaulted |
| push agents onto someone's address to dilute their income | only agents that declared the wallet share it, and a pushed agent's declaration is cleared by the registry |
| spam new tiny payers to stall the index | payers under 1 USDG are ignored, and new payers never hold other scores back |
| fund throwaway payers with under 1 USDG each, to mark a loan repaid from income | a payer under 1 USDG is never netted, and funds no loan (GHSA-4x5r-f6w5-fhhc) |
| buy a loan's bonus with one big payment | at most 20 USDG per payer per loan, unknown payers at half weight |
| sock-puppet payers funded elsewhere | per-payer cap; unknown payers at half weight; breadth only from payers of 1 USDG+; the income rung also needs a 30-day earned record; v2.1 funding-source clusters |
| claim someone else's payments | only the agent's owner and a wallet that signed to be its payment wallet count |
| climb fast | rungs need time: proven needs 14+ days of backed repayments, earned 30+ days since the first |
| buy an aged agent | a plain transfer restarts age, record and recourse. From 2.0.4 a sale on Priors' market keeps them (the owner's rule: a sold agent's score doesn't change): the sale is public, pays the market's fee in force, starts its 14-day hold, and needs no loan open and no default on either side; the buyer's own conduct counts from then on, and its default zeroes the agent |
| launder a plain transfer through the market (2.0.4): send the agent to a wallet, then sell it on, or sell it and pass it on | every hop between the owners must be a sale on Priors' market, seller to buyer in turn: a plain hop before or after a sale restarts the record. A sale on any other contract is a plain transfer |
| sell a zeroed agent to a fresh wallet to escape a default (2.0.4) | the market refuses a seller the pool marked; a sale whose seller, or whose payment wallet at the sale, was in default when it sold (a loan past its defaultable time, marked or not, or the declared wallet of such a loan's agent) carries nothing: the agent restarts as at a plain transfer |
| wash-sell to yourself (2.0.4) | adds nothing: a sale keeps the record as it was, and the seller's side is judged as it was the second before the sale (the payment wallet the agent declared at it stays in the seller's cluster, and a listed agent's listing is counted in), so the seller's loans are judged as before (a sale whose wallet is not read yet keeps nothing), and the income it was paid goes on counting as it did: its payers judged against that side (the seller and the list's wallets paying it are still paying themselves), netted against what that side sends back, a payment the new owner's wallet also gets counted once, the second wallet paying it after the sale counting nothing (it owns the agent then) and weighing before the sale what it weighed then (a payer's weight leaves out the agent it pays). The fee in force is spent; the score counts on no fee, which the market's timelock can lower |
| sell to yourself to count two wallets' income (2.0.4) | for the 30 days after a sale, payments to the wallet at the sale and to the one the new owner declares both count, where re-declaring alone would switch from one to the other. No new kind of payer on the wallet at the sale: its payers are judged against the seller's side as it was (the list's wallets included), and the new owner paying it counts nothing; each payer is capped at 20 USDG across both wallets and weighted, and income stays at 150 points at most; each sale pays the fee and starts its 14-day hold |
| gift your root to a borrower's owner | makes them one party, so the borrower's backed record stops counting; it costs the gifted stake and is undone by moving the root away |
| repay late but eventually | late loans earn nothing and cost 10 points |
| keep the money a day past the due time (2.0.3's window) | the window adds nothing: held time stops at the due time, as the pool's does, so a loan repaid inside it earns what one repaid at the due second earns, and one more than 24 hours past it is late. The pool charges no more for that day, as it charges nothing in its grace (`scripts/test-score-v2-late-window.mjs`) |
| behave, then take a big line and vanish | one default = 0 for every agent of the wallet that defaulted (per wallet, not per person: an owner who keeps one agent per wallet loses only that one); rungs need time. Lines do not follow rungs yet: the treasury's raise and the seats read the v1 score and their own rules, and a line grows only when a backer vouches more |

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
  a result older than an hour is not served. Free. While a newer weights version is scheduled, each answer also
  carries `upcoming: { version, from }`: that version, and the UTC instant from which published scores use it.
- The paid API (`api.priors.trade`, x402): `/v1/score/:id` adds `v2` with the breakdown.
- The hosted MCP (`mcp.priors.trade`) and the npm `@priors/mcp` (0.1.7 and later): `score_of` adds the v2 line.

When a v2 result is not available, each of them answers without it (`v2: null`) rather than failing.

## Changing it (future intervention)

- **Versioned.** The weights file carries a version. A change is a new weights file with its own version, a line in
  the changelog below, and an announcement on the dev log (priors.trade/updates) at least **7 days before** it becomes
  the default. Old versions stay in the repo, so any past score can be recomputed.
- **Pinned outputs.** Every published score names its version; apps can pin a version. The engine computes with
  the version it is given (`weightsFor` in `sdk/score-v2.mjs`: 2.0.0, 2.0.1, 2.0.2, 2.0.3 or 2.0.4; 2.0.0 when none
  is given). Priors' published scores use 2.0.1, 2.0.3 from 2026-11-02 00:00 UTC (in place of 2.0.2 from
  2026-11-01), and 2.0.4 from 2026-11-05 00:00 UTC: a score's version follows from its own timestamp.
- **No per-agent levers.** No per-agent overrides. Protecting the pool from a bad actor uses the existing on-chain tools
  (freeze, pause), which are public events.
- **The clusters list changes only by commit** (in Priors' own repository; it is not published, so a score it touches
  can't be rebuilt from public data alone). A link can only stop loans and payments from counting between the linked
  parties; it never adds points.

## Rollout

| phase | what | status |
|---|---|---|
| 1 | engine, weights, clusters, tests | **done** |
| 2 | show it: API (`/v1/score` adds `v2` with the breakdown), MCP `score_of` (hosted and npm), agent page (breakdown and rung; every agent shown the same way) | **live** 2026-09-27 (API, MCP); the agent page (breakdown and rung) is live too |
| 4 | income from any facilitator (USDG `AuthorizationUsed` events), declared payment wallets, netting, loans repaid from income | **built** (with phase 2) |
| 4a | x402 settled through Permit2 (the x402 proxies' `Settled()`) | **built** 2026-10-02 |
| 4b | v2.1: funding-source clusters (gas and first USDG), payer graph weights | after launch |
| 5 | on chain: attest v2 scores to the ERC-8004 reputation registry with version and input hash; treasury rules read the rung from a signed attestation; stable components move into the next `ScoreLib` | after a month of data |

## Changelog

- **2.0.4** (built 2026-10-27; published on the dev log, priors.trade/updates, on 2026-10-28; Priors' scores use it
  from 2026-11-05 00:00 UTC): 2.0.3 plus the record kept across a sale on Priors' agent market
  (`sdk/score-weights.v2.0.4.json`, `changeOfHands.keepAtMarketSale`; rules in "A sale on Priors' market (2.0.4)"), by
  the owner's rule that a sold agent's score doesn't change. A plain transfer still restarts age, record and recourse;
  so does a sale after or before a plain hop, a sale by a wallet in default (its seller, or the payment wallet the agent
  declared at it; a loan past its defaultable time, marked or not), and a sale whose wallet is not read yet. The
  payment wallet at the sale stays in the seller's cluster, and a listed agent's seller side is judged as it was the
  second before the sale. The income window carries too: for 30 days after the sale, payments to the wallet the agent
  declared at it count for the agent as they did, judged against the seller's side, never from the agent's owner after
  the sale, and the seller's loans keep the income bonus they earned; payments to the new owner's wallet count from the
  sale on; a payer's weight leaves out the agent it pays; so the score the second after the sale is the one the second
  before, income included, and its flags add `keptSale`. A default after the sale is the new owner's. Under 2.0.4 the
  attester posts its owner note, the paid API its flag and Go mode its note only when the score says the record
  restarted with this owner (`flags.ownershipChanged`, and not `keptSale`); the attester posts a plain note for a kept
  sale, and nothing for a change of owner while the scores' sales read (`sales`) is short. No weight, rung or penalty
  number changes, and with no sale every agent scores as under 2.0.3. Past sales count too: every sale on AgentMarket
  since it went live is read, so an agent sold there before 2026-11-05 gets its record back from that day when every
  change of owner in between was such a sale and no seller was in default. Announced 8 days before it becomes the
  default.
- **2.0.3** (built 2026-10-25; published on the dev log, priors.trade/updates, on 2026-10-25; Priors' scores use it
  from 2026-11-02 00:00 UTC, in place of 2.0.2 from 2026-11-01): 2.0.2 plus a 24-hour on-time window after a loan's due
  time (`sdk/score-weights.v2.0.3.json`, `penalties.lateAfterSeconds` 86400; `sdk/score-v2.mjs repaidLate`).
  CreditPoolV2 counts a repayment toward the record once the loan was held its `minScoreTerm` (7 days), held time
  capped at the term, and 2.0.0 to 2.0.2 count any repayment after the due time as late. So a 7-day loan, the shortest
  that counts, could be counted and on time only when repaid at its exact due second (public issue
  priors-agents/priors#16): repaid an hour after, it was late, earned nothing, cost 10 points and kept proven closed.
  Under 2.0.3 a repayment within 24 hours of the due time is on time; held time still stops at the due time, so the
  window earns nothing more than the due second would. And the Ethos lane's root (#8823, enrolled 2026-10-16) counts
  as a backer from day one, as the treasury does (`backers.dayOneRoots` "ethosRoot", the snapshot's
  `meta.ethosRootAgentId`; `dayOneRoots` in `sdk/score-v2-inputs.mjs`): it is Priors' own, but under 2.0.2 it is a
  fresh backer, so a loan on an Ethos line issued before 2026-11-15 would never count. A loan repaid inside the window
  also takes its share of the income bonus. No weight, rung or penalty number changes, and no score goes down: on the
  live snapshot of 2026-10-25 (block 97,262,509), 16 of 51,649 repayments move from late to on time, and 9 agents are
  left with no late repayment (#8811's among them); 5 repayments, 1 to 3 days past due, stay late. Every count of late
  repayments Priors shows beside a score uses the same window from the same instant: the board, the record by owner,
  the attestation's evidence (`evidenceIndex` in `sdk/attestation.mjs`, its `lateAfter`) and, through the snapshot's
  `meta.lateAfter` (86400 while the weights in force have the window), `/api/desks`, the paid API, Go mode's seats and
  the share card (`scripts/test-score-v2-late-window.mjs`). `priors-v2 borrow` defaults to 14 days (a backer that lends
  for less keeps its own limit) and explains a term of 7 days or less before it borrows (`sdk/priors-v2.mjs termNote`).
  Announced 7 days before it becomes the default, and before V5's roots are 30 days old.
- **2.0.2** (published 2026-10-23 on the dev log, priors.trade/updates; due as Priors' scores' version from 2026-11-01
  00:00 UTC, replaced before then by 2.0.3, which keeps its rule, from 2026-11-02): 2.0.1 plus SeatVaultV5's roots as the owner's own collateral (`sdk/score-weights.v2.0.2.json`,
  `backers.ownCollateralRoots` "seatVaultV5": `meta.seatVaultV5AgentId`, and `meta.seatVaultV5RetiredAgentId` when
  named). V5 sizes a line by the owner's own $PRIORS behind the agent and burns 75% of it on a default, so its loans are
  no risk someone else took, and a stake never changes a score. No weight changes. Under 2.0.1, V5's root (#8762,
  enrolled 2026-10-11) passes the 30-day backer rule on 2026-11-10 15:06 UTC; from then a bigger stake would raise the
  score (a $25 line's three loans score 111, a $50 line's 199; 24 for both under 2.0.2:
  `scripts/test-score-v2-priors-stake.mjs`). Inputs under 2.0.2 need the snapshot to name V5's root: without
  `meta.seatVaultV5AgentId` none are built (`ownCollateralRoots` in `sdk/score-v2-inputs.mjs` throws), so no score is
  published rather than one a stake moved. No score moves on the day: until V5's roots are 30 days old (the retired
  #8641 on 2026-11-08, #8762 on 2026-11-10), 2.0.1 and 2.0.2 give every agent the same score, so on 2026-11-01 only
  the published `version` changes. 2.0.0 stays the engine's default.
- **inputs, 2026-10-28** (all versions; private report GHSA-4x5r-f6w5-fhhc): an agent with no loan before its last
  registry transfer restarts at that transfer when it came after its enrolment, as one with v1 loans has since
  2026-10-01; a transfer before the enrolment, such as the mint, changes nothing, and an agent back with the owner whose
  v2 loans it holds keeps them (`transferRestart` in `sdk/score-v2-inputs.mjs`). Priors' publisher reads every scored
  agent's transfers, not only the roots' and those of the agents with v1 loans, and a new agent waits for a read in
  progress instead of restarting it; under 2.0.4 it reads every sold agent's transfers too (`plainTransferAt`), or a
  loanless agent sold on the market would restart at its sale. And only payers whose payments in the index add up to
  1 USDG fund a loan repaid from income: the index nets those alone. No weight changes. On the scores published at
  block 100,277,645 one flag changes and no score: #7617 (no loan, transferred after its enrolment) shows
  `ownershipChanged`, its score 0 before and after; under 2.0.3 and 2.0.4 one loan's income share goes from 0.012 to
  0.009 (#8811's: 0.03 USDG from a payer of 0.03 USDG in all), below the precision of any published figure.
- **inputs, 2026-10-14** (all versions): treasury v5's root (`meta.treasuryV5AgentId`, where an agent moves for its
  $25 raise) backs from day one, as the treasury does: a moved line's loans stay someone else's risk.
- **inputs, 2026-10-04** (all versions): a loan repaid through AutoRepay (Autopay) is read from AutoRepay's own
  `AutoRepaid` log, which names who paid: the agent's wallet, its owner, or both, each of which must be the agent's own
  for the loan to count as repaid from income (`readRepayers` in `sdk/x402-income.mjs`, `repaidByOwn` in
  `sdk/score-v2-inputs.mjs`). Without it the payer was AutoRepay itself, never the agent's own.
- **inputs, 2026-10-02** (all versions): x402 payments settled through Permit2 count as income, read from the x402
  proxies' `Settled()`/`SettledWithPermit()` and the USDG transfer right before; until now only EIP-3009 payments
  were read. No published score changes: a full index read with it from pool v2's deploy block to block 78,018,367
  found no Permit2 payment to an agent's declared wallet (992 USDG settles went through Permit2 on Robinhood Chain
  since v1's deploy, none to an agent's wallet).
- **inputs, 2026-10-01** (all versions): a change of hands after an agent's v1 loans restarts its record too, read
  from the identity registry's transfers (`ownerSince` in `buildInputs`), since v1 loans carry no owner; a transfer
  before every v1 loan (the mint) changes nothing, and an agent with no v1 loan is read from its v2 loans as before.
  Found by our own audit of the public repo; no agent is known to have changed hands after its v1 history.
- **inputs, 2026-09-29** (all versions): a backer's 30 days count from when its current owner took the id, read
  from the identity registry's transfers, not from its enrolment: a bought aged id is a new backer (private report
  GHSA-6f8j). No published score changed: no backer id had changed hands after enrolling.
- **2.0.1** (2026-09-28): a loan backed by the stock vault's root (`meta.stockVaultAgentId`) counts as the borrower's
  own money, since its own tokens stand behind it, not as someone else's risk (`sdk/score-weights.v2.0.1.json`,
  `backers.ownCollateralRoots`; found by the stocks readiness review of 2026-09-28). No weight changes. A
  self-collateralised agent at day 30 scores 29 under it, 519 under 2.0.0. 2.0.0 stays the engine's default (the
  version `weightsFor` returns when none is named) until 2.0.1 is announced on the dev log (priors.trade/updates), 7
  days ahead. While the stock vault is live, Priors publishes v2 scores under 2.0.1 only: 2.0.0 scores (or any score
  while the vault's agent is unknown) are withheld rather than published inflated.
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
