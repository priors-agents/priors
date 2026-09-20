// Resolving "which chain, which pool, which wallet" is the part every agent gets wrong first, so it lives here
// instead of in each script. Nothing is stored anywhere but the chain and your own .env.
//
//   import { resolve } from "./sdk/env.mjs";
//   const { priors, agentWallet, dep, chainId } = await resolve();
//
// Order of precedence, highest first:
//   POOL / TREASURY / USDC env vars   -> explicit addresses, any chain
//   deployments/<chainId>.json        -> whatever `npm run devnet` or a real deployment wrote
//
// The signer comes from PRIVATE_KEY. On a local dev chain (31337) a deterministic throwaway wallet is derived
// instead, so `npm run quickstart` works with no setup at all; that fallback never applies to a real chain.
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { Priors } from "./priors.mjs";

export const ROOT = resolvePath(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Load `.env` into process.env, without a dependency and without clobbering anything already exported.
 *
 * Every doc in this repo tells you to `cp .env.example .env` and put RPC_URL and PRIVATE_KEY in it. Until this
 * existed nothing read that file, so following the documented real-chain setup quietly talked to localhost and
 * signed with nothing — the documented production path failing before the first transaction.
 *
 * Deliberately minimal: `KEY=value`, `#` comments, optional surrounding quotes. An already-set variable wins, so
 * `RPC_URL=... npx priors doctor` still overrides the file.
 */
export function loadDotEnv(file = join(ROOT, ".env")) {
  if (!existsSync(file)) return {};
  const loaded = {};
  for (const raw of readFileSync(file, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim().replace(/^export\s+/, "");
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    loaded[key] = value;
    if (process.env[key] === undefined) process.env[key] = value;
  }
  return loaded;
}
// The repo's own .env (what the docs tell you to create), plus one in the working directory for when the CLI is
// installed as a dependency and run from somewhere else. The working directory wins.
loadDotEnv(join(process.cwd(), ".env"));
loadDotEnv();
export const DEV_CHAIN = 31337;
/// anvil's own published test mnemonic. Public by design, worthless by design, and never used off chain 31337.
export const DEV_MNEMONIC = "test test test test test test test test test test test junk";
/// wallet 0 of that mnemonic: anvil pre-funds it, and `npm run devnet` deploys and lends from it.
export const devWallet = (index) => ethers.HDNodeWallet.fromPhrase(DEV_MNEMONIC, undefined, `m/44'/60'/0'/0/${index}`);

export const deploymentPath = (chainId) => join(ROOT, "deployments", `${chainId}.json`);

// --- money ---------------------------------------------------------------------------------------------------
// USDG has 6 decimals on chain and the SDK speaks whole dollars, so this conversion happens in a dozen places.
// It lives here once: a second implementation that rounds differently is how $0.011666 becomes $0.012.
export const USDG_DECIMALS = 6n;
const UNIT = 10n ** USDG_DECIMALS;
/** Whole dollars (number or bigint) -> 6-decimal units. */
export const toUnits = (dollars) => (typeof dollars === "bigint" ? dollars * UNIT : BigInt(Math.round(Number(dollars) * Number(UNIT))));
/** 6-decimal units -> dollars as a number. Fine for display; do not do arithmetic on the result. */
export const fromUnits = (units) => Number(units) / Number(UNIT);
/**
 * Money, formatted for a human, identically everywhere.
 * Pinned to en-US on purpose: the default locale renders $0.0116 as $0,0116 on a French machine, and a CLI whose
 * output depends on who ran it is a CLI whose output nobody can paste into a bug report.
 */
export const formatUsd = (dollars) => `$${Number(dollars).toLocaleString("en-US", { maximumFractionDigits: Number(USDG_DECIMALS) })}`;
/** Same, from raw on-chain units. */
export const formatUnits = (units) => formatUsd(fromUnits(units));

export function readDeployment(chainId) {
  const p = deploymentPath(chainId);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, "utf8"));
}

export class NoDeployment extends Error {
  constructor(chainId) {
    super(
      `no deployment for chain ${chainId}.\n` +
        (chainId === DEV_CHAIN
          ? "  run `npm run devnet` first (it starts a local chain and deploys the pool)."
          : "  the CreditPool is not deployed on this chain yet. Set POOL and TREASURY explicitly, or run\n" +
            "  `npm run devnet` for a local chain. See the Status section of the README.")
    );
    this.chainId = chainId;
  }
}

/** `RPC_URL` may be one endpoint or several, comma-separated. */
export function splitRpcs(rpc) {
  if (Array.isArray(rpc)) return rpc.filter(Boolean);
  return String(rpc || "").split(",").map((s) => s.trim()).filter(Boolean);
}

