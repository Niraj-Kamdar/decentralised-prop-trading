"use client";

import { borrowCapacity, useProtocol } from "@/hooks/useProtocol";
import { NETWORK_LABEL, PROTOCOL_CONFIGURED } from "@/lib/config";
import { pct, usd } from "@/lib/format";

export function LiveStats() {
  const { data, isLoading, isError } = useProtocol();

  const items = [
    { label: "Vault size", value: data ? usd(data.vault.totalAssets) : "—" },
    { label: "Lent to traders", value: data ? pct(data.vault.utilizationBps, 0) : "—" },
    { label: "Open trades", value: data ? data.pm.openPositionCount.toString() : "—" },
    { label: "Available to borrow", value: data ? usd(borrowCapacity(data)) : "—" },
  ];

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center justify-between border-b border-line px-5 py-3 text-sm">
        <span className="flex items-center gap-2 font-medium">
          <span className={`h-2 w-2 rounded-full ${data ? "animate-pulse bg-up" : "bg-muted"}`} />
          Live on {NETWORK_LABEL}
        </span>
        <span className="text-xs text-muted">
          {!PROTOCOL_CONFIGURED ? "Contracts not configured" : isLoading ? "Loading…" : isError ? "RPC unavailable" : "Read directly from the contracts"}
        </span>
      </div>
      <div className="grid grid-cols-2 divide-line md:grid-cols-4 md:divide-x">
        {items.map((i) => (
          <div key={i.label} className="px-5 py-4">
            <div className="label">{i.label}</div>
            <div className="num mt-1 text-2xl font-semibold">{i.value}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
