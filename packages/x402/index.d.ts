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
  /** Resends of the SAME payment while the merchant answers pending (default 6). */
  pendingRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

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
  /** true: the payment may still land. Resend `paymentHeaders` later with `resend`; do NOT pay again. */
  pending?: boolean;
  paymentHeaders?: Record<string, string>;
}

export interface Payer {
  /** fetch-like: pays an x402 USDG 402 (v2 or legacy v1 "robinhood"), borrowing the gap if allowed. */
  pay(input: RequestInfo | URL, init?: RequestInit): Promise<PayResult>;
  /** Resend an already-signed payment (from a pending result); never signs. */
  resend(input: RequestInfo | URL, paymentHeaders: Record<string, string>, init?: RequestInit): Promise<{ response: Response; pending: boolean; paymentHeaders?: Record<string, string> }>;
  /** Repay open loans, earliest due first, while the wallet covers them. */
  settleLoans(): Promise<{ repaid: bigint[]; open: bigint[] }>;
}

export declare function createPayer(opts: CreatePayerOptions): Payer;

/** An x402Client for USDG on eip155:4663 with a price cap and a ≤600 s signing window (for @x402/fetch, @x402/mcp). */
export declare function createUsdgClient(opts: { signer: any; maxPrice?: UsdgAmount; maxValiditySeconds?: number; asset?: string; x402Signer?: any }): x402Client;

export declare function resend(input: RequestInfo | URL, paymentHeaders: Record<string, string>, opts?: { init?: RequestInit; fetchImpl?: typeof fetch; retries?: number; sleep?: (ms: number) => Promise<void> }): Promise<{ response: Response; pending: boolean; paymentHeaders?: Record<string, string> }>;

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
  /** PRICE_ABOVE_MAX_PRICE, PRICE_ABOVE_MAX_BORROW, MIN_LOAN_ABOVE_MAX_BORROW, ABOVE_MAX_LOAN, TERM_OUT_OF_RANGE, FEE_TOO_HIGH, NO_POOL, NO_SIGNER, NO_PROVIDER, BAD_402, NO_USDG_REQUIREMENT, BORROW_WOULD_REVERT, ... */
  code: string;
  constructor(code: string, message: string, details?: Record<string, unknown>);
}
export declare function settleLoans(o: { signer: any; pool: string | any; agentId: bigint | number | string }): Promise<{ repaid: bigint[]; open: bigint[] }>;
