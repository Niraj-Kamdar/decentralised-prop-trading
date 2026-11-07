import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";
import { createPublicClient } from "@arkiv-network/sdk";
import { rabdi } from "@arkiv-network/sdk/chains";
import { desc, eq } from "@arkiv-network/sdk/query";
import { http } from "viem";
import {
  assembleBacktest,
  Backtest,
  CrashRow,
  YearRow,
} from "./backtest";
import {
  Crash,
  PUBLISHER,
  Results,
  SCENARIOS,
  Year,
} from "./schema";

// Wire format: SDK returns bytes() as hex string "0x..." and u64() as bigint

function toBytes(body: unknown): Uint8Array {
  if (body instanceof Uint8Array) return body;
  if (typeof body === "string") {
    const hex = body.startsWith("0x") ? body.slice(2) : body;
    return Buffer.from(hex, "hex");
  }
  return new Uint8Array();
}

function ensureEnv(): void {
  if (process.env.ARKIV_ACCESS_KEY) return;
  try {
    for (const f of [".env.local", ".env"]) {
      try {
        const content = readFileSync(path.join(process.cwd(), f), "utf8");
        for (const line of content.split("\n")) {
          const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
          if (m && process.env[m[1]] === undefined) {
            process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
          }
        }
      } catch {}
    }
  } catch {}
}

export async function query(client: any): Promise<Backtest | null> {
  try {
    const candidatesRes = await client
      .select({ run: true, section: true, commit: true, published: true, body: true })
      .from(Results)
      .where(eq("section", "headline"))
      .ownedBy(PUBLISHER)
      .orderBy(desc("published"))
      .limit(5)
      .fetch();

    const runs = (candidatesRes?.entities ?? [])
      .map((e: any) => e.run?.value)
      .filter((r: any): r is string => typeof r === "string");

    const uniqueRuns: string[] = Array.from(new Set<string>(runs));

    for (const run of uniqueRuns) {
      const [resultsRes, crashRes, yearRes] = await Promise.all([
        client
          .select({ run: true, section: true, commit: true, published: true, body: true })
          .from(Results)
          .where(eq("run", run))
          .ownedBy(PUBLISHER)
          .limit(100)
          .fetch(),
        client
          .select({
            run: true,
            event: true,
            scenario: true,
            lp_loss_usd: true,
            lp_loss_pct: true,
            liquidations: true,
            eth_1h: true,
            btc_1h: true,
          })
          .from(Crash)
          .where(eq("run", run))
          .ownedBy(PUBLISHER)
          .limit(100)
          .fetch(),
        client
          .select({
            run: true,
            year: true,
            apy: true,
            volume_x: true,
            util: true,
            win: true,
            bad_debt_usd: true,
          })
          .from(Year)
          .where(eq("run", run))
          .ownedBy(PUBLISHER)
          .limit(100)
          .fetch(),
      ]);

      const sectionRows = (resultsRes?.entities ?? []).map((e: any) => ({
        section: String(e.section?.value),
        commit: String(e.commit?.value),
        published: Number(e.published?.value),
        body: toBytes(e.body?.value),
      }));

      const crashRows: CrashRow[] = (crashRes?.entities ?? []).map((e: any) => ({
        event: String(e.event?.value),
        scenario: String(e.scenario?.value) as (typeof SCENARIOS)[number],
        lp_loss_usd: Number(e.lp_loss_usd?.value),
        lp_loss_pct: Number(e.lp_loss_pct?.value),
        liquidations: Number(e.liquidations?.value),
        eth_1h: Number(e.eth_1h?.value),
        btc_1h: Number(e.btc_1h?.value),
      }));

      const yearRows: YearRow[] = (yearRes?.entities ?? []).map((e: any) => ({
        year: String(e.year?.value),
        apy: Number(e.apy?.value),
        volume_x: Number(e.volume_x?.value),
        util: Number(e.util?.value),
        win: Number(e.win?.value),
        bad_debt_usd: Number(e.bad_debt_usd?.value),
      }));

      const assembled = assembleBacktest(run, sectionRows, crashRows, yearRows);
      if (assembled) {
        return assembled;
      }
    }

    return null;
  } catch (err) {
    console.error("Arkiv query error:", err);
    return null;
  }
}

export async function getBacktest(): Promise<Backtest | null> {
  try {
    ensureEnv();
    const chain = rabdi({ accessKey: process.env.ARKIV_ACCESS_KEY ?? "" });
    const client = createPublicClient({ chain, transport: http() });
    return await query(client);
  } catch (err) {
    console.error("getBacktest failed:", err);
    return null;
  }
}



