// Types for "@priors/x402/bridge": the Base float. Robinhood Chain USDG to Base USDC through Across (fundBase), and Base
// USDC back to Robinhood Chain USDG through Relay's gasless route (returnToRobinhood). Amounts are atomic units of the
// 6-decimal dollar tokens. Every host, contract and token is pinned (networks.mjs: ACROSS, RELAY, NETWORKS).
export { PayError } from "./index.js";

/** Codes the bridge throws (PayError), besides the payer's own. `moved` on the error says whether money left the wallet. */
export type BridgeErrorCode =
  | "BAD_AMOUNT" | "NO_PROVIDER" | "BAD_HASH" | "BAD_REQUEST_ID" | "BAD_SIGNATURE"
  /** Across: nothing was sent. */
  | "BRIDGE_QUOTE_FAILED" | "BRIDGE_QUOTE_REFUSED" | "BRIDGE_FEE_TOO_HIGH" | "INSUFFICIENT_USDG" | "BRIDGE_WOULD_REVERT" | "BRIDGE_REVERTED" | "NO_GAS" | "NOT_RECORDED"
  /** Across: the deposit may be out; never send it again. */
  | "DEPOSIT_UNCONFIRMED" | "BRIDGE_PENDING" | "BRIDGE_REFUNDED"
  /** Relay: nothing was signed, or nothing left. */
  | "RELAY_QUOTE_FAILED" | "RELAY_QUOTE_REFUSED" | "INSUFFICIENT_USDC"
  /** Relay: the authorization is out; never sign another before it expires. */
  | "RELAY_SUBMIT_UNCONFIRMED" | "RETURN_PENDING" | "RETURN_FAILED";

export declare const ACROSS_SPOKE_ABI: string[];
export declare const RECEIVE_WITH_AUTHORIZATION_TYPES: { readonly ReceiveWithAuthorization: ReadonlyArray<{ readonly name: string; readonly type: string }> };
/** 100: a fee above 1% of the amount is refused unless the caller says otherwise. */
export declare const DEFAULT_MAX_FEE_BPS: number;
/** 3000 s: an Across quote older than this is refused (the spoke takes one up to 3600 s old). */
export declare const ACROSS_MAX_QUOTE_AGE_S: number;
/** 600 s: an Across fill deadline closer than this is refused. */
export declare const ACROSS_MIN_FILL_WINDOW_S: number;
/** 600 s: the longest exclusivity an Across quote may give one relayer. */
export declare const ACROSS_MAX_EXCLUSIVITY_S: number;
/** 50: the slippage asked of Relay (bps). */
export declare const RELAY_SLIPPAGE_BPS: number;
/** 200: a Relay quote whose minimum out sits further under its expected out is refused (bps). */
export declare const RELAY_MAX_SLIPPAGE_BPS: number;

export interface AcrossQuote {
  readonly route: "across"; readonly amount: bigint; readonly outputAmount: bigint; readonly fee: bigint; readonly feeBps: number;
  readonly timestamp: number; readonly fillDeadline: number; readonly exclusiveRelayer: string; readonly exclusivityDeadline: number;
  readonly spoke: string; readonly estimatedFillTimeSec: number | null;
}
/** Check an Across /api/suggested-fees answer (pure): pinned tokens, chains and spokes by full address, not too low,
 *  above the minimum deposit, fresh for the spoke, a sane fill deadline and exclusivity, the fee within maxFeeBps. */
export declare function checkAcrossQuote(q: unknown, o: { amount: bigint; maxFeeBps?: number; now?: number }): AcrossQuote;
export declare function acrossQuote(o: { amount: bigint; maxFeeBps?: number; fetchImpl?: typeof fetch; now?: () => number; timeoutMs?: number }): Promise<AcrossQuote>;
/** Across's view of a deposit by its transaction hash: pending (incl. not indexed yet), filled, expired, refunded or unknown. */
export declare function depositStatus(o: { hash: string; fetchImpl?: typeof fetch; timeoutMs?: number }): Promise<{ status: "pending" | "filled" | "expired" | "refunded" | "unknown"; fillTx: string | null; refundTx: string | null }>;