/* Tries endpoints in the order given: first entry first, moving on only when that one fails, with a
   second attempt each before writing it off. Deliberately not ethers' FallbackProvider, which queries
   providers together and waits for a weighted quorum - a dead first entry there can stall every call
   or fail quorum while a healthy endpoint sits behind it. Priority order is what an operator with a
   private endpoint and a public backstop actually wants.

   The seam is `_send`, not `send`: ethers' own `getNetwork()` reaches the transport through `_send`
   directly, so overriding the higher-level `send` leaves network detection - the very first call -
   pinned to the first endpoint. Found by testing, not by reading.

   Only a THROWN transport error fails over. A JSON-RPC error inside a successful response (a revert,
   say) is the chain's answer and would be identical everywhere; retrying it elsewhere would just be
   slower. */
export function makeProvider(rpcs, providerOpts = {}) {
  const urls = splitRpcs(rpcs);
  if (urls.length === 0) throw new Error("no RPC endpoint configured");
  // Single endpoints get the retry too - that is the common case, and the one that needs it most.
  const ATTEMPTS = 2;
  const BUDGET_MS = 15000; // a CLI may wait longer than a web page, but not forever

  class FailoverProvider extends ethers.JsonRpcProvider {
    constructor() {
      super(urls[0], undefined, providerOpts);
      this._backups = urls.slice(1).map((u) => new ethers.JsonRpcProvider(u, undefined, providerOpts));
      this.rpcUrls = urls.slice();
    }
    async _send(payload) {
      const started = Date.now();
      let last;
      for (let i = 0; i < urls.length; i++) {
        for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
          if (Date.now() - started > BUDGET_MS) throw last || new Error("RPC budget exhausted");
          try {
            return i === 0 ? await super._send(payload) : await this._backups[i - 1]._send(payload);
          } catch (e) {
            last = e;
          }
        }
      }
      throw last;
    }
  }
  return new FailoverProvider();
}

/**
 * @param {{rpc?: string, privateKey?: string, needSigner?: boolean}} [opts]
 */
export async function resolve(opts = {}) {
  const rpc = opts.rpc || process.env.RPC_URL || "http://127.0.0.1:8545";
  const rpcs = splitRpcs(rpc);
  // cacheTimeout off: on chains that mine instantly, ethers' 250 ms result cache hands back stale nonces
  const provider = makeProvider(rpcs, { cacheTimeout: -1 });
  let chainId;
  try {
    chainId = Number((await provider.getNetwork()).chainId);
  } catch (e) {
    const where = rpcs.length > 1 ? `none of ${rpcs.length} endpoints (${rpcs.join(", ")})` : rpcs[0];
    throw new Error(`cannot reach ${where}: ${e.shortMessage || e.message}\n  is the chain running? \`npm run devnet\` starts a local one.`);
  }

  const file = readDeployment(chainId) || {};
  const dep = {
    chainId,
    creditPool: process.env.POOL || file.creditPool,
    treasurySponsor: process.env.TREASURY || file.treasurySponsor,
    usdc: process.env.USDC || file.usdc,
    registry: file.registry,
    usdcIsMock: process.env.USDC ? false : Boolean(file.usdcIsMock),
    treasuryAgentId: file.treasuryAgentId,
  };
  if (!dep.creditPool) throw new NoDeployment(chainId);

  // `.env.example` ships `PRIVATE_KEY=0x` as a placeholder. Copied and left unfilled it is present-but-useless,
  // and handing it to ethers produces an opaque "invalid BytesLike" instead of "you have not set a key yet".
  const rawPk = opts.privateKey || process.env.PRIVATE_KEY;
  const pk = rawPk && rawPk !== "0x" && rawPk !== "0x0" ? rawPk : undefined;
  let signer = null;
  let derived = false;
  if (pk) {
    signer = new ethers.NonceManager(new ethers.Wallet(pk, provider));
  } else if (chainId === DEV_CHAIN) {
    // a wallet outside the range devnet.mjs and the demos fund, so a quickstart never collides with them
    signer = new ethers.NonceManager(devWallet(50).connect(provider));
    derived = true;
  } else if (opts.needSigner) {
    throw new Error("PRIVATE_KEY is not set. This chain is not a dev chain, so no wallet can be derived for you.\n  cp .env.example .env and put in the key that owns (or will own) your ERC-8004 identity.");
  }

  const priors = new Priors({ provider, pool: dep.creditPool, treasury: dep.treasurySponsor, signer });
  return { provider, signer, derived, dep, chainId, rpc, priors, address: signer ? await signer.getAddress() : null };
}

/** True when the chain answers anvil/hardhat cheat methods, i.e. we may warp time and mint mock money. */
export async function isDevChain(provider) {
  try {
    await provider.send("anvil_nodeInfo", []);
    return true;
  } catch {
    return false;
  }
}
