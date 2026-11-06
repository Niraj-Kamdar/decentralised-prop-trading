import type { PublicClient } from "viem";
import { USDC, type Asset } from "./config";
import { quoteExactIn } from "./uniswap";

const BPS = 10_000n;

/** USDC (6-dec) value of `amount` token units at `price18`, rounded down like UniV4TwapOracle.valueInUsdc. */
export const valueInUsdc = (amount: bigint, price18: bigint, decimals: number) =>
  (amount * price18) / 10n ** BigInt(decimals + 12);

/** Token units bought by `usdc` (6-dec) at `price18`. */
export const tokensForUsdc = (usdc: bigint, price18: bigint, decimals: number) =>
  (usdc * 10n ** BigInt(decimals + 12)) / price18;

/**
 * Open: the PositionManager swaps on the asset's v4 pool itself. We only choose `minAmountOut` from a fresh
 * Quoter quote; the contract additionally rejects a fill worth less than notional * (1 - maxEntrySlippage) at the TWAP.
 */
export async function prepareOpen(
  client: PublicClient,
  p: { asset: Asset; tier: number; margin: bigint; autoRollover: boolean; slippageBps: number; twap18: bigint | null },
) {
  const notional = p.margin * BigInt(p.tier);
  const quote = await quoteExactIn(client, { tokenIn: USDC, tokenOut: p.asset.address, spot: p.asset.address, amountIn: notional });
  const oracleOut = p.twap18 ? tokensForUsdc(notional, p.twap18, p.asset.decimals) : null;
  const expectedOut = quote ?? oracleOut ?? 0n;
  const minAmountOut = (expectedOut * (BPS - BigInt(p.slippageBps))) / BPS;
  return {
    quote,
    expectedOut,
    args: { spotToken: p.asset.address, tier: p.tier, margin: p.margin, autoRollover: p.autoRollover, minAmountOut },
  };
}

/**
 * Exit (close / liquidate / trigger): the contract enforces `max(minAmountOut, mark * (1 - maxSlippage))` with the
 * mark at the TWAP. We pass a quote-based minimum and flag when the pool is below that on-chain floor (the
 * transaction would revert until the pool recovers or the TWAP catches up).
 */
export async function prepareExit(
  client: PublicClient,
  p: { asset: Asset; spotAmount: bigint; slippageBps: number; maxSlippageBps: number; twap18: bigint | null },
) {
  const mark = p.twap18 ? valueInUsdc(p.spotAmount, p.twap18, p.asset.decimals) : null;
  const floor = mark !== null ? (mark * (BPS - BigInt(p.maxSlippageBps))) / BPS : null;
  const quote = await quoteExactIn(client, { tokenIn: p.asset.address, tokenOut: USDC, spot: p.asset.address, amountIn: p.spotAmount });
  const minAmountOut = quote !== null ? (quote * (BPS - BigInt(p.slippageBps))) / BPS : 0n;
  const poolBelowOracle = quote !== null && floor !== null && quote < floor;
  return { mark, floor, quote, poolBelowOracle, minAmountOut };
}
