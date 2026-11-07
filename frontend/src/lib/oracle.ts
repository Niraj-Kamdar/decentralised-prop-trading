import { encodeAbiParameters, formatUnits, keccak256, parseAbi, type Address, type PublicClient } from "viem";
import { oracleAbi } from "@/abi";
import { ASSETS, CONTRACTS } from "./config";
import { poolKeyFor } from "./uniswap";

export type OraclePrice = {
  /** Chainlink price, USD per whole token (what every risk check uses). Null while the feed is stale. */
  twap: number | null;
  twap18: bigint | null;
  /** Current Uniswap v4 pool price. Display only: the contracts never use it. */
  spot: number | null;
  spot18: bigint | null;
  ready: boolean;
};

const POOL_MANAGER: Address = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const extsloadAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);
const POOLS_SLOT = `0x${"6".padStart(64, "0")}` as const;

/** Reads the Chainlink price and the v4 pool price (PoolManager slot0) for every configured asset in one multicall. */
export async function readOraclePrices(client: PublicClient): Promise<Record<string, OraclePrice>> {
  const keys = await Promise.all(ASSETS.map((a) => poolKeyFor(client, a.address)));
  const calls = ASSETS.flatMap((a, i) => {
    const k = keys[i];
    const poolId = keccak256(
      encodeAbiParameters(
        [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
        [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks],
      ),
    );
    const slot = keccak256(`${poolId}${POOLS_SLOT.slice(2)}`);
    return [
      { address: CONTRACTS.oracle, abi: oracleAbi, functionName: "getPrice", args: [a.address] } as const,
      { address: POOL_MANAGER, abi: extsloadAbi, functionName: "extsload", args: [slot] } as const,
    ];
  });
  const res = await client.multicall({ contracts: calls, allowFailure: true });
  const out: Record<string, OraclePrice> = {};
  ASSETS.forEach((a, i) => {
    const t = res[2 * i];
    const s = res[2 * i + 1];
    const twap18 = t.status === "success" ? (t.result as bigint) : null;
    let spot18: bigint | null = null;
    if (s.status === "success") {
      const sqrtP = BigInt(s.result as string) & ((1n << 160n) - 1n);
      if (sqrtP > 0n) {
        // raw = currency1 units per currency0 unit = sqrtP^2 / 2^192; USDC has 6 decimals.
        const scale = 10n ** BigInt(18 + a.decimals - 6);
        const assetIs0 = keys[i].currency0.toLowerCase() === a.address.toLowerCase();
        spot18 = assetIs0 ? (sqrtP * sqrtP * scale) >> 192n : (scale << 192n) / (sqrtP * sqrtP);
      }
    }
    out[a.address.toLowerCase()] = {
      twap18,
      spot18,
      twap: twap18 === null ? null : Number(formatUnits(twap18, 18)),
      spot: spot18 === null ? null : Number(formatUnits(spot18, 18)),
      ready: twap18 !== null,
    };
  });
  return out;
}

export const priceOf = (prices: Record<string, OraclePrice> | undefined, asset: Address) =>
  prices?.[asset.toLowerCase()];
