# Reach

## Who it's for
- **LPs deciding whether to deposit.** Their first question is "can I lose money in a crash?". They can check our answer against signed entities instead of trusting a marketing page.
- **Traders** who want 5x/10x on real spot ETH/BTC without funding rates. The real-trader data shows our sweet spot is swing traders (multi-day holds), not scalpers. Median Hyperliquid hold is 1.8 h, and win rates go from 25% (< 10 min) to 56% (> 1 week).
- **Risk reviewers, auditors and other protocols** who want to rerun or extend the analysis. They get the same frozen trader dataset from Arkiv and the same price data from our Docker image.

## Would they use it?
The numbers are the product's pitch. Hackathon feedback was that people didn't understand what we're building until they saw a concrete example and its risk. The crash-safety and APY figures shown to LPs come straight from Arkiv.

## Can they try it today?
- **Query the results now:** run the [query in the README](README.md#one-query-you-can-run) against Rabdi (owner `0x8F24d5FF02c5FFaCDAa1741dC7a20d37f363f69d`).
- **Reproduce the numbers:** `docker run --rm -v "$PWD:/out" ghcr.io/niraj-kamdar/fulcrum-sim` writes the same `results.json` offline.
- **Explore:** the backtest notebook in [`sim/fulcrum_backtest.ipynb`](../../sim/fulcrum_backtest.ipynb). The `/backtest` page reads live from Arkiv. Links: `/backtest`, `TODO(team): landing URL`.

## Will we keep building after Mumbai?
`TODO(team): confirm plans.` Next on the roadmap:
- the protocol's Base mainnet MVP (PR #10);
- re-running the simulator on the deployed parameters, including trader levels and the Chainlink oracle (issue #12);
- publishing every new run to Arkiv so the public numbers always match the deployed contracts.
