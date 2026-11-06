# Fulcrum on Arkiv

Fulcrum is a spot-funded leverage protocol: LPs lend USDC to a vault, traders borrow it to go long ETH/BTC at 5x or 10x. Before an LP deposits, they need two answers: *will I lose money in a crash?* and *what will I earn?*

We answer both with a minute-by-minute backtest (6.8 years of Binance prices and 6,967 real Hyperliquid trades), and **publish the results to Arkiv**. Every risk and yield claim we show is an Arkiv entity, signed by our publisher wallet, that anyone can query.

| File | Criterion |
|---|---|
| [schema.md](schema.md) | Entities, queried fields, owners, expiry |
| [how-you-use-arkiv.md](how-you-use-arkiv.md) | How you use Arkiv |
| [why-arkiv.md](why-arkiv.md) | Why Arkiv |
| [reach.md](reach.md) | Reach |
| [friction.md](friction.md) | Arkiv feedback |

## Publisher wallet

All entities are written by **`0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d`** on the Rabdi testnet (chain id 7794095).

First publish, run `5847faa@2026-11-06T23:50:44+00:00`:

| tx | contents |
|---|---|
| `0x7620f7df6035840da0075e8e978279e988c3689056a3c913ebd891451c96dbc9` | 35 entities: 7 result sections, 21 crash rows, 7 yearly-APY rows |
| `0x226969fe95c3472d4a8c84ffc188abb3355e0d833cd59e723575869e7266eaea` | trader dataset, part 1/2 |
| `0x0ae2084d23a97f67a8ba9d2e372d13f2e1a9db5c63de80576ee703a16995d04d` | trader dataset, part 2/2 |

Explorer: https://rabdi.explorer.arkiv.network

## One query you can run

> "Did LPs lose money in any historical crash, at our default parameters?"

```ts
// npm i @arkiv-network/sdk viem   ·   save as q.mts   ·   npx tsx q.mts
import { createPublicClient } from "@arkiv-network/sdk";
import { rabdi } from "@arkiv-network/sdk/chains";
import { and, eq, gt } from "@arkiv-network/sdk/query";
import { dec, defineSchema, str, u64 } from "@arkiv-network/sdk/schema";
import { http } from "viem";

const Crash = defineSchema("fulcrum.crash", {
  run: str().indexed(), event: str().indexed(), scenario: str().indexed(), lp_loss_usd: dec().indexed(),
  lp_loss_pct: dec(), liquidations: u64(), eth_1h: dec(), btc_1h: dec(),
});
const pub = createPublicClient({ chain: rabdi({ accessKey: process.env.ARKIV_ACCESS_KEY ?? "" }), transport: http() });
const q = (scenario: string) => pub.select({ event: true, lp_loss_usd: true }).from(Crash)
  .where(and(eq("scenario", scenario), gt("lp_loss_usd", dec("0"))))
  .ownedBy("0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d").limit(100).fetch();

console.log("base:", (await q("base")).entities);                      // [] -> no LP loss in any of 7 crashes
console.log("stress + 30-min outage:", (await q("stress_outage_30m")).entities); // covid ~$4.9k, oct-10 ~$2.6k on a $1M vault
```

Output on the first publish: `base: []`, and `stress + 30-min outage:` COVID $4,933 and Oct-10 $2,623.

## Code
- Writer: [`frontend/scripts/publish-arkiv.ts`](../../frontend/scripts/publish-arkiv.ts) (`@arkiv-network/sdk` 1.0.1)
- Data producer: [`sim/export.py`](../../sim/export.py), reproducible offline via `ghcr.io/niraj-kamdar/fulcrum-sim`
- Simulator: [`sim/`](../../sim/), notebook [`sim/fulcrum_backtest.ipynb`](../../sim/fulcrum_backtest.ipynb)
