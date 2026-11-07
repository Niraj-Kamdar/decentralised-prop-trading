# Why Arkiv

## What users would lose with Postgres
1. **Proof of who said it.** In Postgres, "5.07% APY, $0 LP loss in 7 crashes" is a row we could edit at any time. On Arkiv each number is an entity signed by our publisher wallet. Only that wallet can change it, and every change is a transaction anyone can see. LPs deciding where to put money can check the claim isn't being quietly rewritten.
2. **Querying without asking us.** Anyone can run `scenario = "stress_outage_30m" AND lp_loss_usd > 0` against the network with no API key from us, no backend of ours and no trust in our server. With Postgres, users only see what our API chooses to expose.
3. **One source for every reader.** The landing page, the Streamlit explorer and remote simulator agents all read the same entities, so the numbers can't drift between our site, our deck and our analysis. With Postgres we'd have to run and secure a server just to serve 75 KiB of JSON.
4. **Snapshots that expire on their own.** Old backtest runs drop off at their expiry, so superseded numbers don't linger. In Postgres that's a cron job and a retention policy we'd have to remember to write.

## What we kept off Arkiv, and why
| Data | Where it lives | Why not Arkiv |
|---|---|---|
| Binance 1-minute prices (2020-2026, ~110 MB) | `data.binance.vision` (the source) + baked into `ghcr.io/niraj-kamdar/fulcrum-sim` | Already public at the source. ~900+ entities at the 128 KiB cap, re-hosting adds no trust, and nobody queries individual minutes. |
| Raw Hyperliquid fills (48 MB) | Docker image | Only the simulator needs them; the derived positions (137 KiB) are what people explore, and those *are* on Arkiv. |
| Live protocol state (vault, positions, insurance) | Our contracts on Base | Arkiv is a data layer, not where funds settle; positions must live where the money is. |
| Keys and secrets | `.env`, never committed | Obviously. |
| The simulator itself | GitHub + GHCR | Code, not data. The `commit` attribute on every entity links each result to the exact code that produced it. |
