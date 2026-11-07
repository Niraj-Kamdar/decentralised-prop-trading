import { bytes, dec, defineSchema, str, u64 } from "@arkiv-network/sdk/schema";

export const PUBLISHER = "0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d" as const;

export const SECTIONS = [
  "meta",
  "example",
  "headline",
  "crashes",
  "years",
  "money_map",
  "real_traders",
] as const;

// Read when present; runs published before these sections existed still load.
export const OPTIONAL_SECTIONS = ["lp_equilibrium"] as const;

export const SCENARIOS = ["base", "stress", "stress_outage_30m"] as const;

export const Results = defineSchema("fulcrum.results", {
  run: str().indexed(),
  section: str().indexed(),
  published: u64().indexed(),
  commit: str(),
  body: bytes(), // gzip(JSON)
});

export const Crash = defineSchema("fulcrum.crash", {
  run: str().indexed(),
  event: str().indexed(),
  scenario: str().indexed(),
  lp_loss_usd: dec().indexed(),
  lp_loss_pct: dec(),
  liquidations: u64(),
  eth_1h: dec(),
  btc_1h: dec(),
});

export const Year = defineSchema("fulcrum.year", {
  run: str().indexed(),
  year: str().indexed(),
  apy: dec().indexed(),
  volume_x: dec(),
  util: dec(),
  win: dec(),
  bad_debt_usd: dec(),
});

export const Dataset = defineSchema("fulcrum.dataset", {
  run: str().indexed(),
  name: str().indexed(),
  part: u64().indexed(),
  parts: u64(),
  body: bytes(), // one slice of a gzip file; concatenate parts in order
});
