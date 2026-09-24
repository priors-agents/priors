# Deployment records

One JSON file per chain and pool generation: `<chainId>.json` for v1, written by `script/Deploy.s.sol`, and
`<chainId>.v2.json` for v2, written by `script/DeployV2.s.sol`. Every tool in this repo — the CLIs, the SDK's
`env.mjs`, the quickstart — reads the file matching the chain it is connected to, so a deployment becomes usable
the moment its record lands here. The v1 shape:

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

`4663.v2.json` — **Robinhood Chain mainnet, v2, live.** Written in the shape `script/DeployV2.s.sol` produces
(`pool`, `lens`, `timelock`, `treasuryV4`, `seatVault`, `usdg`, `registry`, `priors`, `safe`, `v1`, `deployBlock`),
plus the two roots' agent ids (`treasuryV4AgentId` 6228, `seatVaultAgentId` 6229), `v1Pool` and
`"status": "live"`. `npx priors-v2` and `resolveV2()` in `sdk/env.mjs` read it; `PRIORS_ADDRESSES` points them at
another file.

```json
{
  "chainId": 4663,
  "status": "live",
  "deployBlock": 71702460,
  "pool": "0x281210097f0de7A8FB6F87310AF0f089c9C8DE21",
  "lens": "0x9d7035722bd42C551f82FEB9FDDd17453AEF3D9B",
  "timelock": "0x5d984C274035F81BB327d532897a902C5125F87c",
  "treasuryV4": "0x0c5091235A25bBFD3F5a009cBe04120D0CBAD573",
  "seatVault": "0x6D934C07a33E7285cE691A9B258cdB53F18e6B5F",
  "…": "…"
}
```

`4663.json` — **Robinhood Chain mainnet, v1, paused.** The v1 CreditPool, TreasurySponsor v3 (ERC-8004 identity
`#486`), the ReserveFunder, and the block the pool was deployed at. It carries `"status": "paused"` and
`"supersededBy": "4663.v2.json"`: the v1 tools still resolve it so v1 history stays readable, and
`npx priors doctor` says the pool is paused and points at v2. New lines and loans on it revert.

`npx priors doctor` (v1) and `npx priors-v2 status` (v2) tell you what they resolved for the chain you are
pointed at, and say so rather than guessing when there is no record.

`31337.json` — the local dev chain — is written by `npm run devnet` and deliberately gitignored: it is a
throwaway chain whose addresses mean nothing to anyone else.

A deployment becomes usable the moment its record is committed here; no further configuration is needed.
For v1, `POOL` and `TREASURY` in `.env` override the record, which is how you point the tools at an address that has
not been committed yet.
