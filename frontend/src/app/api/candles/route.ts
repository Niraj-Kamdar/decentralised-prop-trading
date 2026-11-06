import { NextResponse, type NextRequest } from "next/server";

export const runtime = "nodejs";

const BENCHMARKS = (process.env.PYTH_BENCHMARKS_URL || "https://benchmarks.pyth.network").replace(/\/$/, "");
const RESOLUTIONS = new Set(["1", "5", "15", "60", "240", "1D"]);

/** Proxies Pyth Benchmarks' TradingView history endpoint (avoids CORS, adds caching). */
export async function GET(req: NextRequest) {
  const symbol = req.nextUrl.searchParams.get("symbol") ?? "";
  const resolution = req.nextUrl.searchParams.get("resolution") ?? "15";
  if (!/^[A-Za-z]+\.[A-Z0-9]+\/[A-Z]+$/.test(symbol) || !RESOLUTIONS.has(resolution)) {
    return NextResponse.json({ error: "bad params" }, { status: 400 });
  }
  const seconds = resolution === "1D" ? 86400 : Number(resolution) * 60;
  const to = Math.floor(Date.now() / 1000);
  const from = to - seconds * 300;
  const url = `${BENCHMARKS}/v1/shims/tradingview/history?symbol=${encodeURIComponent(symbol)}&resolution=${resolution}&from=${from}&to=${to}`;
  try {
    const headers: Record<string, string> = {};
    if (process.env.PYTH_API_KEY) headers.Authorization = `Bearer ${process.env.PYTH_API_KEY}`;
    const res = await fetch(url, { headers, next: { revalidate: 30 } });
    if (!res.ok) return NextResponse.json({ error: `upstream ${res.status}` }, { status: 502 });
    const j = (await res.json()) as { s: string; t?: number[]; o?: number[]; h?: number[]; l?: number[]; c?: number[] };
    if (j.s !== "ok" || !j.t) return NextResponse.json({ candles: [] });
    const candles = j.t.map((t, i) => ({ time: t, open: j.o![i], high: j.h![i], low: j.l![i], close: j.c![i] }));
    return NextResponse.json({ candles }, { headers: { "Cache-Control": "public, s-maxage=30" } });
  } catch {
    return NextResponse.json({ error: "upstream unreachable" }, { status: 502 });
  }
}
