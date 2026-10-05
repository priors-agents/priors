# @priors/mcp

An MCP server that gives an AI assistant (Claude Desktop, Claude Code, or any MCP client) a USDG wallet on Robinhood
Chain: pay x402-priced APIs, check balances, read any agent's [Priors](https://priors.trade) credit record, and
borrow from and repay the agent's own Priors line, and keep its spare USDG saved in a Morpho vault until it needs it.

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
| `pay_url(url, method?, body?, max_price_usd?, max_borrow_usd?, use_savings?)` | fetch an https URL, pay its x402 402 in USDG if the price is ≤ `max_price_usd` (default **$0.10**); once the 402 names the price, if the wallet is short it first takes the difference out of savings (unless `use_savings: false`), and borrows the gap only if `max_borrow_usd` is given. Refuses private and local addresses, never follows a redirect, answers within 45 s, and never signs a second payment for a purchase (the same method, URL and body) that is still pending, until its validBefore plus 60 s (a new call resends the same one, also after a restart, in a new session or from another session of the same wallet: see `PRIORS_STATE_DIR`) | yes |
| `wallet_balance(address?)` | USDG and gas ETH of the wallet (or any address) | no (with `address`) |
| `credit_status(agent_id?)` | line, drawn, available, backer, record, score, open loans and due dates; on a stock line, the stock tokens behind it, and `available` capped by what the stock vault lets it draw | no (with `agent_id`) |
| `stock_assets(symbol?)` | the stock tokens the Priors stock vault accepts: live Chainlink price, whether it lends against each now (or why not: a sharp price move, a multiplier change, a paused or blocked token), loan-to-value | no |
| `stock_position(agent_id?)` | the stock tokens behind an agent's stock line: amount, what the vault values them at, loan-to-value, what the line can draw now, any lending hold | no (with `agent_id`) |
| `borrow(amount_usd, days, dry_run?)` | borrow USDG from the line into the wallet; both amounts required; `dry_run` quotes the fee. A borrow sent whose answer is lost is counted and said to be possibly open (check `credit_status`) | yes |
| `repay(loan_id? \| all, use_savings?)` | repay one of the agent's own loans, or all of them earliest due first; another agent's loan is refused. If the wallet is short of what is due, it first takes the difference out of savings (unless `use_savings: false`) | yes |
| `savings(address?)` | what the wallet (or any address) has saved in the savings vault, how much can come out right now, and the USDG in the wallet | no (with `address`) |
| `save(amount_usd)` | move spare USDG from the wallet into the savings vault, where it earns the vault's rate (at most `PRIORS_MAX_SAVE_USD` per call, `PRIORS_MAX_SAVE_TOTAL_USD` per run); needs ETH for gas | yes |
| `unsave(amount_usd? \| all)` | take USDG back out of savings into the wallet: a normal withdrawal, and when that is not enough, the rest from the vault's other markets in the same transaction (only where that costs no penalty); refused before any transaction when even that cannot pay it; needs ETH for gas | yes |
| `autopay_on(cap_usd?, use_savings?, late?, budget_usd?)` | turn on Autopay: the wallet approves AutoRepay for a budget (4 x the limit per loan, never unlimited) and enrolls, so each loan is repaid from the wallet (then its savings, if chosen) in the 6 hours before it is due, with no call per loan, while the wallet holds enough. It makes an on-time repayment more likely; it is not a promise. Default limit: the line plus a 30-day fee, at most `PRIORS_MAX_AUTOPAY_USD`; call again to approve more. Works once AutoRepay is deployed; needs ETH for gas | yes |
| `autopay_off(clear_budget?)` | turn Autopay off (and with `clear_budget`, set the approvals to 0) | yes |
| `score_of(agent_id)` | any agent's on-chain score (0 to 1000) and repayment record, plus its Priors Score v2 and trust rung when published | no |
| `find_services(query?)` | services registered with the Priors facilitator that accept USDG (`GET /merchants`), each marked as approved by Priors or self-registered and not reviewed | no |
| `pt_quote(side, amount, slippage_bps?)` | quote buying PT-USDG with USDG, selling it before maturity or redeeming it after: what comes out at the oracle's spot rate, the minimum a trade would name, the days to maturity and the fixed APY to maturity | no |
| `pt_position(address?)` | the wallet's (or any address's) PT-USDG: balance, what it is worth now, what it pays at maturity, and whether the Priors stock vault takes PT-USDG behind a line yet | no (with `address`) |
| `pt_buy(amount_usdg, slippage_bps?, dry_run?)` | buy PT-USDG with the wallet's USDG through Pendle's router (at most `PRIORS_MAX_PT_USD` per call, `PRIORS_MAX_PT_TOTAL_USD` per run); `dry_run` lists the calls; needs ETH for gas | yes |
| `pt_sell(amount_pt \| "all", slippage_bps?, dry_run?)` | sell the wallet's PT-USDG for USDG at the market, before maturity; needs ETH for gas | yes |
| `pt_redeem(amount_pt \| "all", slippage_bps?, dry_run?)` | redeem the wallet's PT-USDG for USDG 1:1, from maturity (2027-03-25) on; needs ETH for gas | yes |

