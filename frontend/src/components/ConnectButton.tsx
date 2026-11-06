"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { useUsdcBalance } from "@/hooks/useUsdc";
import { addressUrl, arc } from "@/lib/config";
import { shortAddr, usd } from "@/lib/format";

export function ConnectButton() {
  const { address, chainId, isConnected } = useAccount();
  const { connectors, connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { data: balance } = useUsdcBalance();
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => setMounted(true), []);
  useEffect(() => {
    const close = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false);
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);

  if (!mounted) return <div className="h-9 w-32" />;

  if (isConnected && chainId !== arc.id) {
    return (
      <button className="btn bg-warn text-black" onClick={() => switchChain({ chainId: arc.id })}>
        Switch to {arc.name}
      </button>
    );
  }

  if (isConnected && address) {
    return (
      <div className="relative" ref={ref}>
        <button className="btn-secondary" onClick={() => setOpen((o) => !o)}>
          <span className="num hidden text-muted sm:inline">{balance !== undefined ? usd(balance) : ""}</span>
          <span className="h-2 w-2 rounded-full bg-up" />
          <span className="num">{shortAddr(address)}</span>
        </button>
        {open && (
          <div className="card absolute right-0 z-30 mt-2 w-56 p-2 text-sm shadow-xl">
            <div className="px-2 py-1.5 text-xs text-muted">USDC balance</div>
            <div className="num px-2 pb-2 text-base">{balance !== undefined ? usd(balance) : "—"}</div>
            <button className="btn-ghost w-full justify-start" onClick={() => navigator.clipboard.writeText(address)}>
              Copy address
            </button>
            <a className="btn-ghost w-full justify-start" href={addressUrl(address)} target="_blank" rel="noreferrer">
              View on explorer ↗
            </a>
            <button className="btn-ghost w-full justify-start text-down" onClick={() => (disconnect(), setOpen(false))}>
              Disconnect
            </button>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="relative" ref={ref}>
      <button className="btn-primary" disabled={isPending} onClick={() => setOpen((o) => !o)}>
        {isPending ? "Connecting…" : "Connect wallet"}
      </button>
      {open && (
        <div className="card absolute right-0 z-30 mt-2 w-64 p-2 text-sm shadow-xl">
          {connectors.map((c) => (
            <button
              key={c.uid}
              className="btn-ghost w-full justify-start"
              onClick={() => {
                connect({ connector: c, chainId: arc.id });
                setOpen(false);
              }}
            >
              {c.name === "Injected" ? "Browser wallet" : c.name}
            </button>
          ))}
          {error && <p className="px-2 py-1 text-xs text-down">{error.message.split("\n")[0]}</p>}
          <p className="px-2 pt-2 text-xs text-muted">You'll need USDC on Arc. It's also used to pay gas.</p>
        </div>
      )}
    </div>
  );
}
