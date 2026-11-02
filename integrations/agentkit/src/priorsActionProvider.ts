import { z } from "zod";
import { decodeEventLog, encodeFunctionData, erc20Abi, formatUnits, Hex, parseUnits } from "viem";
import { x402Client, wrapFetchWithPayment } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import { ActionProvider, CreateAction, EvmWalletProvider, Network } from "@coinbase/agentkit";
import {
  BorrowSchema,
  GetAgentRecordSchema,
  GetCreditLineSchema,
  PayX402WithCreditSchema,
  RepaySchema,
} from "./schemas";
import {
  AUTO_TERM_DAYS,
  AUTOREPAY,
  AUTOREPAY_ABI,
  DEFAULT_TERM_DAYS,
  LOAN_ACTIVE,
  POOL_ABI,
  PRIORS_API,
  PRIORS_POOL,
  REGISTRY,
  REGISTRY_ABI,
  ROBINHOOD_CHAIN_ID,
  ROBINHOOD_NETWORK,
  USDG,
  USDG_DECIMALS,
} from "./constants";

const usdg = (atomic: bigint) => formatUnits(atomic, USDG_DECIMALS);
const sameAddress = (a: unknown, b: string) => String(a).toLowerCase() === b.toLowerCase();
const utcDay = () => new Date().toISOString().slice(0, 10);

/**
 * Auto-borrow, set by the owner in code (never by the model): pay_x402_with_priors_credit borrows the gap on its own,
 * up to `perCall` USDG a call and `perDay` USDG a UTC day in this process, for the `hosts` listed only (exact host
 * names), for 14 days, and only while this wallet's Autopay (AutoRepay v2) covers the new loan. The model's maxBorrow
 * can only lower the amount.
 */
export type AutoBorrowOptions = { perCall: string; perDay: string; hosts: string[] };
export type PriorsOptions = { autoBorrow?: AutoBorrowOptions };

/** A refusal before anything is sent (its message is the answer). */
class Refusal extends Error {}

type Requirement = {
  scheme?: string;
  network?: string;
  asset?: string;
  amount?: string;
  payTo?: string;
};

/**
 * PriorsActionProvider gives an agent on Robinhood Chain a USDG credit line from Priors: pay an x402 URL and borrow
 * the gap when the wallet is short, borrow and repay, and read another agent's repayment record before paying it.
 */
export class PriorsActionProvider extends ActionProvider<EvmWalletProvider> {
  private readonly auto: { perCall: bigint; perDay: bigint; hosts: Set<string> } | null;
  private borrowedToday = { day: "", amount: 0n };

  /**
   * Constructor for the PriorsActionProvider.
   *
   * @param fetchImpl - The fetch used for Priors' API and the x402 URLs (injectable for tests).
   * @param options - `autoBorrow` (off unless given): see AutoBorrowOptions.
   */
  constructor(
    private readonly fetchImpl: typeof fetch = (input, init) => globalThis.fetch(input, init),
    options: PriorsOptions = {},
  ) {
    super("priors", []);
    const a = options.autoBorrow;
    if (!a) {
      this.auto = null;
      return;
    }
    const perCall = parseUnits(String(a.perCall), USDG_DECIMALS);
    const perDay = parseUnits(String(a.perDay), USDG_DECIMALS);
    if (perCall <= 0n) throw new Error("autoBorrow.perCall must be above 0");
    if (perDay < perCall) throw new Error("autoBorrow.perDay must be at least autoBorrow.perCall");
    const hosts = (a.hosts ?? []).map(h => String(h).trim().toLowerCase());
    if (!hosts.length || hosts.some(h => !/^[a-z0-9.-]+(:\d{1,5})?$/.test(h)))
      throw new Error("autoBorrow.hosts must list the host names it may borrow to pay, e.g. [\"models.example\"]");
    this.auto = { perCall, perDay, hosts: new Set(hosts) };
  }

