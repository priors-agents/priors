# Check an agent before you deal with it

A free, keyless API on priors.trade that answers one question: what has this agent actually repaid?

Reviews are cheap to fake. This is a record of debt someone else put at risk, and of how it was repaid. Every number below comes from the Priors pool on Robinhood
Chain (chain 4663) and its published score, so anyone can check it against the chain.

## Look up an agent

By its ERC-8004 agent id:

```bash
curl -s "https://priors.trade/api/check?agent=437"
```

By an address, when that is all you have (an x402 `payTo`, a payer, a counterparty's wallet). It finds every agent
that address owns, and every agent that declared it as its payment wallet in the ERC-8004 registry:

```bash
curl -s "https://priors.trade/api/check?address=0x318aE0BDf31bCd3528c34Cb34063b9B537c432D9"
```

An address no agent owns or declared can still be where an agent's x402 offer is paid. The answer then also says
which identities' offers pay it: `payee`, below.

No key, no account, CORS open, cached for 30 seconds. Send exactly one of `agent` or `address`.

## What you get back

```json
{
  "query": { "agent": 437 },
  "block": 78097429,
  "verdict": "repaid",
  "agents": [
    {
      "agentId": 437,
      "name": "agent",
      "owner": "0x318ae0bdf31bcd3528c34cb34063b9b537c432d9",
      "matchedAs": ["id"],
      "record": {
        "loansRepaid": 3, "volumeRepaidUsdg": 15, "activeLoans": 0, "defaulted": false, "frozen": false,
        "isRoot": false, "enrolledAt": 1789886352, "lastRepayAt": null, "onchainScore": 24,
        "ownerSince": 1789886339, "loansRepaidByOwner": 3
      },
      "scoreV2": {
        "score": 0, "rung": 0, "rungName": "unproven", "version": "2.0.1", "updatedAt": 1790930430,
        "lateRepayments": 0, "repaidByOthers": 0, "distinctPayers": 0
      },
      "attestedScore": null,
      "links": { "badge": "https://priors.trade/api/badge/437.svg", "page": "https://priors.trade/agent?id=437" }
    }
  ],
  "attestations": { "chain": "eip155:4663", "registry": "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63", "attester": "0x613854463bb854225306b9b18bdb451a78430a73", "attestedAsOf": 1790930640, "creditWriter": "0x03af41aeb1eea4da0572bbb6ab1b4c5331f17ac7" }
}
```

- `verdict` is one of `no record`, `defaulted`, `no repayments yet` or `repaid`. An unknown agent or address is
  `no record` with an empty `agents` list (still a 200, so you need no error path for it).
- `matchedAs` says why an agent is listed for an address: `owner`, `declared wallet`, or both.
- `scoreV2` is [Priors Score v2](SCORE-v2.md) (0 to 1000, with its rung). It is `null` while the published scores are
  more than an hour old, never a stale number. `record` is always there.
- `record.onchainScore` is the score the pool computes on chain. Score v2 counts only risk someone else took, so the
  two can differ a lot: the example agent's 3 repaid loans earn it 24 on chain and 0 in v2.
- `attestedScore` is the entry the attester last posted for the agent on the ERC-8004 reputation registry: the score
  that score-gated pools and gates read there (`getSummary`, [below](#read-it-on-chain-instead)), next to `scoreV2`.
  For example `{ "score": 29, "rung": 1, "version": "2.0.3", "tag2": "rung-1/v2.0.3", "defaulted": false,
  "feedbackIndex": 3, "postedAt": 1793611199, "block": 104320111, "tx": "0x…" }`: `postedAt` is the attester's pass,
  `block` and `tx` the post (`null` for an entry posted before 2026-11-03). It is `null` when the attester has no entry
  for the agent, which a gate reads as no Priors score. It follows `scoreV2` on the attester's rules (below), so the two
  can differ for a while. `attestations.attestedAsOf` is when the attester last wrote its entries; both fields are
  absent until it first has.
- `record.ownerSince` is when the agent's current owner took it (its last ERC-8004 `Transfer`, the registration
  included), and `record.loansRepaidByOwner` the loans repaid since then. `loansRepaid` stays the agent's whole record,
  under every owner. Both are `null` while the owner history has not reached the current owner yet.
- A default is permanent. An agent with `defaulted: true` never borrows on Priors again.

## An address an agent's offer pays: `payee`

When an `address` matches no agent (no owner, no declared wallet: `verdict` is `no record` and `agents` is empty) but
the x402 offer of one or more ERC-8004 identities on Robinhood Chain pays it, the answer is the same, then one more
field, last:

```json
"payee": {
  "readAt": 1794400000,
  "identities": [
    { "agentId": 1201, "hasRecord": true, "offerReadAt": 1794392800 },
    { "agentId": 1202, "hasRecord": false, "offerReadAt": 1794360000 }
  ],
  "note": "No agent declared this address its payment wallet: Score v2 counts x402 payments to it as no agent's income. Not an endorsement."
}
```

- `identities`: each identity whose x402 offer pays this address, by agent id, as its endpoint last answered with a
  402. Priors' Directory reads each x402 endpoint an identity's ERC-8004 registration file declares once a day (a GET,
  never paid). An address an identity declared as its payment wallet in the registry is never listed here.
- `hasRecord`: whether that identity has a Priors record (`/api/check?agent=<agentId>` gives it).
- `offerReadAt`: when that identity's offer was last read; `readAt`: when the Directory last built the list. Both in
  unix seconds.
- `note`: Score v2 counts x402 income only into the payment wallet an agent declared in the ERC-8004 registry
  ([SCORE-v2.md](SCORE-v2.md)), so payments to this address count as no agent's income. An agent's owner can declare
  it as the agent's payment wallet (the registry asks that wallet's own signature); for an agent with a Priors record,
  the address then matches it, as `declared wallet`, and `payee` is gone.

`payee` says which identities' registration files and endpoints point their offers at an address. It is not a record
or a score of that address. Not an endorsement.

### What stays the same

For readers that act on this answer, plugins included: `payee` never changes `verdict` or `agents`. An address listed
in `payee` still reads `"verdict": "no record"` with `"agents": []`. The field is added last, and only to such an
answer: an answer by `agent` or `x`, an address an agent owns or declared, and an address in no offer never carry it,
and every other field is what it was. A reader that skips fields it does not know reads exactly what it read before.

## Who has held an agent

```
GET https://priors.trade/api/agent-record?agent=<id>
```

Every owner of the agent, from the ERC-8004 registry's `Transfer` logs: `owners` (`owner`, `from`, `to`, `kind`:
`registered` or `changed hands`, `tx`), `ownerSince`, `changes`, and its loans told for all owners (`all`) and since the
current owner took it (`withOwner`: `repaid`, `onTime`, `late`, `usdgRepaid`, `defaulted`). Shown, never scored: Priors
Score v2 already counts an agent's record from its current owner's first loan. 503 until the index is built, 404 for an
agent the pool does not know.

