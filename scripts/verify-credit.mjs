// An agent's ERC-8004 credit history (docs/ERC-8004-CREDIT.md), from any lender writing "erc8004-credit/v1"
// entries, checked against the chain alone: no lender's server is asked anything.
//
//   node scripts/verify-credit.mjs <agentId> [--writer 0x… (repeatable)] [--full] [--sources manifest.json]
//        [--no-funds] [--rpc URL] [--history-rpc URL] [--from-block N] [--json]
//
// Light (default) samples. It checks every entry's bytes, hash and shape, each chain (seq, prev, windows back to back,
// sources covered from their first block, one asset, nothing revoked), and each statement's anchors and each default's
// leaf against the lender's logs, with the asset's movement for those loans. It does not check that a root covers every
// loan of its window, nor the totals: it prints them as the writer's claims and counts nothing.
// --full rebuilds every statement from the lender's logs (leaves, root, totals, opened, outstanding); fund movement
// stays sampled (anchors and default entries). Only --full results of --writer writers are counted, by asset.
// --sources: a manifest of the sources the reader trusts each writer to have, { "<writer>": { "sources": [ … ] } },
// sources as the files write them. Without it a source a writer never declares is not seen.
// Without --writer it reports every writer found and trusts none.
//
// Exit: 0 every check that ran passed and every --writer has statements (in light mode: nothing it checked is wrong);
// 1 a problem; 2 no data (a --writer with no statement for the agent, or no credit entry at all); 64 usage.
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { readCredit, readManifest } from "../sdk/credit-reader.mjs";

const USAGE = "usage: node scripts/verify-credit.mjs <agentId> [--writer 0x…] [--full] [--sources manifest.json] [--no-funds] [--rpc URL] [--history-rpc URL] [--from-block N] [--json]";
const usage = (m) => { console.error(m ? `${m}\n${USAGE}` : USAGE); process.exit(64); };
const args = process.argv.slice(2);
const opt = (f) => { const i = args.indexOf(f); return i < 0 ? null : args.splice(i, 2)[1]; };
const opts = (f) => { const out = []; let v; while ((v = opt(f))) out.push(v); return out; };
const flag = (f) => { const i = args.indexOf(f); if (i < 0) return false; args.splice(i, 1); return true; };
const asJson = flag("--json"), full = flag("--full"), noFunds = flag("--no-funds");
let writers;
try { writers = opts("--writer").map((w) => ethers.getAddress(w)); } catch (_) { usage("--writer takes an address"); }
const sourcesFile = opt("--sources");
let manifest = null;
if (sourcesFile) {
  try { manifest = JSON.parse(readFileSync(sourcesFile, "utf8")); readManifest(manifest); } catch (x) { usage(`--sources ${sourcesFile}: ${x.message}`); }
}
const rpc = opt("--rpc") || process.env.RPC_URL || "https://rpc.mainnet.chain.robinhood.com";
const historyRpc = opt("--history-rpc") || process.env.HISTORY_RPC || rpc;
const fromArg = opt("--from-block");
if (fromArg != null && !/^(0|[1-9][0-9]*)$/.test(fromArg)) usage("--from-block takes a block number");
const DEP = JSON.parse(readFileSync(new URL("../deployments/4663.v2.json", import.meta.url), "utf8"));
const fromBlock = Number(fromArg ?? DEP.deployBlock);
if (args.length !== 1 || !/^(0|[1-9][0-9]{0,77})$/.test(args[0])) usage(args.length > 1 ? `unknown arguments: ${args.slice(1).join(" ")}` : null);
const agentId = BigInt(args[0]); // a uint256: never a Number

