// The two Priors MCP servers an elizaOS agent talks to: @priors/mcp in process (the agent's own wallet: its line, x402
// payments that borrow the gap, repayments; every cap and the host allowlist are that server's own), and the hosted
// read-only server (another agent's record). Each is connected once per runtime, on first use.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

export const HOSTED_URL = "https://mcp.priors.trade/mcp";
export const CLIENT = { name: "elizaos-plugin-priors", version: "0.1.0" };

/** The settings @priors/mcp reads, taken from the agent's settings (runtime.getSetting), else the process env. */
export const SETTINGS = Object.freeze([
  "PRIORS_KEY_FILE", "PRIORS_KEY", "PRIORS_AGENT_ID", "PRIORS_PAY_HOSTS", "PRIORS_RPC", "PRIORS_STATE_DIR",
  "PRIORS_MAX_PRICE_USD", "PRIORS_MAX_BORROW_USD", "PRIORS_MAX_SPEND_USD", "PRIORS_MAX_BORROW_TOTAL_USD",
  "PRIORS_MAX_SPEND_DAY_USD", "PRIORS_MAX_BORROW_DAY_USD",
]);

/** The env @priors/mcp is built with: the process env, with every Priors setting the agent has replacing it. */
export function envOf(runtime, base = process.env) {
  const env = { ...base };
  for (const k of SETTINGS) {
    const v = runtime && typeof runtime.getSetting === "function" ? runtime.getSetting(k) : undefined;
    if (v !== undefined && v !== null && String(v) !== "") env[k] = String(v);
  }
  return env;
}

/** A tool answer as text (what the server says, never more). */
const textOf = (r) => (r && Array.isArray(r.content) ? r.content.filter((c) => c && c.type === "text").map((c) => c.text).join("\n") : "");

/**
 * The Priors calls of one runtime: `wallet(tool, args)` on @priors/mcp in process, `read(tool, args)` on the hosted
 * server. Each answers { ok, text }. `connect` replaces both connections for tests: ({ kind, env }) => client with
 * callTool.
 */
export function priorsFor(runtime, { connect = defaultConnect, base = process.env } = {}) {
  const clients = {};
  const clientOf = (kind) => (clients[kind] ||= connect({ kind, env: envOf(runtime, base) }));
  const call = (kind) => async (name, args = {}) => {
    try {
      const r = await (await clientOf(kind)).callTool({ name, arguments: args }, undefined, { timeout: 180_000 });
      return { ok: !r.isError, text: textOf(r) };
    } catch (e) {
      clients[kind] = null; // a broken connection is opened again on the next call
      return { ok: false, text: `Priors (${kind}): ${String((e && e.message) || e).slice(0, 300)}` };
    }
  };
  return { wallet: call("wallet"), read: call("read") };
}

async function defaultConnect({ kind, env }) {
  const client = new Client(CLIENT);
  if (kind === "read") {
    await client.connect(new StreamableHTTPClientTransport(new URL(HOSTED_URL)));
    return client;
  }
  const { createPriorsMcpServer } = await import("@priors/mcp");
  const server = await createPriorsMcpServer({ env });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  await client.connect(b);
  return client;
}

/** One Priors per runtime (an agent's runtime object), connected lazily. */
const byRuntime = new WeakMap();
export function priorsOf(runtime, opts) {
  if (!runtime || typeof runtime !== "object") return priorsFor(runtime, opts);
  if (!byRuntime.has(runtime)) byRuntime.set(runtime, priorsFor(runtime, opts));
  return byRuntime.get(runtime);
}
