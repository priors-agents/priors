# Deployment records

One JSON file per chain, named `<chainId>.json`, written by `script/Deploy.s.sol`. Every tool in this repo —
the CLI, the SDK's `env.mjs`, the quickstart — reads the file matching the chain it is connected to, so a
deployment becomes usable the moment its record lands here.

```json
{
  "chainId": 31337,
  "creditPool": "0x…",
  "treasurySponsor": "0x…",
  "treasuryAgentId": 1,
  "registry": "0x…",
  "usdc": "0x…",
  "usdcIsMock": true,
  "reserveFunder": "0x…",
  "owner": "0x…"
}
```

## What is here today

**Nothing but this file.** There is no committed deployment record, because the CreditPool is not deployed on
Robinhood Chain mainnet (4663) or testnet (46630) yet.

`31337.json` — the local dev chain — is written by `npm run devnet` and deliberately gitignored: it is a
throwaway chain whose addresses mean nothing to anyone else.

When a real deployment happens, its record is committed here and `npx priors doctor` picks it up with no
further configuration. Until then, `POOL` and `TREASURY` in `.env` are the way to point the tools at an
address by hand.
