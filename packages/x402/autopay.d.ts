// Types for "@priors/x402/autopay": Autopay from the agent's own wallet through AutoRepay v2.
export declare const AUTOREPAY_ABI: string[];
/** AutoRepayV2.Status, in order: "ready", "not active", "paused", "too early", "no plan", "short", "registry down". */
export declare const AUTOPAY_STATUS: readonly string[];
export declare const AUTOPAY_WINDOW: { readonly window: number; readonly minWindow: number; readonly season: number; readonly minAge: number };
/** The AutoRepay version this package runs with (2); autopayOn refuses another (PayError AUTOREPAY_V1). */
export declare const AUTOREPAY_VERSION: number;
/** The most this package version enrolls per loan by default (stage 0: 25 USDG). */
export declare const AUTOPAY_STAGE_CAP: bigint;
export declare const BUDGET_LOANS: bigint;
export declare const RESERVE_SECONDS: number;

/** When a loan's repay window opens (AutoRepay.opensAt), seconds. */
export declare function repayWindow(issuedAt: number | bigint, dueAt: number | bigint, w?: { window: number; minWindow: number; season: number; minAge?: number }): { opens: number; dueAt: number };

export interface AutopayContracts { address: string; autoRepay: any; registry: any; usdg: any; vault: any | null; pool: any }
export declare function autopayContracts(o: { runner: any; address: string; registry: string; usdg: string; savingsVault?: string | null; pool: string }): AutopayContracts;

export interface AutopayLoan {
  loanId: bigint; due: bigint; issuedAt: number; dueAt: number; defaultableAt: number; owner: string;
  status: string | null; opens: number; closes: number | null; fromWallet: bigint; fromWalletSavings: bigint;
}
export interface AutopayStatus {
  declared: boolean; owner: string;
  /** `stale`: on, but set before the agent's owner or wallet changed (enroll again); `current` excludes it. */
  plan: { on: boolean; cap: bigint; owner: string; useSavings: boolean; late: boolean; epoch: number; current: boolean; stale: boolean };
  held: boolean; paused: { until: number } | null;
  allowance: { usdg: bigint; shares: bigint }; balance: bigint; budget: bigint;
  loans: AutopayLoan[]; next: AutopayLoan | null;
  short: { loanId: bigint; need: bigint; have: bigint; overCap: boolean } | null;
}
export declare function autopayStatus(c: AutopayContracts, wallet: string, agentId: bigint | number | string, o?: { now?: number }): Promise<AutopayStatus>;
/** What the wallet keeps back for Autopay loans whose window opens within `horizon` seconds (24 h). */
export declare function autopayReserve(status: AutopayStatus | null, now?: number, horizon?: number): bigint;
/** The line plus a 30-day fee, rounded up to the dollar, at most `ceiling`. */
export declare function defaultCap(line: bigint | number | string, ceiling?: bigint): bigint;
export declare function autopayOn(c: AutopayContracts, signer: any, agentId: bigint | number | string, o: { cap: bigint | number | string; useSavings?: boolean; late?: boolean; budget?: bigint | number | string; ceiling?: bigint }): Promise<{ hashes: string[]; cap: bigint; budget: bigint }>;
export declare function autopayOff(c: AutopayContracts, signer: any, agentId: bigint | number | string, o?: { clearBudget?: boolean }): Promise<{ hashes: string[] }>;
