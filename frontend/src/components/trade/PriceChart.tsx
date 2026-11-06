"use client";

import { createChart, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";
import { useEffect, useRef, useState } from "react";
import type { Asset } from "@/lib/config";

const RES = [
  { key: "5", label: "5m", sec: 300 },
  { key: "15", label: "15m", sec: 900 },
  { key: "60", label: "1h", sec: 3600 },
  { key: "240", label: "4h", sec: 14400 },
  { key: "1D", label: "1D", sec: 86400 },
] as const;

type Candle = { time: number; open: number; high: number; low: number; close: number };

export function PriceChart({ asset, livePrice, liqPrices = [] }: { asset: Asset; livePrice?: number; liqPrices?: number[] }) {
  const el = useRef<HTMLDivElement>(null);
  const chart = useRef<IChartApi | null>(null);
  const series = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const last = useRef<Candle | null>(null);
  const [res, setRes] = useState<(typeof RES)[number]>(RES[1]);
  const [status, setStatus] = useState<"loading" | "ok" | "error">("loading");

  useEffect(() => {
    if (!el.current) return;
    const css = getComputedStyle(document.documentElement);
    const rgb = (v: string) => `rgb(${css.getPropertyValue(v).trim().split(" ").join(",")})`;
    const c = createChart(el.current, {
      autoSize: true,
      layout: { background: { color: "transparent" }, textColor: rgb("--muted"), fontSize: 11 },
      grid: { vertLines: { color: "rgba(255,255,255,0.04)" }, horzLines: { color: "rgba(255,255,255,0.04)" } },
      rightPriceScale: { borderColor: rgb("--line") },
      timeScale: { borderColor: rgb("--line"), timeVisible: true },
      crosshair: { mode: 0 },
    });
    series.current = c.addCandlestickSeries({
      upColor: rgb("--up"),
      downColor: rgb("--down"),
      wickUpColor: rgb("--up"),
      wickDownColor: rgb("--down"),
      borderVisible: false,
    });
    chart.current = c;
    return () => {
      c.remove();
      chart.current = null;
      series.current = null;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");
    fetch(`/api/candles?symbol=${encodeURIComponent(asset.chartSymbol)}&resolution=${res.key}`)
      .then((r) => r.json())
      .then((j: { candles?: Candle[] }) => {
        if (cancelled || !series.current) return;
        const candles = j.candles ?? [];
        series.current.setData(candles.map((k) => ({ ...k, time: k.time as UTCTimestamp })));
        last.current = candles.at(-1) ?? null;
        chart.current?.timeScale().fitContent();
        setStatus(candles.length ? "ok" : "error");
      })
      .catch(() => !cancelled && setStatus("error"));
    return () => {
      cancelled = true;
    };
  }, [asset.chartSymbol, res]);

  // Stream the live oracle price into the current candle.
  useEffect(() => {
    if (!livePrice || !series.current) return;
    const bucket = Math.floor(Date.now() / 1000 / res.sec) * res.sec;
    // Without history (e.g. Benchmarks unavailable) the chart builds itself from live oracle ticks.
    const prev = last.current ?? { time: bucket, open: livePrice, high: livePrice, low: livePrice, close: livePrice };
    const k: Candle =
      bucket > prev.time
        ? { time: bucket, open: prev.close, high: Math.max(prev.close, livePrice), low: Math.min(prev.close, livePrice), close: livePrice }
        : { ...prev, high: Math.max(prev.high, livePrice), low: Math.min(prev.low, livePrice), close: livePrice };
    last.current = k;
    series.current.update({ ...k, time: k.time as UTCTimestamp });
  }, [livePrice, res.sec]);

  // Liquidation price lines for the trader's open positions in this market.
  const liqKey = liqPrices.map((p) => p.toPrecision(8)).join(",");
  useEffect(() => {
    const s = series.current;
    if (!s || !liqKey) return;
    const lines = liqKey.split(",").map(Number).map((p) =>
      s.createPriceLine({ price: p, color: "rgba(244,84,100,0.8)", lineWidth: 1, lineStyle: 2, axisLabelVisible: true, title: "Liq." }),
    );
    return () => lines.forEach((l) => s.removePriceLine(l));
  }, [liqKey]);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-1 border-b border-line px-3 py-2">
        {RES.map((r) => (
          <button
            key={r.key}
            onClick={() => setRes(r)}
            className={`rounded px-2 py-1 text-xs font-medium ${r.key === res.key ? "bg-panel2 text-fg" : "text-muted hover:text-fg"}`}
          >
            {r.label}
          </button>
        ))}
        <span className="ml-auto text-xs text-muted">{status === "error" ? "History unavailable: live ticks only" : "Pyth oracle prices"}</span>
      </div>
      <div ref={el} className="min-h-[260px] flex-1" />
    </div>
  );
}
