// @priors/plugin-elizaos: Priors credit for elizaOS agents. Four actions over the two Priors MCP servers (priors.js):
// read another agent's repayment record, read the agent's own line, pay an x402 URL that borrows the gap when the
// wallet is short, and repay a loan. Every amount and URL comes from the user's own message (parse.js); a payment
// borrows only when the message names the most to borrow. The caps, the host allowlist and the signing are
// @priors/mcp's own.
import { priorsOf } from "./priors.js";
import { urlOf, agentIdOf, loanIdOf, maxPriceOf, maxBorrowOf } from "./parse.js";

const textOf = (message) => String((message && message.content && message.content.text) || "");

/** Answer through the callback and as the action's result. */
async function answer(callback, action, ok, text, data = {}) {
  if (typeof callback === "function") await callback({ text, actions: [action] });
  return { success: ok, text, data: { actionName: action, ...data } };
}

export const agentRecordAction = {
  name: "PRIORS_AGENT_RECORD",
  similes: ["CHECK_AGENT_RECORD", "AGENT_REPAYMENT_RECORD", "PRIORS_RECORD"],
  description: "Read an ERC-8004 agent's repayment record on Priors (its line, repaid and late loans, defaults, score) before paying or hiring it. Needs the agent id in the message, as #1234.",
  validate: async (_runtime, message) => agentIdOf(textOf(message)) !== null && /record|repa|default|reliab|trust|check|score/i.test(textOf(message)),
  handler: async (runtime, message, _state, _options, callback) => {
    const id = agentIdOf(textOf(message));
    const r = await priorsOf(runtime).read("agent_record", { agent_id: id });
    return answer(callback, "PRIORS_AGENT_RECORD", r.ok, r.text, { agentId: id });
  },
  examples: [[
    { name: "{{user1}}", content: { text: "Before we pay it, check agent #9233's record on Priors." } },
    { name: "{{agentName}}", content: { text: "Agent #9233 has repaid 2 loans and never defaulted.", actions: ["PRIORS_AGENT_RECORD"] } },
  ]],
};

export const creditStatusAction = {
  name: "PRIORS_CREDIT_STATUS",
  similes: ["MY_CREDIT_LINE", "PRIORS_LINE", "OPEN_LOANS"],
  description: "Read this agent's own Priors credit line on Robinhood Chain: what is available, what is drawn, its open loans and their due dates.",
  validate: async (_runtime, message) => !urlOf(textOf(message)) && /credit line|my line|\bline\b|open loans?|what (do )?i owe|due/i.test(textOf(message)),
  handler: async (runtime, _message, _state, _options, callback) => {
    const r = await priorsOf(runtime).wallet("credit_status", {});
    return answer(callback, "PRIORS_CREDIT_STATUS", r.ok, r.text);
  },
  examples: [[
    { name: "{{user1}}", content: { text: "How much is left on my Priors line, and what is due?" } },
    { name: "{{agentName}}", content: { text: "Your line is 5 USDG; 4.90 is available and one loan is due on 6 November.", actions: ["PRIORS_CREDIT_STATUS"] } },
  ]],
};

export const payX402Action = {
  name: "PRIORS_PAY_X402",
  similes: ["PAY_X402", "PAY_HTTP_402", "BUY_API_CALL"],
  description: "Pay an HTTP 402 (x402) URL in USDG from this agent's wallet. If the wallet is short, it borrows the gap from the agent's Priors line, only when the message names the most to borrow. The message must name the URL and the most to pay. Real money.",
  validate: async (_runtime, message) => !!urlOf(textOf(message)) && /\bpay|buy|call|fetch/i.test(textOf(message)),
  handler: async (runtime, message, _state, _options, callback) => {
    const text = textOf(message);
    const url = urlOf(text), maxPrice = maxPriceOf(text), maxBorrow = maxBorrowOf(text);
    if (maxPrice === null || maxPrice <= 0) {
      return answer(callback, "PRIORS_PAY_X402", false, `Nothing was paid. Say the most to pay for ${url}, for example "at most 0.10", and if the wallet may borrow, the most to borrow, for example "borrow up to 1".`, { url });
    }
    const args = { url, max_price_usd: maxPrice, ...(maxBorrow > 0 ? { max_borrow_usd: maxBorrow } : {}) };
    const r = await priorsOf(runtime).wallet("pay_url", args);
    return answer(callback, "PRIORS_PAY_X402", r.ok, r.text, { url, maxPrice, maxBorrow });
  },
  examples: [[
    { name: "{{user1}}", content: { text: "Pay https://check.blockpin.dev/check at most 0.10, borrow up to 5 if the wallet is short." } },
    { name: "{{agentName}}", content: { text: "Paid 0.10 USDG; the wallet was short, so it borrowed 5 USDG, the pool's minimum loan, from the Priors line (loan #50900, due 6 November).", actions: ["PRIORS_PAY_X402"] } },
  ]],
};

export const repayAction = {
  name: "PRIORS_REPAY",
  similes: ["REPAY_LOAN", "PAY_BACK_LOAN"],
  description: "Repay one of this agent's Priors loans in full (principal and fee) from its wallet. Needs the loan id in the message, as loan 50900. Real money.",
  validate: async (_runtime, message) => loanIdOf(textOf(message)) !== null && /repay|pay (it )?back/i.test(textOf(message)),
  handler: async (runtime, message, _state, _options, callback) => {
    const loan = loanIdOf(textOf(message));
    const r = await priorsOf(runtime).wallet("repay", { loan_id: loan });
    return answer(callback, "PRIORS_REPAY", r.ok, r.text, { loanId: loan });
  },
  examples: [[
    { name: "{{user1}}", content: { text: "Repay loan 50900 now." } },
    { name: "{{agentName}}", content: { text: "Loan #50900 repaid: 5.011666 USDG.", actions: ["PRIORS_REPAY"] } },
  ]],
};

export const priorsPlugin = {
  name: "priors",
  description: "Priors credit for agents on Robinhood Chain: pay x402 APIs and borrow the gap in USDG from the agent's line, repay it, and read another agent's repayment record before paying it.",
  actions: [agentRecordAction, creditStatusAction, payX402Action, repayAction],
  providers: [],
  evaluators: [],
};

export default priorsPlugin;
