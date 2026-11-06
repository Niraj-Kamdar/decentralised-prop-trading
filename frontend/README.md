# SpotProp frontend

Next.js app for the protocol in this repo:

- **`/`**: landing page for traders and LPs. Live vault stats read from chain, an interactive profit/loss calculator
  that uses the contract's settlement rules, FAQ, and the **waitlist** for full launch.
- **`/app`**: dashboard with wallet balance, trading PnL, LP value and earnings, pending payouts and protocol stats.
- **`/app/trade`**: spot trade terminal (Uniswap). Pyth candle chart with liquidation lines, 5x/10x order ticket with
  pre-flight checks that mirror the contract's reverts, and a positions table with close, add margin, TP/SL,
  auto-roll and history.
- **`/app/earn`**: LP vault. Deposit, the 30-day ERC-7540 exit queue (request, cancel, process, claim), stress-bonus
  deposits and tickets, utilisation and insurance.
- **`npm run keeper`**: a bot that liquidates, closes expired epochs, executes TP/SL and processes the LP queue.

Stack: Next.js 15 (App Router), wagmi 2 and viem 2, TanStack Query, Tailwind 3, lightweight-charts, and Postgres
(`postgres`) for the waitlist.

## Run locally

```bash
cd frontend
cp .env.example .env.local    # fill in addresses, assets, PYTH_API_KEY, DATABASE_URL
npm install
npm run dev                   # http://localhost:3000
npm run typecheck && npm run build
```

ABIs in `src/abi/` are generated from the Foundry build: run `npm run build` in the repo root, then `npm run abi` here.

## Configuration

Everything is in `.env.example`. The essentials:

| Variable | Notes |
|---|---|
| `NEXT_PUBLIC_NETWORK` | `mainnet` (Arc, 5042) or `testnet` (5042002). Override `NEXT_PUBLIC_RPC_URL` / `NEXT_PUBLIC_EXPLORER_URL` if needed. |
| `NEXT_PUBLIC_POSITION_MANAGER`, `_LP_VAULT`, `_ORACLE`, `_INSURANCE` | Printed by `script/Deploy.s.sol`. |
| `NEXT_PUBLIC_SWAP_ROUTER` | Uniswap v3 `SwapRouter02` (or the original `SwapRouter` with `NEXT_PUBLIC_SWAP_ROUTER_KIND=router`). It **must** be whitelisted via `PositionManager.setRouter`. |
| `NEXT_PUBLIC_QUOTER` | Uniswap `QuoterV2`. Optional, but it sizes `minAmountOut` and warns about pool/oracle deviation before you sign. |
| `NEXT_PUBLIC_ASSETS` | JSON list of `{symbol, address, decimals, pythId, fee, chartSymbol}`. `fee` is the USDC/token pool fee tier. |
| `PYTH_API_KEY` | **Required.** Pyth Hermes needs an API key since the 2026 Pyth Core upgrade. Requests are proxied through `/api/pyth`, so the key never reaches the browser. |
| `DATABASE_URL` | Postgres for the waitlist (Neon, Supabase, Vercel Postgres...). The table is created automatically (`db/schema.sql`). Without it, signups go to `.data/waitlist.json`, which is for local dev only. |
| `WAITLIST_ADMIN_TOKEN` | Enables CSV export: `curl -H "Authorization: Bearer $TOKEN" https://<host>/api/waitlist/export`. |

### How a trade is built

The swap is executed by the position's own `TraderProxy`, so the app encodes Uniswap `exactInputSingle` calldata
with the proxy as recipient. For opens, that is `predictProxyAddress(positionCount + 1)`. If someone else opens in
the same block, the proxy's balance check fails and the transaction simply reverts. Exits set `minAmountOut` at or
above the contract's oracle bound (`mark × (1 − maxExitSlippage)`), computed from the same Pyth update that is
submitted with the transaction. The Pyth fee is pulled in ERC-20 USDC, so the approval covers margin plus fee.

## MVP launch checklist ($100 vault, $5–$10 trades)

1. **Deploy** with `script/Deploy.s.sol` (needs a MetaMorpho vault, Pyth, and the Uniswap router on Arc).
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
4. **Run the keeper**: `KEEPER_PRIVATE_KEY=0x... npm run keeper` (give it a few USDC for gas and Pyth fees). Without
   a keeper, nobody liquidates losing positions and LP money is at risk.
5. **Deploy the site** (e.g. Vercel, with the root directory set to `frontend/`) and set `DATABASE_URL`,
   `PYTH_API_KEY` and `WAITLIST_ADMIN_TOKEN`.

What a $100 vault can hold: at most 85% can be lent, so about $85 of borrowing in total. That covers, for example,
one $5 × 10x ($45 borrowed) plus one $10 × 5x ($40 borrowed). A second $5 × 10x has to wait until one closes. The
order ticket shows the remaining capacity and explains the limit before the user signs.

## Known limitations

- **5-second oracle staleness.** `OracleVerifier` caps `maxStaleness` at 5s (a constant). The app fetches the price
  update at the last moment, but a user who takes longer than about 4s to confirm in their wallet gets `StalePrice`,
  and the UI asks them to retry. Raising `MAX_STALENESS_CAP` to about 30–60s would remove most of this friction;
  the oracle-bounded swap checks still protect LPs.
- **No indexer.** Positions, requests and tickets are found by scanning recent ids with Multicall3 (the last 2,000
  of each). That is fine for the MVP; add an indexer on `PositionOpened` / `RedeemRequest` events before volume grows.
- **Uniswap v3 only.** Direct `exactInputSingle` routes need a USDC/token pool at the configured fee tier. v4 /
  UniversalRouter needs the adapter noted in the root README.
