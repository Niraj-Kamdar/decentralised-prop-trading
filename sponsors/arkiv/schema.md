# Schema

All entities are owned by the publisher wallet **`0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d`**, written with `@arkiv-network/sdk` named schemas, so each carries the indexed `arkiv.schema` tag. Every entity from one simulator run shares a `run` id `<git commit>@<generated UTC>`, e.g. `df74b20@2026-11-07T01:03:27+00:00`.

**Expiry: 180 days** (`ExpirationTime.fromDays(180)`, near the 182.5-day maximum). A run is a snapshot of the simulator at one commit. Re-publishing writes a new run, readers always take the newest, and old runs expire on their own instead of piling up. No creation flags (not readonly), so the owner can extend a run that's still current.

Source: [`frontend/scripts/publish-arkiv.ts`](../../frontend/scripts/publish-arkiv.ts).

## `fulcrum.results`: one entity per section of `results.json`
| Field | Type | Indexed | Meaning |
|---|---|---|---|
| `run` | str | yes | run id |
| `section` | str | yes | `meta`, `example`, `headline`, `crashes`, `years`, `money_map`, `real_traders` |
| `published` | u64 | yes | unix seconds the run was generated; readers `orderBy(desc("published"))` to get the latest |
| `commit` | str | no | simulator commit |
| `body` | bytes | no | gzipped JSON of that section (largest: `headline`, 21 KiB, includes 2,497 days of vault NAV) |

**Query:** `section = "headline"`, `ownedBy(publisher)`, newest `published` first, limit 1.

## `fulcrum.crash`: one row per historical crash × stress scenario (7 × 3 = 21 per run)
| Field | Type | Indexed | Meaning |
|---|---|---|---|
| `run` | str | yes | run id |
| `event` | str | yes | `covid`, `may-21`, `luna`, `ftx`, `yen-carry`, `tariffs`, `oct-10` |
| `scenario` | str | yes | `base`, `stress` (all 10x, $1M pool depth), `stress_outage_30m` (+ 30-min keeper outage at the steepest hour) |
| `lp_loss_usd` | dec | yes | LP bad debt on a $1M vault, after insurance |
| `lp_loss_pct` | dec | no | same, as a fraction of TVL |
| `liquidations` | u64 | no | positions liquidated in the window |
| `eth_1h`, `btc_1h` | dec | no | worst 1-hour price move in the window |

**Query:** `scenario = X AND lp_loss_usd > 0`. That's the risk claim, as a filter.

## `fulcrum.year`: one row per calendar year (7 per run)
| Field | Type | Indexed | Meaning |
|---|---|---|---|
| `run` | str | yes | run id |
| `year` | str | yes | `2020` … `2025`, `2026 YTD` |
| `apy` | dec | yes | median LP APY across trader populations |
| `volume_x` | dec | no | trading volume as × vault TVL per year |
| `util` | dec | no | average utilisation |
| `win` | dec | no | share of positions closed in profit |
| `bad_debt_usd` | dec | no | LP bad debt that year |

**Query:** `apy < 0.10` finds the years LPs earned under 10%.

## `fulcrum.dataset`: the frozen real-trader sample, chunked
| Field | Type | Indexed | Meaning |
|---|---|---|---|
| `run` | str | yes | run id |
| `name` | str | yes | `hyperliquid-positions` |
| `part` | u64 | yes | chunk index |
| `parts` | u64 | no | number of chunks |
| `body` | bytes | no | slice of `positions.json.gz` (≤ 96 KiB). Concatenate parts in order, then gunzip. |

The dataset is 7,036 ETH/BTC long positions rebuilt from 600 random Hyperliquid accounts (180 days), with entry time, hold, size, PnL, fees, liquidation flag and an anonymised user index. It's 137 KiB gzipped, so 2 entities.