  /**
   * Reads an agent's Priors repayment record.
   *
   * @param _walletProvider - The wallet provider (unused: the record is public).
   * @param args - The agent id.
   * @returns The record in plain words, or an error message.
   */
  @CreateAction({
    name: "get_priors_agent_record",
    description: `
This tool reads an ERC-8004 agent's repayment record on Priors: loans repaid, late repayments, defaults and score.
Use it before paying or hiring another agent. It moves no money.

Inputs:
- agentId: the agent's ERC-8004 id on Robinhood Chain.`,
    schema: GetAgentRecordSchema,
  })
  async getAgentRecord(
    _walletProvider: EvmWalletProvider,
    args: z.infer<typeof GetAgentRecordSchema>,
  ): Promise<string> {
    try {
      const res = await this.fetchImpl(`${PRIORS_API}/api/check?agent=${args.agentId}`);
      if (!res.ok) return `Error: Priors answered HTTP ${res.status} for agent #${args.agentId}.`;
      const body = (await res.json()) as {
        agents?: Array<{
          name?: string;
          record?: Record<string, unknown>;
          scoreV2?: Record<string, unknown>;
        }>;
      };
      const a = body.agents?.[0];
      if (!a || !a.record) return `Agent #${args.agentId} has no Priors record.`;
      const r = a.record;
      return [
        `Agent #${args.agentId}${a.name ? ` (${a.name})` : ""} on Priors:`,
        `- loans repaid: ${r.loansRepaid ?? 0} (${r.volumeRepaidUsdg ?? 0} USDG), open loans: ${r.activeLoans ?? 0}`,
        `- defaulted: ${r.defaulted ? "yes" : "no"}${r.frozen ? ", frozen" : ""}`,
        `- late repayments: ${a.scoreV2?.lateRepayments ?? 0}, Score v2: ${a.scoreV2?.score ?? "n/a"} (${a.scoreV2?.rungName ?? "n/a"})`,
        `A record shows how the agent repaid loans on Priors, not whether its service is good.`,
      ].join("\n");
    } catch (error) {
      return `Error reading agent #${args.agentId}'s record: ${error}`;
    }
  }

  /**
   * Reads an agent's Priors credit line.
   *
   * @param _walletProvider - The wallet provider (unused: the line is public).
   * @param args - The agent id.
   * @returns The line in plain words, or an error message.
   */
  @CreateAction({
    name: "get_priors_credit_line",
    description: `
This tool reads an agent's Priors credit line: its size, what is drawn and what is available to borrow. It moves no money.

Inputs:
- agentId: the agent's ERC-8004 id on Robinhood Chain.`,
    schema: GetCreditLineSchema,
  })
  async getCreditLine(
    _walletProvider: EvmWalletProvider,
    args: z.infer<typeof GetCreditLineSchema>,
  ): Promise<string> {
    try {
      const res = await this.fetchImpl(`${PRIORS_API}/api/hub/agent?id=${args.agentId}`);
      if (!res.ok) return `Error: Priors answered HTTP ${res.status} for agent #${args.agentId}.`;
      const body = (await res.json()) as {
        agent?: {
          line?: { limit?: number; drawn?: number; available?: number };
          activeLoans?: number;
        };
      };
      const line = body.agent?.line;
      if (!line) return `Agent #${args.agentId} has no Priors line.`;
      const fmt = (n?: number) => usdg(BigInt(Math.round(Number(n ?? 0))));
      return `Agent #${args.agentId}'s Priors line: ${fmt(line.limit)} USDG, drawn ${fmt(line.drawn)}, available ${fmt(line.available)}; open loans: ${body.agent?.activeLoans ?? 0}.`;
    } catch (error) {
      return `Error reading agent #${args.agentId}'s line: ${error}`;
    }
  }

  /**
   * Borrows USDG from the agent's Priors line into this wallet.
   *
   * @param walletProvider - The wallet provider: the agent's owner or its registry wallet.
   * @param args - The agent id, the amount and the term.
   * @returns The loan, or an error message.
   */
  @CreateAction({
    name: "borrow_from_priors",
    description: `
This tool borrows USDG from the agent's Priors credit line into this wallet, on Robinhood Chain. Real money: the loan
must be repaid (principal and fee) before its due date, or the agent's record ends in a default.

Inputs:
- agentId: the agent's ERC-8004 id; this wallet must be its owner or its registry wallet.
- amount: USDG to borrow, e.g. 1.5 (at least the pool's minimum loan).
- days: the loan term in days (default 7).`,
    schema: BorrowSchema,
  })
  async borrow(
    walletProvider: EvmWalletProvider,
    args: z.infer<typeof BorrowSchema>,
  ): Promise<string> {
    try {
      const loan = await this.borrowAmount(
        walletProvider,
        args.agentId,
        parseUnits(args.amount, USDG_DECIMALS),
        args.days,
      );
      return `Borrowed ${usdg(loan.amount)} USDG from agent #${args.agentId}'s Priors line: loan #${loan.loanId}, fee ${usdg(loan.fee)} USDG, due ${loan.dueAt}. Transaction: ${loan.hash}`;
    } catch (error) {
      return `Error borrowing from Priors: ${error}`;
    }
  }

