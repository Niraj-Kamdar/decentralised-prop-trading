/**
 * Plain-number mirrors of the PositionManager settlement waterfall, used for previews only.
 * Defaults match the deployed constructor tiers; live values are read from chain when available.
 */
export type TierParams = { maintenanceBps: number; lpProfitBps: number; treasuryProfitBps: number };

export const DEFAULT_TIERS: Record<number, TierParams> = {
  5: { maintenanceBps: 400, lpProfitBps: 800, treasuryProfitBps: 200 },
  10: { maintenanceBps: 200, lpProfitBps: 1200, treasuryProfitBps: 300 },
};

export type Outcome = {
  notional: number;
  borrowed: number;
  valueAfter: number;
  liquidated: boolean;
  traderGets: number;
  traderPnl: number;
  lpEarns: number;
  treasury: number;
  lpShortfall: number;
  /** Price move (fraction, negative) at which the position is liquidated. */
  liqMove: number;
};

/** Settlement of a position after a `move` (0.1 = +10%) in the asset price, ignoring swap slippage. */
export function simulate(
  margin: number,
  tier: number,
  move: number,
  t: TierParams = DEFAULT_TIERS[tier],
  rolloverDebt = 0,
): Outcome {
  const notional = margin * tier;
  const borrowed = notional - margin;
  const threshold = borrowed + rolloverDebt + (notional * t.maintenanceBps) / 10_000;
  const liqMove = threshold / notional - 1;
  const valueAfter = notional * (1 + move);
  const base = { notional, borrowed, valueAfter, liqMove };

  if (valueAfter <= threshold) {
    // Liquidated: LP principal (and rollover) recovered first; any remainder is the penalty to insurance.
    const lpShortfall = Math.max(0, borrowed - valueAfter);
    return {
      ...base,
      liquidated: true,
      traderGets: 0,
      traderPnl: -margin,
      lpEarns: 0,
      treasury: 0,
      lpShortfall,
    };
  }
  let u = valueAfter - borrowed - rolloverDebt;
  const lpRollover = rolloverDebt * 0.8;
  if (u <= margin) {
    return { ...base, liquidated: false, traderGets: u, traderPnl: u - margin, lpEarns: lpRollover, treasury: 0, lpShortfall: 0 };
  }
  const profit = u - margin;
  const lpCut = (profit * t.lpProfitBps) / 10_000;
  const treasury = (profit * t.treasuryProfitBps) / 10_000;
  u -= lpCut + treasury;
  return {
    ...base,
    liquidated: false,
    traderGets: u,
    traderPnl: u - margin,
    lpEarns: lpCut + lpRollover,
    treasury,
    lpShortfall: 0,
  };
}

/** Rollover fee for one 7-day epoch at `aprBps` on `borrowed` USDC. The first epoch is free. */
export const epochFee = (borrowed: number, aprBps: number) => (borrowed * aprBps * 7) / (10_000 * 365);
