// Types for "@priors/x402/credit": the Priors v2 credit line (pool + lens) on Robinhood Chain.
export { PayError, settleLoans } from "./index.js";

export declare const POOL_ABI: string[];
export declare const LENS_ABI: string[];
export declare const ERC20_ABI: string[];
export declare const LOAN_STATUS: readonly string[];
export declare const STOCK_VAULT_ABI: string[];
/** Why the stock vault holds new loans on a token (index = StockVault.lendStatus; "" for 0). */
export declare const STOCK_HOLDS: readonly string[];

export interface CreditContracts {
  addresses: { pool: string; lens: string; usdg: string; registry: string; stockVault: string | null };
  pool: any;
  lens: any;
  usdg: any;
  registry: any;
  /** The stock vault contract, or null when the addresses give none. */
  stockVault: any | null;
}
export declare function creditContracts(o: { runner: any; addresses?: Partial<CreditContracts["addresses"]> }): CreditContracts;
export declare function poolContract(pool: string | any, runner: any): any;
export declare function explainRevert(err: unknown, iface?: any): string;

export interface LoanView { loanId: bigint; agentId: bigint; sponsorId: bigint; principal: bigint; fee: bigint; due: bigint; issuedAt: number; dueAt: number; defaultableAt: number; status: string }
/** The stock collateral behind a stock line. */
export interface StockCollateral {
  token: string; amount: bigint;
  /** What the vault prices the tokens at, USDG base units; null while it will not price them for new loans. */
  value: bigint | null;
  ltvBps: bigint;
  /** What the line can draw now, USDG base units. */
  borrowRoom: bigint;
  /** 0, or why new loans wait (STOCK_HOLDS). */
  hold: number; holdReason: string; status: string; closing: boolean;
}
export declare function stockCollateral(c: CreditContracts, id: bigint | number | string, sponsor: bigint | number | string): Promise<StockCollateral | null>;
export interface StockPosition extends StockCollateral { agentId: bigint; symbol: string | null; decimals: number | null; line: bigint; depositor: string; openedAt: number }
export declare function stockPosition(c: CreditContracts, id: bigint | number | string, assets?: Array<{ symbol: string; token: string; decimals: number }>): Promise<StockPosition | null>;
export interface StockAssetView { symbol: string; name: string; token: string; answer: bigint | null; price: number | null; updatedAt: number | null; usable: boolean; hold: number | null; holdReason: string; ltvBps: bigint }
export declare function stockAssets(c: CreditContracts, assets: Array<{ symbol: string; name: string; token: string; decimals: number; feed: string; feedDecimals: number }>): Promise<StockAssetView[]>;
export interface CreditStatus {
  agentId: bigint; owner: string | null; enrolled: boolean; isRoot: boolean; defaulted: boolean; frozen: boolean;
  sponsor: bigint; premiumBps: bigint; line: bigint; drawn: bigint;
  /** What can be drawn now: the pool's figure, capped by the stock vault's borrowRoom on a stock line. */
  available: bigint;
  /** The stock tokens behind a stock line; null for any other line. */
  collateral: StockCollateral | null;
  loansRepaid: bigint; qualifiedRepaid: bigint; volumeRepaid: bigint; feesPaid: bigint; enrolledAt: number;
  /** 0..1000 */
  score: number | null;
  openLoans: LoanView[];
}
export declare function creditStatus(c: CreditContracts, agentId: bigint | number | string): Promise<CreditStatus>;
export declare function quoteBorrow(c: CreditContracts, agentId: bigint | number | string, amount: bigint, termSeconds: bigint | number): Promise<{ amount: bigint; term: bigint; fee: bigint; due: bigint }>;
export declare function borrowLine(c: CreditContracts, signer: any, agentId: bigint | number | string, amount: bigint, termSeconds: bigint | number): Promise<{ hash: string; loanId: bigint | null; principal: bigint; fee: bigint; dueAt: number | null }>;
export declare function repayLoan(c: CreditContracts, signer: any, loanId: bigint | number | string): Promise<{ hash: string; loanId: bigint; agentId: bigint; paid: bigint }>;
export declare function balances(c: CreditContracts, provider: any, address: string): Promise<{ address: string; usdg: bigint; native: bigint }>;
export declare function borrowGap(o: { signer: any; pool: any; agentId?: bigint | number | string; price: bigint; balance: bigint; maxBorrow: bigint; termSeconds?: bigint | number; maxFee?: bigint; me?: string }): Promise<{ borrowed: bigint; loanId: bigint | null; dueAt: bigint | null; fee: bigint; term: bigint }>;
