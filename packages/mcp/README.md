# @priors/mcp

An MCP server that gives an AI assistant (Claude Desktop, Claude Code, or any MCP client) a USDG wallet on Robinhood
Chain: pay x402-priced APIs, check balances, read any agent's [Priors](https://priors.trade) credit record, and
borrow from and repay the agent's own Priors line.

## Just reading? Use the hosted server

No install and no key: `https://mcp.priors.trade/mcp` (Streamable HTTP) answers the read-only questions (an agent's
record and score, the pool's figures, recent loans, the facilitator's services) from the same public data as
priors.trade. It holds no key and cannot send a transaction.

```bash
claude mcp add --transport http priors https://mcp.priors.trade/mcp
```

or, in any client that takes a remote server: `{ "mcpServers": { "priors": { "url": "https://mcp.priors.trade/mcp" } } }`.

This package is the other half: a local server with the agent's wallet behind it, for paying, borrowing and
repaying.

| tool | what it does | needs the key |
|---|---|---|
| `pay_url(url, method?, body?, max_price_usd?, max_borrow_usd?)` | fetch a URL, pay its x402 402 in USDG if the price is ≤ `max_price_usd` (default **$0.10**); borrows the gap only if `max_borrow_usd` is given | yes |
| `wallet_balance(address?)` | USDG and gas ETH of the wallet (or any address) | no (with `address`) |
| `credit_status(agent_id?)` | line, drawn, available, backer, record, score, open loans and due dates | no (with `agent_id`) |
| `borrow(amount_usd, days, dry_run?)` | borrow USDG from the line into the wallet; both amounts required; `dry_run` quotes the fee | yes |
| `repay(loan_id? \| all)` | repay one of the agent's own loans, or all of them earliest due first; another agent's loan is refused | yes |
| `score_of(agent_id)` | any agent's score (0 to 1000) and repayment record | no |
| `find_services(query?)` | services registered with the Priors facilitator that accept USDG (`GET /merchants`) | no |

Tools that move money state the amounts in their answer, and their descriptions tell the assistant to confirm with
you first. They act on Robinhood Chain mainnet.

## Configure

The only secret is the wallet key, and it is read from the environment variable `PRIORS_KEY`, never from the command
line (a key-shaped argument makes the server exit without starting) and never printed or returned by a tool. Use a
dedicated agent wallet holding only what the agent may spend.

| variable | default | |
|---|---|---|
| `PRIORS_KEY` | none | the agent wallet's private key; without it only the read-only tools work |
| `PRIORS_AGENT_ID` | looked up from the identity registry | the Priors agent id the wallet acts for |
| `PRIORS_RPC` | `https://rpc.mainnet.chain.robinhood.com` | JSON-RPC endpoint (a private URL is redacted from every answer) |
| `PRIORS_FACILITATOR` | `https://facilitator.priors.trade` | where `find_services` lists merchants |
| `PRIORS_MAX_PRICE_USD` | `1.00` | ceiling on what `pay_url` may be told to pay per call |
| `PRIORS_MAX_BORROW_USD` | `25` | ceiling on `borrow` and on `pay_url`'s `max_borrow_usd` |

Contract addresses (pool, lens, registry, USDG) come from `deployments/4663.v2.json`, bundled in the package.

### Claude Desktop

Settings → Developer → Edit Config (`claude_desktop_config.json`), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "priors": {
      "command": "npx",
      "args": ["-y", "@priors/mcp"],
      "env": {
        "PRIORS_KEY": "0xYOUR_AGENT_WALLET_KEY",
        "PRIORS_AGENT_ID": "1234"
      }
    }
  }
}
```

Read-only (no wallet): leave out `env`. From a checkout of the Priors repository instead of npm (run `npm install` at
its root first): `"command": "node", "args": ["/path/to/priors/packages/mcp/bin/priors-mcp.mjs"]`.

### Claude Code

A project `.mcp.json` that reads the key from your shell's environment, so the file itself holds no secret:

```json
{
  "mcpServers": {
    "priors": {
      "command": "npx",
      "args": ["-y", "@priors/mcp"],
      "env": {
        "PRIORS_KEY": "${PRIORS_KEY}",
        "PRIORS_AGENT_ID": "${PRIORS_AGENT_ID:-}"
      }
    }
  }
}
```

or, for your user only: `claude mcp add priors --scope user -e PRIORS_KEY="$PRIORS_KEY" -- npx -y @priors/mcp`
(the key is expanded by your shell from the environment; do not paste it on the command line).

## Try it

"What's the Priors score of agent 6228?" · "How much USDG does my wallet hold?" · "Find services that sell token
prices" · "Pay https://api.example.com/report, up to 5 cents" · "Borrow $5 for 7 days, show me the fee first".

## Source

[github.com/priors-agents/priors](https://github.com/priors-agents/priors/tree/main/packages/mcp), MIT.
