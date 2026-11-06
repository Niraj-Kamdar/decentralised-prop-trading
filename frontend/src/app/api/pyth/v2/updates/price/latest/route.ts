import { NextResponse, type NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Server-side proxy for Pyth Hermes, which requires an API key since the 2026 Pyth Core upgrade.
 * Keeps PYTH_API_KEY off the client and collapses identical polls from many visitors into one upstream call.
 */
const UPSTREAM = (process.env.PYTH_HERMES_URL || "https://hermes.pyth.network").replace(/\/$/, "");
const ID_RE = /^(0x)?[0-9a-fA-F]{64}$/;
const CACHE_MS = 800;
const cache = new Map<string, { at: number; body: string; status: number }>();

export async function GET(req: NextRequest) {
  const ids = req.nextUrl.searchParams.getAll("ids[]");
  if (ids.length === 0 || ids.length > 10 || !ids.every((id) => ID_RE.test(id))) {
    return NextResponse.json({ error: "bad ids" }, { status: 400 });
  }
  const key = [...ids].sort().join(",");
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_MS) {
    return new NextResponse(hit.body, { status: hit.status, headers: { "Content-Type": "application/json" } });
  }

  const qs = ids.map((id) => `ids[]=${id}`).join("&");
  const headers: Record<string, string> = {};
  if (process.env.PYTH_API_KEY) headers.Authorization = `Bearer ${process.env.PYTH_API_KEY}`;
  try {
    const res = await fetch(`${UPSTREAM}/v2/updates/price/latest?${qs}&encoding=hex&parsed=true`, { headers, cache: "no-store" });
    const body = await res.text();
    if (res.ok) {
      cache.set(key, { at: Date.now(), body, status: 200 });
      if (cache.size > 100) cache.clear();
      return new NextResponse(body, { headers: { "Content-Type": "application/json" } });
    }
    const hint = res.status === 401 || res.status === 403 ? " (set PYTH_API_KEY)" : "";
    return NextResponse.json({ error: `Pyth Hermes returned ${res.status}${hint}` }, { status: 502 });
  } catch {
    return NextResponse.json({ error: "Pyth Hermes unreachable" }, { status: 502 });
  }
}
