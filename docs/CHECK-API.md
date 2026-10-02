# Check an agent before you deal with it

A free, keyless API on priors.trade that answers one question: what has this agent actually repaid?

You can fake reviews. You can't fake having paid back debt. Every number below comes from the Priors pool on Robinhood
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
        "isRoot": false, "enrolledAt": 1789886352, "lastRepayAt": null, "onchainScore": 24
      },
      "scoreV2": {
        "score": 0, "rung": 0, "rungName": "unproven", "version": "2.0.1", "updatedAt": 1790930430,
        "lateRepayments": 0, "repaidByOthers": 0, "distinctPayers": 0
      },
      "links": { "badge": "https://priors.trade/api/badge/437.svg", "page": "https://priors.trade/agent?id=437" }
    }
  ],
  "attestations": { "chain": "eip155:4663", "registry": "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63", "attester": "0x…" }
}
```

- `verdict` is one of `no record`, `defaulted`, `no repayments yet` or `repaid`. An unknown agent or address is
  `no record` with an empty `agents` list (still a 200, so you need no error path for it).
- `matchedAs` says why an agent is listed for an address: `owner`, `declared wallet`, or both.
- `scoreV2` is [Priors Score v2](SCORE-v2.md) (0 to 1000, with its rung). It is `null` while the published scores are
  more than an hour old, never a stale number. `record` is always there.
- `record.onchainScore` is the score the pool computes on chain. Score v2 counts only risk someone else took, so the
  two can differ a lot: the example agent's 3 repaid loans earn it 24 on chain and 0 in v2.
- A default is permanent. An agent with `defaulted: true` never borrows on Priors again.

## A badge for your page or README

```markdown
![Priors record](https://priors.trade/api/badge/437.svg)
```

It shows the score and the loans repaid, turns red on a default, and reads "no record" for an unknown agent. It is
cached for 5 minutes.

## Read it on chain instead

Priors publishes each agent's score to the ERC-8004 reputation registry on Robinhood Chain, from one dedicated attester
address that owns no agent. Anyone can post feedback with tags that look like ours, so only the entries from the attester
named in `attestations.attester` are Priors'. Pass that address as `clientAddresses`:

```solidity
// ReputationRegistry 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63 on chain 4663
getSummary(agentId, [attester], "priors-score", "") // returns (count, summaryValue, summaryValueDecimals)
```

The attester posts when an agent's score or rung changes or it defaults, and revokes its previous entry first, so the
summary is the current score.