  /**
   * Repays a Priors loan in full from this wallet.
   *
   * @param walletProvider - The wallet provider.
   * @param args - The loan id.
   * @returns The repayment, or an error message.
   */
  @CreateAction({
    name: "repay_priors_loan",
    description: `
This tool repays a Priors loan in full (principal and fee) from this wallet's USDG on Robinhood Chain. Real money.

Inputs:
- loanId: the loan to repay.`,
    schema: RepaySchema,
  })
  async repay(
    walletProvider: EvmWalletProvider,
    args: z.infer<typeof RepaySchema>,
  ): Promise<string> {
    try {
      const loan = (await walletProvider.readContract({
        address: PRIORS_POOL,
        abi: POOL_ABI,
        functionName: "getLoan",
        args: [BigInt(args.loanId)],
      })) as { agentId: bigint; principal: bigint; fee: bigint; status: number };
      if (Number(loan.status) !== LOAN_ACTIVE) return `Error: loan #${args.loanId} is not active.`;
      const due = loan.principal + loan.fee;
      const me = walletProvider.getAddress() as Hex;
      const balance = (await walletProvider.readContract({
        address: USDG,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [me],
      })) as bigint;
      if (balance < due)
        return `Error: repaying loan #${args.loanId} needs ${usdg(due)} USDG, the wallet holds ${usdg(balance)}.`;
      const allowance = (await walletProvider.readContract({
        address: USDG,
        abi: erc20Abi,
        functionName: "allowance",
        args: [me, PRIORS_POOL],
      })) as bigint;
      if (allowance < due) {
        const approve = await walletProvider.sendTransaction({
          to: USDG,
          data: encodeFunctionData({
            abi: erc20Abi,
            functionName: "approve",
            args: [PRIORS_POOL, due],
          }),
        });
        await walletProvider.waitForTransactionReceipt(approve);
      }
      const hash = await walletProvider.sendTransaction({
        to: PRIORS_POOL,
        data: encodeFunctionData({
          abi: POOL_ABI,
          functionName: "repay",
          args: [BigInt(args.loanId), loan.agentId, due],
        }),
      });
      await walletProvider.waitForTransactionReceipt(hash);
      return `Repaid Priors loan #${args.loanId}: ${usdg(due)} USDG. Transaction: ${hash}`;
    } catch (error) {
      return `Error repaying loan #${args.loanId}: ${error}`;
    }
  }

