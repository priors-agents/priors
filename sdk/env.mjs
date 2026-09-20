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

/** How long the whole call may take, across every endpoint and attempt, before an honest error beats waiting. */
const RPC_BUDGET_MS = 15000; // a CLI may wait longer than a web page, but not forever
const RPC_ATTEMPTS = 2; // passes over the endpoint list
/* A single attempt may use most of the budget, and the cap is deliberately NOT divided by the number
   of endpoints. Dividing it was a real bug: with three endpoints configured each attempt got 2.5s, and
   Robinhood Chain's own endpoint has been measured answering in 5.4s (and once at 10.4s) against a
   375ms median. So adding backups - exactly what the docs tell you to do - made a working setup fail,
   because the healthy-but-slow first endpoint was killed before it could answer. Slow-but-alive is the
   failure that actually happens on this chain; a silent endpoint costs one attempt's worth and no more,
   because the remaining budget is what bounds every later attempt. */
const RPC_ATTEMPT_MAX_MS = 6000;

/** True when the response is a node declining to serve the request, rather than the chain answering. */
function declinedByNode(res) {
  for (const r of Array.isArray(res) ? res : [res]) {
    const e = r && r.error;
    if (!e) continue;
    const msg = String(e.message || "").toLowerCase();
    if (e.code === -32005 || e.code === -32029 || e.code === 429) return e.message;
    if (/rate limit|too many requests|archive|exceed|range|capacity|unavailable|try again/.test(msg)) return e.message;
  }
  return "";
}

/* Tries endpoints in the order given: first entry first, moving on only when that one fails, with a
   second pass before writing the list off. Deliberately not ethers' FallbackProvider, which queries
   providers together and waits for a weighted quorum - a dead first entry there can stall every call
   or fail quorum while a healthy endpoint sits behind it. Priority order is what an operator with a
   private endpoint and a public backstop actually wants.

   The seam is `_send`, not `send`: ethers' own `getNetwork()` reaches the transport through `_send`
   directly, so overriding the higher-level `send` leaves network detection - the very first call -
   pinned to the first endpoint. Found by testing, not by reading.

   A THROWN transport error fails over, and so does a node REFUSING to serve the request - a rate limit,
   or a non-archive node declining a deep `eth_getLogs`. On Robinhood Chain that distinction is not
   academic: of the three public endpoints, two answer a deep log query with HTTP 403 "Archive requests
   require a personal token" and `-32005` "the network is busy". A revert is different: it is the chain's
   answer, identical on every node, so it is returned rather than retried everywhere for nothing. */
export function makeProvider(rpcs, providerOpts = {}) {
  const urls = splitRpcs(rpcs);
  if (urls.length === 0) throw new Error("no RPC endpoint configured");
  // Single endpoints get the retry too - that is the common case, and the one that needs it most.
  const connect = (url) => {
    const req = new ethers.FetchRequest(url);
    req.timeout = RPC_ATTEMPT_MAX_MS; // backstop; the race below is what actually bounds an attempt
    return req;
  };
  /* FetchRequest's timeout is fixed at construction, so bounding an attempt by the REMAINING budget
     has to be a race here rather than a property. */
  const withDeadline = (promise, ms) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`RPC attempt exceeded ${ms}ms`)), ms);
      promise.then(
        (v) => {
          clearTimeout(t);
          resolve(v);
        },
        (e) => {
          clearTimeout(t);
          reject(e);
        }
      );
    });

  class FailoverProvider extends ethers.JsonRpcProvider {
    constructor() {
      super(connect(urls[0]), undefined, providerOpts);
      this._backups = urls.slice(1).map((u) => new ethers.JsonRpcProvider(connect(u), undefined, providerOpts));
      this.rpcUrls = urls.slice();
    }
    async _send(payload) {
      // A broadcast is never retried and never failed over. If the transport dies after the node
      // already accepted the transaction, sending it again gets "already known" back - an RPC error
      // inside a 200, which this loop would hand to the caller as a failure for a transaction that
      // in fact succeeded. A caller that believes that may re-sign at the next nonce and pay twice.
      // Surfacing the transport error immediately is the honest answer: the tx hash is deterministic,
      // so the caller can look it up.
      const one = Array.isArray(payload) ? payload : [payload];
      if (one.some((r) => r && r.method === "eth_sendRawTransaction")) return super._send(payload);

      const started = Date.now();
      let last;
      /* Endpoints are the INNER loop: one pass over all of them in priority order, then a second pass.
         Exhausting the first endpoint's retries before trying the second meant a silent first endpoint
         ate the whole budget and the healthy backup was never reached - the failover starving itself.
         Priority still holds, because every pass starts at the first entry. */
      for (let attempt = 0; attempt < RPC_ATTEMPTS; attempt++) {
        for (let i = 0; i < urls.length; i++) {
          const left = RPC_BUDGET_MS - (Date.now() - started);
          if (left <= 0) throw last || new Error("RPC budget exhausted");
          const share = Math.min(left, RPC_ATTEMPT_MAX_MS);
          try {
            const call = i === 0 ? super._send(payload) : this._backups[i - 1]._send(payload);
            const res = await withDeadline(call, share);
            if (declinedByNode(res) && urls.length > 1) {
              last = new Error(declinedByNode(res));
              continue;
            }
            return res;
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