const mk = (url) => new ethers.JsonRpcProvider(url.split(",")[0], 4663, { staticNetwork: true, batchMaxCount: 1 });
const provider = mk(rpc), history = historyRpc === rpc ? provider : mk(historyRpc);
let r;
try {
  r = await readCredit(provider, agentId, { writers: writers.length ? writers : null, fromBlock, mode: full ? "full" : "light", funds: !noFunds, history, manifest, log: asJson ? () => {} : (m) => console.log(m) });
} catch (x) {
  console.error(`could not read agent #${agentId}'s credit entries: ${x?.shortMessage || x?.message || x}`);
  process.exit(1);
} finally {
  provider.destroy();
  if (history !== provider) history.destroy();
}
const requested = new Set(writers.map((w) => w.toLowerCase()));
const code = r.writers.some((w) => w.status === "failed") ? 1
  : r.writers.some((w) => w.status === "no-data" && requested.has(w.writer.toLowerCase())) || !r.writers.some((w) => w.statements > 0) ? 2 : 0;
if (asJson) { console.log(JSON.stringify(r, null, 1)); process.exit(code); }

const say = (m) => console.log(String(m).replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, "?"));
const fmt = (a, decimals) => (decimals == null ? String(a) : ethers.formatUnits(BigInt(a), decimals));
const named = (asset, symbol) => (symbol ? `${symbol} ${asset}` : asset);
const line = (T, d) => `on time ${T.onTime.count} (${fmt(T.onTime.amount, d)}), late ${T.late.count} (${fmt(T.late.amount, d)}), defaulted ${T.defaulted.count} (${fmt(T.defaulted.amount, d)})`;
say(`\nagent #${r.agentId}: ${full ? "full check, every statement rebuilt from its sources' logs (leaves, root, totals, opened, outstanding)" : "light check, a sample (not a rebuild)"}`);
if (full) {
  say(`  fund movement is sampled: ${noFunds ? "not checked (--no-funds)" : "checked on the anchors and default entries, not on every loan"}`);
  say("  not checked: the class split (the lender's claim)");
} else {
  say(`  checked: each entry's bytes, hash and shape; each chain (seq, prev, back-to-back windows, sources from their first block, one asset, nothing revoked); each statement's anchors and each default entry against the sources' logs${noFunds ? "" : ", with the asset's movement"}`);
  say("  not checked: that each root covers every loan of its window, and the totals, opened and outstanding figures. They are printed as the writer's claims and are not counted. Run with --full to rebuild them.");
  if (noFunds) say("  funds: not checked (--no-funds)");
}
say(`  sources: ${sourcesFile ? `checked against the manifest ${sourcesFile}` : "as each writer declares them; a source a writer never declares is not seen (--sources <file> requires a set)"}`);
const LABEL = { rebuilt: "rebuilt", sampled: "sampled", failed: "FAIL", "no-data": "no data" };
for (const w of r.writers) {
  say(`\n${LABEL[w.status].padEnd(8)} writer ${w.writer}${w.lender?.name ? ` (says: ${w.lender.name})` : ""}${requested.has(w.writer.toLowerCase()) ? "" : ", not trusted"}`);
  if (w.statements || w.defaults || w.problems.length) say(`         ${w.statements} statements, blocks ${w.window ? w.window.join("-") : "-"}, ${w.defaults} default entries, ${w.anchorsChecked} anchors and default leaves checked`);
  if (w.asset) say(`         asset ${named(w.asset, w.token?.symbol)}, ${w.decimals} decimals`);
  if (w.statements) say(`         ${w.status === "rebuilt" ? "rebuilt" : w.status === "sampled" ? "claimed, not rebuilt" : "claimed"}: ${line(w.claimed, w.decimals)}, outstanding ${w.claimed.outstanding.count} (${fmt(w.claimed.outstanding.amount, w.decimals)})`);
  if (!w.statements) say(`         no statements for agent #${r.agentId}`);
  for (const p of w.problems) say(`         - ${p}`);
}
const assets = Object.values(r.counted);
if (!writers.length) say("\ncounted: nothing (no --writer: no writer is trusted)");
else if (!full) say("\ncounted: nothing (light mode counts no claims; run with --full)");
else if (!assets.length) say("\ncounted: nothing (no trusted writer was rebuilt)");
else {
  say("\ncounted (trusted writers, rebuilt), by asset:");
  for (const a of assets) say(`  ${named(a.asset, a.symbol)}: ${line(a, a.decimals)}`);
}
process.exit(code);