  /**
   * Pays an x402 URL in USDG on Robinhood Chain, borrowing the gap from the Priors line when the wallet is short.
   *
   * @param walletProvider - The wallet provider: the agent's owner or its registry wallet.
   * @param args - The URL, the agent id, the most to pay and the most to borrow.
   * @returns What was paid and borrowed and the response, or an error message.
   */
  @CreateAction({
    name: "pay_x402_with_priors_credit",
    description: `
This tool fetches a URL that charges per call with x402 (HTTP 402) and pays it in USDG on Robinhood Chain from this
wallet, with GET, or with POST and a body (an OpenAI-style chat completion, for one). If the wallet is short of the
price, it first borrows the gap from the agent's Priors line, only when maxBorrow covers it, or, when the provider was
set up with autoBorrow, on its own within the owner's limits while Autopay covers the loan. Real money: confirm the URL,
the price and the most to borrow with the user first.

Inputs:
- url: the https URL.
- agentId: the agent's ERC-8004 id whose line may be drawn.
- maxPrice: the most to pay for this call, in USDG (e.g. 0.10).
- maxBorrow: the most to borrow if the wallet is short, in USDG (default 0: never borrow; with autoBorrow, its amount
  per call, which this can only lower).
- days: the term of a loan taken for the gap (default 7; 14 with autoBorrow).
- method, body: POST and its body (default GET with no body).`,
    schema: PayX402WithCreditSchema,
  })
  async payX402WithCredit(
    walletProvider: EvmWalletProvider,
    args: z.infer<typeof PayX402WithCreditSchema>,
  ): Promise<string> {
    try {
      if (!/^https:\/\//i.test(args.url)) return "Error: only https URLs are paid.";
      const method = args.method ?? (args.body !== undefined ? "POST" : "GET");
      if (method === "GET" && args.body !== undefined)
        return "Error: a GET request cannot carry a body: use POST.";
      let json = false;
      if (args.body !== undefined) {
        try {
          JSON.parse(args.body);
          json = true;
        } catch {
          json = false;
        }
      }
      const init = (): RequestInit =>
        args.body !== undefined
          ? { method, body: args.body, headers: { "content-type": json ? "application/json" : "text/plain; charset=utf-8" } }
          : { method };
      const maxPrice = parseUnits(args.maxPrice, USDG_DECIMALS);
      // autoBorrow: the owner's amount per call, which the model's maxBorrow can only lower, and only for its hosts
      const auto = this.auto;
      const host = new URL(args.url).host.toLowerCase();
      const autoHere = !!auto && auto.hosts.has(host);
      const named = parseUnits(args.maxBorrow ?? "0", USDG_DECIMALS);
      const maxBorrow = !auto
        ? named
        : !autoHere
          ? 0n
          : args.maxBorrow === undefined || named > auto.perCall
            ? auto.perCall
            : named;
      const days = args.days ?? (auto ? AUTO_TERM_DAYS : DEFAULT_TERM_DAYS);
      const probe = await this.fetchImpl(args.url, init());
      if (probe.status !== 402)
        return `No payment asked (HTTP ${probe.status}):\n${(await probe.text()).slice(0, 2000)}`;
      const requirement = await this.usdgRequirement(probe);
      if (!requirement)
        return "Error: the URL asks for no USDG payment on Robinhood Chain (x402 exact).";
      const price = BigInt(requirement.amount ?? "0");
      if (price > maxPrice)
        return `Error: the URL asks ${usdg(price)} USDG, above maxPrice ${args.maxPrice}. Nothing was paid.`;
      const me = walletProvider.getAddress() as Hex;
      const balance = (await walletProvider.readContract({
        address: USDG,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [me],
      })) as bigint;
      let borrowed = "";
      if (balance < price) {
        const params = (await walletProvider.readContract({
          address: PRIORS_POOL,
          abi: POOL_ABI,
          functionName: "getParams",
        })) as { minLoan: bigint; maxTerm: bigint };
        const gap = price - balance;
        const amount = gap > params.minLoan ? gap : params.minLoan;
        if (auto && !autoHere)
          return `Error: the wallet holds ${usdg(balance)} USDG, short of ${usdg(price)}, and auto-borrow borrows only to pay ${[...auto.hosts].join(", ")}. Nothing was borrowed or paid.`;
        if (amount > maxBorrow) {
          return `Error: the wallet holds ${usdg(balance)} USDG, short of ${usdg(price)}; borrowing ${usdg(amount)} (the pool's minimum loan is ${usdg(params.minLoan)}) is above ${auto ? `the most this call may borrow, ${usdg(maxBorrow)}` : `maxBorrow ${args.maxBorrow || "0"}`}. Nothing was paid.`;
        }
        // auto: the day's room is taken here, before any await, so two calls running at once never both pass the
        // limit; it is given back only when the borrow is refused before anything is sent (a borrow sent whose answer
        // was lost stays counted, the safe direction)
        let reserved: { day: string; amount: bigint } | null = null;
        if (auto) {
          const today = utcDay();
          if (this.borrowedToday.day !== today) this.borrowedToday = { day: today, amount: 0n };
          if (this.borrowedToday.amount + amount > auto.perDay)
            return `Error: the wallet holds ${usdg(balance)} USDG, short of ${usdg(price)}, and auto-borrow's limit of ${usdg(auto.perDay)} USDG a day has ${usdg(auto.perDay - this.borrowedToday.amount)} left in this process, less than ${usdg(amount)}. Nothing was borrowed or paid.`;
          this.borrowedToday.amount += amount;
          reserved = { day: today, amount };
        }
        // auto: 14 days, brought down to the pool's maxTerm; otherwise the term asked, as before
        const termDays = auto && params.maxTerm !== undefined && BigInt(days) * 86400n > BigInt(params.maxTerm) ? Number(BigInt(params.maxTerm) / 86400n) : days;
        const loan = await this.borrowAmount(walletProvider, args.agentId, amount, termDays,
          auto ? (fee: bigint) => this.autopayCovers(walletProvider, args.agentId, amount + fee) : undefined)
          .catch((error: unknown) => {
            if (reserved && error instanceof Refusal && this.borrowedToday.day === reserved.day) this.borrowedToday.amount -= reserved.amount;
            throw error;
          });
        borrowed = `Borrowed ${usdg(loan.amount)} USDG first: loan #${loan.loanId}, fee ${usdg(loan.fee)}, due ${loan.dueAt} (transaction ${loan.hash}). ${auto ? "Auto-borrow: Autopay repays it from this wallet in its window, the last hours before it is due; keep its due in the wallet by then." : "Repay it with repay_priors_loan before then."}\n`;
      }
      const client = new x402Client()
        .register(ROBINHOOD_NETWORK, new ExactEvmScheme(walletProvider.toSigner()))
        .registerPolicy((_version, reqs) =>
          reqs.filter(
            r =>
              r.network === ROBINHOOD_NETWORK &&
              sameAddress(r.asset, USDG) &&
              BigInt((r as Requirement).amount ?? "0") <= maxPrice,
          ),
        );
      const paid = await wrapFetchWithPayment(this.fetchImpl, client)(args.url, init());
      const receipt =
        paid.headers.get("payment-response") || paid.headers.get("x-payment-response");
      return `${borrowed}Paid ${usdg(price)} USDG to ${requirement.payTo} (HTTP ${paid.status})${receipt ? `; settlement: ${receipt.slice(0, 200)}` : ""}.\nResponse:\n${(await paid.text()).slice(0, 2000)}`;
    } catch (error) {
      if (error instanceof Refusal) return `Error: ${error.message}`;
      return `Error paying ${args.url} with Priors credit: ${error}`;
    }
  }

  /**
   * Auto-borrow's condition, read before the borrow is sent: this wallet is the agent's declared wallet, its Autopay
   * plan is on and set under the agent's current owner and key, not held or paused, its limit per loan is at least
   * `due`, and its USDG approval to AutoRepay covers `due` on top of the agent's open loans it already repays (those
   * within its limit), as @priors/mcp's check. Throws a Refusal saying what to turn on otherwise.
   *
   * @param walletProvider - The wallet provider.
   * @param agentId - The agent id.
   * @param due - The new loan's principal plus fee, atomic USDG.
   */
  private async autopayCovers(walletProvider: EvmWalletProvider, agentId: number, due: bigint) {
    const me = walletProvider.getAddress() as Hex;
    const id = BigInt(agentId);
    const read = (address: Hex, abi: typeof REGISTRY_ABI | typeof AUTOREPAY_ABI | typeof erc20Abi, functionName: string, args: unknown[] = []) =>
      walletProvider.readContract({ address, abi, functionName, args } as never) as Promise<unknown>;
    const [wallet, owner, plan, epoch, held, pausedUntil, allowance] = (await Promise.all([
      read(REGISTRY, REGISTRY_ABI, "getAgentWallet", [id]),
      read(REGISTRY, REGISTRY_ABI, "ownerOf", [id]),
      read(AUTOREPAY, AUTOREPAY_ABI, "planOf", [me, id]),
      read(AUTOREPAY, AUTOREPAY_ABI, "epochOf", [id]),
      read(AUTOREPAY, AUTOREPAY_ABI, "held", [me]),
      read(AUTOREPAY, AUTOREPAY_ABI, "pausedUntil"),
      read(USDG, erc20Abi, "allowance", [me, AUTOREPAY]),
    ])) as [string, string, readonly [number | bigint, string, boolean, boolean, boolean, number | bigint], readonly [number | bigint, boolean], boolean, bigint, bigint];
    const no = (why: string) =>
      new Refusal(`auto-borrow borrows only when Autopay covers the new loan (${usdg(due)} USDG due), and ${why}. Nothing was borrowed or paid. Turn Autopay on for this wallet with a limit of at least ${usdg(due)} USDG per loan (Go mode, or @priors/mcp's autopay_on).`);
    const [cap, planOwner, on, , , planEpoch] = plan;
    if (!sameAddress(wallet, me)) throw no(`this wallet is not agent #${agentId}'s declared wallet`);
    if (!on) throw no("Autopay is off for this wallet");
    if (!sameAddress(planOwner, owner) || BigInt(planEpoch) !== BigInt(epoch[0]))
      throw no("this wallet's Autopay plan was set under an earlier owner or key of the agent");
    if (held) throw no("Autopay is on hold for this wallet");
    if (BigInt(pausedUntil) > BigInt(Math.floor(Date.now() / 1000))) throw no("Autopay is paused by the Safe");
    if (BigInt(cap) < due) throw no(`Autopay's limit is ${usdg(BigInt(cap))} USDG per loan`);
    // what the agent's open loans already need from that approval: each active loan within the plan's limit
    const ids = (await walletProvider.readContract({ address: PRIORS_POOL, abi: POOL_ABI, functionName: "loansOf", args: [id] })) as readonly bigint[];
    let owed = 0n;
    for (const loanId of ids) {
      const l = (await walletProvider.readContract({ address: PRIORS_POOL, abi: POOL_ABI, functionName: "getLoan", args: [loanId] })) as { principal: bigint; fee: bigint; status: number };
      const loanDue = BigInt(l.principal) + BigInt(l.fee);
      if (Number(l.status) === LOAN_ACTIVE && loanDue <= BigInt(cap)) owed += loanDue;
    }
    if (BigInt(allowance) < owed + due)
      throw no(`Autopay may pull ${usdg(BigInt(allowance))} USDG from this wallet, and its open loans already need ${usdg(owed)} USDG`);
  }

  /**
   * Checks if the action provider supports the given network: Robinhood Chain only.
   *
   * @param network - The network to check.
   * @returns True on Robinhood Chain (chain id 4663).
   */
  supportsNetwork = (network: Network) =>
    network.protocolFamily === "evm" && String(network.chainId) === ROBINHOOD_CHAIN_ID;

  /**
   * The x402 v2 `exact` requirement for USDG on Robinhood Chain, from the 402's header or body.
   *
   * @param probe - The 402 response.
   * @returns The requirement, or null.
   */
  private async usdgRequirement(probe: Response): Promise<Requirement | null> {
    let accepts: Requirement[] = [];
    const header = probe.headers.get("payment-required");
    if (header) {
      try {
        accepts = JSON.parse(Buffer.from(header, "base64").toString("utf8")).accepts ?? [];
      } catch {
        accepts = [];
      }
    }
    if (!accepts.length) {
      try {
        accepts = ((await probe.clone().json()) as { accepts?: Requirement[] }).accepts ?? [];
      } catch {
        accepts = [];
      }
    }
    return (
      accepts.find(
        r =>
          r.scheme === "exact" &&
          r.network === ROBINHOOD_NETWORK &&
          sameAddress(r.asset, USDG) &&
          /^\d+$/.test(String(r.amount)),
      ) ?? null
    );
  }

  /**
   * Borrows `amount` atomic USDG for `days` from the agent's line into this wallet.
   *
   * @param walletProvider - The wallet provider.
   * @param agentId - The agent id.
   * @param amount - Atomic USDG.
   * @param days - The term in days.
   * @param check - Called with the quoted fee before the borrow is sent; a throw refuses it.
   * @returns The loan.
   */
  private async borrowAmount(
    walletProvider: EvmWalletProvider,
    agentId: number,
    amount: bigint,
    days: number,
    check?: (fee: bigint) => Promise<void>,
  ) {
    const me = walletProvider.getAddress() as Hex;
    const term = BigInt(days * 86400);
    const [fee] = (await walletProvider.readContract({
      address: PRIORS_POOL,
      abi: POOL_ABI,
      functionName: "quoteFee",
      args: [BigInt(agentId), amount, term],
    })) as readonly [bigint, bigint, bigint, bigint];
    if (check) await check(fee);
    const hash = await walletProvider.sendTransaction({
      to: PRIORS_POOL,
      data: encodeFunctionData({
        abi: POOL_ABI,
        functionName: "borrow",
        args: [BigInt(agentId), amount, term, me, fee],
      }),
    });
    const receipt = await walletProvider.waitForTransactionReceipt(hash);
    let loanId = "?";
    let dueAt = "?";
    for (const log of (receipt?.logs ?? []) as Array<{
      address: string;
      data: Hex;
      topics: [Hex, ...Hex[]];
    }>) {
      if (!sameAddress(log.address, PRIORS_POOL)) continue;
      try {
        const ev = decodeEventLog({ abi: POOL_ABI, data: log.data, topics: log.topics });
        if (ev.eventName === "Borrowed") {
          loanId = String(ev.args.loanId);
          dueAt = new Date(Number(ev.args.dueAt) * 1000).toISOString();
        }
      } catch {
        // another event of the pool
      }
    }
    return { amount, fee, hash, loanId, dueAt };
  }
}

export const priorsActionProvider = (fetchImpl?: typeof fetch, options?: PriorsOptions) =>
  new PriorsActionProvider(fetchImpl, options);
