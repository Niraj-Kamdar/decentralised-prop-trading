/**
 * Publishes the backtest to Arkiv (Rabdi testnet) so the app, landing page and Streamlit read one signed source.
 *
 *   npx tsx scripts/publish-arkiv.ts ../sim/results.json [--dry-run]
 *
 * Reads ARKIV_PRIVATE_KEY and ARKIV_ACCESS_KEY from .env.local / .env. Writes, all tagged with one `run` id:
 *   fulcrum.results  one entity per results.json section (gzipped JSON body), indexed by run/section/published
 *   fulcrum.crash    one row per crash x scenario, LP loss indexed, so anyone can query the risk claim directly
 *   fulcrum.year     one row per calendar year, APY indexed
 *   fulcrum.dataset  the Hyperliquid positions sample (positions.json.gz next to results.json), in chunks
 * Readers take the newest run: select section rows ownedBy the publisher, orderBy desc("published").
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { createPublicClient, createWalletClient, ExpirationTime } from "@arkiv-network/sdk";
import { rabdi } from "@arkiv-network/sdk/chains";
import { and, desc, eq } from "@arkiv-network/sdk/query";
import { bytes, dec, defineSchema, str, u64 } from "@arkiv-network/sdk/schema";
import { http, isHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

for (const f of [".env.local", ".env"]) {
  try {
    for (const line of readFileSync(path.join(process.cwd(), f), "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {
    /* file absent */
  }
}

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

const CHUNK = 96 * 1024; // bytes per entity (cap 128 KiB) and per transaction, well under node tx-size limits
const EXPIRY = ExpirationTime.fromDays(180); // max lifetime is ~182.5 days; re-publish to refresh
const d = (x: number) => dec(Number(x).toFixed(6));

type Res = Record<string, any>;

function build(res: Res, positions: Buffer | null) {
  const run = `${res.meta.commit}@${res.meta.generated}`;
  const published = u64(Math.floor(Date.parse(res.meta.generated) / 1000));
  const sections = Object.entries(res).map(([section, v]) => ({
    schema: Results,
    values: { run, section, published, commit: String(res.meta.commit), body: gzipSync(JSON.stringify(v)) },
    expiration: EXPIRY,
  }));
  const crashes = Object.entries(res.crashes as Res).flatMap(([event, c]) =>
    ["base", "stress", "stress_outage_30m"].map((scenario) => ({
      schema: Crash,
      values: {
        run, event, scenario,
        lp_loss_usd: d(c[scenario].lp_loss), lp_loss_pct: d(c[scenario].lp_loss_pct),
        liquidations: u64(c[scenario].liquidations), eth_1h: d(c.eth_1h), btc_1h: d(c.btc_1h),
      },
      expiration: EXPIRY,
    })),
  );
  const years = Object.entries(res.years as Res).map(([year, y]) => ({
    schema: Year,
    values: {
      run, year, apy: d(y.apy), volume_x: d(y.volume), util: d(y.util), win: d(y.win), bad_debt_usd: d(y.bad_debt),
    },
    expiration: EXPIRY,
  }));
  const parts = positions ? Math.ceil(positions.length / CHUNK) : 0;
  const dataset = Array.from({ length: parts }, (_, i) => ({
    schema: Dataset,
    values: {
      run, name: "hyperliquid-positions", part: u64(i), parts: u64(parts),
      body: positions!.subarray(i * CHUNK, (i + 1) * CHUNK),
    },
    expiration: EXPIRY,
  }));
  // Batch so each transaction carries < CHUNK of blob bytes: small rows ride along with the sections.
  const batches: any[][] = [];
  let cur: any[] = [], size = 0;
  for (const c of [...sections, ...crashes, ...years, ...dataset]) {
    const b = (c.values as Res).body?.length ?? 0;
    if (cur.length && size + b > CHUNK) (batches.push(cur), (cur = []), (size = 0));
    cur.push(c);
    size += b;
  }
  if (cur.length) batches.push(cur);
  return { run, sections, crashes, years, dataset, batches };
}

async function main() {
  const file = process.argv.find((a) => a.endsWith(".json")) ?? "../sim/results.json";
  const dry = process.argv.includes("--dry-run");
  const res = JSON.parse(readFileSync(file, "utf8"));
  let positions: Buffer | null = null;
  try {
    positions = readFileSync(path.join(path.dirname(file), "positions.json.gz"));
  } catch {
    console.warn("no positions.json.gz next to results.json — publishing results only");
  }
  const p = build(res, positions);
  const kib = (n: number) => `${(n / 1024).toFixed(1)} KiB`;
  console.log(`run ${p.run}`);
  for (const s of p.sections) console.log(`  section ${s.values.section.padEnd(13)} ${kib(s.values.body.length)}`);
  console.log(`  ${p.crashes.length} crash rows, ${p.years.length} year rows, ${p.dataset.length} dataset parts` +
    (positions ? ` (${kib(positions.length)})` : ""));
  console.log(`  ${p.batches.length} transactions`);
  if (dry) return;

  const pk = process.env.ARKIV_PRIVATE_KEY;
  if (!pk || !isHex(pk)) throw new Error("Set ARKIV_PRIVATE_KEY in .env to a funded Rabdi account");
  const chain = rabdi({ accessKey: process.env.ARKIV_ACCESS_KEY ?? "" });
  const account = privateKeyToAccount(pk);
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = createWalletClient({ chain, transport: http(), account });
  console.log(`publisher ${account.address}`);

  for (const [i, creates] of p.batches.entries()) {
    const { txHash, createdEntities } = await wallet.executeBatch({ creates });
    console.log(`  tx ${i + 1}/${p.batches.length} ${txHash} (${createdEntities.length} entities)`);
  }

  // Read back what a consumer would: the newest headline from this publisher.
  const got = await pub
    .select({ run: true, body: true })
    .from(Results)
    .where(and(eq("section", "headline"), eq("run", p.run)))
    .ownedBy(account.address)
    .orderBy(desc("published"))
    .limit(1)
    .fetch();
  if (got.entities[0]?.run.value !== p.run) throw new Error("published run not found on read-back");
  console.log(`verified: headline for ${p.run} is queryable`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
