"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { insuranceAbi, pmAbi, vaultAbi } from "@/abi";
import { ASSETS, CONTRACTS, PROTOCOL_CONFIGURED, TIERS } from "@/lib/config";
import { DEFAULT_TIERS, type TierParams } from "@/lib/math";
import { zeroAddress } from "viem";

export type Level = {
  enabled: boolean;
  maxLeverage: number;
  maxMargin: bigint;
  lpProfitBps: number;
  treasuryProfitBps: number;
  promoteMinTrades: number;
  promoteMinPnl: bigint;
  demoteMaxLoss: bigint;
};
export const LEVEL_NAMES = ["Starter", "Trader", "Pro"] as const;

export type ProtocolState = {
  vault: {
    totalAssets: bigint;
    totalSupply: bigint;
    totalBorrowed: bigint;
    utilizationBps: number;
    maxUtilizationBps: number;
    stressUtilizationBps: number;
    isStressed: boolean;
    freeLiquidity: bigint;
    pendingRedeemAssets: bigint;
    fulfilmentBudget: bigint;
    bonusPot: bigint;
    redeemCooldown: number;
    exitPenaltyBps: number;
    bonusDuration: number;
    maxBonusAprBps: number;
    minBonusDeposit: bigint;
    queueLength: bigint;
    queueHead: bigint;
    /** USDC value of 1 USDC worth of shares at 1:1 issuance (share price), 1e6 = $1.00 */
    sharePrice: bigint;
  };
  pm: {
    paused: boolean;
    minNotional: bigint;
    keeperBounty: bigint;
    rolloverAprBps: number;
    maxEntrySlippageBps: number;
    maxExitSlippageBps: number;
    positionCount: bigint;
    openPositionCount: bigint;
    tiers: Record<number, { enabled: boolean; maintenanceBps: number }>;
    levels: Level[];
    assets: Record<string, { enabled: boolean; maxExposureBps: number; exposure: bigint }>;
  };
  insurance: bigint;
};

/** Max new borrow allowed right now: utilisation cap headroom vs. liquidity not reserved for LP exits. */
export function borrowCapacity(s: ProtocolState): bigint {
  const v = s.vault;
  const cap = (v.totalAssets * BigInt(v.maxUtilizationBps)) / 10_000n;
  const utilHeadroom = cap > v.totalBorrowed ? cap - v.totalBorrowed : 0n;
  const allocatable = v.freeLiquidity > v.pendingRedeemAssets ? v.freeLiquidity - v.pendingRedeemAssets : 0n;
  return utilHeadroom < allocatable ? utilHeadroom : allocatable;
}

/** Max notional that can still be opened on `asset` before its open-interest cap. */
export function exposureHeadroom(s: ProtocolState, asset: string): bigint {
  const a = s.pm.assets[asset.toLowerCase()];
  if (!a) return 0n;
  const cap = (s.vault.totalAssets * BigInt(a.maxExposureBps)) / 10_000n;
  return cap > a.exposure ? cap - a.exposure : 0n;
}

