"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address, Hash, WalletClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { erc20Abi } from "@/abi";
import { chain, USDC } from "@/lib/config";
import type { PublicClient } from "viem";

export function useUsdcBalance() {
  const client = usePublicClient();
  const { address } = useAccount();
  return useQuery({
    queryKey: ["usdc", address],
    enabled: !!client && !!address,
    refetchInterval: 10_000,
    queryFn: () => client!.readContract({ address: USDC, abi: erc20Abi, functionName: "balanceOf", args: [address!] }),
  });
}

/** Approve `spender` for exactly `amount` USDC if the current allowance is lower. Returns null if not needed. */
export async function approveIfNeeded(
  publicClient: PublicClient,
  walletClient: WalletClient,
  spender: Address,
  amount: bigint,
): Promise<Hash | null> {
  const owner = walletClient.account!.address;
  const allowance = await publicClient.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
  });
  if (allowance >= amount) return null;
  return walletClient.writeContract({
    address: USDC,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
    account: walletClient.account!,
    chain,
  });
}
