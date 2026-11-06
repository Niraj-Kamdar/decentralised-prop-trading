import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

/** Plain-English explanations for protocol custom errors. */
const FRIENDLY: Record<string, string> = {
  // PositionManager
  BelowMinNotional: "Position is below the minimum size. Increase your margin or leverage.",
  ExposureCapExceeded: "This market is at its open-interest cap right now. Try a smaller size.",
  EntryPriceDeviation: "The pool price is too far from the oracle price. Try again or use a smaller size.",
  UnhealthyAtOpen: "Entry fill was too poor to open safely. Try a smaller size.",
  MinOutBelowOracleBound: "Pool price moved too far from the oracle. Try again in a few seconds.",
  PositionNotOpen: "This position is already closed.",
  NotAuthorized: "Your wallet is not allowed to do this.",
  AssetNotEnabled: "This market is not enabled.",
  RouterNotWhitelisted: "The configured swap router is not whitelisted.",
  InvalidTier: "That leverage tier is disabled.",
  InvalidAmount: "Invalid amount.",
  NothingToClaim: "Nothing to claim.",
  EnforcedPause: "New positions are paused. You can still close existing ones.",
  // OracleVerifier
  StalePrice:
    "The price update went stale before your transaction landed (the oracle only accepts prices up to 5 seconds old). Please try again and confirm quickly.",
  ConfidenceTooWide: "The market is too volatile right now (oracle confidence too wide). Try again shortly.",
  FeedNotEnabled: "No oracle feed for this market.",
  // TraderProxy
  InsufficientOutput: "Swap returned less than the minimum. Increase slippage tolerance or retry.",
  SwapCallFailed: "The Uniswap swap failed (insufficient pool liquidity or price moved).",
  // LPVault
  UtilizationCapExceeded: "The vault has no spare capacity for this position size right now.",
  AllocationBlockedByQueue: "Vault liquidity is reserved for LP withdrawals right now. Try a smaller size.",
  InsufficientLiquidity: "Not enough liquidity in the vault right now.",
  ExceedsClaimable: "Amount exceeds what is claimable.",
  RequestNotPending: "This withdrawal request is no longer pending.",
  NotStressed: "Bonus deposits are only available while the pool is stressed (≥ 80% utilised).",
  BelowMinBonusDeposit: "Amount is below the minimum bonus deposit.",
  TicketNotActive: "This bonus ticket is no longer active.",
  TicketNotMatured: "This bonus ticket has not matured yet.",
  TicketMatured: "This ticket has matured: claim it instead of breaking it.",
  SyncRedeemDisabled: "Withdrawals go through the exit queue.",
  ERC20InsufficientBalance: "Insufficient USDC balance.",
  ERC20InsufficientAllowance: "USDC allowance too low. Approve first.",
};

export function explainError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "Transaction rejected in wallet.";
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && FRIENDLY[name]) return FRIENDLY[name];
    if (name) return `Transaction would fail: ${name}`;
    // Errors nested in raw revert bytes (e.g. SwapCallFailed wrapping a router revert) still name themselves.
    const msg = err.shortMessage || err.message;
    for (const key of Object.keys(FRIENDLY)) if (err.message.includes(key)) return FRIENDLY[key];
    return msg;
  }
  if (err instanceof Error) return err.message;
  return String(err);
}

export const isStalePrice = (err: unknown) => err instanceof Error && /StalePrice/.test(err.message);
