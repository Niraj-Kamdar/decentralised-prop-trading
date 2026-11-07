import test from "node:test";
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import {
  assembleBacktest,
  CrashRow,
  decodeSection,
  YearRow,
} from "./backtest";
import { query } from "./read";
import { PUBLISHER, SCENARIOS, SECTIONS } from "./schema";

test("decodeSection round-trips", () => {
  const data = { a: 1 };
  const compressed = gzipSync(JSON.stringify(data));
  const decoded = decodeSection(compressed);
  assert.deepEqual(decoded, data);
});

function makeDummyCrashes(count = 21): CrashRow[] {
  return Array.from({ length: count }, (_, i) => ({
    event: `crash_${Math.floor(i / 3)}`,
    scenario: SCENARIOS[i % SCENARIOS.length],
    lp_loss_usd: 0,
    lp_loss_pct: 0,
    liquidations: 100,
    eth_1h: -0.15,
    btc_1h: -0.1,
  }));
}

function makeDummyYears(count = 7): YearRow[] {
  return Array.from({ length: count }, (_, i) => ({
    year: `${2019 + i}`,
    apy: 0.15,
    volume_x: 50,
    util: 0.4,
    win: 0.55,
    bad_debt_usd: 0,
  }));
}

test("assembleBacktest complete run", () => {
  const sectionRows = SECTIONS.map((section) => ({
    section,
    commit: "5847faa",
    published: 1794009044,
    body: gzipSync(
      JSON.stringify(section === "headline" ? { apy: 0.1246 } : { ok: true })
    ),
  }));

  const crashes = makeDummyCrashes(21);
  const years = makeDummyYears(7);

  const result = assembleBacktest(
    "5847faa@2026-11-06T23:50:44+00:00",
    sectionRows,
    crashes,
    years
  );

  assert.notEqual(result, null);
  assert.equal(result?.sections.headline.apy, 0.1246);
  assert.equal(result?.crashes.length, 21);
  assert.equal(result?.published, 1794009044);
});

test("assembleBacktest partial run", () => {
  const sectionRows = SECTIONS.map((section) => ({
    section,
    commit: "5847faa",
    published: 1794009044,
    body: gzipSync(JSON.stringify({ ok: true })),
  }));

  const crashes = makeDummyCrashes(21);
  const years = makeDummyYears(7);

  // Missing one section (6 sections)
  assert.equal(
    assembleBacktest(
      "run-1",
      sectionRows.slice(0, 6),
      crashes,
      years
    ),
    null
  );

  // 20 crash rows
  assert.equal(
    assembleBacktest(
      "run-1",
      sectionRows,
      makeDummyCrashes(20),
      years
    ),
    null
  );

  // 6 year rows
  assert.equal(
    assembleBacktest(
      "run-1",
      sectionRows,
      crashes,
      makeDummyYears(6)
    ),
    null
  );
});

test("assembleBacktest ignores unknown sections", () => {
  const sectionRows = [
    ...SECTIONS.map((section) => ({
      section,
      commit: "5847faa",
      published: 1794009044,
      body: gzipSync(
        JSON.stringify(section === "headline" ? { apy: 0.1246 } : { ok: true })
      ),
    })),
    {
      section: "junk",
      commit: "5847faa",
      published: 1794009044,
      body: gzipSync(JSON.stringify({ garbage: true })),
    },
  ];

  const result = assembleBacktest(
    "5847faa@2026-11-06T23:50:44+00:00",
    sectionRows,
    makeDummyCrashes(21),
    makeDummyYears(7)
  );

  assert.notEqual(result, null);
  assert.equal(result?.sections.headline.apy, 0.1246);
  assert.equal((result?.sections as any).junk, undefined);
});

test("every query is owner-filtered", async () => {
  const recordedOwners: string[] = [];

  const createQueryChain = () => {
    const chain: any = {
      from: () => chain,
      where: () => chain,
      ownedBy: (owner: string) => {
        recordedOwners.push(owner);
        return chain;
      },
      orderBy: () => chain,
      limit: () => chain,
      fetch: async () => {
        return {
          entities: [
            {
              run: { value: "test-run" },
              section: { value: "headline" },
              commit: { value: "commit1" },
              published: { value: 1794009044n },
              body: { value: "0x" },
              event: { value: "ev" },
              scenario: { value: "base" },
              lp_loss_usd: { value: "0" },
              lp_loss_pct: { value: "0" },
              liquidations: { value: 10n },
              eth_1h: { value: "-0.1" },
              btc_1h: { value: "-0.1" },
              year: { value: "2020" },
              apy: { value: "0.1" },
              volume_x: { value: "10" },
              util: { value: "0.5" },
              win: { value: "0.5" },
              bad_debt_usd: { value: "0" },
            },
          ],
        };
      },
    };
    return chain;
  };

  const fakeClient = {
    select: () => createQueryChain(),
  };

  await query(fakeClient);

  assert.ok(recordedOwners.length >= 4, "should have recorded at least 4 queries (1 candidates + 3 details)");
  for (const owner of recordedOwners) {
    assert.equal(owner, PUBLISHER);
  }
});


test("assembleBacktest reads an optional section when present", () => {
  const sectionRows = [...SECTIONS, "lp_equilibrium"].map((section) => ({
    section,
    commit: "bf3cdb9",
    published: 1794009044,
    body: gzipSync(JSON.stringify(section === "lp_equilibrium" ? { calibrated: { "0.055": { apy: { mean: 0.102 } } } } : { ok: true })),
  }));
  const result = assembleBacktest("bf3cdb9@x", sectionRows, makeDummyCrashes(21), makeDummyYears(7));
  assert.equal(result?.sections.lp_equilibrium.calibrated["0.055"].apy.mean, 0.102);
});
