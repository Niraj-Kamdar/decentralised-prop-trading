import { formatUnits, type Address, type PublicClient } from "viem";
import { oracleAbi } from "@/abi";
import { ASSETS, CONTRACTS } from "./config";

export type OraclePrice = {
  /** 10-minute Uniswap v4 TWAP, USD per whole token (what every risk check uses). Null while warming up or stale. */
  twap: number | null;
  twap18: bigint | null;
  /** Current pool price. Display only: the contracts never use it. */
  spot: number | null;
  spot18: bigint | null;
  ready: boolean;
};

/** Reads TWAP + spot for every configured asset in one multicall. */
export async function readOraclePrices(client: PublicClient): Promise<Record<string, OraclePrice>> {
  const o = { address: CONTRACTS.oracle, abi: oracleAbi } as const;
  const calls = ASSETS.flatMap((a) => [
    { ...o, functionName: "getPrice", args: [a.address] } as const,
    { ...o, functionName: "spotPrice", args: [a.address] } as const,
  ]);
  const res = await client.multicall({ contracts: calls, allowFailure: true });
  const out: Record<string, OraclePrice> = {};
  ASSETS.forEach((a, i) => {
    const t = res[2 * i];
    const s = res[2 * i + 1];
    const twap18 = t.status === "success" ? (t.result as bigint) : null;
    const spot18 = s.status === "success" ? (s.result as bigint) : null;
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
