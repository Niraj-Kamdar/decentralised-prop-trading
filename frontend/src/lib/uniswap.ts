import { encodeFunctionData, zeroAddress, type Address, type Hex, type PublicClient } from "viem";
import { CONTRACTS, SWAP_ROUTER_KIND } from "./config";

const swapRouter02Abi = [
  {
    type: "function",
    name: "exactInputSingle",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "recipient", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMinimum", type: "uint256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
] as const;

const swapRouterAbi = [
  {
    type: "function",
    name: "exactInputSingle",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "recipient", type: "address" },
          { name: "deadline", type: "uint256" },
          { name: "amountIn", type: "uint256" },
          { name: "amountOutMinimum", type: "uint256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
] as const;

const quoterV2Abi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "tokenOut", type: "address" },
          { name: "amountIn", type: "uint256" },
          { name: "fee", type: "uint24" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96After", type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

/**
 * Calldata the TraderProxy executes on the router. The proxy approves exactly `amountIn`, so a plain
 * `exactInputSingle` pulling from msg.sender works; the recipient must be the proxy itself, because the proxy
 * measures its own balance delta and a wrong recipient makes the whole transaction revert.
 */
export function encodeExactInputSingle(p: {
  tokenIn: Address;
  tokenOut: Address;
  fee: number;
  recipient: Address;
  amountIn: bigint;
  amountOutMinimum: bigint;
}): Hex {
  if (SWAP_ROUTER_KIND === "router") {
    return encodeFunctionData({
      abi: swapRouterAbi,
      functionName: "exactInputSingle",
      args: [{ ...p, deadline: BigInt(Math.floor(Date.now() / 1000) + 600), sqrtPriceLimitX96: 0n }],
    });
  }
  return encodeFunctionData({
    abi: swapRouter02Abi,
    functionName: "exactInputSingle",
    args: [{ ...p, sqrtPriceLimitX96: 0n }],
  });
}

/** Uniswap QuoterV2 quote via eth_call. Returns null when no quoter is configured or the pool can't fill. */
export async function quoteExactInputSingle(
  client: PublicClient,
  p: { tokenIn: Address; tokenOut: Address; fee: number; amountIn: bigint },
): Promise<bigint | null> {
  if (CONTRACTS.quoter === zeroAddress || p.amountIn === 0n) return null;
  try {
    const { result } = await client.simulateContract({
      address: CONTRACTS.quoter,
      abi: quoterV2Abi,
      functionName: "quoteExactInputSingle",
      args: [{ ...p, sqrtPriceLimitX96: 0n }],
    });
    return result[0];
  } catch {
    return null;
  }
}
