# How we use Arkiv

## Pipeline
```
sim (Python, Docker image with frozen data) ──► results.json + positions.json.gz
        │
        ▼  frontend/scripts/publish-arkiv.ts  (@arkiv-network/sdk, executeBatch, 3 txs)
Arkiv Rabdi: fulcrum.results / fulcrum.crash / fulcrum.year / fulcrum.dataset
        │  owned by 0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d, expire after 180 days
        ▼  reads: newest run, filtered by owner
landing page · /backtest page · remote simulator agents
```

## Do the filters, ownership and expiry fit the app?

| Arkiv feature | What we do with it | Why it fits |
|---|---|---|
| **Indexed filters** | `fulcrum.crash` indexes `scenario`, `event`, `lp_loss_usd`; `fulcrum.year` indexes `year`, `apy`. | Our claims *are* filters: "no LP loss in any crash" is `scenario = "base" AND lp_loss_usd > 0` returning nothing. Everything else (liquidation counts, price moves, blobs) is stored but not indexed, so we don't pay for indexes nobody queries. |
| **Owner** | Every entity is owned by one publisher wallet; readers always add `ownedBy(publisher)`. | Anyone can write a `fulcrum.crash` entity, but only ours count. Owner-filtering is how a reader knows a number came from Fulcrum and wasn't planted. |
| **Expiry** | 180 days per run. | A backtest is a snapshot of the code at one commit. New runs supersede old ones, and stale numbers should disappear instead of being quoted forever. |
| **Batched writes** | `executeBatch` packs 38 small entities into one tx; blob chunks go one per tx. | One run is one consistent snapshot: sections, crash rows and year rows land together under the same `run` id. |
| **Ordering** | Custom indexed `published` (u64) + `orderBy(desc("published"))`. | `$createdAt` can't be sorted on, so we carry our own timestamp to find "latest". |

## Does each feature change something users see?
- **Crash-safety badge on the landing page** ("$0 LP loss through 7 crashes"): it comes from `fulcrum.crash` rows, and links to the query that proves it. *(In progress.)*
- **Headline APY and the vault-value chart**: from the latest `fulcrum.results` `headline` section (5.07% APY, 2,497 daily points). *(Done, live on the `/backtest` page and the landing page.)*
- **Yearly APY table**: from `fulcrum.year`. *(Done, live on `/backtest` page.)*
- **Crash stress-test matrix & risk claim**: from `fulcrum.crash` across base, stress, and outage scenarios. *(Done, live on `/backtest` page.)*
- **Real-trader behavior and leverage distribution**: from the `real_traders` section on Arkiv. *(Done, live on `/backtest` page.)*
- **Remote simulator agents** read the same dataset, so their results match ours exactly.

Already verified end to end against Rabdi: publish (3 txs), then read back the newest headline (APY 5.07%, $0 bad debt), base-scenario crash rows with loss > $0 (none), and stress-scenario crash rows with loss > $0 (none either). Exact query: [README](README.md#one-query-you-can-run).
