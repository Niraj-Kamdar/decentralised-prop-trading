"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { pmAbi } from "@/abi";
import { CONTRACTS, PROTOCOL_CONFIGURED } from "@/lib/config";

export const STATUS = ["NONE", "OPEN", "CLOSED", "LIQUIDATED"] as const;

export type Position = {
  id: bigint;
  trader: Address;
  proxy: Address;
  spotToken: Address;
  tier: number;
  autoRollover: boolean;
  status: (typeof STATUS)[number];
  notional: bigint;
  userMargin: bigint;
  borrowedPrincipal: bigint;
  accruedRolloverDebt: bigint;
  spotAmount: bigint;
  openedAt: number;
  epochEndTime: number;
  stopLossPrice: bigint;
  takeProfitPrice: bigint;
  trailingStopPrice: bigint;
  /** Liquidation threshold in USDC including epochs due but not yet processed (open positions only). */
  liqThreshold: bigint;
};

/** How many of the most recent positions to scan. PositionManager has no per-trader index. */
const SCAN_LIMIT = 2000n;

/**
 * Loads the connected trader's positions by scanning recent ids via Multicall3.
 * Fine at MVP scale; swap for an indexer (events: PositionOpened by trader) once volume grows.
 */
export function usePositions() {
  const client = usePublicClient();
  const { address } = useAccount();
  return useQuery({
    queryKey: ["positions", address],
    enabled: PROTOCOL_CONFIGURED && !!client && !!address,
    refetchInterval: 10_000,
    queryFn: async (): Promise<Position[]> => {
      const pm = { address: CONTRACTS.positionManager, abi: pmAbi } as const;
      const count = await client!.readContract({ ...pm, functionName: "positionCount" });
      const start = count > SCAN_LIMIT ? count - SCAN_LIMIT + 1n : 1n;
      const ids: bigint[] = [];
      for (let i = start; i <= count; i++) ids.push(i);
      if (ids.length === 0) return [];

      const raw = await client!.multicall({
        contracts: ids.map((id) => ({ ...pm, functionName: "getPosition", args: [id] }) as const),
        allowFailure: false,
      });
      const mine = raw
        .map((p, i) => ({ p, id: ids[i] }))
        .filter(({ p }) => p.trader.toLowerCase() === address!.toLowerCase());

      const open = mine.filter(({ p }) => p.status === 1);
      const thresholds = open.length
        ? await client!.multicall({
            contracts: open.map(({ id }) => ({ ...pm, functionName: "liquidationThreshold", args: [id] }) as const),
            allowFailure: false,
          })
        : [];
      const thMap = new Map(open.map(({ id }, i) => [id, thresholds[i] as bigint]));

      return mine
        .map(({ p, id }) => ({
          id,
          trader: p.trader,
          proxy: p.proxy,
          spotToken: p.spotToken,
          tier: p.tier,
          autoRollover: p.autoRollover,
          status: STATUS[p.status],
          notional: p.notional,
          userMargin: p.userMargin,
          borrowedPrincipal: p.borrowedPrincipal,
          accruedRolloverDebt: p.accruedRolloverDebt,
          spotAmount: p.spotAmount,
          openedAt: Number(p.openedAt),
          epochEndTime: Number(p.epochEndTime),
          stopLossPrice: p.stopLossPrice,
          takeProfitPrice: p.takeProfitPrice,
          trailingStopPrice: p.trailingStopPrice,
          liqThreshold: thMap.get(id) ?? 0n,
        }))
        .reverse();
    },
  });
}

export function useClaimable() {
  const client = usePublicClient();
  const { address } = useAccount();
  return useQuery({
    queryKey: ["claimable", address],
    enabled: PROTOCOL_CONFIGURED && !!client && !!address,
    refetchInterval: 15_000,
    queryFn: () =>
      client!.readContract({
        address: CONTRACTS.positionManager,
        abi: pmAbi,
        functionName: "claimableUSDC",
        args: [address!],
      }),
  });
}
