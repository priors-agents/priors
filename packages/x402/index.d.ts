// Hand-written types for @priors/x402 (the package is plain ESM JavaScript).
import type { FacilitatorConfig, HTTPFacilitatorClient, x402ResourceServer } from "@x402/core/server";
import type { x402Client } from "@x402/core/client";
import type { PaymentRequirements, SchemeNetworkClient, PaymentPayloadContext, PaymentPayloadResult, SettleResponse } from "@x402/core/types";

export interface RobinhoodConstants {
  /** CAIP-2 id: "eip155:4663". */
  readonly network: "eip155:4663";
  /** x402 v1 network name: "robinhood". */
  readonly legacyNetwork: "robinhood";
  readonly chainId: 4663;
  /** USDG address on chain 4663. */
  readonly usdg: `0x${string}`;
  readonly usdgDecimals: 6;
  /** USDG's EIP-712 domain: { name: "Global Dollar", version: "1" }. */
  readonly eip712: { readonly name: "Global Dollar"; readonly version: "1" };
  /** "https://facilitator.priors.trade" */
  readonly facilitatorUrl: string;
  /** Public JSON-RPC endpoint of Robinhood Chain. */
  readonly rpcUrl: string;
  /** Priors v2 CreditPoolV2. */
  readonly pool: `0x${string}`;
  /** Priors v2 CreditLensV2 (score). */
  readonly lens: `0x${string}`;
  /** ERC-8004 identity registry. */
  readonly registry: `0x${string}`;
  /** The Priors stock vault (lines backed by the agent's own stock tokens), live since 2026-09-28. */
  readonly stockVault: `0x${string}` | null;
}
export declare const robinhood: RobinhoodConstants;
export declare const ROBINHOOD_NETWORKS: ReadonlySet<string>;
/** 100000n: 0.10 USDG. */
export declare const DEFAULT_MAX_PRICE: bigint;
/** 600 seconds. */
export declare const MAX_VALIDITY_SECONDS: number;
/** 7 days in seconds. */
export declare const DEFAULT_TERM_SECONDS: number;
export declare const TRANSFER_WITH_AUTHORIZATION_TYPES: { readonly TransferWithAuthorization: ReadonlyArray<{ name: string; type: string }> };

/** Atomic USDG, or dollars with a leading "$" ("$0.05"). A number is atomic units. */
export type UsdgAmount = bigint | number | string;
export declare function toAtomicUsdg(v: UsdgAmount, what?: string): bigint;
export declare function formatUsdg(units: bigint | number | string): string;

// ---- merchant ----------------------------------------------------------------------------------------------

/** Registers a money parser so `price: "$0.05"` on eip155:4663 becomes USDG with extra {name, version}. */
export declare function registerUsdg<S extends { registerMoneyParser: (...args: any[]) => any }>(scheme: S, opts?: { asset?: string }): S;

export interface PriorsFacilitatorOptions {
  /** Default https://facilitator.priors.trade (http allowed for localhost only). */
  url?: string;
  /** Merchant API key from POST /merchants/register; sent as `Authorization: Bearer <apiKey>`. */
  apiKey?: string;
  timeoutMs?: number;
}
/** Config for `new HTTPFacilitatorClient(...)`, with per-path auth headers {verify, settle, supported}. */
export declare function priorsFacilitator(opts?: PriorsFacilitatorOptions): FacilitatorConfig;
export declare function priorsFacilitatorClient(opts?: PriorsFacilitatorOptions): HTTPFacilitatorClient;
/** An x402ResourceServer on the Priors facilitator with eip155:4663 priced in USDG. */
export declare function createResourceServer(opts?: PriorsFacilitatorOptions & { asset?: string; facilitatorClient?: any }): x402ResourceServer;

// ---- agent -------------------------------------------------------------------------------------------------