export function useProtocol() {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["protocol"],
    enabled: PROTOCOL_CONFIGURED && !!client,
    refetchInterval: 10_000,
    queryFn: async (): Promise<ProtocolState> => {
      const v = { address: CONTRACTS.lpVault, abi: vaultAbi } as const;
      const p = { address: CONTRACTS.positionManager, abi: pmAbi } as const;
      const tradable = ASSETS.filter((a) => a.address !== zeroAddress);

      const vaultCalls = [
        { ...v, functionName: "totalAssets" },
        { ...v, functionName: "totalSupply" },
        { ...v, functionName: "totalBorrowedPrincipal" },
        { ...v, functionName: "utilizationBps" },
        { ...v, functionName: "maxUtilizationBps" },
        { ...v, functionName: "stressUtilizationBps" },
        { ...v, functionName: "isStressed" },
        { ...v, functionName: "freeLiquidity" },
        { ...v, functionName: "pendingRedeemAssets" },
        { ...v, functionName: "fulfilmentBudget" },
        { ...v, functionName: "bonusPot" },
        { ...v, functionName: "redeemCooldown" },
        { ...v, functionName: "exitPenaltyBps" },
        { ...v, functionName: "bonusDuration" },
        { ...v, functionName: "maxBonusAprBps" },
        { ...v, functionName: "minBonusDeposit" },
        { ...v, functionName: "queueLength" },
        { ...v, functionName: "queueHead" },
        { ...v, functionName: "convertToAssets", args: [10n ** 12n] },
      ] as const;
      const pmCalls = [
        { ...p, functionName: "paused" },
        { ...p, functionName: "minNotional" },
        { ...p, functionName: "keeperBounty" },
        { ...p, functionName: "rolloverAprBps" },
        { ...p, functionName: "maxEntrySlippageBps" },
        { ...p, functionName: "maxExitSlippageBps" },
        { ...p, functionName: "positionCount" },
        { ...p, functionName: "openPositionCount" },
      ] as const;

      const [vr, pr, tierR, assetR, expR, ins, lvlR] = await Promise.all([
        client!.multicall({ contracts: vaultCalls, allowFailure: false }),
        client!.multicall({ contracts: pmCalls, allowFailure: false }),
        client!.multicall({
          contracts: TIERS.map((t) => ({ ...p, functionName: "tiers", args: [t] }) as const),
          allowFailure: false,
        }),
        client!.multicall({
          contracts: tradable.map((a) => ({ ...p, functionName: "assetConfigs", args: [a.address] }) as const),
          allowFailure: false,
        }),
        client!.multicall({
          contracts: tradable.map((a) => ({ ...p, functionName: "assetExposure", args: [a.address] }) as const),
          allowFailure: false,
        }),
        CONTRACTS.insurance === zeroAddress
          ? Promise.resolve(0n)
          : client!.readContract({ address: CONTRACTS.insurance, abi: insuranceAbi, functionName: "insurancePoolBalance" }),
        client!.multicall({
          contracts: LEVEL_NAMES.map((_, l) => ({ ...p, functionName: "levels", args: [l] }) as const),
          allowFailure: false,
        }),
      ]);

      const tiers: ProtocolState["pm"]["tiers"] = {};
      TIERS.forEach((t, i) => {
        const [enabled, maintenanceBps] = tierR[i] as readonly [boolean, number];
        tiers[t] = { enabled, maintenanceBps };
      });
      const assets: ProtocolState["pm"]["assets"] = {};
      tradable.forEach((a, i) => {
        const [enabled, maxExposureBps] = assetR[i] as readonly [boolean, number, number];
        assets[a.address.toLowerCase()] = { enabled, maxExposureBps, exposure: expR[i] as bigint };
      });

      return {
        vault: {
          totalAssets: vr[0],
          totalSupply: vr[1],
          totalBorrowed: vr[2],
          utilizationBps: Number(vr[3]),
          maxUtilizationBps: Number(vr[4]),
          stressUtilizationBps: Number(vr[5]),
          isStressed: vr[6],
          freeLiquidity: vr[7],
          pendingRedeemAssets: vr[8],
          fulfilmentBudget: vr[9],
          bonusPot: vr[10],
          redeemCooldown: Number(vr[11]),
          exitPenaltyBps: Number(vr[12]),
          bonusDuration: Number(vr[13]),
          maxBonusAprBps: Number(vr[14]),
          minBonusDeposit: vr[15],
          queueLength: vr[16],
          queueHead: vr[17],
          sharePrice: vr[18],
        },
        pm: {
          paused: pr[0],
          minNotional: pr[1],
          keeperBounty: pr[2],
          rolloverAprBps: Number(pr[3]),
          maxEntrySlippageBps: Number(pr[4]),
          maxExitSlippageBps: Number(pr[5]),
          positionCount: pr[6],
          openPositionCount: pr[7],
          tiers,
          assets,
          levels: lvlR.map((r) => {
            const [enabled, maxLeverage, maxMargin, lpProfitBps, treasuryProfitBps, promoteMinTrades, promoteMinPnl, demoteMaxLoss] =
              r as readonly [boolean, number, bigint, number, number, number, bigint, bigint];
            return { enabled, maxLeverage, maxMargin, lpProfitBps, treasuryProfitBps, promoteMinTrades, promoteMinPnl, demoteMaxLoss };
          }),
        },
        insurance: ins as bigint,
      };
    },
  });
}

/** Settlement params for a position: maintenance from its leverage tier, profit cuts from the trader's level. */
export function tierParams(s: ProtocolState | undefined, tier: number, level = 0): TierParams {
  const d = DEFAULT_TIERS[tier];
  const l = s?.pm.levels[level];
  return {
    maintenanceBps: s?.pm.tiers[tier]?.maintenanceBps ?? d.maintenanceBps,
    lpProfitBps: l?.lpProfitBps ?? d.lpProfitBps,
    treasuryProfitBps: l?.treasuryProfitBps ?? d.treasuryProfitBps,
  };
}

/** The connected wallet's trader level and progress since entering it. */
export function useTraderStats() {
  const client = usePublicClient();
  const { address } = useAccount();
  return useQuery({
    queryKey: ["traderStats", address],
    enabled: PROTOCOL_CONFIGURED && !!client && !!address,
    refetchInterval: 15_000,
    queryFn: async () => {
      const [level, trades, pnl] = (await client!.readContract({
        address: CONTRACTS.positionManager,
        abi: pmAbi,
        functionName: "traderStats",
        args: [address!],
      })) as readonly [number, number, bigint];
      return { level, trades, pnl };
    },
  });
}
