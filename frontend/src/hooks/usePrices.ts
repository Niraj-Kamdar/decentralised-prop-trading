"use client";

import { useQuery } from "@tanstack/react-query";
import { ASSETS } from "@/lib/config";
import { fetchPriceUpdate, priceFor, type PythPrice } from "@/lib/pyth";
import type { Hex } from "viem";

/** Live Pyth prices for every configured asset, polled from Hermes. */
export function usePrices(intervalMs = 3000) {
  const q = useQuery({
    queryKey: ["pyth-prices"],
    queryFn: async () => (await fetchPriceUpdate(ASSETS.map((a) => a.pythId))).prices,
    refetchInterval: intervalMs,
    staleTime: intervalMs,
  });
  return {
    prices: q.data,
    get: (id: Hex): PythPrice | undefined => priceFor(q.data, id),
    error: q.error,
  };
}