export interface CreatePayerOptions {
  /** ethers v6 Signer connected to a Robinhood Chain provider: the payer, and the controller of `agentId`. */
  signer: any;
  /** Priors agent id to borrow for (needed only to borrow). */
  agentId?: bigint | number | string;
  /** CreditPoolV2 address or ethers Contract (needed only to borrow), e.g. `robinhood.pool`. */
  pool?: string | any;
  /** Most one purchase may borrow; default 0 (never borrow). */
  maxBorrow?: UsdgAmount;
  /** Most one purchase may pay; default 0.10 USDG. Checked before anything is signed or borrowed. */
  maxPrice?: UsdgAmount;
  /** Loan term when borrowing; default 7 days, clamped to the pool's range (an explicit term above maxTerm is refused). */
  termSeconds?: bigint | number;
  /** Refuse a loan whose fee is above this (atomic USDG). */
  maxFee?: bigint;
  /** Signed authorizations are valid at most this long (≤ 600 s, the default). */
  maxValiditySeconds?: number;
  /** USDG address override (fork or test token); default the pool's usdg(), else mainnet USDG. */
  asset?: string;
  fetchImpl?: typeof fetch;
  /** Per-request timeout in ms (default 60 000; 0 = none). A payer's payments run one at a time. */
  timeoutMs?: number;
  /** Aborts the whole call; once the payment is out an abort is reported as pending, never thrown. */
  signal?: AbortSignal;
  /** Resends of the SAME payment while the merchant answers pending (default 6). */
  pendingRetries?: number;
  /** Longest wait between two resends, in ms (default 30 000). */
  maxSleepMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /** Called with each signed payment before it is sent, so a caller can keep its own record across processes;
   *  awaited. If it throws, the payment is not sent and pay() rejects with NOT_RECORDED. */
  onSigned?: (s: { purchase: string; paymentHeaders: Record<string, string>; validBefore: number; price: bigint; requirement: any; x402Version: number; borrowed?: bigint; loanId?: bigint | null }) => void | Promise<void>;
  /** Called once the price is known when the wallet holds less, before any loan: fund the wallet from the caller's own
   *  money (e.g. `(need) => topUpFromSavings(c, signer, need)` from "@priors/x402/savings"). Its result, or the error
   *  it threw as `{ withdrawn: 0n, error }`, is returned as `savings`; a failure never stops the payment. Also used by
   *  `settleLoans` with what all open loans need. */
  topUp?: (need: bigint) => Promise<SavingsTopUp>;
  /** What the wallet keeps back (e.g. what Autopay loans pull in the next 24 h): a payment that would cut into it is
   *  refused (PayError RESERVE) before anything is signed or borrowed. */
  reserve?: () => bigint | Promise<bigint>;
  /** SeatVaultV5 (address or contract) and its root's agent id: a borrow on a V5 line refreshes it first
   *  (credit v5BeforeBorrow). */
  v5?: string | any | null;
  v5Root?: bigint | number | string | null;
}

/** What a `topUp` did (the shape of topUpFromSavings' result; `error` when it threw). */
export interface SavingsTopUp { withdrawn: bigint; hash?: string | null; short?: bigint; saved?: bigint; inKind?: boolean; error?: unknown }

export interface PayResult {
  response: Response;
  /** Atomic USDG paid (0 unless the paid response is 2xx). */
  paid: bigint;
  /** Atomic USDG borrowed for this purchase (0 if none). */
  borrowed: bigint;
  loanId: bigint | null;
  /** Unix seconds the loan is due: repay (settleLoans) before this. */
  dueAt: bigint | null;
  requirement?: PaymentRequirements | Record<string, unknown>;
  x402Version?: 1 | 2;
  /** Decoded PAYMENT-RESPONSE on success, when the merchant sent one. */
  settlement?: SettleResponse;
  /** true: the payment may still land (a "pending" answer, a timeout, or a lost connection). Resend
   *  `paymentHeaders` later with `resend`; do NOT pay again. */
  pending?: boolean;
  /** No answer within timeoutMs after the payment was sent (a synthetic 504 response). */
  timedOut?: boolean;
  /** The connection failed after the payment was sent (a synthetic 502 response; the error in `error`). */
  transportError?: boolean;
  error?: unknown;
  paymentHeaders?: Record<string, string>;
  /** Once a payment is signed: its headers and validBefore (unix seconds), whatever the outcome. */
  signed?: { paymentHeaders: Record<string, string>; validBefore: number };
  /** true: this payer already had an unsettled payment for the purchase (the method, the URL without its fragment, and
   *  the body: see purchaseKey) and sent that one again instead of signing a second. */
  resent?: boolean;
  /** When `topUp` ran: what it did. */
  savings?: SavingsTopUp;
}

