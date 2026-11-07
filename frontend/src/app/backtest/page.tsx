import type { Metadata } from "next";
import Link from "next/link";
import { AppNav } from "@/components/AppNav";
import { Bars } from "@/components/backtest/Bars";
import { NavChart } from "@/components/backtest/NavChart";
import { Stat } from "@/components/ui";
import { getBacktest } from "@/lib/arkiv/read";
import { PUBLISHER } from "@/lib/arkiv/schema";
import { histogram, pct, usd0 } from "@/lib/format";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: "Backtest — Fulcrum",
  description:
    "Live backtest results from 6.8 years of Binance prices and real Hyperliquid trades, verified on Arkiv.",
};

const README_QUERY = `// Query Arkiv directly for historical crash losses:
import { createPublicClient } from "@arkiv-network/sdk";
import { rabdi } from "@arkiv-network/sdk/chains";
import { and, eq, gt } from "@arkiv-network/sdk/query";
import { dec, defineSchema, str, u64 } from "@arkiv-network/sdk/schema";
import { http } from "viem";

const Crash = defineSchema("fulcrum.crash", {
  run: str().indexed(), event: str().indexed(), scenario: str().indexed(), lp_loss_usd: dec().indexed(),
  lp_loss_pct: dec(), liquidations: u64(), eth_1h: dec(), btc_1h: dec(),
});
const pub = createPublicClient({ chain: rabdi({ accessKey: process.env.ARKIV_ACCESS_KEY ?? "" }), transport: http() });
const q = (scenario: string) => pub.select({ event: true, lp_loss_usd: true }).from(Crash)
  .where(and(eq("scenario", scenario), gt("lp_loss_usd", dec("0"))))
  .ownedBy("${PUBLISHER}").limit(100).fetch();

console.log("base:", (await q("base")).entities); // [] -> no LP loss in any of 7 crashes`;

const EVENT_LABELS: Record<string, string> = {
  covid: "COVID crash (Mar 2020)",
  "may-21": "May 2021 drop",
  luna: "LUNA collapse (May 2022)",
  ftx: "FTX collapse (Nov 2022)",
  "yen-carry": "Yen carry unwind (Aug 2024)",
  tariffs: "Tariff crash (Feb 2025)",
  "oct-10": "Oct 2025 drawdown",
};

function VerifyBox({
  run,
  commit,
  published,
}: {
  run?: string;
  commit?: string;
  published?: number;
}) {
  return (
    <section className="rounded-xl border border-line bg-panel p-6 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line pb-3">
        <div>
          <h2 className="text-base font-semibold text-fg">Verify on Arkiv</h2>
          <p className="text-xs text-muted">
            All simulation data is published and signed on the Rabdi testnet.
          </p>
        </div>
        <a
          href="https://github.com/niraj-kamdar/decentralised-prop-trading/blob/main/sponsors/arkiv/README.md"
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-accent hover:underline"
        >
          Arkiv Track Docs →
        </a>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 text-xs">
        <div>
          <span className="text-muted block mb-0.5">Publisher Address</span>
          <a
            href={`https://rabdi.explorer.arkiv.network/address/${PUBLISHER}`}
            target="_blank"
            rel="noopener noreferrer"
            className="font-mono text-accent hover:underline break-all"
          >
            {PUBLISHER}
          </a>
        </div>
        <div>
          <span className="text-muted block mb-0.5">Run & Commit</span>
          <span className="font-mono text-fg">
            {commit ?? "—"} {run ? `(${run})` : ""}
          </span>
          {published ? (
            <span className="text-muted block mt-0.5">
              Published: {new Date(published * 1000).toUTCString()}
            </span>
          ) : null}
        </div>
      </div>

      <div>
        <span className="text-muted block text-xs mb-1.5 font-medium">
          Query the Risk Claim Yourself
        </span>
        <pre className="overflow-x-auto rounded-lg bg-panel2 p-3 font-mono text-[11px] text-fg leading-relaxed border border-line">
          {README_QUERY}
        </pre>
      </div>
    </section>
  );
}

