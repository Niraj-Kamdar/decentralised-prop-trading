"use client";

import { createChart, type IChartApi, type UTCTimestamp } from "lightweight-charts";
import { useEffect, useRef } from "react";

export function NavChart({
  start,
  nav,
  insurance,
}: {
  start: string;
  nav: number[];
  insurance: number[];
}) {
  const el = useRef<HTMLDivElement>(null);
  const chart = useRef<IChartApi | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const css = getComputedStyle(document.documentElement);
    const rgb = (v: string) => `rgb(${css.getPropertyValue(v).trim().split(" ").join(",")})`;

    const c = createChart(el.current, {
      autoSize: true,
      layout: { background: { color: "transparent" }, textColor: rgb("--muted"), fontSize: 11 },
      grid: { vertLines: { color: "rgba(6,27,49,0.05)" }, horzLines: { color: "rgba(6,27,49,0.05)" } },
      rightPriceScale: { borderColor: rgb("--line") },
      timeScale: { borderColor: rgb("--line") },
      crosshair: { mode: 0 },
      localization: {
        priceFormatter: (p: number) => `$${Math.round(p).toLocaleString("en-US")}`,
      },
    });

    const navSeries = c.addLineSeries({
      color: rgb("--accent"),
      lineWidth: 2,
      title: "Vault NAV",
    });

    const insSeries = c.addLineSeries({
      color: rgb("--fg"),
      lineWidth: 1,
      lineStyle: 2,
      title: "Insurance Reserve",
    });

    const startSec = Math.floor(new Date(start.includes("T") ? start : `${start}T00:00:00Z`).getTime() / 1000);

    const navData = nav.map((val, i) => ({
      time: (startSec + i * 86400) as UTCTimestamp,
      value: val,
    }));

    const insData = insurance.map((val, i) => ({
      time: (startSec + i * 86400) as UTCTimestamp,
      value: val,
    }));

    navSeries.setData(navData);
    insSeries.setData(insData);
    c.timeScale().fitContent();

    chart.current = c;
    return () => {
      c.remove();
      chart.current = null;
    };
  }, [start, nav, insurance]);

  return (
    <div className="rounded-xl border border-line bg-panel p-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3 border-b border-line pb-3 text-xs">
        <div className="flex items-center gap-4">
          <span className="flex items-center gap-1.5 font-medium text-fg">
            <span className="h-2 w-2 rounded-full bg-accent" />
            Vault NAV
          </span>
          <span className="flex items-center gap-1.5 text-muted">
            <span className="h-2 w-2 rounded-full border border-dashed border-fg" />
            Insurance Reserve
          </span>
        </div>
        <span className="text-muted">Daily value · 2020 to 2026</span>
      </div>
      <div ref={el} className="h-72 w-full" />
      <p className="mt-2 text-xs text-muted">
        Vault value over time from a $1M deposit. The protocol insurance reserve is drawn as a second line (dashed).
      </p>
    </div>
  );
}
