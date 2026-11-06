"use client";

import { createChart, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";
import { useEffect, useRef } from "react";
import type { Asset } from "@/lib/config";

type Point = { time: number; value: number };
/** Samples survive asset switches and re-mounts for the browser session (capped). */
const history = new Map<string, { spot: Point[]; twap: Point[] }>();
const MAX_POINTS = 5_000;

function push(arr: Point[], time: number, value: number | null | undefined) {
  if (value == null || !Number.isFinite(value)) return;
  const last = arr.at(-1);
  if (last && last.time === time) last.value = value;
  else if (!last || time > last.time) arr.push({ time, value });
  if (arr.length > MAX_POINTS) arr.splice(0, arr.length - MAX_POINTS);
}

/**
 * Live chart built from on-chain samples: the Uniswap v4 pool price (spot) and the 10-minute TWAP that every
 * protocol check uses, plus liquidation lines for the trader's open positions.
 */
export function PriceChart({
  asset,
  spot,
  twap,
  liqPrices = [],
}: {
  asset: Asset;
  spot?: number | null;
  twap?: number | null;
  liqPrices?: number[];
}) {
  const el = useRef<HTMLDivElement>(null);
  const chart = useRef<IChartApi | null>(null);
  const spotSeries = useRef<ISeriesApi<"Line"> | null>(null);
  const twapSeries = useRef<ISeriesApi<"Line"> | null>(null);
  const key = asset.address.toLowerCase();

  useEffect(() => {
    if (!el.current) return;
    const css = getComputedStyle(document.documentElement);
    const rgb = (v: string) => `rgb(${css.getPropertyValue(v).trim().split(" ").join(",")})`;
    const c = createChart(el.current, {
      autoSize: true,
      layout: { background: { color: "transparent" }, textColor: rgb("--muted"), fontSize: 11 },
      grid: { vertLines: { color: "rgba(255,255,255,0.04)" }, horzLines: { color: "rgba(255,255,255,0.04)" } },
      rightPriceScale: { borderColor: rgb("--line") },
      timeScale: { borderColor: rgb("--line"), timeVisible: true, secondsVisible: true },
      crosshair: { mode: 0 },
    });
    spotSeries.current = c.addLineSeries({ color: rgb("--fg"), lineWidth: 2, title: "Pool" });
    twapSeries.current = c.addLineSeries({ color: rgb("--accent"), lineWidth: 2, lineStyle: 2, title: "10m TWAP" });
    chart.current = c;
    return () => {
      c.remove();
      chart.current = null;
      spotSeries.current = null;
      twapSeries.current = null;
    };
  }, []);

  // Reload the stored samples when the market changes.
  useEffect(() => {
    const h = history.get(key) ?? { spot: [], twap: [] };
    history.set(key, h);
    spotSeries.current?.setData(h.spot.map((p) => ({ ...p, time: p.time as UTCTimestamp })));
    twapSeries.current?.setData(h.twap.map((p) => ({ ...p, time: p.time as UTCTimestamp })));
    chart.current?.timeScale().fitContent();
  }, [key]);

  // Append each new on-chain sample.
  useEffect(() => {
    const h = history.get(key);
    if (!h) return;
    const now = Math.floor(Date.now() / 1000);
    push(h.spot, now, spot);
    push(h.twap, now, twap);
    const s = h.spot.at(-1);
    const t = h.twap.at(-1);
    if (s && s.time === now) spotSeries.current?.update({ ...s, time: s.time as UTCTimestamp });
    if (t && t.time === now) twapSeries.current?.update({ ...t, time: t.time as UTCTimestamp });
  }, [key, spot, twap]);

  // Liquidation price lines for the trader's open positions in this market.
  const liqKey = liqPrices.map((p) => p.toPrecision(8)).join(",");
  useEffect(() => {
    const s = twapSeries.current;
    if (!s || !liqKey) return;
    const lines = liqKey
      .split(",")
      .map(Number)
      .map((p) => s.createPriceLine({ price: p, color: "rgba(244,84,100,0.8)", lineWidth: 1, lineStyle: 2, axisLabelVisible: true, title: "Liq." }));
    return () => lines.forEach((l) => s.removePriceLine(l));
  }, [liqKey]);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-4 border-b border-line px-3 py-2 text-xs">
        <span className="flex items-center gap-1.5">
          <span className="inline-block h-0.5 w-4 bg-fg" /> Uniswap pool
        </span>
        <span className="flex items-center gap-1.5 text-accent">
          <span className="inline-block h-0.5 w-4 border-t-2 border-dashed border-accent" /> 10-min TWAP (used for risk)
        </span>
        <span className="ml-auto text-muted">Live on-chain samples</span>
      </div>
      <div ref={el} className="min-h-[260px] flex-1" />
    </div>
  );
}