Tools that move money state the amounts in their answer, are marked destructive for MCP clients, and their
descriptions tell the assistant to confirm with you first. Merchant text (response bodies, listings, redirect targets)
comes back between random `<<merchant-data …>>` markers, as data. They act on Robinhood Chain mainnet.

## Savings

Spare USDG doesn't have to sit idle. `save` puts it in a Morpho vault (Steakhouse USDG by default, a Morpho Vault V2
curated by Steakhouse Financial), where it earns the vault's rate. When the agent has to pay (`pay_url`) or repay
(`repay`) and its wallet is short, the server takes the difference back out first, and only then borrows. That makes
an on-time repayment more likely; it does not guarantee one: savings come out only while the vault's markets have
liquidity.

It is the agent's own money in someone else's vault: Priors never holds it, and the saver carries the vault's risks: a
loss in one of its markets lowers the share value at once; its curator and allocators choose the markets and some
settings change with no timelock; liquidity can be lent out; USDG's issuer can freeze addresses. The rate moves with
Morpho's markets. How money goes in and comes out: the Savings section of
[@priors/x402's README](https://www.npmjs.com/package/@priors/x402).

How the server handles it: the vault must be a contract whose asset is USDG; `save` checks the vault's deposit gate
before approving, and approves the amount only when the current allowance is lower; every vault transaction is sent
with a gas margin; what can come out is found by simulating the withdrawal (Morpho Vault V2 answers 0 to `maxWithdraw`
by design). A failed top-up never stops a payment or repayment, and the answer says what happened.

A top-up is bounded by the call's own time. When time runs out it stops before sending anything; if a withdrawal
was already sent and has not confirmed, `pay_url` neither borrows nor signs, says so, and the next money call waits
for that withdrawal. `save` keeps the USDG that signed, unsettled payments still need.

`PRIORS_SAVINGS_VAULT=off` stops `save` and the automatic top-ups, not the way out: `savings` and `unsave` keep working
on the default vault. Pointing `PRIORS_SAVINGS_VAULT` at another vault means trusting that vault (the only check is a
contract whose asset is USDG); money saved in the default one stays there, and money saved in a custom one is reached
by setting that vault again.

## PT-USDG

PT-USDG is Pendle's principal token for USDG on Robinhood Chain (the market maturing 2027-03-25, 00:00 UTC): bought
below 1 USDG, it redeems for exactly 1 USDG at maturity, so a buyer held to maturity locks in a fixed yield; sold
before then, it gets the market's rate at that moment, which can be lower. The `pt_*` tools trade it through Pendle's
router with the same calls as the Priors SDK (`sdk/pt-usdg.mjs` and `sdk/pendle-pt.mjs`, bundled here byte for byte):
an approval of exactly the trade's amount, right before the router call that uses it; USDG in or out directly (no
outside aggregator, no limit orders); the PT or USDG always paid to the wallet itself; and a minimum out (the quote
less `slippage_bps`, 1% by default): the router reverts rather than fill worse. Each call is simulated before it is
sent and its receipt checked. The quote is the oracle's spot rate, before the trade's own price impact, so a large
trade may need a wider margin.

