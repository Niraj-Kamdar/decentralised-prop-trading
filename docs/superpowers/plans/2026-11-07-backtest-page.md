# Backtest Page (read from Arkiv) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/backtest` page to the existing Next.js frontend. It shows the latest simulator run (headline APY, vault value, crash table, yearly APY, real-trader stats) read live from Arkiv. This replaces the planned Streamlit app and gives the Arkiv track its required user-facing read.

**Architecture:** A server-only module `src/lib/arkiv/` finds the newest complete run from the publisher wallet, decodes the gzipped section bodies, and returns one typed `Backtest` object. `/backtest` is a server component with `revalidate = 3600` (ISR), so the access key never reaches the browser and Arkiv is hit at most once an hour. Charts are plain HTML/CSS bars, except the vault-value line, which uses the `lightweight-charts` already installed. Schemas move out of `scripts/publish-arkiv.ts` into a shared file, so writer and reader can't drift.

**Tech Stack:** Next.js 15 app router, React 19, Tailwind 3, `@arkiv-network/sdk` 1.0.1, `lightweight-charts` 4.2.3, `node:test` run through `tsx` (no new test dependency).

**Spec:** this conversation's decision ("skip Streamlit, `/backtest` page in the existing frontend"), plus `sponsors/arkiv/schema.md` (entity shapes) and `sim/export.py` (`results.json` section shapes).

## Global Constraints

- **Work in a new branch in a git worktree. Never in the main checkout.**
  ```bash
  cd /Volumes/Lexar/Home/Documents/ETHGlobal/decentralised-prop-trading
  git worktree add .worktrees/backtest-page -b feat/backtest-page feat/backtest-sim
  cd .worktrees/backtest-page/frontend && npm ci
  cp ../../../frontend/.env ./.env   # gitignored; ARKIV_ACCESS_KEY lives here
  ```
  - `.worktrees/` is already ignored through `.git/info/exclude`.
  - The base is `feat/backtest-sim`, because it has the SDK dependency and the publish script.
  - All paths below are relative to `.worktrees/backtest-page/`.
- **Publisher address.** Hard-code it once as `PUBLISHER = "0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d"`. Every read uses `.ownedBy(PUBLISHER)`.
- **Chain:** `rabdi({ accessKey: process.env.ARKIV_ACCESS_KEY ?? "" })` with `http()` transport, the same as `scripts/publish-arkiv.ts`.
- **Secrets:**
  - `ARKIV_ACCESS_KEY` is read only in server code: files that start with `import "server-only"`.
  - Never use a `NEXT_PUBLIC_` prefix for it.
  - Never print env values.
- **Dependencies:**
  - Move `@arkiv-network/sdk` from `devDependencies` to `dependencies`, pinned to the exact version `1.0.1`.
  - Add no new dependencies.
  - The npm `before` config blocks fresh installs. `npm ci` from the existing lockfile is fine.