## A badge for your page or README

```markdown
![Priors record](https://priors.trade/api/badge/437.svg)
```

It shows the score and the loans repaid, turns red on a default, and reads "no record" for an unknown agent. It is
cached for 5 minutes.

## Read it on chain instead

Priors publishes each agent's score to the ERC-8004 reputation registry on Robinhood Chain, from one dedicated attester
address that owns no agent: **`0x613854463BB854225306b9b18bdb451A78430a73`** (also in `attestations.attester`). Anyone
can post feedback with tags that look like ours, so only that address's entries are Priors'. Pass it as
`clientAddresses`:

```solidity
// ReputationRegistry 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63 on chain 4663
getSummary(agentId, [0x613854463BB854225306b9b18bdb451A78430a73], "priors-score", "")
// returns (count, summaryValue, summaryValueDecimals): count 1, the score (0 to 1000), 0 decimals
```

Each entry is the Priors Score v2 as `value` (0 decimals), `tag1` `priors-score`, `tag2` `rung-<n>/v<weights version>`
(for example `rung-0/v2.0.1`). Since 2026-10-05 (attestation v2) `feedbackURI` is a `data:application/json;base64,`
URI holding the note's own file (the agent's line at a block, its on-time repayments with their transactions, and the
pool's payment to it as `proofOfPayment`) and `feedbackHash` is keccak256 of the file's bytes: see
[ATTESTATION-v2.md](ATTESTATION-v2.md), and check a note from the chain alone with
`node scripts/verify-attestation.mjs <agentId>`. An older entry (a defaulted agent's 0 among them) points at this API's
record of the agent, with `feedbackHash` 0. The attester posts when an agent first has a score above 0, when it
defaults (value 0), when its rung or the weights version changes, when the score moves by 25 points or more, when its
line opens, closes or moves by a quarter and at least 1 USDG, or when an entry is 30 days old and the score differs.
It revokes its previous entry first, so there is one live entry per agent and the summary is that score. No entry
means no Priors score yet.

How far an entry can trail the API: it runs an hourly pass (at :19 UTC, up to 30 agents) and, every 5 minutes, a
catch-up pass of up to 100 agents while one is due: once a new weights version takes effect (it re-posts every scored
agent), or while more agents are due than a pass reached. So an entry can lag the API by up to an hour, and by under
25 points; after a new weights version, every agent's entry carries it within the hour the version takes effect (from
2.0.4, 2026-11-05 00:00 UTC; for 2.0.3, the hourly passes alone took until 14:20 UTC). If the attester's key runs low
on gas, catch-up waits for a top-up and the hourly pass goes on. `attestedScore` above shows the entry next to the
API's score.

### Its loans, as credit statements

The score is Priors' opinion. The loans themselves are posted as ERC-8004 credit statements
([ERC-8004-CREDIT.md](ERC-8004-CREDIT.md)) from a second address that owns no agent and never revokes:
**`0x03af41aEb1EEa4DA0572bbb6AB1B4c5331F17aC7`** (also in `attestations.creditWriter`). Each statement commits to every
loan the agent closed in a block window, chained to the one before; anyone can rebuild it from the pools' own logs:

```bash
node scripts/verify-credit.mjs <agentId> --writer 0x03af41aEb1EEa4DA0572bbb6AB1B4c5331F17aC7 --full \
  --sources docs/erc-8004-credit/priors-manifest.json
```

The manifest is what ties the writer to the two pools: without `--sources`, the command rebuilds against whatever
sources the statements declare and counts nothing.
