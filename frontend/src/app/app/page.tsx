"use client";

import Link from "next/link";
import { useAccount } from "wagmi";
import { pmAbi } from "@/abi";
import { Empty, Row, Stat } from "@/components/ui";
import { useLP } from "@/hooks/useLP";
import { useClaimable, usePositions } from "@/hooks/usePositions";
import { usePrices } from "@/hooks/usePrices";
import { borrowCapacity, tierParams, useProtocol, useTraderStats } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { useUsdcBalance } from "@/hooks/useUsdc";
import { chain, assetByAddress, CONTRACTS } from "@/lib/config";
import { pct, price, timeLeft, toUsdc, usd } from "@/lib/format";
import { positionView } from "@/lib/positionView";

export default function Dashboard() {
  const { isConnected } = useAccount();
  const { data: proto } = useProtocol();
  const level = useTraderStats().data?.level ?? 0;
  const { data: positions } = usePositions();
  const { data: lp } = useLP();
  const { data: balance } = useUsdcBalance();
  const { data: claimable } = useClaimable();
  const { get } = usePrices();
  const { run, busy, walletClient } = useTx();

  const open = positions?.filter((p) => p.status === "OPEN") ?? [];
  const views = open.map((p) => {
    const a = assetByAddress(p.spotToken);
    return { p, a, v: positionView(p, a?.decimals ?? 18, a ? (get(a.address)?.twap18 ?? undefined) : undefined, tierParams(proto, p.tier, level)) };
  });
  const totalMargin = open.reduce((s, p) => s + toUsdc(p.userMargin), 0);
  const totalPnl = views.reduce((s, x) => s + (x.v.pnl ?? 0), 0);
  const lpEarned = lp ? toUsdc(lp.value) - toUsdc(lp.costBasis) : 0;
  const pendingWithdrawals = lp?.requests.filter((r) => r.status === "PENDING").reduce((s, r) => s + toUsdc(r.assetsAtRequest), 0) ?? 0;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-[32px] leading-tight tracking-heading">Dashboard</h1>
          <p className="mt-1 text-sm text-muted">Your trades and liquidity at a glance.</p>
        </div>
        <div className="flex gap-2">
          <Link href="/app/trade" className="btn-primary">Trade</Link>
          <Link href="/app/earn" className="btn-secondary">Provide liquidity</Link>
        </div>
      </div>

      {!isConnected ? (
        <div className="card">
          <Empty>
            Connect a wallet to see your portfolio. New here? Read the{" "}
            <Link href="/" className="text-accent hover:underline">two-minute overview</Link>.
          </Empty>
        </div>
      ) : (
        <>
          {claimable !== undefined && claimable > 0n && (
            <div className="card flex flex-wrap items-center justify-between gap-4 border-up/30 bg-up/5 p-4">
              <div>
                <div className="font-medium text-up">{usd(claimable)} trade payout waiting</div>
                <div className="text-sm text-muted">A payout couldn't be sent automatically, so it is held for you to claim.</div>
              </div>
              <button
                className="btn-up"
                disabled={busy}
                onClick={() =>
                  run("Payout claimed", [
                    {
                      title: "Claim payout",
                      send: () =>
                        walletClient!.writeContract({
                          address: CONTRACTS.positionManager,
                          abi: pmAbi,
                          functionName: "claimTraderPayout",
                          account: walletClient!.account!,
                          chain,
                        }),
                    },
                  ])
                }
              >
                Claim
              </button>
            </div>
          )}

          <div className="grid gap-4 md:grid-cols-3">
            <div className="card p-5">
              <Stat label="Wallet" value={balance !== undefined ? usd(balance) : "—"} sub="USDC on Base" />
            </div>
            <div className="card p-5">
              <Stat
                label="Trading"
                value={usd(totalPnl, { sign: true })}
                tone={totalPnl >= 0 ? "up" : "down"}
                sub={`${open.length} open · ${usd(totalMargin)} margin at work`}
              />
            </div>
            <div className="card p-5">
              <Stat
                label="Liquidity"
                value={lp ? usd(lp.value) : "—"}
                sub={
                  <>
                    <span className={lpEarned >= 0 ? "text-up" : "text-down"}>{usd(lpEarned, { sign: true })}</span> earned
                    {pendingWithdrawals > 0 && ` · ${usd(pendingWithdrawals)} withdrawing`}
                  </>
                }
              />
            </div>
          </div>

          <div className="card">
            <div className="flex items-center justify-between border-b border-line px-5 py-3">
              <h2 className="text-lg">Open positions</h2>
              <Link href="/app/trade" className="text-sm text-accent hover:underline">Manage →</Link>
            </div>
            {views.length === 0 ? (
              <Empty>No open positions.</Empty>
            ) : (
              <div className="divide-y divide-line/60">
                {views.map(({ p, a, v }) => (
                  <div key={p.id.toString()} className="grid grid-cols-2 items-center gap-3 px-5 py-3 text-sm md:grid-cols-5">
                    <div className="font-medium">
                      {a?.symbol} <span className="pill ml-1 border border-accent/20 bg-accent/5 text-accent">{p.tier}x</span>
                    </div>
                    <div className="num">{usd(p.notional)}</div>
                    <div className="num text-muted">liq {price(v.liqPrice)}</div>
                    <div className="text-muted">{p.autoRollover ? "rolls" : "closes"} in {timeLeft(p.epochEndTime)}</div>
                    <div className={`num text-right ${v.pnl !== null && v.pnl >= 0 ? "text-up" : "text-down"}`}>{usd(v.pnl, { sign: true })}</div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </>
      )}

      <div className="card p-5">
        <h2 className="text-lg">Protocol</h2>
        <div className="mt-3 grid gap-x-8 md:grid-cols-2">
          <div>
            <Row label="Vault size" value={proto ? usd(proto.vault.totalAssets) : "—"} />
            <Row label="Utilisation" value={proto ? pct(proto.vault.utilizationBps) : "—"} tone={proto?.vault.isStressed ? "warn" : undefined} />
            <Row label="Available to borrow" value={proto ? usd(borrowCapacity(proto)) : "—"} />
            <Row label="Insurance pool" value={proto ? usd(proto.insurance) : "—"} />
          </div>
          <div>
            <Row label="Open positions (all traders)" value={proto ? proto.pm.openPositionCount.toString() : "—"} />
            <Row label="Minimum position size" value={proto ? usd(proto.pm.minNotional) : "—"} />
            <Row label="Rollover rate (after week 1)" value={proto ? `${pct(proto.pm.rolloverAprBps, 0)} APR` : "—"} />
            <Row label="Withdrawal queue" value={proto ? `${Math.round(proto.vault.redeemCooldown / 86400)} days` : "—"} />
          </div>
        </div>
      </div>
    </div>
  );
}
