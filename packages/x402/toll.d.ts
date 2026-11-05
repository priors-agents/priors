// Types for "@priors/x402/toll": Toll's free payee check as a createPayer `beforePay`.
import type { BeforePayInput } from "./index.js";

export declare const TOLL_CHECK_URL: string;
export declare const TOLL_TIMEOUT_MS: number;

export interface TollCheckOptions {
  /** Toll's check endpoint (default https://t0ll.xyz/api/tx/check). */
  url?: string;
  /** Actions that refuse the payment (default ["BLOCK"]; add "WARN" for a strict agent). */
  refuse?: Array<"BLOCK" | "WARN">;
  /** The seller's ERC-8004 agent id, when the 402 does not name it. */
  agentId?: number | bigint | string;
  /** How long Toll may take (default 8000 ms). */
  timeoutMs?: number;
  /** Pay when Toll cannot answer (default false: PayError TOLL_UNREAD). */
  failOpen?: boolean;
  fetchImpl?: typeof fetch;
  /** Called with every answer read, before it is acted on. */
  onResult?: (r: TollResult) => void | Promise<void>;
}

export interface TollResult {
  action: "ALLOW" | "WARN" | "BLOCK";
  /** Toll's warning codes, e.g. "x402-payee-mismatch". */
  codes: string[];
  /** Where to read more on t0ll.xyz, or null. */
  link: string | null;
}

/** A createPayer `beforePay` that refuses what Toll says to refuse: PayError TOLL_REFUSED (or TOLL_UNREAD). */
export declare function tollCheck(o?: TollCheckOptions): (payment: BeforePayInput) => Promise<void>;
