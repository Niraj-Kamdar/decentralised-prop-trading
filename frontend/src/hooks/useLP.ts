"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient } from "wagmi";
import { vaultAbi } from "@/abi";
import { CONTRACTS, PROTOCOL_CONFIGURED } from "@/lib/config";

export const REQUEST_STATUS = ["NONE", "PENDING", "FULFILLED", "CANCELLED"] as const;

export type RedeemRequest = {
  id: bigint;
  requestedAt: number;
  maturesAt: number;
  stressedAtRequest: boolean;
  status: (typeof REQUEST_STATUS)[number];
  shares: bigint;
  basis: bigint;
  assetsAtRequest: bigint;
  filledShares: bigint;
};

export type BonusTicket = {
  id: bigint;
  maturesAt: number;
  active: boolean;
  shares: bigint;
  weight: bigint;
  pendingBonus: bigint;
};

export type LPState = {
  shares: bigint;
  value: bigint;
  costBasis: bigint;
  claimableAssets: bigint;
  claimableShares: bigint;
  requests: RedeemRequest[];
  tickets: BonusTicket[];
};

const SCAN_LIMIT = 2000n;

const range = (count: bigint) => {
  const start = count > SCAN_LIMIT ? count - SCAN_LIMIT + 1n : 1n;
  const ids: bigint[] = [];
  for (let i = start; i <= count; i++) ids.push(i);
  return ids;
};

/** The connected wallet's LP position, exit-queue requests and bonus tickets. */
export function useLP() {
  const client = usePublicClient();
  const { address } = useAccount();
  return useQuery({
    queryKey: ["lp", address],
    enabled: PROTOCOL_CONFIGURED && !!client && !!address,
    refetchInterval: 10_000,
    queryFn: async (): Promise<LPState> => {
      const v = { address: CONTRACTS.lpVault, abi: vaultAbi } as const;
      const [shares, costBasis, claimableAssets, claimableShares, nextRequestId, nextTicketId] = await client!.multicall({
        contracts: [
          { ...v, functionName: "balanceOf", args: [address!] },
          { ...v, functionName: "costBasis", args: [address!] },
          { ...v, functionName: "claimableAssets", args: [address!] },
          { ...v, functionName: "claimableShares", args: [address!] },
          { ...v, functionName: "nextRequestId" },
          { ...v, functionName: "nextTicketId" },
        ],
        allowFailure: false,
      });
      const value = shares > 0n ? await client!.readContract({ ...v, functionName: "convertToAssets", args: [shares] }) : 0n;

      const reqIds = range(nextRequestId);
      const reqs = reqIds.length
        ? await client!.multicall({
            contracts: reqIds.map((id) => ({ ...v, functionName: "getRedeemRequest", args: [id] }) as const),
            allowFailure: false,
          })
        : [];
      const requests: RedeemRequest[] = reqs
        .map((r, i) => ({ r, id: reqIds[i] }))
        .filter(({ r }) => r.controller.toLowerCase() === address!.toLowerCase())
        .map(({ r, id }) => ({
          id,
          requestedAt: Number(r.requestedAt),
          maturesAt: Number(r.maturesAt),
          stressedAtRequest: r.stressedAtRequest,
          status: REQUEST_STATUS[r.status],
          shares: r.shares,
          basis: r.basis,
          assetsAtRequest: r.assetsAtRequest,
          filledShares: r.filledShares,
        }))
        .reverse();

      const tIds = range(nextTicketId);
      const ts = tIds.length
        ? await client!.multicall({
            contracts: tIds.map((id) => ({ ...v, functionName: "getTicket", args: [id] }) as const),
            allowFailure: false,
          })
        : [];
      const mineT = ts.map((t, i) => ({ t, id: tIds[i] })).filter(({ t }) => t.owner.toLowerCase() === address!.toLowerCase());
      const pend = mineT.length
        ? await client!.multicall({
            contracts: mineT.map(({ id }) => ({ ...v, functionName: "pendingBonus", args: [id] }) as const),
            allowFailure: false,
          })
        : [];
      const tickets: BonusTicket[] = mineT
        .map(({ t, id }, i) => ({
          id,
          maturesAt: Number(t.maturesAt),
          active: t.active,
          shares: t.shares,
          weight: t.weight,
          pendingBonus: pend[i] as bigint,
        }))
        .reverse();

      return { shares, value, costBasis, claimableAssets, claimableShares, requests, tickets };
    },
  });
}
