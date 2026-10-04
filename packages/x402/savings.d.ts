// Types for "@priors/x402/savings": an agent's spare USDG kept in a Morpho vault (Morpho Vault V2, ERC-4626) on
// Robinhood Chain. Amounts are USDG base units (6 decimals).
export declare const DEFAULT_SAVINGS_VAULT: string;
export declare const VAULT_ABI: string[];
export type SavingsErrorCode = "BAD_VAULT" | "NOT_USDG" | "ZERO" | "SHORT" | "NOTHING_SAVED" | "MORE_THAN_SAVED" | "VAULT_ILLIQUID" | "EXIT_FAILED" | "DEPOSITS_CLOSED" | "VAULT_FULL" | "EXIT_BLOCKED" | "NO_GAS" | "REVERTED" | "UNCONFIRMED";
export declare class SavingsError extends Error {
  code: SavingsErrorCode;
  /** SHORT: the wallet's balance. */ balance?: bigint;
  /** MORE_THAN_SAVED / VAULT_ILLIQUID: what is saved. */ saved?: bigint;
  /** VAULT_ILLIQUID / EXIT_FAILED: what a plain withdrawal pays now, and with in-kind exits too. */ withdrawable?: bigint; reachable?: bigint;
  /** REVERTED (on chain) / UNCONFIRMED: the transaction that was sent. */ hash?: string;
  /** save: whether the approval was put back after the deposit was refused. */ allowanceReset?: boolean;
  constructor(code: string, message: string, details?: Record<string, unknown>);
}
export interface SavingsContracts { vault: any; usdg: any; address: string; provider: any }
/** Checks there is a contract at `vault` and its asset is USDG. An RPC failure is thrown as is (not as BAD_VAULT). */
export declare function savingsContracts(o: { runner: any; vault?: string; usdg?: string }): Promise<SavingsContracts>;
export interface Savings {
  owner: string; vault: string; shares: bigint;
  /** What the shares are worth now (rounded down). */ saved: bigint;
  /** What a plain withdrawal pays now (idle, then the liquidity market), to within 0.01 USDG. */ withdrawable: bigint;
  /** With in-kind exits from penalty-free markets too; at most `saved`. */ reachable: bigint;
  wallet: bigint;
}
export declare function savingsOf(c: SavingsContracts, owner: string): Promise<Savings>;
export declare function withdrawableNow(c: SavingsContracts, owner: string, saved: bigint): Promise<bigint>;
export interface InKindSource { adapter: string; data: string; available: bigint; penalty: bigint }
export declare function inKindSources(c: SavingsContracts): Promise<InKindSource[]>;
/** `signal` stops the call before it sends a transaction; `sent` is set to the hash once one is sent. */
export interface SendOptions { signal?: AbortSignal; sent?: string }
export declare function save(c: SavingsContracts, signer: any, amount: bigint | number | string, o?: SendOptions): Promise<{ hash: string; amount: bigint }>;
export declare function unsave(c: SavingsContracts, signer: any, what: { amount?: bigint | number | string; all?: boolean }, o?: SendOptions): Promise<{ hash: string; amount: bigint; inKind: boolean }>;
/** Take out of savings what the wallet is short of `need`, as much as the vault can pay. */
export declare function topUpFromSavings(c: SavingsContracts, signer: any, need: bigint | number | string, o?: SendOptions): Promise<{ withdrawn: bigint; hash: string | null; short: bigint; saved: bigint; inKind: boolean }>;
