# @priors/mcp changelog

## 0.19.0 (2026-11-09)

- **The agent's open loans, named when a session starts.** `initialize`'s instructions end with each open loan of the
  configured agent: its id, what is due (principal and fee), its due time in UTC and "repay before then" (one past due:
  "repay it now"), the earliest due first; with a wallet, that `repay` pays it from there with the user's go-ahead. The
  agent is `PRIORS_AGENT_ID`, else the identity `join` registered for this wallet (its record in `PRIORS_STATE_DIR`)
  while the wallet still owns it; no search of the registry's logs, which takes far too long for a start. One bounded
  read of the pool (5 s): nothing is said when no loan is open or the read fails, and with no agent configured the
  instructions are 0.18.2's, byte for byte.
- **`credit_status`'s next step for a registered identity with no Priors record**: after "no Priors record yet" and its
  owner, the routes to a first line that `line_options` on Priors' hosted MCP reads (the treasury's first line by
  invite, the Ethos lane, a stock line, a line from its owner's own $PRIORS) and the line board, where its owner may ask
  the roots for a line with `line_ask`: a backer may offer, or not. An id with no owner in the registry is answered as
  before.
- **`line_ask` and `line_take`, signed here** (only with `PRIORS_LINE_BOARD=on`, off by default; off, the server is as
  before, word for word, and `PRIORS_LINE_BOARD_URL` is not read). The hosted MCP's `line_ask` and `line_take` draft an
  agent's owner's request for a line on Priors' line board and its take of one offer there, and sign nothing; here the
  configured wallet, when it is the agent's owner in the ERC-8004 registry, signs each one and posts it to the board
  (`PRIORS_LINE_BOARD_URL`, default `https://priors.trade/api/line-requests`; https, or http for localhost only).
  `line_ask` signs the board's LineRequest (the line, the most premium its owner takes, the term, how long it stands);
  `line_take` signs the pool's own consent for the offer's root alone, at the agent's nonce, the offer's premium as its
  cap and a deadline six days on, and says what taking does (a line from another root handed over whole, a smaller
  line, an open loan to repay first, the root's free backing, what Score v2 would say of a line from that root). Each is
  checked first as the hosted tools check it and refused with their reasons, nothing signed: a key that does not own the
  agent, the board's rules, an offer not on the request or ended, a request taken or unknown, a root no longer a root or
  no longer its signer's. The messages are the board's own (`src/line-market.mjs`, `sdk/line-market.mjs` in the
  repository, byte for byte), which the board checks again. Neither moves money: once a take is posted, the root's owner
  sends the line from its own wallet, or not. Asking promises no line.

## 0.18.2 (2026-11-06)

- **The state file's lock is never taken from a running server by a clock** (GHSA-wqww-vjpx-w8mq, reported by
  @JasmeJun). A lock was judged abandoned by its file time against this process's clock, so after a clock step (NTP, a
  resumed VM), or on a file server whose clock is behind, a lock held for milliseconds was taken, two servers of one
  wallet wrote at once, and an unsettled payment's entry could be lost; another session, or a restart, then signed that
  purchase again. The lock now names its holder and is removed only by it, and is taken over only when that holder, on
  this host, has ended, or once this server has seen it unchanged for 10 s. After 2 s the write still goes ahead
  without it, as before.