export default async function BacktestPage() {
  const backtest = await getBacktest();

  if (!backtest) {
    return (
      <div className="min-h-screen">
        <AppNav />
        <main className="mx-auto max-w-[1100px] px-4 py-8 space-y-8">
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-fg">Protocol Backtest</h1>
            <p className="text-sm text-muted mt-1">
              Historical simulation results read directly from Arkiv.
            </p>
          </div>

          <div className="rounded-xl border border-warn/40 bg-warn/10 p-6 text-sm text-warn">
            <h3 className="font-semibold text-base mb-1">Notice</h3>
            <p>
              Backtest data is temporarily unavailable from Arkiv. Either the network node is
              restarting, or the published run has expired after 180 days. You can still verify the
              records directly on the Rabdi explorer below.
            </p>
          </div>

          <VerifyBox />
        </main>
      </div>
    );
  }

  const { sections, crashes, years, run, commit, published } = backtest;
  const headline = sections.headline ?? {};
  const realTraders = sections.real_traders ?? {};

  // Compute crash table rows & risk claim
  const eventsMap = new Map<
    string,
    {
      event: string;
      eth_1h: number;
      btc_1h: number;
      base?: number;
      stress?: number;
      stress_outage_30m?: number;
    }
  >();

  for (const c of crashes) {
    let row = eventsMap.get(c.event);
    if (!row) {
      row = {
        event: c.event,
        eth_1h: c.eth_1h,
        btc_1h: c.btc_1h,
      };
      eventsMap.set(c.event, row);
    }
    if (c.scenario === "base") row.base = c.lp_loss_usd;
    else if (c.scenario === "stress") row.stress = c.lp_loss_usd;
    else if (c.scenario === "stress_outage_30m") row.stress_outage_30m = c.lp_loss_usd;
  }

  const crashRows = Array.from(eventsMap.values());
  const baseLossCount = crashRows.filter((r) => (r.base ?? 0) >= 0.5).length;
  const crashClaim =
    baseLossCount === 0
      ? `No LP loss in any of ${crashRows.length} crashes at default settings`
      : `${baseLossCount} of ${crashRows.length} crashes had LP loss at default settings`;

  // Real trader data
  const holdBars = (realTraders.by_hold ?? []).map((b: any) => ({
    label: b.hold,
    value: b.win_net ?? 0,
    text: pct(b.win_net ?? 0),
  }));

  const leverageHistogram = histogram(
    realTraders.open_long_leverage ?? [],
    [1, 3, 5, 10, 20]
  );
  const levLabels = ["1–3x", "3–5x", "5–10x", "10–20x", "20x+"];
  const levBars = levLabels.map((label, i) => ({
    label,
    value: leverageHistogram[i] ?? 0,
    text: (leverageHistogram[i] ?? 0).toLocaleString(),
  }));

  const sample = realTraders.sample ?? {};
  const insuranceAtEnd =
    headline.daily?.insurance && headline.daily.insurance.length > 0
      ? headline.daily.insurance[headline.daily.insurance.length - 1]
      : 0;

  return (
    <div className="min-h-screen">
      <AppNav />
      <main className="mx-auto max-w-[1100px] px-4 py-8 space-y-12">
        {/* Header */}
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-fg">Protocol Backtest</h1>
          <p className="mt-1 text-sm text-muted">
            Simulated minute-by-minute performance across 6.8 years of Binance market data and 6,967
            real Hyperliquid trades. Stored immutably on Arkiv.
          </p>
        </div>

        {/* 1. Hero stats */}
        <section>
          <div className="mb-3 text-xs text-muted uppercase tracking-wider font-medium">
            Vault Performance · $1M vault ({headline.start ?? "2020-01-01"} – {headline.end ?? "2026-11-01"})
          </div>
          <div className="grid grid-cols-2 gap-4 rounded-xl border border-line bg-panel p-5 sm:grid-cols-4">
            <Stat
              label="LP APY"
              value={headline.apy !== undefined ? pct(headline.apy) : "—"}
              sub="Net after bad debt"
              tone="up"
            />
            <Stat
              label="LP Bad Debt"
              value={headline.bad_debt !== undefined ? usd0(headline.bad_debt) : "—"}
              sub="Across full 6.8y history"
              tone={headline.bad_debt > 0 ? "warn" : undefined}
            />
            <Stat
              label="Positions Simulated"
              value={headline.positions !== undefined ? headline.positions.toLocaleString() : "—"}
              sub="Long ETH & BTC"
            />
            <Stat
              label="Insurance Reserve"
              value={usd0(insuranceAtEnd)}
              sub="Accumulated at end"
              tone="up"
            />
          </div>
        </section>

        {/* 2. Vault value line chart */}
        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold text-fg">Vault Value Over Time</h2>
            <span className="text-xs text-muted">Initial deposit $1,000,000</span>
          </div>
          {headline.daily?.nav ? (
            <NavChart
              start={headline.start ?? "2020-01-01"}
              nav={headline.daily.nav}
              insurance={headline.daily.insurance ?? []}
            />
          ) : null}
        </section>

        {/* 3. Crash Stress Tests */}
        <section className="space-y-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <div>
              <h2 className="text-lg font-semibold text-fg">Historical Crash Stress Tests</h2>
              <p className="text-xs text-up font-medium mt-0.5">{crashClaim}</p>
            </div>
            <span className="text-xs text-muted">7 major drawdowns tested</span>
          </div>

          <div className="overflow-x-auto rounded-xl border border-line bg-panel">
            <table className="w-full text-left text-xs">
              <thead className="border-b border-line bg-panel2 text-muted">
                <tr>
                  <th className="px-4 py-3 font-medium">Event</th>
                  <th className="px-3 py-3 font-medium text-right">Worst ETH 1h</th>
                  <th className="px-3 py-3 font-medium text-right">Worst BTC 1h</th>
                  <th className="px-3 py-3 font-medium text-right">Normal</th>
                  <th className="px-3 py-3 font-medium text-right">All 10x, thin pool</th>
                  <th className="px-4 py-3 font-medium text-right">+ 30-min keeper outage</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {crashRows.map((r) => (
                  <tr key={r.event} className="hover:bg-panel2/50 transition-colors">
                    <td className="px-4 py-3 font-medium text-fg">
                      {EVENT_LABELS[r.event] ?? r.event}
                    </td>
                    <td className="px-3 py-3 text-right font-mono text-down">
                      {pct(r.eth_1h)}
                    </td>
                    <td className="px-3 py-3 text-right font-mono text-down">
                      {pct(r.btc_1h)}
                    </td>
                    <td className="px-3 py-3 text-right font-mono">
                      <span className={(r.base ?? 0) > 0 ? "text-down font-semibold" : "text-fg"}>
                        {usd0(r.base ?? 0)}
                      </span>
                    </td>
                    <td className="px-3 py-3 text-right font-mono">
                      <span className={(r.stress ?? 0) > 0 ? "text-down font-semibold" : "text-fg"}>
                        {usd0(r.stress ?? 0)}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right font-mono">
                      <span
                        className={
                          (r.stress_outage_30m ?? 0) > 0 ? "text-down font-semibold" : "text-fg"
                        }
                      >
                        {usd0(r.stress_outage_30m ?? 0)}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {/* 4. By Year */}
        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold text-fg">Performance By Calendar Year</h2>
            <span className="text-xs text-muted">Consistent yield in bull & bear markets</span>
          </div>

          <div className="overflow-x-auto rounded-xl border border-line bg-panel">
            <table className="w-full text-left text-xs">
              <thead className="border-b border-line bg-panel2 text-muted">
                <tr>
                  <th className="px-4 py-3 font-medium">Year</th>
                  <th className="px-3 py-3 font-medium text-right">LP APY</th>
                  <th className="px-3 py-3 font-medium text-right">Volume ×TVL</th>
                  <th className="px-3 py-3 font-medium text-right">Utilisation</th>
                  <th className="px-3 py-3 font-medium text-right">Trader Win Rate</th>
                  <th className="px-4 py-3 font-medium text-right">Bad Debt</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {years.map((y) => (
                  <tr key={y.year} className="hover:bg-panel2/50 transition-colors">
                    <td className="px-4 py-3 font-medium text-fg">{y.year}</td>
                    <td className="px-3 py-3 text-right font-mono font-semibold text-up">
                      {pct(y.apy)}
                    </td>
                    <td className="px-3 py-3 text-right font-mono text-fg">
                      {y.volume_x.toFixed(1)}x
                    </td>
                    <td className="px-3 py-3 text-right font-mono text-fg">
                      {pct(y.util)}
                    </td>
                    <td className="px-3 py-3 text-right font-mono text-fg">
                      {pct(y.win)}
                    </td>
                    <td className="px-4 py-3 text-right font-mono">
                      <span className={y.bad_debt_usd > 0 ? "text-down font-semibold" : "text-fg"}>
                        {usd0(y.bad_debt_usd)}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {/* 5. Real Traders Distribution */}
        <section className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-fg">Real Trader Behavior</h2>
            <p className="text-xs text-muted mt-0.5">
              {sample.positions
                ? `${sample.positions.toLocaleString()} positions from ${sample.accounts?.toLocaleString() ?? "—"} Hyperliquid accounts, median hold ${sample.hold_median_h ? sample.hold_median_h.toFixed(1) : "—"} h`
                : "Real Hyperliquid dataset sample metrics"}
            </p>
          </div>

          <div className="grid gap-6 md:grid-cols-2">
            <div className="rounded-xl border border-line bg-panel p-5 space-y-3">
              <div className="flex items-center justify-between text-xs">
                <span className="font-semibold text-fg">Net Win Rate by Hold Time</span>
                <span className="text-muted">Trader net PnL {">"} 0</span>
              </div>
              <Bars rows={holdBars} />
            </div>

            <div className="rounded-xl border border-line bg-panel p-5 space-y-3">
              <div className="flex items-center justify-between text-xs">
                <span className="font-semibold text-fg">Open Long Leverage Distribution</span>
                <span className="text-muted">Positions count</span>
              </div>
              <Bars rows={levBars} />
            </div>
          </div>
        </section>

        {/* 6. Verify on Arkiv */}
        <VerifyBox run={run} commit={commit} published={published} />
      </main>
    </div>
  );
}
