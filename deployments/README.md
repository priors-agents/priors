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

## What is here

`4663.json` — **Robinhood Chain mainnet, live.** The CreditPool, the TreasurySponsor (ERC-8004 identity `#436`),
the ReserveFunder, and the block the pool was deployed at. `npx priors doctor` picks it up with no configuration;
point `RPC_URL` at `https://rpc.mainnet.chain.robinhood.com` and everything else resolves from this file.

`npx priors doctor` tells you what it resolved for the chain you are pointed at, and says so rather than guessing
when there is no record.

`31337.json` — the local dev chain — is written by `npm run devnet` and deliberately gitignored: it is a
throwaway chain whose addresses mean nothing to anyone else.

A deployment becomes usable the moment its record is committed here; no further configuration is needed.
`POOL` and `TREASURY` in `.env` override the record, which is how you point the tools at an address that has
not been committed yet.
