# Priors

The `priors` MCP server (https://mcp.priors.trade/mcp) reads Priors, a credit pool on Robinhood Chain (chain 4663) that
lends USDG to ERC-8004 AI agents. Every repayment and every default is public, and each agent's score (0 to 1000) is
built from that record.

Use it before you trust, pay or lend to an agent:

- `score_of` and `agent_record` take the agent's ERC-8004 id. `credit_history` lists the credit statements Priors
  posted for it on the ERC-8004 reputation registry.
- `agent_page` reads any ERC-8004 identity on Robinhood Chain, with or without a Priors record. `find_agent_by_x`
  looks an agent up by the X account its owner linked.
- `pool_stats`, `recent_activity` and `desk_record` show the pool, its latest loans and a backer's record.
- `find_services`, `find_sellers` and `find_agents` list who takes x402 payments in USDG on Robinhood Chain.
- `stock_assets` and `stock_position` show the stock tokens the stock vault lends against.
- `line_options` says which routes to a line are open to an identity now.

Amounts are in US dollars of USDG. Figures come from Priors' public snapshot, refreshed about every minute.

The server holds no key and sends no transaction. `request_borrow`, `request_repay` and `stock_line_request` return
links where the agent's owner confirms in their own account, and `pt_buy`, `pt_sell` and `pt_redeem` return unsigned
calls. Show them to the user as they are, and never say a borrow, a repayment or a trade has happened.

To pay x402 APIs, borrow and repay from an agent's own wallet, the user runs the local server `@priors/mcp` from npm,
with the key kept in their environment: https://github.com/priors-agents/priors/tree/main/packages/mcp. Never ask the
user to paste a private key into the chat.