export interface Payer {
  /** fetch-like: pays an x402 USDG 402 (v2 or legacy v1 "robinhood"), borrowing the gap if allowed. */
  pay(input: RequestInfo | URL, init?: RequestInit): Promise<PayResult>;
  /** Resend an already-signed payment (from a pending result); never signs. */
  resend(input: RequestInfo | URL, paymentHeaders: Record<string, string>, init?: RequestInit): Promise<{ response: Response; pending: boolean; timedOut?: boolean; transportError?: boolean; error?: unknown; paymentHeaders?: Record<string, string> }>;
  /** Repay open loans, earliest due first, while the wallet covers them. */
  /** `onlyInWindow`: only loans whose repay window (repayWindow) is open, or past due. */
  settleLoans(o?: { onlyInWindow?: boolean }): Promise<{ repaid: bigint[]; open: bigint[]; waiting?: Array<{ loanId: bigint; opens: number }>; savings?: SavingsTopUp }>;
}

export declare function createPayer(opts: CreatePayerOptions): Payer;

/** An x402Client for USDG on eip155:4663 with a price cap and a ≤600 s signing window (for @x402/fetch, @x402/mcp). */
export declare function createUsdgClient(opts: { signer: any; maxPrice?: UsdgAmount; maxValiditySeconds?: number; asset?: string; x402Signer?: any }): x402Client;

export declare function resend(input: RequestInfo | URL, paymentHeaders: Record<string, string>, opts?: { init?: RequestInit; fetchImpl?: typeof fetch; retries?: number; sleep?: (ms: number) => Promise<void>; maxSleepMs?: number; timeoutMs?: number; signal?: AbortSignal }): Promise<{ response: Response; pending: boolean; timedOut?: boolean; transportError?: boolean; error?: unknown; paymentHeaders?: Record<string, string> }>;
/** A payer's per-request timeout unless `timeoutMs` says otherwise: 60 000 ms. */
export declare const DEFAULT_TIMEOUT_MS: number;
/** Merchant bodies are read at most this far: 256 KB. */
export declare const MAX_BODY_BYTES: number;
/** Seconds an unsettled payment is kept past its validBefore, for a chain clock behind the payer's: 60. */
export declare const SKEW_SECONDS: number;
/** A purchase's identity: "METHOD url" (the URL as the merchant reads it: no fragment, query fields in name order, one
 *  spelling of each escape), plus " body:<sha256>" when there is a body (a JSON body by its value, a urlencoded or
 *  multipart form by its fields, any other body by its bytes). The key `onSigned` receives as `purchase`. */
export declare function purchaseKey(req: Request): Promise<string>;
/** A response body as text, at most `max` bytes (default MAX_BODY_BYTES); the rest is cancelled, not read. `cut` says it was. */
export declare function readCapped(response: Response | null | undefined, max?: number): Promise<{ text: string; cut: boolean }>;

export declare class CappedExactEvmScheme implements SchemeNetworkClient {
  readonly scheme: "exact";
  constructor(signer: any, opts?: { maxValiditySeconds?: number });
  createPaymentPayload(x402Version: number, requirements: PaymentRequirements, context?: PaymentPayloadContext): Promise<PaymentPayloadResult>;
}
export declare function toX402Signer(signer: any, address?: string): { address: `0x${string}`; signTypedData(m: { domain: Record<string, unknown>; types: Record<string, unknown>; primaryType: string; message: Record<string, unknown> }): Promise<`0x${string}`> };
export declare function pickV2Requirement(accepts: unknown, asset?: string): PaymentRequirements | null;
export declare function pickV1Requirement(accepts: unknown, asset?: string): Record<string, any> | null;
export declare function signPaymentV1(signer: any, req: Record<string, any>, opts?: { now?: number; chainId?: number; maxValiditySeconds?: number }): Promise<string>;

