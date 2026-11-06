import type { Address, Hex, PublicClient } from "viem";
import { oracleAbi, pmAbi } from "@/abi";
import { CONTRACTS, USDC, type Asset } from "./config";
import { fetchPriceUpdate, priceFor } from "./pyth";
import { encodeExactInputSingle, quoteExactInputSingle } from "./uniswap";

const BPS = 10_000n;

/** USDC (6-dec) value of `amount` token units at `price18`, rounded down like OracleVerifier.valueInUsdc. */
export const valueInUsdc = (amount: bigint, price18: bigint, decimals: number) =>
  (amount * price18) / 10n ** BigInt(decimals + 12);

/** Token units bought by `usdc` (6-dec) at `price18`. */
export const tokensForUsdc = (usdc: bigint, price18: bigint, decimals: number) =>
  (usdc * 10n ** BigInt(decimals + 12)) / price18;

/** Pyth fee in 6-dec ERC-20 USDC, rounded up exactly like PositionManager._updateOracle. */
export async function pythFeeUsdc(client: PublicClient, updateData: Hex[]): Promise<bigint> {
  const nativeFee = await client.readContract({
    address: CONTRACTS.oracle,
    abi: oracleAbi,
    functionName: "getUpdateFee",
    args: [updateData],
  });
  return (nativeFee + 10n ** 12n - 1n) / 10n ** 12n;
}

export async function prepareOpen(
  client: PublicClient,
  p: { asset: Asset; tier: number; margin: bigint; autoRollover: boolean; slippageBps: number },
) {
  const { updateData, prices } = await fetchPriceUpdate([p.asset.pythId]);
  const px = priceFor(prices, p.asset.pythId);
  if (!px) throw new Error("No oracle price for this market");

  const [fee, count] = await Promise.all([
    pythFeeUsdc(client, updateData),
    client.readContract({ address: CONTRACTS.positionManager, abi: pmAbi, functionName: "positionCount" }),
  ]);
  // The clone address is deterministic in the position id. If another open lands first the swap pays the
  // wrong proxy, the balance check fails and the whole transaction reverts, so this is safe to retry.
  const proxy = (await client.readContract({
    address: CONTRACTS.positionManager,
    abi: pmAbi,
    functionName: "predictProxyAddress",
    args: [count + 1n],
  })) as Address;

  const notional = p.margin * BigInt(p.tier);
  const quote = await quoteExactInputSingle(client, {
    tokenIn: USDC,
    tokenOut: p.asset.address,
    fee: p.asset.fee,
    amountIn: notional,
  });
  const oracleOut = tokensForUsdc(notional, px.price18, p.asset.decimals);
  const expectedOut = quote ?? oracleOut;
  const minAmountOut = (expectedOut * (BPS - BigInt(p.slippageBps))) / BPS;

  const data = encodeExactInputSingle({
    tokenIn: USDC,
    tokenOut: p.asset.address,
    fee: p.asset.fee,
    recipient: proxy,
    amountIn: notional,
    amountOutMinimum: minAmountOut,
  });

  return {
    fee,
    expectedOut,
    quote,
    oracleOut,
    price: px.price,
    args: {
      spotToken: p.asset.address,
      tier: p.tier,
      margin: p.margin,
      autoRollover: p.autoRollover,
      swap: { router: CONTRACTS.swapRouter, minAmountOut, data },
      priceUpdateData: updateData,
    },
  };
}

/**
 * Builds the exit swap for closePosition / liquidate / executeTrigger. `minAmountOut` must clear the
 * contract's oracle bound (mark * (1 - maxSlippage)), computed from the very price update we submit.
 */
export async function prepareExit(
  client: PublicClient,
  p: { asset: Asset; proxy: Address; spotAmount: bigint; slippageBps: number; maxSlippageBps: number },
) {
  const { updateData, prices } = await fetchPriceUpdate([p.asset.pythId]);
  const px = priceFor(prices, p.asset.pythId);
  if (!px) throw new Error("No oracle price for this market");

  const mark = valueInUsdc(p.spotAmount, px.price18, p.asset.decimals);
  const bound = (mark * (BPS - BigInt(p.maxSlippageBps))) / BPS;
  // A couple of bps above the bound absorbs a slightly newer on-chain price than the one we fetched.
  const floor = bound + (bound * 2n) / BPS;

  const quote = await quoteExactInputSingle(client, {
    tokenIn: p.asset.address,
    tokenOut: USDC,
    fee: p.asset.fee,
    amountIn: p.spotAmount,
  });
  let minAmountOut = quote !== null ? (quote * (BPS - BigInt(p.slippageBps))) / BPS : floor;
  if (minAmountOut < floor) minAmountOut = floor;
  const poolBelowOracle = quote !== null && quote < floor;

  const data = encodeExactInputSingle({
    tokenIn: p.asset.address,
    tokenOut: USDC,
    fee: p.asset.fee,
    recipient: p.proxy,
    amountIn: p.spotAmount,
    amountOutMinimum: minAmountOut,
  });

  const fee = await pythFeeUsdc(client, updateData);
  return {
    fee,
    mark,
    quote,
    poolBelowOracle,
    swap: { router: CONTRACTS.swapRouter, minAmountOut, data },
    priceUpdateData: updateData,
  };
}
