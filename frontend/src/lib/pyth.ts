import type { Hex } from "viem";
import { HERMES_URL } from "./config";

export type PythPrice = {
  price: number;
  conf: number;
  publishTime: number;
  /** Price scaled to 1e18, exactly as OracleVerifier.getPrice normalises it. */
  price18: bigint;
};

type HermesResponse = {
  binary: { encoding: string; data: string[] };
  parsed: Array<{ id: string; price: { price: string; conf: string; expo: number; publish_time: number } }>;
};

const norm = (id: string) => id.toLowerCase().replace(/^0x/, "");

/** Latest signed Pyth update (to submit on-chain) plus the decoded prices it carries. */
export async function fetchPriceUpdate(ids: Hex[]): Promise<{ updateData: Hex[]; prices: Record<string, PythPrice> }> {
  const qs = ids.map((id) => `ids[]=${id}`).join("&");
  // Outside the browser (keeper bot) talk to Hermes directly with the API key. The browser uses the
  // /api/pyth proxy, and PYTH_API_KEY is not NEXT_PUBLIC_, so it is never inlined into client bundles.
  const headers: Record<string, string> =
    typeof window === "undefined" && process.env.PYTH_API_KEY ? { Authorization: `Bearer ${process.env.PYTH_API_KEY}` } : {};
  const res = await fetch(`${HERMES_URL}/v2/updates/price/latest?${qs}&encoding=hex&parsed=true`, {
    cache: "no-store",
    headers,
  });
  if (!res.ok) {
    const detail = await res.json().then((j: { error?: string }) => j.error).catch(() => undefined);
    throw new Error(detail || `Pyth price service returned ${res.status}`);
  }
  const json = (await res.json()) as HermesResponse;
  const prices: Record<string, PythPrice> = {};
  for (const p of json.parsed) {
    const scale = 10 ** p.price.expo;
    prices[norm(p.id)] = {
      price: Number(p.price.price) * scale,
      conf: Number(p.price.conf) * scale,
      publishTime: p.price.publish_time,
      price18: BigInt(p.price.price) * 10n ** BigInt(18 + p.price.expo),
    };
  }
  return { updateData: json.binary.data.map((h) => (h.startsWith("0x") ? h : `0x${h}`) as Hex), prices };
}

export const priceFor = (prices: Record<string, PythPrice> | undefined, id: Hex) => prices?.[norm(id)];
