import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

/** Plain-English explanations for protocol custom errors. */
const FRIENDLY: Record<string, string> = {
  // PositionManager
  BelowMinNotional: "Position is below the minimum size. Increase your margin or leverage.",
  ExposureCapExceeded: "This market is at its open-interest cap right now. Try a smaller size.",
  EntryPriceDeviation: "The pool would fill too far from the 10-minute average price. Try a smaller size or wait for the pool to settle.",
  UnhealthyAtOpen: "Entry fill was too poor to open safely. Try a smaller size.",
  PositionNotOpen: "This position is already closed.",
  NotAuthorized: "Your wallet is not allowed to do this.",
  AssetNotEnabled: "This market is not enabled.",
  RouterNotWhitelisted: "The swap router is not whitelisted.",
  SwapRouterNotSet: "Trading is not configured yet (no swap router).",
  InvalidTier: "That leverage tier is disabled.",
  InvalidAmount: "Invalid amount.",
  NothingToClaim: "Nothing to claim.",
  EnforcedPause: "New positions are paused. You can still close existing ones.",
  // UniV4TwapOracle
  TwapNotReady: "The price oracle is still collecting its 10 minutes of pool history. Try again shortly.",
  TwapStale: "The price oracle has not been updated recently (keeper offline). Try again shortly.",
  FeedNotEnabled: "No oracle feed for this market.",
  // TraderProxy
  InsufficientOutput:
    "The Uniswap pool would pay less than allowed (your slippage limit, or the protocol's floor at the 10-minute average price). Retry, raise slippage, or wait for the pool to recover.",
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

export const isOracleNotReady = (err: unknown) => err instanceof Error && /TwapNotReady|TwapStale/.test(err.message);
