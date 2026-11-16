# @priors/plugin-elizaos

Priors credit for [elizaOS](https://github.com/elizaOS/eliza) agents. An agent pays HTTP 402 (x402) APIs in USDG
from its wallet on Robinhood Chain; when the wallet is short, it borrows the gap from its
[Priors](https://priors.trade) credit line and repays it. Before paying another ERC-8004 agent, it can read that
agent's repayment record.

## Install

```bash
npm install @priors/plugin-elizaos
```

Add it to the character's plugins (elizaOS 1.7 or later):

```json
{
  "name": "MyAgent",
  "plugins": ["@elizaos/plugin-sql", "@elizaos/plugin-bootstrap", "@elizaos/plugin-openrouter", "@priors/plugin-elizaos"],
  "settings": {
    "secrets": {
      "PRIORS_KEY_FILE": "/path/to/agent-wallet.key",
      "PRIORS_AGENT_ID": "1234",
      "PRIORS_OWNER_ENTITY_IDS": "<your elizaOS entity id>",
      "PRIORS_PAY_HOSTS": "api.priors.trade"
    }
  }
}
```

| Setting | What it is |
|---|---|
| `PRIORS_KEY_FILE` | a file holding the agent wallet's private key, readable by this user only (`chmod 600`); a dedicated wallet, never a main one (`PRIORS_KEY` works too) |
| `PRIORS_AGENT_ID` | the agent's ERC-8004 id on Robinhood Chain |
| `PRIORS_OWNER_ENTITY_IDS` | the elizaOS entity ids whose messages may make the agent pay or repay, comma-separated. In a room (Discord, Telegram, X replies) a message is from whoever spoke, so unset, `PRIORS_PAY_X402` and `PRIORS_REPAY` answer no one; `*` lets anyone in the agent's rooms make it pay, within the caps below. The reads answer everyone. New in 0.3.0: an agent upgraded without it pays and repays for no one, so set it when upgrading |
| `PRIORS_PAY_HOSTS` | the only hosts a payment may go to, comma-separated |
| `PRIORS_MAX_PRICE_USD` | most one x402 call may cost (default 1.00) |
| `PRIORS_STATE_DIR` | where the daily caps and sent payments are kept: a directory only this user can write to, with no group- or world-writable parent (otherwise nothing is signed) |
| `PRIORS_MAX_SPEND_DAY_USD`, `PRIORS_MAX_BORROW_DAY_USD` | optional daily caps |
| `PRIORS_AUTO_BORROW_USD` | optional, off by default (`@priors/mcp` 0.15.0): auto-borrow. A payment whose message names no borrow then borrows the gap on its own, up to this amount, for 14 days, only while the agent wallet's Autopay covers the loan (from 0.3.0, on `@priors/mcp` 0.16.0, never while the agent wallet is its owner's own address, which Autopay does not repay under a wallet plan). Needs `PRIORS_MAX_BORROW_DAY_USD` above 0, `PRIORS_PAY_HOSTS`, `PRIORS_AGENT_ID` and `PRIORS_STATE_DIR` |

Without a key, only `PRIORS_AGENT_RECORD` works.

## Actions

| Action | What it does | Moves money |
|---|---|---|
| `PRIORS_AGENT_RECORD` | reads another agent's record on the hosted read-only Priors server: its line, repaid and late loans, defaults, score. The message names the agent, as `#1234` | no |
| `PRIORS_CREDIT_STATUS` | reads this agent's own line: available, drawn, open loans and due dates | no |
| `PRIORS_PAY_X402` | pays an x402 URL at most the price the message names, with GET, or with POST when the message gives a JSON body (a chat completion); if the wallet is short, borrows the gap when the message names the most to borrow (`borrow up to 5`; a loan is at least the pool's minimum, 5 USDG today), or, with `PRIORS_AUTO_BORROW_USD` set, on its own within it. "don't borrow" never borrows | yes |
| `PRIORS_REPAY` | repays the loan the message names (`loan 50900`), principal and fee | yes |

Example messages:

- "Before we pay it, check agent #1234's record on Priors."
- "Pay https://api.priors.trade/v1/report/1234 at most 0.05, borrow up to 5 if the wallet is short."
- "Buy a chat completion from https://models.example/v1/chat/completions at most 0.02: {"model": "…", "messages": [{"role": "user", "content": "…"}]}" (the URL, the price and any borrow are read outside the JSON, which must be the message's only JSON object; `models.example` stands for an OpenAI-compatible model API you choose that charges over x402, its host in `PRIORS_PAY_HOSTS`)
- "Repay loan 50900 now."

## How it works

The plugin runs [`@priors/mcp`](https://www.npmjs.com/package/@priors/mcp) in process for the agent's own wallet,
and reads records from the hosted read-only server at `https://mcp.priors.trade/mcp`. Every cap, the host
allowlist and the signing are `@priors/mcp`'s own: a payment above `max_price_usd` or to a host outside
`PRIORS_PAY_HOSTS` is refused before anything is signed, and the server's totals (`PRIORS_MAX_SPEND_USD` 5 and
`PRIORS_MAX_BORROW_TOTAL_USD` 25 by default while it runs) bound what one process can spend or borrow. Amounts and
URLs are read from the message of a sender listed in `PRIORS_OWNER_ENTITY_IDS`, never chosen by the model: the URL is
taken out before the amounts are read, so nothing in a seller's path or query (`/pay1/borrow5.json`, `#123`) is ever
read as a price, a borrow or an id, and a bare "pay 5" is a price only when no cap phrase ("at most", "max", "up to",
"no more than") is named and it is an amount, not a count ("pay 5 items"); a cap phrase's number is an amount too, not
a count ("up to 50 items"). The JSON body, and anything else the message writes in braces or a ``` block (a
template's `{model}`, an example), is taken out the same way wherever it stands, so nothing in a prompt is read as a
price or a borrow. A message must write exactly one JSON object for the body: with two (an example before the body),
one that does not parse, or one joined to the URL with no space, nothing is paid.

## Disclosure

- Payments and loans are real money: USDG on Robinhood Chain mainnet, signed with the key in `PRIORS_KEY_FILE`.
- A loan more than three days late can be marked defaulted, which ends the agent's record on Priors.
- The hosted server counts each connection by its client's runtime name only (https://mcp.priors.trade/privacy).

## Demo

A production run in elizaOS 1.7.2 on 2026-10-30 (agent #437, Robinhood Chain mainnet). The agent reads the seller's record, then pays its x402 check (0.10
USDG) from an empty wallet: PRIORS_PAY_X402 borrows 5 USDG, the pool's minimum loan (loan #50896). The agent's income
then arrives from another wallet, and PRIORS_REPAY closes the loan for 5.011666 USDG.
Transactions: [borrow](https://robinhoodchain.blockscout.com/tx/0x1a17ff6a4f4329d4a16fee0c7654f43104b037a0d9109f9c7ee4c503cbdd2d81),
[payment](https://robinhoodchain.blockscout.com/tx/0xc508fd46c613aa642bf8fe3c609c2b93eea00f93c173bdda5945e461e0c060c1),
[repayment](https://robinhoodchain.blockscout.com/tx/0x4186f11d1db84408740dbf7154f71978ef8301d54c7c1a6ef80704737f87c342).

## Test

```bash
npm test
```

## License

MIT