- **Copy rules** (match the landing page): plain words, no jargon in headings, and numbers formatted with the existing `src/lib/format.ts` helpers where they fit.
- **Git** (from the user's CLAUDE.md):
  - Conventional atomic commits with domain scopes: `feat(backtest):`, `refactor(arkiv):`, `docs(arkiv):`.
  - `git add` specific files only.
  - Never commit `.claude/`, `CLAUDE.md`, `todo/`, `.env`.
  - No AI mentions and no Co-Authored-By lines in commits or PRs.
  - Don't push until the user asks.
- **Don't touch the landing redesign.** `feat/landing-redesign` is a separate branch. On `src/app/page.tsx`, this plan only adds one nav link (Task 5).

## Review Focus

1. **Arkiv returns nothing: runs expire after 180 days, or the node is down.** `/backtest` must render an "unavailable" panel with the verify query, not a 500 and not a failed `next build`. Pinned by `getBacktest` returning `null` (Task 2 test) and by the page's null branch (Task 4).
2. **A partial run: publish stopped after transaction 1 of 3.** Sections, crash rows and year rows land atomically in transaction 1. The dataset parts are separate. A run is complete when it has 7 sections, 21 crash rows and 7 year rows; the dataset is optional. Pinned by `assembleBacktest` tests (Task 2).
3. **Someone else writes `fulcrum.*` entities.** Every query carries `ownedBy(PUBLISHER)`. Pinned by a test asserting the query builder calls `ownedBy` with `PUBLISHER` (Task 2).
4. **Float noise shown as a loss.** `lp_loss_usd` can be something like `1e-9`. Anything under $0.50 must render as `$0`, so the "$0 LP loss" claim stays readable. Pinned by a `usd0` test (Task 3).
5. **Phone width.** The 7×3 crash table and the years table must scroll inside their container. There must be no page-wide horizontal scroll at 375px. Checked in Task 6's browser pass.

---

### Task 1: Share Arkiv schemas between writer and reader

**Files:**
- Create: `frontend/src/lib/arkiv/schema.ts`
- Modify: `frontend/scripts/publish-arkiv.ts` (delete the 4 `defineSchema` blocks; import them instead)
- Modify: `frontend/package.json` (move SDK to `dependencies`; add `"test": "tsx --test src/**/*.test.ts"`)

**Interfaces:**
- Produces:
  - `Results`, `Crash`, `Year`, `Dataset`: the exact schema objects now in `publish-arkiv.ts`.
  - `PUBLISHER: \`0x${string}\``.
  - `SECTIONS = ["meta","example","headline","crashes","years","money_map","real_traders"] as const`.
  - `SCENARIOS = ["base","stress","stress_outage_30m"] as const`.

- [ ] **Step 1:** Move the schemas into `schema.ts`, unchanged. Add the constants above. Don't put `server-only` here, because the publish script imports this file.
- [ ] **Step 2:** In `publish-arkiv.ts`, `import { Results, Crash, Year, Dataset } from "../src/lib/arkiv/schema";`. Its `scripts/tsconfig.json` may need `"include"` to cover that file.
- [ ] **Step 3: Verify.** Run `npm run typecheck && npx tsx scripts/publish-arkiv.ts ../sim/results.json --dry-run`.
  - If `results.json` is absent, regenerate it first with `docker run --rm -v "$PWD/../sim:/out" ghcr.io/niraj-kamdar/fulcrum-sim`.
  - Expected output: the same section sizes as before, `21 crash rows, 7 year rows, 2 dataset parts`, `3 transactions`.
- [ ] **Step 4: Commit.**
  ```bash
  git add frontend/src/lib/arkiv/schema.ts frontend/scripts/publish-arkiv.ts frontend/scripts/tsconfig.json frontend/package.json frontend/package-lock.json
  git commit -m "refactor(arkiv): share entity schemas between publisher and readers"
  ```

### Task 2: Server-side reader `getBacktest()`

**Files:**
- Create: `frontend/src/lib/arkiv/backtest.ts`. Holds pure types, the `assembleBacktest` function and decoding. No network calls.
- Create: `frontend/src/lib/arkiv/read.ts`. Starts with `import "server-only"`. Contains the network calls.
- Test: `frontend/src/lib/arkiv/backtest.test.ts`

**Interfaces:**
- Consumes: Task 1 exports.
- Produces (`backtest.ts`):
  ```ts
  export type CrashRow = { event: string; scenario: (typeof SCENARIOS)[number]; lp_loss_usd: number; lp_loss_pct: number; liquidations: number; eth_1h: number; btc_1h: number };
  export type YearRow = { year: string; apy: number; volume_x: number; util: number; win: number; bad_debt_usd: number };
  export type Backtest = {
    run: string; commit: string; published: number;           // unix seconds
    sections: Record<(typeof SECTIONS)[number], any>;          // decoded JSON per section (shapes: sim/export.py)
    crashes: CrashRow[]; years: YearRow[];
  };
  export function decodeSection(body: Uint8Array): unknown;    // gunzipSync + JSON.parse
  export function assembleBacktest(run: string, sectionRows: {section: string; commit: string; published: number; body: Uint8Array}[], crashes: CrashRow[], years: YearRow[]): Backtest | null;  // null unless 7 sections, 21 crashes, 7 years
  ```
- Produces (`read.ts`): `export async function getBacktest(): Promise<Backtest | null>`. It never throws: it logs with `console.error` and returns `null`.

- [ ] **Step 1: Spike the wire format.** Write a throwaway scratch script, not committed. Fetch 1 `Results` row with `{ run: true, body: true, published: true }`. Print `typeof row.body.value` and its constructor name, and `typeof row.published.value`.
  - `bytes()` may come back as a `Uint8Array` or as a hex string, and `u64` as `bigint`.
  - Write the finding as a one-line comment in `read.ts`, and convert in `read.ts` only, so `backtest.ts` stays pure.
- [ ] **Step 2: Write the failing tests** in `backtest.test.ts` (`node:test` + `node:assert/strict`). Build fixtures with `gzipSync(JSON.stringify(x))`.
  - `decodeSection round-trips`: `decodeSection(gzipSync('{"a":1}'))` deep-equals `{a:1}`.
  - `assembleBacktest complete run`: 7 section rows, 21 crash rows and 7 year rows give a non-null result.
    - `result.sections.headline.apy === 0.1246`;
    - `result.crashes.length === 21`;
    - `result.published === 1794009044`.
  - `assembleBacktest partial run`: 6 sections give `null`; 20 crash rows give `null`.
  - `assembleBacktest ignores unknown sections`: an extra `section: "junk"` row is dropped, and the run is still complete.
- [ ] **Step 3:** Run `npm test`. Expected: FAIL, because the module isn't found.
- [ ] **Step 4: Implement `backtest.ts`.**
- [ ] **Step 5: Implement `read.ts`.**
  - **Find the run.** Query `Results` with `section = "headline"`, `ownedBy(PUBLISHER)`, `orderBy(desc("published"))`, `limit(5)`.
  - **Load each candidate** in that order. For one run, fetch these three in parallel, each `where eq("run", run)` plus `ownedBy(PUBLISHER)` and `limit(100)`:
    - all `Results` rows;
    - all `Crash` rows;
    - all `Year` rows.
  - **Return** the first candidate where `assembleBacktest` gives non-null.
  - **Export a `query()` helper** that takes the public client. That lets the test below inject a fake client.
- [ ] **Step 6: Add the owner test.** `every query is owner-filtered`: give the helper a fake client whose `select().from().where().ownedBy()…` chain records its calls. Assert every recorded `ownedBy` argument is `PUBLISHER`.
- [ ] **Step 7: Run tests and the live check.**
  - Run `npm test`. Expected: PASS.
  - Run the live check:
    ```bash
    npx tsx -e 'import("./src/lib/arkiv/read.ts").then(async m=>{const b=await m.getBacktest();console.log(b?.run,b?.sections.headline.apy,b?.crashes.filter(c=>c.scenario==="base"&&c.lp_loss_usd>0).length)})'
    ```
    The `server-only` import throws outside Next. Run with `--conditions=react-server`, or stub it only for this check.
  - Expected output: `5847faa@2026-11-06T23:50:44+00:00 0.1246… 0`.
- [ ] **Step 8: Commit.** `feat(arkiv): read the latest complete backtest run from Arkiv`.

### Task 3: Display helpers

**Files:**
- Modify: `frontend/src/lib/format.ts`. Add to it; reuse whatever already exists there first.
- Test: `frontend/src/lib/format.test.ts`

**Interfaces:**
- Produces:
  - `usd0(x: number): string`: whole dollars. Below $0.50 shows `"$0"`, and `4932.63` shows `"$4,933"`.
  - `pct(x: number, digits = 1): string`: `0.1246` shows `"12.5%"`.
  - `histogram(values: number[], edges: number[]): number[]`: counts for each `[edges[i], edges[i+1])`. The last bin also takes values ≥ the last edge.

- [ ] **Step 1: Write the failing tests.**
  - `usd0(1e-9) === "$0"`, `usd0(0.49) === "$0"`, `usd0(4932.63) === "$4,933"`;
  - `pct(0.1246) === "12.5%"`;
  - `histogram([1,3,5,10,20,50],[1,3,5,10,20]) deepEqual [1,1,1,1,2]`.
- [ ] **Step 2:** Run `npm test`. Expected: FAIL.
- [ ] **Step 3:** Implement. If `format.ts` already has an equivalent, use it and drop the duplicate test.
- [ ] **Step 4:** Run `npm test`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(backtest): add money, percent and histogram formatters`.

### Task 4: `/backtest` page

**Files:**
- Create: `frontend/src/app/backtest/page.tsx`. A server component with `export const revalidate = 3600` and `metadata` (title "Backtest — Fulcrum").
- Create: `frontend/src/components/backtest/NavChart.tsx`. A `"use client"` `lightweight-charts` line. Copy the setup and theme from `components/trade/PriceChart.tsx`.
- Create: `frontend/src/components/backtest/Bars.tsx`. A server component: horizontal CSS bars with a label, value text and a `title` tooltip.

**Interfaces:**
- Consumes:
  - `getBacktest()` (Task 2);
  - `usd0`, `pct`, `histogram` (Task 3);
  - `Stat` and `Row` from `components/ui.tsx`;
  - `PUBLISHER` (Task 1).
- Produces:
  - `NavChart({ start: string; nav: number[]; insurance: number[] })`. Point `i` is day `start + i`, from `headline.daily.nav` and `headline.daily.insurance`.
  - `Bars({ rows: { label: string; value: number; text: string }[]; max?: number })`.

Page sections, top to bottom. All numbers come from `Backtest`. Field paths follow `sim/export.py`:

1. **Hero stats:** 4 `Stat` tiles on a `$1M` vault, `headline.start`–`headline.end`:
   - LP APY: `pct(sections.headline.apy)`;
   - LP bad debt: `usd0(sections.headline.bad_debt)`;
   - positions: `sections.headline.positions`;
   - insurance at end: the last element of `daily.insurance`.
2. **Vault value:** `NavChart`. Its caption explains that the insurance reserve is drawn as a second line.
3. **Crashes:** a table with one row per event. Columns:
   - worst ETH 1h move;
   - worst BTC 1h move;
   - LP loss in each of `base`, `stress`, `stress_outage_30m` (header text: "Normal", "All 10x, thin pool", "+ 30-min keeper outage").

   Wrap it in `overflow-x-auto`. Above it, show a one-line claim computed from the rows, e.g. "No LP loss in any of 7 crashes at default settings". Don't hard-code it.
4. **By year:** a table built from the `years` rows: year, APY, volume ×TVL, utilisation, win rate, bad debt.
5. **Real traders:**
   - `Bars` of `real_traders.by_hold`: label `hold`, value `win_net`, text `pct(win_net)`;
   - a second `Bars` of `histogram(real_traders.open_long_leverage, [1,3,5,10,20])`, labels `1–3x … 20x+`;
   - one sentence from `real_traders.sample`: "N positions from M Hyperliquid accounts, median hold H h".
6. **Verify on Arkiv:** a box containing
   - the publisher address, linked to `https://rabdi.explorer.arkiv.network/address/${PUBLISHER}`;
   - `run`, `commit` and the published date;
   - the README query as a `<pre>` block, imported as a string constant (duplicating 15 lines is fine);
   - a link to `sponsors/arkiv/README.md` on GitHub.
7. **Null branch:** if `getBacktest()` returns `null`, render only a panel saying "Backtest data is temporarily unavailable from Arkiv", plus section 6. The page must still build and return 200.

- [ ] **Step 1:** Build `Bars.tsx` and `NavChart.tsx`.
- [ ] **Step 2:** Build `page.tsx` with sections 1–7.
- [ ] **Step 3: Verify the build.** Run `npm run typecheck && npm run build`.
  - Expected: success, and the build output lists `○ /backtest` with a `1h` revalidate.
- [ ] **Step 4: Verify the null branch.** Run `ARKIV_ACCESS_KEY=bogus npm run build`, or point the chain at a dead URL.
  - Expected: the build still succeeds. `npm start` then `curl -s localhost:3000/backtest | grep -c "temporarily unavailable"` prints `1`.
  - Rebuild normally afterwards.
- [ ] **Step 5: Commit.** `feat(backtest): add backtest page backed by Arkiv`.

### Task 5: Link it

**Files:**
- Modify: `frontend/src/app/page.tsx:74-76`. Add `<Link href="/backtest">Backtest</Link>` beside "How it works", with the same classes.
- Modify: `frontend/src/components/AppNav.tsx`. Add a "Backtest" item, matching the existing items.

- [ ] **Step 1:** Add both links.
- [ ] **Step 2: Verify.** Run `npm run build`. Both pages build.
- [ ] **Step 3: Commit.** `feat(backtest): link the backtest page from the landing page and app nav`.

### Task 6: Browser check + Arkiv docs

**Files:**
- Modify: `sponsors/arkiv/how-you-use-arkiv.md`:
  - replace "Streamlit" with "`/backtest` page";
  - change the "(In progress)" marks for the headline, crash and yearly items to done;
  - keep the landing-page items as in progress.
- Modify: `sponsors/arkiv/reach.md`. Change `TODO(team): Streamlit URL` to the `/backtest` path. Leave the other TODOs for the user.
- Modify: `sponsors/arkiv/README.md` (the code list). Add the reader `frontend/src/lib/arkiv/read.ts`.
- Modify: `sponsors/arkiv/friction.md`. Add the Task 2 Step 1 finding about the wire format, but only if it surprised us.

- [ ] **Step 1: Browser check.**
  - Run `npm run dev` and open `localhost:3000/backtest` in Chrome, at 1280px and at 375px width.
  - Check: no label collisions; the crash table scrolls inside its box; no page-wide horizontal scroll; the chart renders; the numbers match `results.json`.
  - Screenshot both widths for the user.
- [ ] **Step 2:** Update the docs as listed.
- [ ] **Step 3: Commit.** `docs(arkiv): point the Arkiv docs at the backtest page`.
- [ ] **Step 4: Hand back.**
  - Report the branch `feat/backtest-page`, its commits and the screenshots.
  - Don't push or open a PR until the user asks.
  - Deploy note for the user: the hosting env must set `ARKIV_ACCESS_KEY` as a **server** env var.

## Out of scope (add when asked)

- Parameter sliders: they need precomputed parameter grids published to Arkiv first.
- The `fulcrum.dataset` download or explorer: the page uses `real_traders` aggregates. Reassembling the 2 parts is a later route.
- `money_map` heatmap and the 10x worked example: both belong in the landing redesign, which will reuse `getBacktest()`.
