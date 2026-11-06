"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { usePublicClient } from "wagmi";
import { PROTOCOL_CONFIGURED } from "@/lib/config";
import { priceOf, readOraclePrices, type OraclePrice } from "@/lib/oracle";

/** Live on-chain prices (Uniswap v4 TWAP and spot) for every market, polled from the oracle contract. */
export function usePrices(intervalMs = 4000) {
  const client = usePublicClient();
  const q = useQuery({
    queryKey: ["oracle-prices"],
    enabled: !!client && PROTOCOL_CONFIGURED,
    queryFn: () => readOraclePrices(client!),
    refetchInterval: intervalMs,
    staleTime: intervalMs,
  });
  return {
    prices: q.data,
    get: (asset: Address): OraclePrice | undefined => priceOf(q.data, asset),
    error: q.error,
  };
}
