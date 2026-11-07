"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import type { Hash } from "viem";
import { useAccount, usePublicClient, useSwitchChain, useWalletClient } from "wagmi";
import { useToast } from "@/components/Toast";
import { chain } from "@/lib/config";
import { explainError } from "@/lib/errors";

/**
 * Runs a sequence of wallet transactions with toasts, chain switching and query refresh.
 * Each step returns a tx hash (or null to skip); steps run in order and each waits for its receipt.
 */
export function useTx() {
  const { push, update } = useToast();
  const qc = useQueryClient();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const { chainId } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const [busy, setBusy] = useState(false);

  const run = useCallback(
    async (label: string, steps: Array<{ title: string; send: () => Promise<Hash | null> }>) => {
      if (!walletClient || !publicClient) {
        push({ kind: "error", title: "Connect your wallet first" });
        return false;
      }
      setBusy(true);
      let id: number | null = null;
      try {
        if (chainId !== chain.id) await switchChainAsync({ chainId: chain.id });
        for (const step of steps) {
          id = push({ kind: "info", title: step.title, body: "Confirm in your wallet…" });
          const hash = await step.send();
          if (!hash) {
            update(id, { kind: "success", body: "Not needed" });
            continue;
          }
          update(id, { body: "Waiting for confirmation…", hash });
          const receipt = await publicClient.waitForTransactionReceipt({ hash });
          if (receipt.status !== "success") throw new Error("Transaction reverted");
          update(id, { kind: "success", body: "Confirmed", hash });
          id = null;
        }
        push({ kind: "success", title: label });
        return true;
      } catch (e) {
        const msg = explainError(e);
        if (id !== null) update(id, { kind: "error", body: msg });
        else push({ kind: "error", title: `${label} failed`, body: msg });
        console.error(e);
        return false;
      } finally {
        setBusy(false);
        await qc.invalidateQueries();
      }
    },
    [walletClient, publicClient, chainId, switchChainAsync, push, update, qc],
  );

  return { run, busy, walletClient, publicClient };
}
