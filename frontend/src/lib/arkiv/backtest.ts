import { gunzipSync } from "node:zlib";
import { OPTIONAL_SECTIONS, SCENARIOS, SECTIONS } from "./schema";

export type CrashRow = {
  event: string;
  scenario: (typeof SCENARIOS)[number];
  lp_loss_usd: number;
  lp_loss_pct: number;
  liquidations: number;
  eth_1h: number;
  btc_1h: number;
};

export type YearRow = {
  year: string;
  apy: number;
  volume_x: number;
  util: number;
  win: number;
  bad_debt_usd: number;
};

export type Backtest = {
  run: string;
  commit: string;
  published: number; // unix seconds
  sections: Record<(typeof SECTIONS)[number], any> & Partial<Record<(typeof OPTIONAL_SECTIONS)[number], any>>;
  crashes: CrashRow[];
  years: YearRow[];
};

export function decodeSection(body: Uint8Array): unknown {
  const uncompressed = gunzipSync(body);
  return JSON.parse(uncompressed.toString("utf8"));
}

export function assembleBacktest(
  run: string,
  sectionRows: { section: string; commit: string; published: number; body: Uint8Array }[],
  crashes: CrashRow[],
  years: YearRow[]
): Backtest | null {
  if (crashes.length !== 21 || years.length !== 7) {
    return null;
  }

  const sectionsMap = new Map<string, { commit: string; published: number; body: Uint8Array }>();
  for (const row of sectionRows) {
    if ([...SECTIONS, ...OPTIONAL_SECTIONS].includes(row.section as never)) {
      if (!sectionsMap.has(row.section)) {
        sectionsMap.set(row.section, row);
      }
    }
  }

  if (SECTIONS.some((name) => !sectionsMap.has(name))) {
    return null;
  }

  const sections = {} as Backtest["sections"];
  for (const name of SECTIONS) {
    const row = sectionsMap.get(name);
    if (!row) return null;
    try {
      sections[name] = decodeSection(row.body);
    } catch {
      return null;
    }
  }

  for (const name of OPTIONAL_SECTIONS) {
    const row = sectionsMap.get(name);
    if (row) {
      try {
        sections[name] = decodeSection(row.body);
      } catch {
        /* optional: a bad optional section never hides the required ones */
      }
    }
  }

  const primaryRow = sectionsMap.get("meta") ?? sectionsMap.get(SECTIONS[0])!;

  return {
    run,
    commit: primaryRow.commit,
    published: primaryRow.published,
    sections,
    crashes,
    years,
  };
}
