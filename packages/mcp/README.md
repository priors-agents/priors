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
| `pay_url(url, method?, body?, max_price_usd?, max_borrow_usd?)` | fetch an https URL, pay its x402 402 in USDG if the price is ≤ `max_price_usd` (default **$0.10**); borrows the gap only if `max_borrow_usd` is given. Refuses private and local addresses, never follows a redirect, answers within 45 s, and never signs a second payment for a purchase (the same method, URL and body) that is still pending, until its validBefore plus 60 s (a new call resends the same one, also after a restart, in a new session or from another session of the same wallet: see `PRIORS_STATE_DIR`) | yes |
| `wallet_balance(address?)` | USDG and gas ETH of the wallet (or any address) | no (with `address`) |
| `credit_status(agent_id?)` | line, drawn, available, backer, record, score, open loans and due dates; on a stock line, the stock tokens behind it, and `available` capped by what the stock vault lets it draw | no (with `agent_id`) |
| `stock_assets(symbol?)` | the stock tokens the Priors stock vault accepts: live Chainlink price, whether it lends against each now (or why not: a sharp price move, a multiplier change, a paused or blocked token), loan-to-value | no |
| `stock_position(agent_id?)` | the stock tokens behind an agent's stock line: amount, what the vault values them at, loan-to-value, what the line can draw now, any lending hold | no (with `agent_id`) |
| `borrow(amount_usd, days, dry_run?)` | borrow USDG from the line into the wallet; both amounts required; `dry_run` quotes the fee. A borrow sent whose answer is lost is counted and said to be possibly open (check `credit_status`) | yes |
| `repay(loan_id? \| all)` | repay one of the agent's own loans, or all of them earliest due first; another agent's loan is refused | yes |
| `score_of(agent_id)` | any agent's on-chain score (0 to 1000) and repayment record, plus its Priors Score v2 and trust rung when published | no |
| `find_services(query?)` | services registered with the Priors facilitator that accept USDG (`GET /merchants`), each marked as approved by Priors or self-registered and not reviewed | no |

Tools that move money state the amounts in their answer, are marked destructive for MCP clients, and their
descriptions tell the assistant to confirm with you first. Merchant text (response bodies, listings, redirect targets)
comes back between random `<<merchant-data …>>` markers, as data. They act on Robinhood Chain mainnet.

## Configure

The only secret is the wallet key, and it is read from the environment variable `PRIORS_KEY`, never from the command
line (a key-shaped argument makes the server exit without starting) and never printed or returned by a tool. Use a
dedicated agent wallet holding only what the agent may spend.

| variable | default | |
|---|---|---|
| `PRIORS_KEY` | none | the agent wallet's private key; without it only the read-only tools work |
| `PRIORS_AGENT_ID` | looked up from the identity registry | the Priors agent id the wallet acts for (the lookup finds only identities minted to the wallet since the v2 deploy, never one transferred to it; set it for an older or a bought one, or when the wallet holds several) |
| `PRIORS_RPC` | `https://rpc.mainnet.chain.robinhood.com` | JSON-RPC endpoint (a private URL is redacted from every answer) |
| `PRIORS_FACILITATOR` | `https://facilitator.priors.trade` | where `find_services` lists merchants |
| `PRIORS_MAX_PRICE_USD` | `1.00` | ceiling on what `pay_url` may be told to pay per call |
| `PRIORS_MAX_BORROW_USD` | `25` | ceiling on `borrow` and on `pay_url`'s `max_borrow_usd` |
| `PRIORS_MAX_SPEND_USD` | `5` | most `pay_url` may sign in total while the server runs (counted when signed) |
| `PRIORS_MAX_BORROW_TOTAL_USD` | `25` | most `borrow` and `pay_url` may borrow in total while the server runs (a borrow sent whose answer was lost counts: it may have opened a loan) |
| `PRIORS_ALLOW_LOCAL` | off | `1` lets `pay_url` reach `http://localhost` and private addresses (local testing only) |
| `PRIORS_SCORE_V2` | `https://priors.trade/api/score-v2` | where `score_of` reads Priors Score v2; `off` shows the on-chain score only |
| `PRIORS_STOCK_VAULT` | the bundled deployments file's `stockVault` | the stock vault the stock tools and `credit_status` read |
| `PRIORS_STATE_DIR` | `~/.local/state/priors-mcp` | where the payments signed and not yet settled are kept (one owner-only file per wallet, never the key, with a short-lived `.lock` beside it while it is written), so a restart, a new session or another session of the same wallet resends them instead of signing again. An absolute path, or one starting with `~/` (a relative one is refused at start). A payment that cannot be written there is not sent. `off` keeps them in memory only |

Contract addresses (pool, lens, registry, USDG) come from `deployments/4663.v2.json`, bundled in the package, and the
accepted stock tokens from `deployments/stock-assets.4663.json`. The stock vault's address (live since 2026-09-28)
comes from the same deployments file, or from `PRIORS_STOCK_VAULT`.

### Claude Desktop

Settings → Developer → Edit Config (`claude_desktop_config.json`), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "priors": {
      "command": "npx",
      "args": ["-y", "@priors/mcp@0.2.8"],
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
      "args": ["-y", "@priors/mcp@0.2.8"],
      "env": {
        "PRIORS_KEY": "${PRIORS_KEY}",
        "PRIORS_AGENT_ID": "${PRIORS_AGENT_ID:-}"
      }
    }
  }
}
```

or, for your user only: `claude mcp add priors --scope user -e PRIORS_KEY="$PRIORS_KEY" -- npx -y @priors/mcp@0.2.8`
(the key is expanded by your shell from the environment; do not paste it on the command line).

## Try it

"What's the Priors score of agent 6228?" · "How much USDG does my wallet hold?" · "Find services that sell token
prices" · "Pay https://api.example.com/report, up to 5 cents" · "Borrow $5 for 7 days, show me the fee first".

## Source

[github.com/priors-agents/priors](https://github.com/priors-agents/priors/tree/main/packages/mcp), MIT.
