"use client";

import Link from "next/link";
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

export function AppNav() {
  const path = usePathname();
  const { data } = useProtocol();
  return (
    <>
      <header className="sticky top-0 z-20 border-b border-line bg-bg/90 backdrop-blur">
        <div className="mx-auto flex max-w-[1400px] items-center justify-between gap-4 px-4 py-3">
          <div className="flex items-center gap-6">
            <Logo href="/" />
            <nav className="hidden items-center gap-1 sm:flex">
              {LINKS.map((l) => (
                <Link
                  key={l.href}
                  href={l.href}
                  className={`rounded-md px-3 py-1.5 text-sm font-medium ${
                    path === l.href ? "bg-panel2 text-fg" : "text-muted hover:text-fg"
                  }`}
                >
                  {l.label}
                </Link>
              ))}
            </nav>
          </div>
          <div className="flex items-center gap-3">
            <span className="pill hidden border border-line text-muted md:inline-flex">
              {NETWORK_LABEL}
            </span>
            <ConnectButton />
          </div>
        </div>
        <nav className="flex border-t border-line sm:hidden">
          {LINKS.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className={`flex-1 py-2 text-center text-sm font-medium ${path === l.href ? "text-fg" : "text-muted"}`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
      </header>
      {!PROTOCOL_CONFIGURED && (
        <div className="border-b border-warn/30 bg-warn/10 px-4 py-2 text-center text-sm text-warn">
          Contract addresses are not configured. Set the NEXT_PUBLIC_* variables (see frontend/.env.example).
        </div>
      )}
      {data?.pm.paused && (
        <div className="border-b border-warn/30 bg-warn/10 px-4 py-2 text-center text-sm text-warn">
          New positions are paused. You can still close positions and manage liquidity.
        </div>
      )}
      <div className="border-b border-line bg-panel px-4 py-1.5 text-center text-xs text-muted">
        Early MVP with real funds and unaudited contracts. Trade small.
      </div>
    </>
  );
}
