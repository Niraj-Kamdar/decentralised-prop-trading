import { formatUnits } from "viem";
import type { Position } from "@/hooks/usePositions";
import type { TierParams } from "./math";
import { toUsdc } from "./format";
import { valueInUsdc } from "./trade";

export type PositionView = {
  tokens: number;
  entryPrice: number;
  markPrice: number | null;
  markValue: number | null;
  liqPrice: number | null;
  rolloverDebt: number;
  /** Estimated USDC returned to the trader if closed at the oracle price (no slippage). */
  receive: number | null;
  pnl: number | null;
  pnlPct: number | null;
  health: number | null; // 0..1, 0 = at liquidation
};

export function positionView(pos: Position, decimals: number, price18: bigint | undefined, t: TierParams): PositionView {
  const tokens = Number(formatUnits(pos.spotAmount, decimals));
  const notional = toUsdc(pos.notional);
  const margin = toUsdc(pos.userMargin);
  const borrowed = toUsdc(pos.borrowedPrincipal);
  const entryPrice = tokens > 0 ? notional / tokens : 0;
  const maintenance = (notional * t.maintenanceBps) / 10_000;
  const threshold = pos.liqThreshold > 0n ? toUsdc(pos.liqThreshold) : borrowed + toUsdc(pos.accruedRolloverDebt) + maintenance;
  // liquidationThreshold() already includes epochs that are due but not yet processed.
  const rolloverDebt = Math.max(0, threshold - borrowed - maintenance);
  const liqPrice = tokens > 0 ? threshold / tokens : null;

  if (price18 === undefined || pos.status !== "OPEN") {
    return { tokens, entryPrice, markPrice: null, markValue: null, liqPrice, rolloverDebt, receive: null, pnl: null, pnlPct: null, health: null };
  }
  const markPrice = Number(formatUnits(price18, 18));
  const markValue = toUsdc(valueInUsdc(pos.spotAmount, price18, decimals));

  let receive: number;
  if (markValue <= threshold) receive = 0;
  else {
    const u = markValue - borrowed - rolloverDebt;
    if (u <= margin) receive = u;
    else {
      const profit = u - margin;
      receive = u - (profit * (t.lpProfitBps + t.treasuryProfitBps)) / 10_000;
    }
  }
  const pnl = receive - margin;
  const health = notional > threshold ? Math.max(0, Math.min(1, (markValue - threshold) / (notional - threshold))) : null;
  return { tokens, entryPrice, markPrice, markValue, liqPrice, rolloverDebt, receive, pnl, pnlPct: margin > 0 ? pnl / margin : null, health };
}
