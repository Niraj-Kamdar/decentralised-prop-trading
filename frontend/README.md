# Fulcrum frontend

Next.js app for the protocol in this repo, on Base mainnet. Live at https://fulcrum-trade.vercel.app.

- **`/`**: landing page for traders and lenders: how it works, trader levels, a profit/loss calculator that uses the
  contract's settlement rules and level cuts, the crash backtest, FAQ and the **waitlist**.
- **`/backtest`**: the full backtest, read from Arkiv (see [sponsors/arkiv](../sponsors/arkiv/README.md)).
- **`/app`**: dashboard with wallet balance, trading PnL, lender value and earnings, pending payouts and protocol stats.
- **`/app/trade`**: ETH and BTC spot terminal (Uniswap v4). Live chart of the Chainlink price
  with liquidation lines, 5x/10x order ticket with pre-flight checks that mirror the contract's reverts and a v4
  Quoter estimate, and a positions table with close, add margin, TP/SL, auto-roll and history.
- **`/app/earn`**: lender vault. Deposit, the 30-day ERC-7540 exit queue (request, cancel, process, claim),
  stress-bonus deposits and tickets, utilisation and insurance.
- **`npm run keeper`**: a bot that liquidates, closes expired epochs, executes TP/SL and processes the lender queue.

Stack: Next.js 15 (App Router), wagmi 2 and viem 2, TanStack Query, Tailwind 3, lightweight-charts, Arkiv SDK for the
backtest, and Postgres (`postgres`) for the waitlist.

## Run locally

```bash
cd frontend
cp .env.example .env.local    # fill in contract addresses and DATABASE_URL
npm install
npm run dev                   # http://localhost:3000
npm run typecheck && npm test && npm run build
```

ABIs in `src/abi/` are generated from the Foundry build: run `npm run build` in the repo root, then `npm run abi` here.

## Configuration

Everything is in `.env.example`. The essentials:

| Variable | Notes |
|---|---|
| `NEXT_PUBLIC_POSITION_MANAGER`, `_LP_VAULT`, `_ORACLE`, `_INSURANCE` | Printed by `script/DeployBase.s.sol`. The oracle is `ChainlinkOracle`. |
| `NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_EXPLORER_URL` | Optional; default to `https://mainnet.base.org` and Basescan. |
| `NEXT_PUBLIC_V4_QUOTER`, `_WETH`, `_CBBTC` | Optional; default to the Base Uniswap V4Quoter, WETH and cbBTC. |
| `ARKIV_*` | Read access for the backtest page; write access only for `scripts/publish-arkiv.ts`. |
| `DATABASE_URL` | Postgres for the waitlist (Neon, Supabase, Vercel Postgres...). The table is created automatically (`db/schema.sql`). Without it, signups go to `.data/waitlist.json`, which is for local dev only. |
| `WAITLIST_ADMIN_TOKEN` | Enables CSV export: `curl -H "Authorization: Bearer $TOKEN" https://<host>/api/waitlist/export`. |

### How a trade is built

The app sends only `minAmountOut`: `PositionManager` builds the Uniswap v4 swap itself on the asset's pool and runs it
through the position's own `TraderProxy`. For opens, `minAmountOut` comes from a fresh V4Quoter quote minus your
slippage. On-chain, the fill must also be worth at least `notional × (1 − maxEntrySlippage)` at the Chainlink price.
For closes, the contract enforces `max(minAmountOut, mark × (1 − maxExitSlippage))` with the Chainlink mark. The
close dialog warns, before you sign, when the pool is below that floor.

## Launch checklist

1. **Deploy** with `script/DeployBase.s.sol` (`GOVERNANCE`, `GUARDIAN`, optional `IDLE_VAULT`). It deploys the
   Chainlink oracle, the v4 router, the vault, insurance and the PositionManager, sets risk params, asset caps and
   trader levels, and enables WETH and cbBTC on their Base v4 pools. Governance then calls `acceptOwnership()`.
2. **Seed the vault** by depositing on `/app/earn` (launch caps: $10k total, $100 per wallet). Optionally seed the
   insurance pool with `InsuranceReserve.donate`.
3. **Run the keeper**: `KEEPER_PRIVATE_KEY=0x... npm run keeper` (give it a little ETH for gas on Base). Without a
   keeper, nobody liquidates losing positions.
4. **Deploy the site** (Vercel, root directory `frontend/`) and set the contract addresses, `DATABASE_URL` and
   `WAITLIST_ADMIN_TOKEN`.

## Known limitations

- **Feed staleness.** If a Chainlink feed has not updated within an hour, priced actions for that asset revert until
  it does.
- **Fast moves.** Fills must land within 1% of the Chainlink price (2% for liquidations). In a fast move the pool can
  sit outside that band and closes revert until it comes back.
- **Chart history.** The chart is built from on-chain samples taken while the page is open; there is no backfill.
- **No indexer.** Positions, requests and tickets are found by scanning recent ids with Multicall3 (the last 2,000
  of each). Add an indexer on `PositionOpened` / `RedeemRequest` events before volume grows.
- **One pool per market.** Each asset trades on the single v4 pool configured in the oracle; there is no routing.