/** What fundBase hands its hooks before (and once the hash is known, after) the deposit is broadcast. */
export interface BridgeTransfer { route: "across"; from: string; amount: bigint; outputAmount: bigint; fee: bigint; quoteTimestamp: number; fillDeadline: number; startedAt: number; hash?: string }
export interface FundBaseResult {
  route: "across"; hash: string; approveHash: string | null; depositId: bigint | null; amount: bigint; outputAmount: bigint; fee: bigint; feeBps: number; fillDeadline: number;
  filled: true; fillTx: string | null;
  /** The FundsDeposited event was not found in the receipt. */
  noEvent?: true;
  /** Event fields that differ from what was asked. */
  mismatch?: string[];
}
/** Robinhood Chain USDG to the same address's USDC on Base, through Across. Needs ETH for gas on Robinhood Chain. */
export declare function fundBase(o: {
  signer: any; amount: bigint; maxFeeBps?: number; fetchImpl?: typeof fetch; now?: () => number;
  /** Longest wait for the fill after the broadcast (default 30 000 ms). */
  timeoutMs?: number;
  /** Stop waiting at this epoch ms, if sooner. */
  pollUntil?: number;
  pollMs?: number; sleep?: (ms: number) => Promise<void>;
  /** Awaited right before the broadcast; if it throws, nothing is sent (NOT_RECORDED). */
  onDepositSending?: (t: BridgeTransfer) => void | Promise<void>;
  /** Once the hash is known (best effort). */
  onDepositSent?: (t: BridgeTransfer & { hash: string }) => void | Promise<void>;
}): Promise<FundBaseResult>;

export interface RelayReturnPlan {
  requestId: string;
  domain: { name: "USD Coin"; version: "2"; chainId: 8453; verifyingContract: string };
  types: { ReceiveWithAuthorization: Array<{ name: string; type: string }> };
  primaryType: "ReceiveWithAuthorization";
  /** Rebuilt from the checked fields, never the quote's own object. */
  message: { from: string; to: string; value: bigint; validAfter: bigint; validBefore: bigint; nonce: string };
  submit: { endpoint: "/execute/permits"; body: { kind: "eip3009"; requestId: string; api: "swap" } };
  amount: bigint; expectedOut: bigint; minimumOut: bigint; fee: bigint; feeBps: number; nonce: string; validBefore: number;
}
export declare function relayQuote(o: { me: string; amount: bigint; fetchImpl?: typeof fetch; timeoutMs?: number }): Promise<unknown>;
/** Check a Relay /quote answer field by field (pure) and rebuild the one ReceiveWithAuthorization to sign. */
export declare function checkRelayReturn(quote: unknown, o: { me: string; amount: bigint; now?: number; maxFeeBps?: number }): RelayReturnPlan;
/** UNVERIFIED against the live API: POST /execute/permits?signature=… with the checked body (Relay's SDK's shape). */
export declare function submitRelayPermit(o: { plan: RelayReturnPlan; signature: string; fetchImpl?: typeof fetch; timeoutMs?: number }): Promise<{ status: number }>;
export declare function relayStatus(o: { requestId: string; fetchImpl?: typeof fetch; timeoutMs?: number }): Promise<{ status: "success" | "failure" | "refund" | "pending"; txHashes: string[] }>;
/** USDC's authorizationState(from, nonce) on Base: whether a return's authorization was spent. */
export declare function authorizationUsed(o: { baseProvider: any; from: string; nonce: string }): Promise<boolean>;
export interface ReturnTransfer { route: "relay"; from: string; amount: bigint; expectedOut: bigint; fee: bigint; requestId: string; nonce: string; validBefore: number; startedAt: number }
/** Base USDC back to the same address's USDG on Robinhood Chain, through Relay's gasless route: one checked signature. */
export declare function returnToRobinhood(o: {
  signer: any; amount: bigint; maxFeeBps?: number; fetchImpl?: typeof fetch; now?: () => number; baseProvider?: any;
  timeoutMs?: number; pollUntil?: number; pollMs?: number; sleep?: (ms: number) => Promise<void>;
  /** Awaited after signing and before the authorization leaves; if it throws, it never leaves (NOT_RECORDED). */
  onSigned?: (t: ReturnTransfer) => void | Promise<void>;
}): Promise<ReturnTransfer & { delivered: true; txHashes: string[] }>;
