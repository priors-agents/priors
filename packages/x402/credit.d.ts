// Types for "@priors/x402/credit": the Priors v2 credit line (pool + lens) on Robinhood Chain.
export { PayError, settleLoans } from "./index.js";

export declare const POOL_ABI: string[];
export declare const LENS_ABI: string[];
export declare const ERC20_ABI: string[];
export declare const LOAN_STATUS: readonly string[];

export interface CreditContracts {
  addresses: { pool: string; lens: string; usdg: string; registry: string };
  pool: any;
  lens: any;
  usdg: any;
  registry: any;
}
export declare function creditContracts(o: { runner: any; addresses?: Partial<CreditContracts["addresses"]> }): CreditContracts;
export declare function poolContract(pool: string | any, runner: any): any;
export declare function explainRevert(err: unknown, iface?: any): string;

export interface LoanView { loanId: bigint; agentId: bigint; sponsorId: bigint; principal: bigint; fee: bigint; due: bigint; issuedAt: number; dueAt: number; defaultableAt: number; status: string }
export interface CreditStatus {
  agentId: bigint; owner: string | null; enrolled: boolean; isRoot: boolean; defaulted: boolean; frozen: boolean;
  sponsor: bigint; premiumBps: bigint; line: bigint; drawn: bigint; available: bigint;
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
