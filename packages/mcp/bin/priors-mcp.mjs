#!/usr/bin/env node
// priors-mcp: the Priors MCP server over stdio. Configure it in an MCP client (README.md); it takes no arguments.
// The wallet key comes from the PRIORS_KEY environment variable only. stdout carries the MCP protocol, so every
// human-readable line goes to stderr, and none of them ever contains the key.
const argv = process.argv.slice(2);
// A private key on the command line lands in shell history, `ps` and client logs: refuse it, without echoing it.
if (argv.some((a) => /(^|[^0-9a-fA-F])(0x)?[0-9a-fA-F]{64}($|[^0-9a-fA-F])/.test(a))) {
  process.stderr.write("priors-mcp: a private key was passed on the command line: refused. Put it in the PRIORS_KEY environment variable instead, and rotate this key: it is now in your shell history and process list.\n");
  process.exit(2);
}
if (argv.includes("--help") || argv.includes("-h")) {
  process.stderr.write("priors-mcp: MCP server (stdio) for Priors on Robinhood Chain.\nenv: PRIORS_KEY (wallet key, optional), PRIORS_RPC, PRIORS_AGENT_ID, PRIORS_FACILITATOR, PRIORS_MAX_PRICE_USD, PRIORS_MAX_BORROW_USD\nSee the README for the Claude Desktop / Claude Code config.\n");
  process.exit(0);
}
if (argv.length > 0) {
  process.stderr.write("priors-mcp: takes no arguments (configuration is by environment variable; see --help)\n");
  process.exit(2);
}

const { createPriorsMcpServer, VERSION } = await import("../src/server.mjs");
const { StdioServerTransport } = await import("@modelcontextprotocol/sdk/server/stdio.js");
try {
  const server = await createPriorsMcpServer();
  await server.connect(new StdioServerTransport());
  const k = (process.env.PRIORS_KEY || "").trim();
  process.stderr.write(`priors-mcp ${VERSION} ready: ${k ? "wallet configured from PRIORS_KEY" : "no PRIORS_KEY, read-only tools only"}, ${process.env.PRIORS_RPC ? "custom RPC" : "public RPC"}\n`);
} catch (e) {
  // Configuration errors only (bad PRIORS_MAX_* values); the message never includes the key.
  const k = (process.env.PRIORS_KEY || "").trim().replace(/^0x/i, "");
  let m = String(e?.message || e);
  if (k.length >= 16) m = m.split(k).join("<redacted>");
  process.stderr.write(`priors-mcp: ${m}\n`);
  process.exit(1);
}
