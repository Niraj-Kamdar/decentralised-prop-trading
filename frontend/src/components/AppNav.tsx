"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { usePathname } from "next/navigation";
import { ConnectButton } from "./ConnectButton";
import { Logo } from "./Logo";
import { NETWORK_LABEL, PROTOCOL_CONFIGURED } from "@/lib/config";
import { useProtocol } from "@/hooks/useProtocol";

const LINKS = [
  { href: "/app", label: "Dashboard" },
  { href: "/app/trade", label: "Trade" },
  { href: "/app/earn", label: "Earn" },
];

function Banner({ children }: { children: ReactNode }) {
  return <div className="border-b border-warn/20 bg-warn/5 px-4 py-2 text-center text-sm text-warn">{children}</div>;
}

export function AppNav() {
  const path = usePathname();
  const { data } = useProtocol();
  return (
    <>
      <header className="sticky top-0 z-20 border-b border-line bg-bg/85 backdrop-blur-md">
        <div className="mx-auto flex h-14 max-w-[1400px] items-center justify-between gap-4 px-4">
          <div className="flex items-center gap-8">
            <Logo href="/" />
            <nav className="hidden items-center gap-1 sm:flex" aria-label="App">
              {LINKS.map((l) => {
                const active = path === l.href;
                return (
                  <Link
                    key={l.href}
                    href={l.href}
                    aria-current={active ? "page" : undefined}
                    className={`relative px-3 py-[17px] text-sm font-normal transition-colors duration-150 ${
                      active
                        ? "text-fg after:absolute after:inset-x-3 after:bottom-0 after:h-0.5 after:bg-accent"
                        : "text-muted hover:text-fg"
                    }`}
                  >
                    {l.label}
                  </Link>
                );
              })}
            </nav>
          </div>
          <div className="flex items-center gap-3">
            <span className="hidden items-center gap-1.5 rounded border border-line px-2 py-1 text-xs text-fg2 md:inline-flex">
              <span className="h-1.5 w-1.5 rounded-full bg-up" aria-hidden />
              {NETWORK_LABEL}
            </span>
            <ConnectButton />
          </div>
        </div>
        <nav className="flex border-t border-line sm:hidden" aria-label="App">
          {LINKS.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              aria-current={path === l.href ? "page" : undefined}
              className={`flex-1 py-2.5 text-center text-sm ${path === l.href ? "text-fg shadow-[inset_0_-2px_0_rgb(var(--accent))]" : "text-muted"}`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
      </header>
      {!PROTOCOL_CONFIGURED && <Banner>Contract addresses aren&apos;t configured. Set the NEXT_PUBLIC_* variables (see frontend/.env.example).</Banner>}
      {data?.pm.paused && <Banner>New positions are paused. You can still close positions and manage liquidity.</Banner>}
      <div className="border-b border-line bg-panel2 px-4 py-1.5 text-center text-xs text-muted">
        Early release. Real funds, unaudited contracts. Trade small.
      </div>
    </>
  );
}
