import { zeroAddress, type Address, type PublicClient } from "viem";
import { oracleAbi } from "@/abi";
import { CONTRACTS } from "./config";

/** Uniswap v4 V4Quoter.quoteExactInputSingle. */
const v4QuoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {
            name: "poolKey",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "exactAmount", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
const keyCache = new Map<string, PoolKey>();

/** The v4 pool the protocol trades `asset` on (read from the oracle, which prices on the same pool). */
export async function poolKeyFor(client: PublicClient, asset: Address): Promise<PoolKey> {
  const k = asset.toLowerCase();
  const hit = keyCache.get(k);
  if (hit) return hit;
  const key = (await client.readContract({
    address: CONTRACTS.oracle,
    abi: oracleAbi,
    functionName: "poolKey",
    args: [asset],
  })) as PoolKey;
  keyCache.set(k, key);
  return key;
}

/**
 * Exact-input quote on the asset's v4 pool via the Uniswap V4Quoter (eth_call). Returns null when no quoter is
 * configured or the pool cannot fill. Fees (LP + protocol) and price impact are included.
 */
export async function quoteExactIn(
  client: PublicClient,
  p: { tokenIn: Address; tokenOut: Address; spot: Address; amountIn: bigint },
): Promise<bigint | null> {
  if (CONTRACTS.quoter === zeroAddress || p.amountIn === 0n) return null;
  try {
    const poolKey = await poolKeyFor(client, p.spot);
    const { result } = await client.simulateContract({
      address: CONTRACTS.quoter,
      abi: v4QuoterAbi,
      functionName: "quoteExactInputSingle",
      args: [{ poolKey, zeroForOne: poolKey.currency0.toLowerCase() === p.tokenIn.toLowerCase(), exactAmount: p.amountIn, hookData: "0x" }],
    });
    return result[0];
  } catch {
    return null;
  }
}
