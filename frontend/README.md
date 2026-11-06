# SpotProp frontend

Next.js app for the protocol in this repo:

- **`/`**: landing page for traders and LPs. Live vault stats read from chain, an interactive profit/loss calculator
  that uses the contract's settlement rules, FAQ, and the **waitlist** for full launch.
- **`/app`**: dashboard with wallet balance, trading PnL, LP value and earnings, pending payouts and protocol stats.
- **`/app/trade`**: ETH and BTC spot terminal (Uniswap v4). Live chart of the pool price against the 10-minute TWAP
  with liquidation lines, 5x/10x order ticket with pre-flight checks that mirror the contract's reverts and a v4
  Quoter estimate, and a positions table with close, add margin, TP/SL, auto-roll and history.
- **`/app/earn`**: LP vault. Deposit, the 30-day ERC-7540 exit queue (request, cancel, process, claim), stress-bonus
  deposits and tickets, utilisation and insurance.
- **`npm run keeper`**: a bot that records the TWAP, liquidates, closes expired epochs, executes TP/SL and processes
  the LP queue. The oracle goes stale without it.

Stack: Next.js 15 (App Router), wagmi 2 and viem 2, TanStack Query, Tailwind 3, lightweight-charts, and Postgres
(`postgres`) for the waitlist.

## Run locally

```bash
cd frontend
cp .env.example .env.local    # fill in contract addresses and DATABASE_URL
npm install
npm run dev                   # http://localhost:3000
npm run typecheck && npm run build
```

To run against a local fork of Arc mainnet instead, start `npm run fork` in the repo root first: it writes
`.env.development.local` for `next dev` (see [DEVELOPMENT.md](../DEVELOPMENT.md)).

ABIs in `src/abi/` are generated from the Foundry build: run `npm run build` in the repo root, then `npm run abi` here.

## Configuration

Everything is in `.env.example`. The essentials:

| Variable | Notes |
|---|---|
| `NEXT_PUBLIC_NETWORK` | `mainnet` (Arc, 5042), `fork` (local anvil fork, 5042) or `testnet` (5042002). Override `NEXT_PUBLIC_RPC_URL` / `NEXT_PUBLIC_EXPLORER_URL` if needed. |
| `NEXT_PUBLIC_POSITION_MANAGER`, `_LP_VAULT`, `_ORACLE`, `_INSURANCE` | Printed by `script/Deploy.s.sol`. The oracle is `UniV4TwapOracle`. |
| `NEXT_PUBLIC_V4_QUOTER`, `_WETH`, `_CIRBTC` | Optional; default to the Arc mainnet Uniswap V4Quoter, WETH and cirBTC. |
| `DATABASE_URL` | Postgres for the waitlist (Neon, Supabase, Vercel Postgres...). The table is created automatically (`db/schema.sql`). Without it, signups go to `.data/waitlist.json`, which is for local dev only. |
| `WAITLIST_ADMIN_TOKEN` | Enables CSV export: `curl -H "Authorization: Bearer $TOKEN" https://<host>/api/waitlist/export`. |

### How a trade is built

The app sends only `minAmountOut`: `PositionManager` builds the Uniswap v4 swap itself on the asset's pool and runs it
through the position's own `TraderProxy`. For opens, `minAmountOut` comes from a fresh V4Quoter quote minus your
slippage. On-chain, the fill must also be worth at least `notional × (1 − maxEntrySlippage)` at the 10-minute TWAP.
For closes, the contract enforces `max(minAmountOut, mark × (1 − maxExitSlippage))` with the mark at the TWAP. The
close dialog warns, before you sign, when the pool is below that floor. There is no oracle fee and no rush to sign:
prices live on-chain.

## MVP launch checklist ($100 vault, $5–$10 trades)

1. **Deploy** with `script/Deploy.s.sol` (`GOVERNANCE`, `GUARDIAN`, `RECORDERS` = keeper address). It deploys the
   oracle, the v4 router and a single LP vault, and enables WETH and cirBTC on their Arc v4 pools.
2. **Retune for a small vault.** The defaults ($500 minimum size, $5 keeper bounty, 35% per-asset cap, $1,000 minimum
   bonus deposit) make a $100 vault unusable. As the owner, run:
   ```bash
   POSITION_MANAGER=0x... LP_VAULT=0x... ASSETS=0xBTC,0xETH \
     forge script script/ConfigureMVP.s.sol --rpc-url arc_mainnet --broadcast --account <owner>
   ```
   This sets a $25 minimum notional ($5 at 5x), a $0.10 keeper bounty, a 100% per-asset cap and a $10 minimum bonus
   deposit. If ownership already sits with a multisig, submit the same calls from the Safe. `test/MVPConfig.t.sol`
   covers the resulting flows.
3. **Seed the vault** by depositing $100 on `/app/earn`. Optionally seed the insurance pool with
   `InsuranceReserve.donate`.
4. **Run the keeper**: `KEEPER_PRIVATE_KEY=0x... npm run keeper` (give it a few USDC for gas). It must be a recorder
   on the oracle. Trading opens 10 minutes after it starts recording. Without a keeper, the TWAP goes stale,
   nothing can trade, and nobody liquidates losing positions.
5. **Deploy the site** (e.g. Vercel, with the root directory set to `frontend/`) and set the contract addresses,
   `DATABASE_URL` and `WAITLIST_ADMIN_TOKEN`.

What a $100 vault can hold: at most 85% can be lent, so about $85 of borrowing in total. That covers, for example,
one $5 × 10x ($45 borrowed) plus one $10 × 5x ($40 borrowed). A second $5 × 10x has to wait until one closes. The
order ticket shows the remaining capacity and explains the limit before the user signs.

## Known limitations

- **Oracle warm-up.** After deployment, or after a keeper outage longer than 5 minutes, prices are unavailable for
  10 minutes while the TWAP refills. The UI shows "warming up" and blocks trading until then.
- **TWAP lag.** Entries, exits and liquidations follow the 10-minute average, not the live pool. In a fast move the
  pool can sit outside the allowed slippage band and closes revert until the TWAP catches up.
- **Chart history.** The chart is built from on-chain samples taken while the page is open; there is no backfill.
- **No indexer.** Positions, requests and tickets are found by scanning recent ids with Multicall3 (the last 2,000
  of each). That is fine for the MVP; add an indexer on `PositionOpened` / `RedeemRequest` events before volume grows.
- **One pool per market.** Each asset trades on the single v4 pool configured in the oracle; there is no routing.