Once the Priors stock vault lists PT-USDG, an agent's owner can post it behind a line (`pt_position` says when);
until then it is a token the wallet holds. `PRIORS_PT=off` removes the five tools.

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
| `PRIORS_SAVINGS_VAULT` | Steakhouse USDG on Morpho (`0xBeEff033F34C046626B8D0A041844C5d1A5409dd`) | the USDG vault savings go to; `off` (or `false`, `0`, `no`) stops `save` and the automatic top-ups, while `savings` and `unsave` keep working on the default vault. Its value is never echoed |
| `PRIORS_MAX_SAVE_USD` | `50` | most one `save` call may move into the vault |
| `PRIORS_MAX_SAVE_TOTAL_USD` | `200` | most `save` may move in total while the server runs |
| `PRIORS_AUTOREPAY` | the bundled deployments file's `autoRepay` (none until AutoRepay v2 is deployed) | AutoRepay v2's address, for `autopay_on`, `autopay_off` and the Autopay lines of `credit_status`; AutoRepay v1 (retired before use) is refused |
| `PRIORS_V5`, `PRIORS_V5_ROOT` | the bundled deployments file's `seatVaultV5` and `seatVaultV5AgentId` (none until V5 is deployed) | SeatVaultV5 and its root's agent id: a borrow on a V5 line (the `borrow` tool, `pay_url`) refreshes it first. The agent's key may do so 24 hours after V5 recorded it (`noteDelegate`, sent for it when needed); until then a borrow goes ahead only within the line's room, and the tool says when the key can borrow more |
| `PRIORS_MAX_AUTOPAY_USD` | `25` | the most `autopay_on` enrolls per loan (stage 0) |
| `PRIORS_AUTOPAY_RESERVE` | on | with Autopay on, `pay_url` keeps back what loans whose window opens in the next 24 h will pull, and says so when a payment would cut into it; `off` turns that off |
| `PRIORS_PT` | on | `off` (or `false`, `0`, `no`) removes the PT-USDG tools |
| `PRIORS_MAX_PT_USD` | `50` | most USDG one `pt_buy` may spend (sales and redemptions only turn the wallet's PT back into USDG) |
| `PRIORS_MAX_PT_TOTAL_USD` | `200` | most USDG `pt_buy` may spend in total while the server runs (a buy whose transaction was sent counts, even if its answer is lost) |
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
      "args": ["-y", "@priors/mcp@0.6.0"],
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
      "args": ["-y", "@priors/mcp@0.6.0"],
      "env": {
        "PRIORS_KEY": "${PRIORS_KEY}",
        "PRIORS_AGENT_ID": "${PRIORS_AGENT_ID:-}"
      }
    }
  }
}
```

or, for your user only: `claude mcp add priors --scope user -e PRIORS_KEY="$PRIORS_KEY" -- npx -y @priors/mcp@0.6.0`
(the key is expanded by your shell from the environment; do not paste it on the command line).

## Try it

"What's the Priors score of agent 6228?" · "How much USDG does my wallet hold?" · "Find services that sell token
prices" · "Pay https://api.example.com/report, up to 5 cents" · "Borrow $5 for 7 days, show me the fee first".

## Tests

`npm run test:packages` in the Priors repository lists and calls every tool through the MCP SDK's in-memory client and
over stdio, and checks that the key never appears in any output or error.
