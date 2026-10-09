#!/usr/bin/env node
// priors-mcp: the Priors MCP server over stdio. Configure it in an MCP client (README.md); it takes no arguments.
// The wallet key comes from the environment only: PRIORS_KEY_FILE (a file only the user can read, 0.8.0) or PRIORS_KEY.
// stdout carries the MCP protocol, so every human-readable line goes to stderr, and none of them ever contains the key.
// One command besides the server: `priors-mcp link-wallet --agent <id>` (src/link-wallet.mjs) signs the ERC-8004
// AgentWalletSet message with the agent's key and prints what the owner sends; it prints to stdout and exits.
const argv = process.argv.slice(2);
// A private key on the command line lands in shell history, `ps` and client logs: refuse it, without echoing it.
if (argv.some((a) => /(^|[^0-9a-fA-F])(0x)?[0-9a-fA-F]{64}($|[^0-9a-fA-F])/.test(a))) {
  process.stderr.write("priors-mcp: a private key was passed on the command line: refused. Put it in a file only you can read and set PRIORS_KEY_FILE to its path (or use the PRIORS_KEY environment variable), and rotate this key: it is now in your shell history and process list.\n");
  process.exit(2);
}
if (argv[0] === "link-wallet") {
  const { runLinkWallet } = await import("../src/link-wallet.mjs");
  process.exitCode = await runLinkWallet(argv.slice(1));
} else if (argv.includes("--help") || argv.includes("-h")) {
  process.stderr.write("priors-mcp: MCP server (stdio) for Priors on Robinhood Chain.\nenv: PRIORS_KEY_FILE (path to a file holding the wallet key, readable by you only) or PRIORS_KEY (the key; optional: without one only read-only tools work), PRIORS_RPC, PRIORS_AGENT_ID, PRIORS_FACILITATOR, PRIORS_MAX_PRICE_USD, PRIORS_MAX_BORROW_USD, PRIORS_MAX_SPEND_USD, PRIORS_MAX_BORROW_TOTAL_USD, PRIORS_MAX_SPEND_DAY_USD, PRIORS_MAX_BORROW_DAY_USD, PRIORS_PAY_HOSTS, PRIORS_ALLOW_LOCAL, PRIORS_STOCK_VAULT, PRIORS_SCORE_V2, PRIORS_SAVINGS_VAULT, PRIORS_MAX_SAVE_USD, PRIORS_MAX_SAVE_TOTAL_USD, PRIORS_PT, PRIORS_MAX_PT_USD, PRIORS_MAX_PT_TOTAL_USD, PRIORS_STATE_DIR\ncommand: priors-mcp link-wallet --agent <id> [--owner <0x>] [--valid <seconds>] [--json]: sign the ERC-8004 AgentWalletSet message with the agent's key, for its owner's setAgentWallet\nSee the README for the Claude Desktop / Claude Code config.\n");
  process.exitCode = 0;
} else if (argv.length > 0) {
  process.stderr.write("priors-mcp: takes no arguments (configuration is by environment variable; see --help), except the link-wallet command\n");
  process.exitCode = 2;
} else {
  const { createPriorsMcpServer, VERSION } = await import("../src/server.mjs");
  const { keyFromEnv } = await import("../src/key-file.mjs");
  const { StdioServerTransport } = await import("@modelcontextprotocol/sdk/server/stdio.js");
  // read once, here: the line below says where the key came from, or why a configured one is not used
  const keyed = keyFromEnv(process.env);
  try {
    const server = await createPriorsMcpServer({ deps: { key: keyed } });
    await server.connect(new StdioServerTransport());
    const wallet = keyed.problem ? `no wallet: ${keyed.problem}; read-only tools only` : keyed.key ? `wallet configured from ${keyed.source}` : "no PRIORS_KEY_FILE or PRIORS_KEY, read-only tools only";
    process.stderr.write(`priors-mcp ${VERSION} ready: ${wallet}, ${process.env.PRIORS_RPC ? "custom RPC" : "public RPC"}\n`);
  } catch (e) {
    // Configuration errors only (bad PRIORS_MAX_* values); the message never includes the key.
    let m = String(e?.message || e);
    for (const raw of [process.env.PRIORS_KEY, keyed.key]) {
      const k = String(raw || "").trim().replace(/^0x/i, "");
      if (k.length >= 16) m = m.split(k).join("<redacted>");
    }
    process.stderr.write(`priors-mcp: ${m}\n`);
    process.exit(1);
  }
}