- **`pt_buy` and `pt_sell` hold the trade to the quote the user agreed to** (GHSA-3fwm-95gh-5xh4, reported by
  @SanjilVinsmoke): `min_out_pt` and `min_out_usdg`, such as `pt_quote`'s "at least". A fresh quote under it is refused
  before anything is signed; otherwise the router call names the larger of it and the fresh quote's own minimum, never a
  lower one. Without it, the minimum came from the fresh quote alone, so a trade could fill below the quote the user
  agreed to (never below the oracle's rate at its own block less the slippage).

## 0.18.1 (2026-11-05)

On @priors/x402 0.8.8 (a plan whose AutoRepay epoch could not be read, below).

- **A bid made while Priors' hub does not answer never sets the bids' approval down, and counts it** (GHSA-mc89-r73h-33vv,
  reported by @sonson0910; only with `PRIORS_MARKET` on). With the hub's list of this wallet's bids unread, `market_bid`
  and `market_bid_any` planned from this server's own record alone: an approval standing above `PRIORS_MAX_BIDS_USD`
  (bids made in Go mode, on the board or on another machine) was set down to the new bid's price, leaving those bids
  unfunded (0.16.0 had fixed the same in `market_cancel_bid`), and an approval under it was neither counted against
  `PRIORS_MAX_BIDS_USD` nor kept back from the agent's open loans. With the hub down, the approval standing now counts
  with the new bid: it is only ever raised, a bid that would pass `PRIORS_MAX_BIDS_USD` with it is refused before
  anything is signed (try again once the hub answers), and keep back counts it.
- **Auto-borrow never borrows on a plan whose AutoRepay epoch could not be read** (GHSA-mc89-r73h-33vv): with
  `@priors/x402` 0.8.7, a failed `epochOf` read made a plan set before the agent's key or owner changed, which
  AutoRepayV2 never pays, read as current. The borrow is refused now ("AutoRepay's epoch ... could not be read just
  now"), and `credit_status` says the same.

## 0.18.0 (2026-11-04)

- `line_key_status` and `line_key_spend` (only with `PRIORS_LINE_KEY=on`, off by default; docs/LINE-KEY.md in the
  repository): the agent's spending key on LineKey (`0x1090Df1B8A4B3F1e7D9aeDaA06fd29f56B9214fB`), which the agent's owner
  names the delegate of its line, with an operator, caps per payment and per trailing period, payees with caps of their
  own, an expiry, a loan term and a most fee. `line_key_status` reads it, no wallet needed: its state (live; stale when
  the agent changed hands; expired; not the line's delegate), its terms, the payees with what each can be paid now, what
  was paid in the period and when room frees up. `line_key_spend` pays a listed payee from this wallet when it is the
  key's operator: one transaction to LineKey (gas limit 900,000, from the operator's own ETH), the pool lending the amount
  as a loan of the agent, paid straight to the payee. Its address, call, state and refusal codes are Go mode's own
  (`src/line-key-core.cjs`, the site's `web/line-key-core.js` byte for byte). Refused before anything is signed when the
  key's `check` refuses (each reason in words), the amount is under the pool's smallest loan or over its largest, the line
  refuses it in a simulation (the pool's own error read from `LineRefused`), the wallet lacks the gas, or a limit would
  pass: a payment counts as a loan against `PRIORS_MAX_BORROW_USD`, `PRIORS_MAX_BORROW_TOTAL_USD` and
  `PRIORS_MAX_BORROW_DAY_USD`, and as money out against `PRIORS_MAX_SPEND_DAY_USD`. The answer names the loan from
  LineKey's own `Paid` log, with its fee and due date. Off, the server is as before, word for word.

## 0.17.1 (2026-11-04)

On @priors/x402 0.8.7 (Autopay's savings approval and current plan, below).

- **Rialto's route holds the router call's fee words too** (GHSA-m3hr-g75r-gmcj, reported by @sonson0910; only with
  `PRIORS_STOCKS` and `PRIORS_RIALTO=on`, both off by default). 0.17.0 decoded the router call's fee words
  (`feeRecipient`, `srcBps`, `dstBps`) and checked none of them, and the router pays them to whatever address they name
  (it checks the minimum after the fee): an answer whose JSON was honest could still pay the output above the
  transaction's minimum, within the slippage, to another address, and a quote stating no fee showed "Rialto's fee 0
  bps". The transaction is now taken only with no fee or Rialto's own, at most 5 bps paid to Rialto's address
  (`src/rialto.mjs` `checkSwapFee`, `RIALTO_FEE_BPS`, `RIALTO_FEE_RECIPIENT`), never above the fee the quote states; the
  fee shown is the one the transaction takes. Anything else keeps the pinned trade, and the answer says why. Priors' gas
  gate and Go mode hold Rialto's quotes to the same rule.
- **A sale through Rialto counts its quote against `PRIORS_MAX_STOCK_TOTAL_USD`** (GHSA-m3hr-g75r-gmcj): 0.17.0 counted
  its transaction's minimum, up to the slippage under the quote. It counts the quote, as the pinned trade's does.
- **A dry run's `min_out` through Rialto holds on the live call** (GHSA-m3hr-g75r-gmcj): when Rialto's quote beat the
  pinned pool by more than the slippage, the `min_out` a dry run printed was above the pinned pool's output, and the
  live call stopped "the price moved past the slippage" before Rialto was asked. Rialto is asked now, and its route
  taken only when its transaction's minimum is at least that `min_out`; otherwise the refusal stands.
- **The PT buys keep to `PRIORS_MAX_PT_TOTAL_USD` and keep back what signed payments still need**
  (GHSA-hx6h-j9hm-9gvr, reported by @sonson0910). `pt_buy_and_deposit` (only with `PRIORS_PT_ONESTEP=on`) counted its
  buy only after its chain reads and its consent: a call stalled in those reads past its hold was left out of the total
  a later buy read, and both bought past the cap. Both PT buys now count their amount from the check, before any read,
  until the call ends. Neither kept back the USDG of payments signed and not settled yet, as `save`, `stock_buy` and the
  market tools do: a live buy that would spend it is now refused before anything is signed. And a buy whose swap did
  nothing after its USDG approval (refused in its simulation, refused for gas, or mined and reverted) stayed counted, as
  though it had spent its USDG: it counts nothing now, and the answer says so.
- `autopay_on` with savings approves shares worth the whole budget, and `credit_status` and the reserve never count a
  plan of a wallet the agent no longer declares (@priors/x402 0.8.7).

## 0.17.0 (2026-11-04)

On @priors/x402 0.8.6, as 0.16.0.

- **Rialto's route checks the quote's transaction, not only its JSON** (GHSA-cqcw-9qjc-5qc7, reported by
  @hey-research-lab; only with `PRIORS_STOCKS` and `PRIORS_RIALTO=on`, both off by default). 0.16.0 checked the gate's
  JSON terms (this wallet as taker, the tokens, the amount, a minimum within the slippage), then sent the quote's
  transaction data as it came, and the router's swap carries its own recipient and minimum: an answer whose JSON was
  honest and whose data was not could pay up to the amount sold to another address, or fill at any price. The data is
  now decoded (`src/rialto.mjs` `decodeSwap`, `checkSwap`, `sdk/rialto.mjs` in the repository) and Rialto's route is
  taken only when it is the router's swap of the tokens and the amount checked, paid to this wallet, with at least the
  quote's minimum and a deadline at most 30 minutes after the plan's block. Anything else keeps the pinned trade, and
  the answer says why. The minimum shown and sent is the transaction's own, and a sale's value is counted from it. Priors'
  gas gate and Go mode hold Rialto's quotes to the same check.
- `pt_buy_and_deposit` (only with `PRIORS_PT_ONESTEP=on`, off by default; docs/PT-USDG.md in the repository, "One step:
  buy and back a line"): PT-USDG bought with the wallet's USDG and deposited, with the PT-USDG the wallet already holds,
  behind the agent's line on the Priors stock vault in one call. Its plan and its four calls are Go mode's own
  (`src/pt-onestep-core.cjs`, the site's `web/pt-onestep-core.js` byte for byte): the exact USDG approval to Pendle's
  router, the buy with its minimum out from the oracle's spot rate less the slippage (at most 3%), the exact PT-USDG
  approval to the vault, then the vault's open with this wallet's pool consent, checked against the pool's
  `consentDigest` before it is signed. Refused before anything is signed when the wallet does not own the agent, the agent
  has an open line, the vault takes no new PT-USDG line, the line would be under the pool's smallest, or over a cap.
  `pt_buy`'s caps count it. Off, the server is as before, word for word.

## 0.16.0 (2026-11-02)

On @priors/x402 0.8.6 (Autopay's `OWNER_IS_WALLET`, below).

- **Rialto's route for `stock_buy` and `stock_sell`** (`PRIORS_RIALTO`, off by default; off, every list, instruction
  and answer is as before, and nothing is asked of anyone). With it on, a trade that passes every check is also quoted
  by Rialto through Priors' gas gate (`priors_stockQuote` at `PRIORS_STOCK_QUOTE_URL`, default
  `https://priors.trade/gas`). Rialto's API key stays on the gate, never in this package. The quote is checked again
  here: the router Rialto's Router Registry names on chain, the tokens, the amount, this wallet, the slippage, and
  Chainlink's 5% for its output and its minimum. It is taken only when it gives more of the token bought than the
  pinned pool: an approval of exactly the amount sold to that router, then Rialto's transaction, its gas estimated
  first. Otherwise the pinned trade goes ahead as before, and the answer says why. The answer names the route, both
  quotes, Rialto's fee and quote id, what the wallet received and the router's allowance after (0 after a full fill). No
  Priors fee. `src/rialto.mjs` (`sdk/rialto.mjs` in the repository) is bundled byte for byte.
- **AgentLease's record is in this package** (`deployments/4663.agent-lease.json`: AgentLease
  `0xF2299A992879764ceF0107Aa9Beb07AdfBe0e479` on Robinhood Chain, deployed 2026-11-01, its market this package's
  AgentMarketV2). So with `PRIORS_MARKET` on, `market_buy` and `market_accept` now claim on a stored lease around a
  change of hands, as 0.15.0 set out: they read the lease stored on the agent (`leaseOf`) and, while one is stored, send
  `claim` on the lease before the change of hands and after it (gas only), the client rule of `docs/AGENT-LEASE.md`, so
  each day's rent goes to whoever held the agent when the day ended. `market_agent` says who runs a rented agent and
  until when.
- **The market tools' day count holds what each step commits** (`PRIORS_MARKET`): a step whose answer is lost
  (`TX_UNCONFIRMED`) adds what it alone commits, an approval nothing and a buy, a bid or a bond its amount, and what the
  steps mined before it committed stays counted. A bond mined before a later step's answer was lost was released from
  `PRIORS_MAX_MARKET_DAY_USD` (GHSA-pg36-8pmq-5p4v), and an approval whose answer was lost counted the whole buy, bid or
  bond, then the retry counted it again (GHSA-m2h8-m55f-9j66).
- **`market_accept` refuses a bid made before the agent's builder share was set** (its id under the market's
  `builderSince`, which `acceptBid` refuses with `BuilderAfterBid`) before anything is signed, so no cancel, bond or
  approval is sent for it; `market_agent` leaves such a bid out, and the market's refusal is said in its words
  (GHSA-m2h8-m55f-9j66).
- **Keep back counts what this wallet has committed elsewhere**: before a buy or a bond, what its open bids can still
  take (its approval to the bids' spender) and what payments signed and not settled yet still need are not counted as
  there to repay the agent's open loans (GHSA-m2h8-m55f-9j66). `first_line` keeps the latter back too.
- **`market_cancel_bid` never sets the bids' approval down while Priors' hub doesn't answer** (bids made elsewhere,
  Go mode's or another machine's, can't be counted then, and would be left unfunded), and with `all` and no open bid it
  sets an approval left standing to 0 (GHSA-m2h8-m55f-9j66).
- **Stock tools** (`PRIORS_STOCKS`): a swap mined and reverted moved nothing, so it counts neither in
  `PRIORS_MAX_STOCK_TOTAL_USD` nor in the day's trades (GHSA-m2h8-m55f-9j66, GHSA-c4xq-qmpq-6xmm); a sale planned again
  after its approval is held to `PRIORS_MAX_STOCK_TOTAL_USD` at its new quote, before the swap is signed, and counted at
  it (GHSA-c4xq-qmpq-6xmm).
- **`first_line`** (`PRIORS_JOIN`): a bond deposit the node refused for its gas, or one mined and reverted, no longer
  counts against `PRIORS_MAX_SPEND_DAY_USD` (it already gave back its `PRIORS_MAX_BOND_TOTAL_USD` room).
- **`PRIORS_KEY_FILE`**: on Windows, an access rule that lets another account change the file or who may read it
  (WriteData, AppendData, WRITE_DAC, WRITE_OWNER, GENERIC_WRITE) refuses the file as read access does; root reading
  another user's key, and `PRIORS_STATE_DIR`, check the directory of every link a chain of symlinks passes through, not
  only the path given and the one it resolves to (GHSA-m2h8-m55f-9j66).
- **Autopay and auto-borrow** (GHSA-65qg-4h7m-j2cm): an agent whose declared wallet is its owner's own address (what
  `join`'s `register()` leaves) is repaid by AutoRepayV2 under its owner's plan only, never under a wallet plan of that
  address. `autopay_on` enrolled such a plan and said each loan would be repaid from this wallet, and auto-borrow
  (`PRIORS_AUTO_BORROW_USD`) borrowed on it. Now `autopay_on` refuses it before anything is sent (with @priors/x402's
  `OWNER_IS_WALLET`), auto-borrow refuses to borrow on it, and `credit_status` says Autopay is off for this wallet and
  why: declare a key of the agent's own as its wallet (`setAgentWallet`) and turn Autopay on from that key, or repay by
  hand.

## 0.15.0 (2026-11-01)

- **Auto-borrow, for inference on credit** (`PRIORS_AUTO_BORROW_USD`, off by default): with it set, a `pay_url` (or
  `pay_gateway`) call that names no `max_borrow_usd` borrows the gap on its own when the wallet and the agent's
  savings are short, up to that amount a call, for 14 days. That way an agent buying its own model calls (from an
  OpenAI-compatible model API it chooses, paid over x402 in USDG on Robinhood Chain) keeps working mid-task. The guards:
  - It borrows only while this wallet's Autopay covers the new loan: plan on and current, not held or paused, its
    limit per loan at least the loan's due, its approval enough for that due on top of the loans it already repays.
    Otherwise nothing is borrowed or signed, and the answer says to turn Autopay on.
  - The server does not start with it unless `PRIORS_MAX_BORROW_DAY_USD` (above 0, with `PRIORS_AGENT_ID` and
    `PRIORS_STATE_DIR`) and `PRIORS_PAY_HOSTS` are set, and it is at most `PRIORS_MAX_BORROW_USD` and
    `PRIORS_MAX_BORROW_TOTAL_USD`.
  - When the day's borrow limit or the run's total has no room, a call pays from what the wallet holds and says why it
    did not borrow, instead of being refused.
  - The control check and the Autopay check run only once the wallet is short, so a call that needs no loan makes no
    extra read.
  - A call naming `max_borrow_usd` works as before (`0` never borrows).

  `pay_url`'s description, its answers, the instructions and `credit_status` say when it is on.

- **The market tools claim on an agent's lease around a change of hands, once this package carries AgentLease's
  record** (`deployments/4663.agent-lease.json`, written by the lease's deploy; AgentLease isn't deployed, so there is
  none yet, and every tool, read and answer is as before). With it, `market_buy` and `market_accept` read the lease
  stored on the agent (`leaseOf`) and, while one is stored, send `claim` on the lease before the change of hands and
  after it (gas only), the client rule of `docs/AGENT-LEASE.md`, so each day's rent goes to whoever held the agent when
  the day ended. The lease is confirmed at the first market call (its `market()` must be this package's AgentMarketV2),
  else every market tool refuses. `market_agent` says who runs a rented agent and until when. A claim after the change
  of hands that can't be sent, or doesn't go through, leaves the change as it is, and the answer says so, a retry's
  from the market record too. The lease's seam (`src/agent-lease.mjs`, `sdk/agent-lease.mjs` in the repository) is
  bundled byte for byte.

## 0.14.1 (2026-10-30)

On @priors/x402 0.8.4, whose @x402 packages are 2.29.0 or later.

- **No zod 3 through @priors/x402's @x402 packages** ("Zod can exhaust memory while validating oversized constrained
  collections", GHSA-mrhx-c7xc-m3w5: every zod below 4.6.6, no fix in 3.x). @x402/core, @x402/evm and @x402/fetch 2.27
  and 2.28 depend on zod ^3.24.2, and @priors/x402 0.8.3 took them from ^2.27.0, so an install that already held them
  (a lockfile, or a project that uses them itself) kept zod 3.25 nested under each. @priors/x402 0.8.4 requires
  ^2.29.0, the first on zod ^4.6.6: npm moves them. This server's own zod was already ^4.6.6 (since 0.13.0). Its tools,
  instructions and answers are 0.14.0's.

## 0.14.0 (2026-10-29)

Still on @priors/x402 0.8.3.

- **Buying and selling Stock Tokens from the agent's own key, with `PRIORS_STOCKS=on` and `PRIORS_STOCKS_ELIGIBLE=yes`
  (both off by default).** `stock_buy` spends the wallet's own USDG on one of the 30 Robinhood Stock Tokens Go mode's
  stock buy offers, and `stock_sell` sells one back to USDG, on the same Uniswap pools it pins
  (`deployments/stock-zap.4663.json`, now in the package): an approval of exactly the amount, then one exact-input swap
  paying this wallet, its minimum out a fresh quote less the slippage. Without both settings the server is exactly as
  before: no tool, no sentence in the instructions.
  - `PRIORS_STOCKS_ELIGIBLE=yes` is the user's statement, Go mode's eligibility tick word for word (in the README): not a
    person of the United States, the United Kingdom, Canada or Switzerland, nor of the countries Robinhood prohibits,
    nor of the United Arab Emirates, and not acting for one. This server cannot tell where its user is; unset, the tools
    are not offered, and any value other than yes or no stops the start.
  - Refused before anything is signed: `$PRIORS` (never), a token not on the pinned list, a slippage above 2%, a price
    impact of 3% or more, Chainlink's price older than 4 hours or the trade more than 5% from it, the issuer's pauses
    and block list, a trade under 1 USDG or above `PRIORS_MAX_STOCK_USD` (default 50, at most 1,000), past
    `PRIORS_MAX_STOCK_TOTAL_USD` while the server runs (default 200) or past 5 buys or 5 sales a UTC day for the agent
    and the wallet (in `PRIORS_STATE_DIR/stocks`, across restarts), a fresh quote under `min_out`, more than the wallet
    holds, and a buy that would leave less USDG, savings counted, than the agent's open loans owe or than payments
    signed and not settled yet need. Nothing borrows. With both on, the start needs `PRIORS_AGENT_ID` and
    `PRIORS_STATE_DIR`.
  - One money call at a time, as every money tool; each step simulated before it is signed, and the trade read and
    planned again after its approval (a refusal then says the approval stands, usable only by this wallet's own swap);
    a lost answer is `TX_UNCONFIRMED`. Gas is the wallet's own ETH. The tool descriptions ask for the user's go-ahead
    and say each trade is public on chain.
  - The SDK files it runs are bundled byte for byte: `sdk/stock-trade.mjs` (`stockQuote`, `stockBuy`, `stockSell`,
    `openLoansOwed`; a trade needs `eligible: true`) and `sdk/stock-zap.mjs` (now with `buildSell`). `sdk/pt-usdg.mjs`'s
    `sendCalls` takes the words its `TX_UNCONFIRMED` names to check (`recheck`) and a call's own `nonce`, which each step
    of a stock trade carries, read just before it (an ethers provider's 250 ms cache could give a step the one the step
    before took); PT-USDG's calls and words are unchanged.
- **A Base payment its seller answered as paid stays counted until USDC shows its settlement** (found in Priors' own
  live test of 2026-10-29). `pay_url` forgot a payment on Base once the seller answered it paid, but a facilitator can
  answer before its settlement is mined: `return_to_robinhood("all")`, called half a second after such a payment, asked
  Relay for USDC the settlement was about to take, and Relay reported the return failed (no USDG delivered; its
  authorization expired unused). Such a payment is now counted until USDC records its authorization's nonce as used or
  the authorization expires, and it is read before the float: `return_to_robinhood` keeps it back, and `pay_url`'s Base
  reserve, which counted only a return still in flight, counts it with the payments signed on Base and not settled yet
  (a payment the rest cannot cover is refused before anything is signed, and says so). The nonces are asked at once
  under one 5 s bound; one whose record cannot be read stays counted. They are kept in this process's memory: another
  session of the wallet, or a server restarted meanwhile, does not see them for the seconds a settlement takes.

## 0.13.0 (2026-10-29)

Still on @priors/x402 0.8.3.

- **Invisible characters in a merchant's text no longer reach the model.** The data fence kept merchant text from
  writing outside its markers, but the invisible characters inside it came through as written: Unicode tag characters
  (U+E0000 to U+E007F, "ASCII smuggling": each reads to a model as an ASCII letter and shows nothing to a person),
  zero-width characters, bidi controls and marks, variation selectors. Every default-ignorable code point and format
  character is now removed from third-party text before the fence reads it (a response body, a redirect target, the
  listings, Keyring's listing, a third-party string quoted in an answer or in `structuredContent`), but the number signs
  such as U+0600, which are visible. Where a fence removed any, a line of the server's own right after its closing
  marker says how many, never which: `(response body: 98 invisible characters removed)`. What it costs legitimate
  text: an emoji ZWJ sequence shows its emoji side by side, an emoji loses its VS16 style, a subdivision flag shows as a
  black flag, a Persian or Indic word loses its ZWNJ or ZWJ, mixed-direction text shows in the bidi algorithm's own
  order. A reference to one (`&zwj;`) is visible and stays as written; a merchant's link that carries one, as written or
  percent-encoded, is not given ("no url"), like any link the fence would change. Text with none comes back byte for
  byte. The hosted MCP (mcp.priors.trade) shares the fence: its listings and manifests lose them too.
- **`pay_url` and `pay_gateway` say when the answer's body could not be read whole** (issue #19, reported by
  ryan-ubi). A body that failed mid-read after the headers (a timeout, a reset) was dropped with no line, so a paid
  call read as delivered. Now the answer says so, and once the payment settled, that it is not undone and that calling
  again for the same purchase pays again.
- **Trading agents from the agent's own key, with `PRIORS_MARKET=on` (off by default)**. `market_agent` reads an agent
  on Priors' agent market: its holder, its listing, its hold, its line and bond, whether this server may sell it, and on
  AgentMarketV2 its open bids with their ids and proofs. `market_list`, `market_cancel` and `market_buy` list, cancel
  and buy on AgentMarket; `market_bid`, `market_bid_any`, `market_cancel_bid` and `market_accept` register only with
  AgentMarketV2's record in the package (`deployments/4663.agent-market-v2.json`), which it carries since V2's deploy
  (2026-10-28): the market is AgentMarketV2, with AgentMarket v1 as its `previous`.
  - Each step is a plain transaction from the configured wallet, its gas in ETH, sent through the one-money-call queue.
    `sdk/market-plan.mjs` (bundled byte for byte, with the SDK files it imports) checks every rule of the market on
    reads taken at one block before anything is signed; each step is simulated before it is signed, and everything is
    read and planned again before each later step, so a listing changed meanwhile stops the call between steps.
  - Refused before anything is signed: an agent not in `PRIORS_MARKET_SELL` (off by default), the agent the server acts
    for (`PRIORS_AGENT_ID`, always), a price or a net under `PRIORS_MARKET_MIN_SELL_USD`, a buy or a bid above
    `PRIORS_MAX_MARKET_USD`, open bids above `PRIORS_MAX_BIDS_USD`, a day above `PRIORS_MAX_MARKET_DAY_USD` (required with
    the switch, counted per UTC day for the agent and the wallet across restarts, in `PRIORS_STATE_DIR/market`), and a
    buy, a bid or a bond that would leave less USDG, savings counted, than the agent's open loans owe (checked again
    before each later step that takes USDG).
  - A market record per wallet (`market-<wallet>.json`) is written before each broadcast: a lost answer is
    `TX_UNCONFIRMED`, nothing more is sent while it is pending, and a retry of the same call within 10 minutes of its
    settling answers from the record instead of buying or bidding again; a bid on the same terms as one the record made
    in those 10 minutes, still open, is refused.
  - `market_bid_any` bids on Priors' hub's list for an origin, its ids checked against its root (which proves only that
    the list is the hub's): the answer names the list and its first ids, and the bid asks at least 1 repaid loan by
    default.
  - A sale's net is the price less the fee, and less the agent's builder share where the market answers `builderOf`;
    an accept pins it exactly (`minNet`).
  - The market is the package's deployment record, confirmed on chain at the first market call; there is no address
    setting. With `PRIORS_MARKET` off (unset, or `off`, `false`, `0`, `no`, `none`), the tools and the instructions are
    0.12.0's, byte for byte, and none of the market's settings is read.
- **`first_line` posts at most `PRIORS_MAX_BOND_TOTAL_USD` in bonds while the server runs (default 5 USDG: one bond)**
  (GHSA-43jv-qfcj-qhjh, rated Low, reported by mfrxivu). It was the one money tool with no bound on the process (P-2's
  rule, which `pay_url`'s `PRIORS_MAX_SPEND_USD` and the totals of `borrow`, `save`, `pt_buy` and the bridge keep for
  theirs): with no `PRIORS_MAX_SPEND_DAY_USD` set, one process posted a 5 USDG bond for every identity the wallet owns
  with no record, as long as the invite bot answered open. A bond past it is refused before anything is signed or the
  bot is asked. It counts from its deposit's broadcast; a deposit refused before it, or that the chain shows moved
  nothing (dropped, refused for gas, reverted), counts nothing. Read only with `PRIORS_JOIN=on`; with it off the server
  is as before.
- **`first_line` counts the bond against `PRIORS_MAX_SPEND_DAY_USD` only once its deposit is about to be broadcast.**
  A deposit refused by its simulation, or whose gas or balance could not be read, or that could not be signed or kept
  on file, sent nothing, but it was counted as the day's 5 USDG: under a 5 USDG limit, first_line could not be called
  again that day. Such a deposit now counts nothing; one broadcast counts, whatever its answer, as before.
- **zod ^4.6.6** (from ^4.6.5).

## 0.12.2 (2026-10-27)

Still on @priors/x402 0.8.3.

- **A dollar amount rounds up to the next USDG unit only by the float rounding of its own value** (GHSA-6rfc-64cr-p7v5,
  reported by Leonardiae). Since 0.2.6 a `max_price_usd`, `max_borrow_usd` or other dollar amount that would round up
  is refused as having more than 6 decimals, but the check let it round up by as much as 1e-12 USD, kept for float
  noise: a `max_price_usd` of 0.0999999999995 or 0.09999999999999 signed a 0.10 USDG payment, an excess of at most a
  millionth of one USDG unit. An amount now rounds up only by a few units in the last place of its own value, and never
  by more than 1e-12: a computed 0.7 + 0.1 (0.7999999999999999) still reads as 0.80, and both values above are refused.

## 0.12.1 (2026-10-27)

On @priors/x402 0.8.3 (GHSA-xccq-5ghg-w7mq and GHSA-qcrq-x8xg-25vg, reported by hey-research-lab):

- **`borrow` for more than 10 days on a line SeatVaultV5 backs is refused before anything is sent.** It sent V5's
  refresh (or this key's `noteDelegate`) first, then the borrow reverted; the refusal names the limit. `pay_url`,
  `pay_gateway` and `fund_base`'s loan borrow for 7 days, within it.
- **The agent's key borrows on a V5 line only 24 hours after V5 recorded it, whatever the line's room:** `borrow`
  records the key (`noteDelegate`) and answers `V5_DELEGATE_WAIT` with when it can borrow, instead of trying a borrow
  that could only revert.
- **`credit_status` and `stock_position` say 0 can be drawn, and why, when every loan would be refused:** a default
  marked on the owner's account (any line), or a stock line whose agent changed hands since its position opened,
  defaulted or is frozen. They showed the stock vault's `borrowRoom`, or the pool's figure.

## 0.12.0 (2026-10-26)

- **A borrow the node took is always counted** (GHSA-rh27-m4c4-p2c7, reported by kevin9327). ethers' default
  transport sends a JSON-RPC request again after an HTTP 429, and a node that took the first copy of a signed borrow
  can answer the identical retried bytes "insufficient funds for gas * price + value". `borrow`, `pay_url`,
  `pay_gateway` and `fund_base`'s loan took that answer as a refusal before anything was sent and gave back what the
  call had reserved: `PRIORS_MAX_BORROW_TOTAL_USD` let a second borrow through in the same session, and
  `PRIORS_MAX_BORROW_DAY_USD` after a restart on the same `PRIORS_STATE_DIR` (two loans of 25 USDG against limits of
  25). `fund_base` also cleared its record of a deposit that may have left, and a savings top-up that may have landed
  read as "no ETH for gas", so `pay_url` could borrow for money already on its way.
  - On @priors/x402 0.8.2: that answer is a refusal only while the node does not know the signed transaction's hash.
    Otherwise a borrow is unconfirmed: counted against both limits, and the answer says it may have opened a loan, with
    its hash. `fund_base` keeps its record of the deposit, and a top-up is pending (the payment waits for it).
  - This server's own connection (`PRIORS_RPC`) no longer sends a request carrying `eth_sendRawTransaction` again
    after a 429: that 429 is the call's answer, unconfirmed like any lost answer. Reads keep ethers' retries.
  - What is left: behind a load balancer, the hash lookup can reach a backend that has not seen the transaction yet
    (`docs/SECURITY-v2.md` P-48 in the repository).
- **`first_line`, with `PRIORS_JOIN=on`: the treasury's first line for the identity `join` registered, with no clone or
  Telegram** (`docs/growth/mcp-first-line.md` in the repository). For the identity the configured wallet owns, when it
  has no Priors record, it takes the invite page's steps from the wallet: the invite's 5 USDG bond (USDG's `approve`
  when the allowance is short, then InviteBond's `deposit`, as the page posts it), the invite bot's browser proof
  (`POST /prove {agentId}`, then `{n, signature}`, at `PRIORS_BOT_URL`, default `https://priors.trade`), then the pool
  consent and treasury v4's `firstLine`, as the SDK's `redeemInvite` does. Its answer names the line (the pool's
  `Vouched` from its receipt) and how the bond comes back.
  - It signs the bot's proof only when the message is, byte for byte, the bot's own start-page text rebuilt here for
    that agent, its request and its expiry, and the answer names the wallet as the owner; anything else is refused,
    judged before the bond, with nothing signed. A bot release that changes that text makes it refuse until this
    package follows.
  - Refused before anything is signed: an identity the wallet does not own; one with a Priors record (its state is the
    answer); too little ETH for the gas, or less USDG than the bond; a `PRIORS_MAX_SPEND_DAY_USD` limit the bond would
    pass (the bond counts against it); the bot's check (`POST /prove {check: true, owner}`) closed, with its reason and
    `line_options`' routes, the fourth the quote of the line the owner's own $PRIORS would open.
  - Every transaction goes through the one-money-call queue, is signed here, kept in `PRIORS_STATE_DIR`
    (`first-line-<wallet>.json`, under the payments' lock) before its one broadcast, and looked up after a failed one,
    as `join`'s. One whose receipt is lost answers `TX_UNCONFIRMED` with its hash; every later call, a restart or
    another session included, sends nothing until it settles, then goes on from there. A bond the wallet already posted
    for the identity is never posted again.
  - With `PRIORS_JOIN` off (unset, or `off`, `false`, `0`, `no`, `none`), the tools, the instructions and every answer
    are 0.11.1's, byte for byte, but for the fix above, and `PRIORS_BOT_URL` is not read. With it on, the instructions
    gain one sentence on `first_line` after `join`'s.
- **The routes `join` and `first_line` answer word SeatVaultV5's step rule as the hosted server does:** each of the 3
  loans is at least half the step's top line (it said "half the line").

## 0.11.1 (2026-10-25)

- **The daily limits count a call that ends while another server checks them.** With `PRIORS_MAX_SPEND_DAY_USD` or
  `PRIORS_MAX_BORROW_DAY_USD` set and several servers sharing one `PRIORS_STATE_DIR`, a check read the day's entries,
  then the markers of the calls in flight, in two listings. A call begun before 00:00 UTC that ended between them (its
  entry moved into the new day, then its marker removed) was in neither, and another server's call could pass the
  day's limit (50 USDG against 25). The markers are now listed first, so such a call is counted at least once, and at
  worst twice for that one check: a refusal near the limit, which passes on a retry. `credit_status`'s "Today (UTC)"
  reads through the same check. A single server was not affected: its money calls run one at a time. 0.8.5 to 0.11.0.
- **undici 6.29.1** (from 6.29.0): its fixes for an unhandled error on a response with too many content encodings,
  and for unbounded memory in its EventSource parser.

## 0.11.0 (2026-10-24)

- **`find_services` lists only the merchants Go mode's Tools lists.** The ones Priors approved, and the ones under review
  whose own endpoint passed the facilitator's 402 check (USDG to their own address), marked under review; a hidden
  merchant, or one under review whose check has not passed, is no longer listed or counted, its words included.
- **`join`, off by default (`PRIORS_JOIN=on`): an agent identity without a clone of the repository.** For the
  configured wallet, when it owns no ERC-8004 identity on Robinhood Chain, `join` sends one transaction to the identity
  registry's `register(string)` (as the SDK's `PriorsV2.register`) with the URI `priors:agent:mcp:<its address>`, which
  the Priors Directory counts under origin Priors, apart from the command line's `priors:agent:<address>`
  (`docs/growth/mcp-join.md` in the repository). Its gas is paid in the wallet's own ETH. It answers the new id and its
  routes to a first line, as the hosted server's `line_options` reads them (the treasury's first line by invite, the
  Ethos lane, a stock line, and the line the owner's own $PRIORS would open, as a quote): `src/line-options.mjs` is the
  hosted server's own computation, and the bundled deployment record gains `treasuryV5`, `treasuryV5AgentId` and
  `ethosRoot` for it.
  - A wallet that already owns an identity gets its id back and nothing is sent; so does a server with
    `PRIORS_AGENT_ID` set.
  - A wallet with no ETH, or less than the registration's gas can cost (the estimate and a quarter, at the fee's
    ceiling), is refused before anything is signed.
  - The registration is signed first, so its hash is known, and kept in `PRIORS_STATE_DIR` (`join-<wallet>.json`,
    owner-only; with the id it registered once mined) before its one broadcast. After a failed broadcast the node is asked about that hash, as `pt_buy` does
    since 0.9.3. A registration whose receipt is lost answers `TX_UNCONFIRMED` with its hash, and every later `join`,
    after a restart or from another session of the same wallet too, sends nothing until the node shows it mined, then
    answers its id. Only once the wallet's nonce is used by another transaction is a registration the node never showed
    dropped: that call registers nothing either, or answers the identity a faster copy of it registered (the nonce and
    the registry read at one block).
  - With it off (unset, or `off`, `false`, `0`, `no`, `none`), the tools, the instructions and every answer are as in
    0.10.2, but for `find_services` (above); any other value stops the start. With it on, the no-agent error names `join` in place of the clone, and the
    instructions gain one sentence on it.

## 0.10.2 (2026-10-23)

- **Every money tool needs the agent's owner or its declared ERC-8004 wallet.** CreditPoolV2 lets an owner name any
  address its pool delegate without that address's consent. A buyer of an agent this wallet once held (or was the
  key of) could name the wallet delegate, borrow, and have `repay` (by `loan_id` or `all: true`) pay the buyer's loans
  from the wallet's USDG, after taking the difference out of its savings, whether the agent came from
  `PRIORS_AGENT_ID` or from the lookup. A wallet that is not the owner must now be the agent's declared wallet (set
  only by its own `AgentWalletSet` signature naming the owner, cleared by a transfer: AutoRepay v2's rule).
  `repay`, `borrow`, `pay_url`, `pay_gateway`, `fund_base` and `autopay_on` all check it, before anything is read,
  signed or sent, and `repay` leaves savings untouched. **Borrowing and repaying are deliberately symmetric:** a key
  that may not repay here may not borrow here either, so no agent can draw a loan this server would then refuse to
  settle before its due date.
- **Breaking for a delegate-only key.** A key named with `setDelegate` but never declared as the agent's wallet now
  does nothing with money here. Its owner declares it once: run `priors-mcp link-wallet --agent <id>`, which prints
  the key's `AgentWalletSet` signature, and the owner sends the registry's `setAgentWallet` (Go mode's Start key is
  already both). Until then, act from the owner's key. Every refusal says this.
- **The agent the lookup found is kept only while the wallet owns it.** Without `PRIORS_AGENT_ID`, the identity found
  was kept for the whole process; one sold since is now looked up again (and so no longer taken as the wallet's).

## 0.10.1 (2026-10-22)

- **`pay_url` no longer times out for a wallet with no `PRIORS_AGENT_ID`.** Since 0.10.0 bundles AutoRepay's address,
  `pay_url` keeps back what Autopay pulls in the next 24 h, which first looks up the wallet's agent in the registry's
  logs (some 470 reads on chain 4663). 0.10.0 waited for that lookup with no bound and repeated it before every
  payment, so a payment from a wallet that owns no agent, or whose agent the lookup is slow to find, ran out of its
  45 s. The lookup now gets a quarter of the call's budget (10 s at most) and keeps nothing back when it runs out, as a
  failed Autopay read always did; a wallet found to own no agent is not looked up again for 10 minutes, unless another
  tool (such as `credit_status`) has found its agent since, and then its plan is read at once. With
  `PRIORS_AGENT_ID` set, nothing changes. `fund_base`'s reserve is the same code. Use 0.10.1 rather than 0.10.0.

## 0.10.0 (2026-10-22)

- **Repay on time works with no setting.** The bundled deployment record names AutoRepay v2
  (`0x72B510AF4e66e5960aB9b975e0BdCf80239e83A0`, deployed 2026-10-20), so `autopay_on` turns on a plan for the agent's
  wallet without `PRIORS_AUTOREPAY`. Versions up to 0.9.3 bundled no address, and `autopay_on` answered that it was
  not deployed unless the variable named one.
- The bundled PT-USDG record carries the stock vault's settings as it holds them on chain: 60% and one $1,000 cap for
  all PT-USDG lines (0.9.3 bundled the launch settings, 50% and $250).
- **`pay_gateway`, off by default (`PRIORS_GATEWAY=on`), and not working with Keyring yet: leave it off.** It buys
  from a seller in Vantis' Keyring catalog with one USDG payment on Robinhood Chain. Most of these sellers (LLM inference, search, data) take USDC on Base. Keyring's
  gateway takes the USDG, pays the seller itself and relays its answer, so the agent's line covers them with no Base
  float. It calls `@priors/x402`'s `createPayer({ gateway }).payViaGateway` (0.8.0).
  - Before anything is signed or borrowed: the seller's record must name `seller_url` when given; Keyring's quote must
    be within `max_price_usd` and `PRIORS_GATEWAY_MAX_FEE_BPS` (default 1000) over the seller's own price; its 402
    may ask no more than the quote, on Robinhood Chain only, and must pay `PRIORS_GATEWAY_PAYTO` when set.
  - `pay_url`'s guards, shared rather than copied: `PRIORS_MAX_PRICE_USD`, `PRIORS_MAX_BORROW_USD`, the session caps,
    the daily caps (`pay_url` and `pay_gateway` count together), `PRIORS_PAY_HOSTS`, one money call at a time, and the
    record of signed, unsettled payments (the same `service_id` and `input` is sent again, never signed twice). It
    borrows only the shortfall, raised to the pool's minimum loan.
  - Tested against a mock Keyring (`scripts/test-mcp-gateway.mjs`). Live, on 2026-10-21, Keyring's 402 asked
    `exact` USDG on Robinhood Chain for `0xa68a4ee3fe22340dde776601a5f67cdcf996f9e9`, then answered every signed
    payment with another 402 or a 502: it reads `X-PAYMENT`, not the `PAYMENT-SIGNATURE` header this version sends,
    and verified none. Nothing was settled; a later version sends what Keyring reads (`docs/X402-ROUTES.md`).
  - Off, the server is unchanged: the tool is not listed and no answer names it. `pay_url`'s answers are unchanged.
- `pt_position` reads the stock vault's hold on PT-USDG live (`lendStatus`): while it holds new PT-USDG credit, the
  answer says the vault lists PT-USDG but takes no new line on it right now, and it says "takes ... now" only once the
  hold reads 0. Where to deposit it is Go mode's PT-USDG link (go.priors.trade/account#ac-pt).
- `stock_line_request` for PT-USDG points at that Go mode link instead of answering that it is not among the stock
  tokens. A stock line already open points at Go mode's Add stock, with no tab name.
- The planned settings shown before a listing are the vault's live ones (60%, one $1,000 cap for all PT-USDG lines).

## 0.9.3 (2026-10-14)

- **A PT-USDG trade whose answer is lost is never said to have done nothing.** `pt_buy`, `pt_sell` and `pt_redeem` now
  sign each step before sending it, so its hash is known first, and after a failed broadcast they ask the node about
  that hash: a step the node shows mined goes on (the trade is done and said so, once), one it shows pending is waited
  for, and "insufficient funds" with no trace of the transaction is a refusal that counts nothing. Any other failure
  says the trade may have been sent, keeps a buy counted against `PRIORS_MAX_PT_TOTAL_USD`, and asks to check
  `pt_position` and `wallet_balance` before trying again. Until now a node's "insufficient funds" was always a refusal,
  though it can also answer a retried request after the first one was taken (GHSA-g5cv's class); the buy was then
  uncounted and given back as nothing sent. Waiting for a receipt is bounded (3 minutes), a lookup that never answers
  included, and a lookup that fails is asked again. The same change is in the SDK's `sdk/pt-usdg.mjs`, whose
  `ptBuy`/`ptSell`/`ptRedeem` throw `TX_UNCONFIRMED` (with the hash and the steps done before) instead of a bare error.

## 0.9.2 (2026-10-13)

- **Merchant text can no longer write a line outside the data fence, or spell its marker.** The marker's keyword was
  rewritten only when split by a space, a hyphen or a soft or zero-width character, and only listed brackets were
  replaced, so a merchant could still close the fence early with an invisible separator (U+180E, U+2063) and
  look-alike brackets (U+22D8 and U+22D9, U+2770 and U+2771, U+27EC and U+27ED, U+2991 to U+2996), and write the lines
  after it as if they were this server's. Every line inside the fence now starts with U+2502 and a space, whatever
  line break the merchant writes (LF, CR, CRLF, NEL, U+2028, U+2029, as a character or as an HTML reference such as
  `&#10;` or `&NewLine;`), so none of its lines stands outside, however it spells or words a boundary; only the
  closing marker with the call's own id ends the fence, and its label says so. Outside the fence, every third-party
  string an answer quotes (an error a library or a node wrote, a bridge's status, the echoed search word) and every
  string and property name of structured content is read the same way, with such a reference as a space; a merchant's
  link is given only whole and as it is: not when the URL parser or cleaning would change it as the merchant wrote it
  (a control character, a tab or line break, a space at either end), not when the fence would change it, as written or
  with its percent-encoding read (`%0A`), not when that encoding does not decode cleanly, and not when it is too long
  to show whole (over 200 characters); then it reads "no url", since a changed or cut link would be another URL.
  Within its lines, merchant text is read as a reader would read it: HTML character references decoded (numeric ones
  however many digits they have), compatibility forms (fullwidth, mathematical, and ones that read as two letters,
  such as U+33CA), no combining marks or invisible characters, any case, and Cyrillic, Greek, Armenian and
  small-capital look-alikes. The keyword comes out as `merchant[-]data` wherever it is split by nothing, a space, a
  dash or any other character outside ASCII, and also by ASCII punctuation where it has a marker's shape (`<<end
  merchant_data ...>>`); a line break inside the fence ends it. Brackets change only in that shape (an opening run
  right before `end` or the keyword, a closing run right after the keyword or its id) with a marker's evidence (the
  word `end`, not the end of `friend` or `backend`; an id; or two brackets), and in runs of two or more facing the
  same way, which become single angle quotation marks (U+2039, U+203A). Everything else is left as written: a single
  bracket, quotation mark or comparison sign (`price<merchant-data`, `merchant-data price < 5`, U+2264 and U+2265, CJK
  brackets), a `merchant_data` key, a `/merchant/data` path, or a URL ending in `merchant` before a line starting
  `data`. A doubled `<<` in merchant text (a C++ stream, a shell here-document) now reads as two U+2039.
  `find_services` echoes the search word the same way. The hosted server's `find_services` uses the same code
  (`src/fence.mjs`).
- **`autopay_on` approves at most 4 x the limit per loan.** The README and the tool's description said the budget is
  4 x the limit and never unlimited, but a `budget_usd` above it was approved as given (1,000,000 USDG on a 25 USDG
  limit). A larger `budget_usd` is now refused before anything is sent; it can still set a smaller budget, down to one
  loan's limit. An allowance approved above it before stays until `autopay_off` with `clear_budget: true`.
- On `@priors/x402` 0.7.1, unchanged.

## 0.9.1 (2026-10-13)

- **`stock_line_request` checks the caps against the line the deposit opens.** The deposit is the line's need × 1.3,
  so the vault opens about 1.3 times the line asked for (at most its largest line); the token's cap and the week's room
  were checked against the line asked for, so a 100 USDG request with 110 USDG of room returned a link to a deposit that
  opens 130 USDG, which the vault refuses. The request is now refused when the line the filled deposit opens is over
  either, and the answer names the largest line that fits with the same room for a 23% fall.
- **`stock_line_request` sizes a named agent at its own loan-to-value**: the vault's `ltvOf(agent, token)`, the token's
  own plus the agent's record bonus, which is what the vault opens its line at. It sized at the token's own, so an agent
  with a bonus was asked for more of the token than its line needs (about 25% more at 75% against 60%). The answer says
  the bonus; when that figure cannot be read, the request is refused rather than sized at the token's own.
- **`stock_line_request` without `agent_id` no longer turns a failed lookup into a new agent's link.** With a wallet
  configured, a wallet that owns several agent identities, or none, a lookup that failed, or a key that can't be used
  now gives a tool error that asks for `agent_id`; before, the link opened the new-agent deposit, where the owner could
  fund another identity than the agent's. `PRIORS_AGENT_ID` is used when set. Only with no wallet configured (and no
  `PRIORS_AGENT_ID`) is a request without `agent_id` for a new agent.
- `stock_line_request` refuses an agent whose owner has a default marked on their account (the pool's `ownerDefaults`,
  which `StockVault.open` refuses for every agent of that owner), instead of a link to a sheet that can open nothing.
- `stock_line_request` names the tab as Go mode shows it (Stock lines, not Backing), and says the pool's grace as it is,
  never rounded up (a 36 h grace reads 1.5 days). `pt_position` names it the same where the vault takes PT-USDG
  behind a line ("Go mode's Stock lines tab").

## 0.9.0 (2026-10-12)

- **`stock_line_request`**: when the agent's line is too small for a task, it asks its owner for a line backed by a
  Robinhood stock token the owner holds. It checks the token takes new lines now (its price, holds, the token's cap, the
  vault's room this week) and that the agent can take one, sizes the deposit to the line asked for (line ÷ LTV × 1.3,
  so what the agent can draw holds through a 23% fall), states the cost in cents for a day and a week, says what a
  default would keep as the live vault does it (its fair-default buffer, or the whole deposit), and returns a Go mode
  link that opens the owner's deposit sheet already filled in. It reads; it never deposits, signs or holds the owner's
  tokens. The same answer as the hosted server's tool (both from `src/stock-line.mjs`).
- `credit_status` names `stock_line_request` as the way to a bigger line, for an agent without a stock line.
- On `@priors/x402` 0.7.0.

## 0.8.5 (2026-10-12)

- **Money counts in the UTC day it lands** (GHSA-266h-jfr9-42cx). A call reserved its room in the day it started and
  kept what it did there, so a borrow sent before 00:00 UTC that landed after was invisible to the new day's
  `PRIORS_MAX_BORROW_DAY_USD` (and to `credit_status`'s "Today"), and a day could carry twice its limit; the same for
  `PRIORS_MAX_SPEND_DAY_USD`. A call's money is now filed in the day it ends, and while a call is in flight every
  process counts it in the days after the one it started, however long its transaction takes; one cut short by a
  crash stays counted for the day it started and the two after.
- **`fund_base` counts against the session caps from its check** (GHSA-24qq-9p83-8798). It checked
  `PRIORS_MAX_BORROW_TOTAL_USD` and `PRIORS_MAX_BRIDGE_TOTAL_USD`, then read the transfer record and the Base float,
  and only then counted, so a second call made while the first waited on a late Base read could pass both caps
  beside it. It now counts right after the check, as `borrow` and `pay_url` do (GHSA-cq9v), and gives it back when it
  is refused.

## 0.8.4 (2026-10-11)

- **SeatVaultV5 lines work out of the box.** The bundled `deployments/4663.v2.json` names SeatVaultV5
  (`0xC999014C6218EC41f0aE412d49AE8f2aA4c539fD`, root `#8762`, live since 2026-10-11 and named by BuyAndBack and the
  SwapLimiter), so a borrow on a V5 line refreshes the line first (from the agent's owner, or from this key once V5
  has recorded it for 24 h); before, that needed `PRIORS_V5` and `PRIORS_V5_ROOT`, which still override it. On
  `@priors/x402` 0.6.5, whose `robinhood` constants name the same V5 and whose `creditContracts` uses it by default.

## 0.8.3 (2026-10-10)

- **`PRIORS_STATE_DIR` must be yours alone** (GHSA-52gp-533q-jx99). It keeps what stops a payment being signed twice
  and the daily limits' ledgers; another local user who could rename its entries made the server start counting from
  nothing (a second borrow past `PRIORS_MAX_BORROW_DAY_USD`). On Linux and macOS, with a wallet configured, the
  directory must belong to your user with no group or other write bit, and every directory above it must belong to
  root or you and not be writable by others unless sticky (`/tmp`): OpenSSH's rule. Otherwise every money tool refuses
  and says what to fix (`chmod 700`), and the read-only tools still answer. The default directory is created `0700`
  and passes; one you made yourself under a `0002` umask (`0775`) needs `chmod 700`.

## 0.8.2 (2026-10-10)

- **On `@priors/x402` 0.6.4**, whose merchant-side `recordGate` keeps a bounded cache (GHSA-vjcp-qx2h-gr2q). The MCP
  server does not use the gate; nothing else changes from 0.8.1.

## 0.8.1 (2026-10-10)

- **`repay` pays only loans the agent's owner now took** (GHSA-mmp8-g8jw-7gqp). A loan opened while someone else
  held the agent (the pool's `Loan.owner` is not the agent's owner now) is refused by `loan_id` and left out by
  `all: true`, which names it and who opened it; nothing is paid for it.
- **The agent lookup skips an identity that left the wallet** (GHSA-mmp8-g8jw-7gqp). Without `PRIORS_AGENT_ID`, the
  wallet's agent is an identity minted to it since the v2 deploy that never left it: one that went to someone else
  and came back, carrying what they borrowed, now needs `PRIORS_AGENT_ID` like a bought one.
- **On `@priors/x402` 0.6.3**, whose `repayLoan` refuses such a loan (`NOT_OWNERS_LOAN`) and whose `settleLoans` leaves
  it unpaid, listed in `others`.

## 0.8.0 (2026-10-09)

For agents that run on their own (in ElizaOS, OpenClaw, Hermes or their own code) and read untrusted text all day.
Every change is opt-in: with none of the new settings, a 0.7.x configuration behaves as before, and every 0.7.x
variable and state file (`outstanding-<wallet>.json`, `bridge-<wallet>.json`) keeps working.

- **`PRIORS_KEY_FILE`**: the key from a file, so a runtime's config holds a path instead of the key. The file is read
  only when nobody but the user can read it: on Linux and macOS a regular file the user owns with no group or other
  permission bits (root may read another user's owner-only file, such as a container secret, only where every
  directory above it, on the path as given and as resolved, belongs to root or to that user and nobody else can write
  it: ssh's secure_path rule, so never under /tmp, where anyone could have put their own key at the path); on Windows
  a file whose access list lets only the user, SYSTEM and Administrators read it, checked by SID through PowerShell's
  Get-Acl (PowerShell run from System32 by its full path, never looked up in the working directory). Any other file is
  refused without being read (the checks use the opened file itself), and the server starts read-only, each money tool
  saying what to fix. `~/` (and `~\` on Windows) is the home directory; a relative path is refused. The content is
  never echoed. `PRIORS_KEY` still works; both at once are refused. Replaces the `sh -c` wrapper.
- **Daily limits that survive a restart**: `PRIORS_MAX_SPEND_DAY_USD` (what `pay_url` signs) and
  `PRIORS_MAX_BORROW_DAY_USD` (what `borrow`, `pay_url` and `fund_base` borrow), per UTC day for the agent
  (`PRIORS_AGENT_ID`, which a daily limit requires: without it the start stops) and for the wallet that signs, across
  restarts and every process sharing `PRIORS_STATE_DIR`: every key and client of the agent shares one count, and a key
  run under another agent id still shares its wallet's. A call is counted at its most from before its check until it
  ends, then at what it did; a call cut short by a crash stays counted at its most. The ledger is one empty file per
  call whose name carries its amounts, created before the directory is summed, so two processes can never pass a limit
  together and there is no lock to go stale. `PRIORS_MAX_BORROW_DAY_USD=0` turns borrowing off. A daily limit with
  `PRIORS_STATE_DIR=off` stops the start. `credit_status` shows today's use.
- **`PRIORS_PAY_HOSTS`**: the only hosts `pay_url` pays, matched exactly after the WHATWG URL parser's normalisation
  (lowercase, punycode, one trailing dot, default port), checked before any request and again on every request the
  payer sends; redirects are never followed. A wildcard, URL, path or user info in the list stops the start.
- **Share facts from `repay`**: for each loan repaid, the agent, the loan, the amount, on time or late (by the
  repaying block's time, read back from the pool) and by how many days, for a late one whether it came inside the
  pool's grace period (said only when the loan's defaultableAt was read: the pool takes a repayment after it too,
  until someone marks the loan defaulted), the loans repaid in all, and the record's page, in the answer and as
  structured content with a suggested line. Reads are best effort within the call's time and never fail the repayment.
  Nothing is ever posted.
- **`@priors/mcp/share`**: `shareFacts`, `repaidPost(facts, { link })` (lowercase, no @mention, hashtag or link unless
  asked) and `REPAID_POST_TEMPLATE`, the rule a runtime's character can carry: one post per repaid loan, in its own
  words, never a reply and never about a borrow alone.
- **`priors-mcp link-wallet --agent <id>`**: the agent's key signs the ERC-8004 registry's `AgentWalletSet` (EIP-712,
  domain "ERC8004IdentityRegistry" version 1 on chain 4663, read from the registry and refused if it differs; the
  owner from `ownerOf`; a deadline 4 minutes past the latest block, at most 290 seconds), and it prints the owner's
  `setAgentWallet` call (`--json` for one line). A command only, never an MCP tool.
- The tool descriptions and the server's instructions name the daily limits and the host list when they are set.

Setup for these, with a block for ElizaOS, OpenClaw and Hermes: the README's "An agent that runs on its own". No
@priors/x402 change: it stays 0.6.2.
