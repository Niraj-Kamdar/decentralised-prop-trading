import { formatUnits, parseUnits } from "viem";
import { USDC_DECIMALS } from "./config";

export const toUsdc = (v: bigint) => Number(formatUnits(v, USDC_DECIMALS));

export function parseUsdc(input: string): bigint {
  const clean = input.replace(/,/g, "").trim();
  if (!clean || clean === "." || !/^\d*\.?\d*$/.test(clean)) return 0n;
  try {
    return parseUnits(clean, USDC_DECIMALS);
  } catch {
    return 0n;
  }
}

export function usd(v: number | bigint | undefined | null, opts: { decimals?: number; sign?: boolean } = {}): string {
  if (v === undefined || v === null) return "—";
  const n = typeof v === "bigint" ? toUsdc(v) : v;
  if (!Number.isFinite(n)) return "—";
  const decimals = opts.decimals ?? (Math.abs(n) >= 10_000 ? 0 : 2);
  const s = Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
  const sign = n < 0 ? "-" : opts.sign && n > 0 ? "+" : "";
  return `${sign}$${s}`;
}

export function price(n: number | undefined | null): string {
  if (n === undefined || n === null || !Number.isFinite(n)) return "—";
  const decimals = n >= 1000 ? 2 : n >= 1 ? 4 : 6;
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: decimals })}`;
}

export const pct = (bps: number | bigint, decimals = 1) => `${(Number(bps) / 100).toFixed(decimals)}%`;

export function tokenAmount(v: bigint, decimals: number, max = 6): string {
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString("en-US", { maximumFractionDigits: max });
}

export const shortAddr = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

export function timeLeft(unixSeconds: number | bigint): string {
  const diff = Number(unixSeconds) - Math.floor(Date.now() / 1000);
  if (diff <= 0) return "now";
  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${Math.max(m, 1)}m`;
}

export const dateTime = (unixSeconds: number | bigint) =>
  new Date(Number(unixSeconds) * 1000).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