export declare class PayError extends Error {
  /** PRICE_ABOVE_MAX_PRICE, PRICE_ABOVE_MAX_BORROW, MIN_LOAN_ABOVE_MAX_BORROW, ABOVE_MAX_LOAN, TERM_OUT_OF_RANGE, FEE_TOO_HIGH, NO_POOL, NO_SIGNER, NO_PROVIDER, BAD_402, NO_USDG_REQUIREMENT, BORROW_WOULD_REVERT, BORROW_UNCONFIRMED, ... */
  code: string;
  /** Set on BORROW_UNCONFIRMED (the amount sent to borrow: it may have opened a loan), and on any error thrown after a loan. */
  borrowed?: bigint;
  loanId?: bigint | null;
  dueAt?: bigint | null;
  /** BORROW_UNCONFIRMED: a borrow was sent and its answer (the broadcast's or the receipt's) was lost; check the agent's loans and repay. */
  unconfirmed?: boolean;
  /** BORROW_UNCONFIRMED: the borrow's transaction hash, when it came back before the answer was lost. */
  hash?: string | null;
  constructor(code: string, message: string, details?: Record<string, unknown>);
}
export declare function settleLoans(o: { signer: any; pool: string | any; agentId: bigint | number | string; topUp?: (need: bigint) => Promise<SavingsTopUp>; onlyInWindow?: boolean; now?: () => number }): Promise<{ repaid: bigint[]; open: bigint[]; waiting?: Array<{ loanId: bigint; opens: number }>; savings?: SavingsTopUp }>;
export { repayWindow, autopayReserve, defaultCap as autopayDefaultCap } from "./autopay.js";

/** A payer's Priors record as the record gate reads it. */
export interface PriorsRecord {
  /** Whether Priors knows this payer at all (an agent it owns, declared, or names). */
  known: boolean;
  agents: number[];
  /** True if any of the payer's agents defaulted on a Priors loan. */
  defaulted: boolean;
  /** The most loans repaid by any of the payer's agents. */
  loansRepaid: number;
  /** Priors Score v2 (api source) or the on-chain score (chain source); null when not published. */
  score: number | null;
}
export interface RecordGateOptions {
  /** "api" (default): https://priors.trade/api/check by the payer's address. "chain": pool v2 over `rpc`, for the agent the payer names in X-Priors-Agent. */
  source?: "api" | "chain";
  checkUrl?: string;
  rpc?: string;
  /** A pool other than the published one (a fork's). */
  pool?: string;
  /** Refuse payers whose agent defaulted. Default true. */
  refuseDefaulted?: boolean;
  /** Repaid loans the payer must have. Default 0. */
  minRepaid?: number;
  minScore?: number | null;
  /** Lower prices for longer records, e.g. [{ minRepaid: 3, price: "$0.01" }]; needs basePrice. */
  tiers?: Array<{ minRepaid: number; price: string }>;
  basePrice?: string | null;
  cacheSeconds?: number;
  fetchImpl?: typeof fetch;
  onDecision?: (d: { payer: string; record: PriorsRecord | null; ok: boolean; reason?: string; message?: string }) => void;
}
export interface RecordGate {
  /** Install on an x402ResourceServer: a payment the policy refuses is never verified or settled. Returns the server. */
  attach<S extends { onBeforeVerify(hook: any): any }>(server: S): S;
  recordOf(address: string, agentId?: number | string | null): Promise<PriorsRecord>;
  /** A dynamic route price from the stated payer's record (X-Payer, plus X-Priors-Agent for the chain source). */
  tierPrice(): (ctx: any) => Promise<string>;
  beforeVerify(ctx: any): Promise<void | { abort: true; reason: string; message?: string }>;
}
/** Check the payer's Priors record before serving: refuse defaulters, ask for a track record, price by record. */
export declare function recordGate(opts?: RecordGateOptions): RecordGate;
/** The address that signed an x402 v2 EVM payment (EIP-3009 or Permit2), or null. */
export declare function payerOf(paymentPayload: any): string | null;
export declare function recordFromCheck(body: any): PriorsRecord;
export declare function judge(record: PriorsRecord, policy?: { refuseDefaulted?: boolean; minRepaid?: number; minScore?: number | null }): { ok: boolean; reason?: string; message?: string };
export declare function priceFor(record: PriorsRecord, base: string, tiers?: Array<{ minRepaid: number; price: string }>): string;
export declare const CHECK_API: string;
