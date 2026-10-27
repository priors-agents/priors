# Installing the Priors MCP server

Instructions for an AI agent (Cline or another MCP client) setting up Priors for a user. Priors is a credit pool on
Robinhood Chain that lends USDG to ERC-8004 AI agents; its MCP servers read any agent's credit record and score.

There are two servers. Install the hosted one unless the user asks to pay, borrow or repay from an agent's own wallet.

## 1. Hosted server (default): read-only, no key, nothing to install

- URL: `https://mcp.priors.trade/mcp`
- Transport: Streamable HTTP. No authentication, no API key, no environment variable.

Add this entry under `mcpServers` in Cline's MCP settings file (`cline_mcp_settings.json`), keeping the servers already
there:

```json
{
  "mcpServers": {
    "priors": {
      "type": "streamableHttp",
      "url": "https://mcp.priors.trade/mcp",
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

From the Cline CLI the same server is added with:

```bash
cline mcp add priors https://mcp.priors.trade/mcp --transport http --yes
```

Check: the server connects as `priors-read` and lists its read-only tools (`score_of`, `agent_record`, `pool_stats` and
others). `pool_stats` takes no argument, so it makes a good test call. The server holds no key and sends no transaction:
`request_borrow` and `request_repay` return links where the agent's owner confirms in their own account.

## 2. Local server: pays and borrows with the agent's own wallet

Only when the user wants to pay x402 APIs in USDG, borrow or repay from an agent's wallet on Robinhood Chain. It needs
Node.js 20.10 or later.

```json
{
  "mcpServers": {
    "priors-wallet": {
      "command": "npx",
      "args": ["-y", "@priors/mcp"],
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

With no key it starts with its read-only tools only (it logs `read-only tools only` when it starts). To let it pay and
borrow, add `"env": { "PRIORS_KEY_FILE": "~/.config/priors/agent.key" }`: the path of a file holding the agent wallet's
private key, absolute or starting with `~/`.

- Never ask the user to paste a private key into the chat, and never write a key into `cline_mcp_settings.json`. The
  user creates the key file in their own terminal and makes it readable by them alone (`chmod 600`); the server
  refuses a file others can read. The steps are in the package README, "An agent that runs on its own":
  https://github.com/priors-agents/priors/blob/main/packages/mcp/README.md
- Use a dedicated agent wallet holding only what the agent may spend.
- Keep `autoApprove` empty for this server, so the user confirms every `pay_url`, `borrow` and `repay` call.
- The spending caps (`PRIORS_MAX_PRICE_USD`, 1.00 per call by default; `PRIORS_MAX_SPEND_USD`, 5 per run;
  `PRIORS_MAX_BORROW_USD`, 25) and every other setting are in that README's "Configure" section.
