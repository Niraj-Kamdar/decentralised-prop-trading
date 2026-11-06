# Spot-Funded Prop Trading on Arc

Leveraged spot longs (5x / 10x) on **ETH and BTC** on Arc. Each position gets its own isolated EIP-1167
`TraderProxy`. The trader's USDC margin is paired with principal borrowed from a single ERC-4626 LP vault. Spot is
bought and sold on the asset's **Uniswap v4** USDC pool and marked at that pool's **10-minute TWAP**. The protocol
charges no entry or exit fees, and the first 7-day epoch is free. Later epochs roll over at 8% APR.

## Layout

| Contract | Role |
|---|---|
| `src/PositionManager.sol` | Entry point for traders and keepers: opens positions, rolls epochs, liquidates and runs the settlement waterfall |
| `src/LPVault.sol` | `spUSDC` ERC-4626 vault (UUPS) with ERC-7540 async redemptions: lending to proxies, 12h linear profit vesting, 85% utilization cap, 30-day exit queue, stress bonus pot, solvency gate. MetaMorpho is optional (`address(0)` = single-vault mode, the default) |
| `src/UniV4TwapOracle.sol` | 10-minute TWAP of each asset's Uniswap v4 USDC pool, recorded by whitelisted keepers; prices normalised to 1e18 |
| `src/V4SwapRouter.sol` | Minimal exact-input, single-pool v4 router (unlock callback, plain ERC-20 approval, no Permit2) |
| `src/TraderProxy.sol` | Per-position custody clone that swaps only through the whitelisted router and checks its own balance after each swap |
| `src/InsuranceReserve.sol` | First-loss bucket and ops-treasury bucket |
| `script/Deploy.s.sol` | Arc mainnet deployment (WETH + cirBTC on their v4 pools) and hand-off to governance through Ownable2Step |
| `script/lib/ArcMainnet.sol` | Verified Arc addresses: v4 PoolManager / Quoter, WETH, cirBTC and both pool keys |
| `script/ConfigureMVP.s.sol` | Retunes a deployed protocol for a ~$100 vault with $5–$10 positions |
| `script/fork/` | Local Arc mainnet fork for UI testing (`npm run fork`), USDC fork shim, pool mover |
| `frontend/` | Landing page with waitlist, dashboard, trade terminal, LP vault UI and keeper bot ([frontend/README.md](frontend/README.md)) |

## Build & test

```bash
npm install                 # forge / anvil / cast 1.7.1, OpenZeppelin 5.4.0, Uniswap v4-core 1.0.2 from npm
git submodule update --init # forge-std
npm test                    # 72 unit tests incl. 512-run fuzzes and a 256x64 queue invariant suite (fork suite skipped)
npm run test:fork           # 14 tests against a fork of Arc mainnet: real v4 pools, real liquidity
npm run build               # prints contract sizes
```

`npm run test:fork` forks `https://rpc.mainnet.arc.io` unless `ARC_MAINNET_RPC_URL` is set; `FORK_BLOCK` pins a block.
The fork suite deploys the protocol exactly as `script/Deploy.s.sol` does, warms up the TWAP, then opens, rallies,
closes, crashes, liquidates and triggers stop-losses on real ETH and BTC positions, and checks the oracle's
manipulation guards against live pools.

## Testing the UI on a local Arc mainnet fork

```bash
npm run fork                 # anvil fork + deploy + seed $100 vault + warm TWAP + keeper; leave it running
cd frontend && npm run dev   # http://localhost:3000/app/trade, configured for the fork automatically
npm run fork:move -- ETH -8  # (repo root) push the real ETH/USDC pool down 8% by trading against it
npm run fork:warp -- 600     # fast-forward 10 minutes with TWAP observations; the keeper then liquidates
```

`npm run fork` writes `frontend/.env.development.local` (used by `next dev` only, never by production builds), starts
the keeper (`.fork/keeper.log`) and prints funded anvil test wallets. Add the network to your wallet (RPC
`http://127.0.0.1:8545`, chain ID 5042, currency USDC) and import the printed trader key, or pass
`TEST_WALLET=0xYourAddress` to fund your own address. `frontend/e2e/fork-smoke.mjs` drives the same flow in a
headless browser (open, close in profit, keeper liquidation, BTC open).

**Why a USDC shim.** Arc's USDC (`0x3600…`) moves value through native precompiles (`0x1800…00` for transfers,
`0x1800…01` for the Circle blocklist, which WETH also consults) that anvil and forge do not have, so on a plain fork
every USDC and WETH transfer reverts. The fork tooling installs `script/fork/UsdcForkShim.sol` as the USDC proxy's
implementation: an ordinary ERC-20 whose balances start from each account's real native balance, so the Uniswap
PoolManager keeps its real USDC. It is never deployed outside a fork.

## Price oracle: Uniswap v4 TWAP

Uniswap v4 pools keep no price history, so `UniV4TwapOracle` keeps it: a 128-slot ring buffer of tick observations
per asset, integrated like the v3 oracle (each observation's tick holds until the next one). Prices are the
arithmetic-mean tick over `twapWindow` (600 s), converted to USD per whole token with USDC = $1.

- **Who records.** Only whitelisted recorders (the keeper). With permissionless recording, anyone could push the
  pool, record and swap back in one transaction for a few dollars of fees, and walk the TWAP anywhere.
- **Sandwich guard.** The recorder passes the tick it saw at the end of the previous block. A sample whose live tick
  deviates by more than `maxRecordDeviation` (100 ticks, ~1%) is rejected, so sandwiching the recorder's own
  transaction can move a sample by at most ~1%.
- **Clamp.** Each observation moves at most `maxTickDelta` (500 ticks, ~5%) from the previous one, bounding a bad
  sample or a compromised recorder. Genuine moves are followed within a few observations.
- **Liveness.** `getPrice` reverts while the series is younger than the window (`TwapNotReady`) or when the newest
  observation is older than `maxStaleness` (90 s, `TwapStale`). A gap longer than `maxObservationGap` (300 s)
  restarts the series instead of extrapolating across a keeper outage, so after an outage nothing can be priced for
  10 minutes. Positions cannot be liquidated while the oracle is stale: keepers are critical infrastructure.

Every risk decision (entry check, exit floors, liquidation, epoch, stop-loss / take-profit) uses the TWAP. The
current pool price (`spotPrice`) is exposed for display only.

## Implementation decisions beyond / deviating from the spec

1. **Every exit swap is bounded by the TWAP, including the trader's own close.** The swap must return at least
   `max(minAmountOut, mark × (1 − maxSlippage))` with the mark at the TWAP. If only `liquidate()` were bounded, a
   trader could close into a pool they had manipulated themselves and push the shortfall onto LP principal. For the
   same reason, `openPosition` rejects any fill worth less than `notional × (1 − maxEntrySlippageBps)` at the TWAP.
   Consequence: when the pool trades more than the allowed slippage below the TWAP (a fast crash, or a dump),
   exits revert until the pool recovers or the TWAP catches up.
2. **The proxy measures its own balance changes.** It does not rely on what the router reports. Router calldata
   that sends the proceeds to a different recipient therefore fails the `minOut` check.
3. **Rollover debt is charged up front for each epoch and accrues lazily.** If keepers are late, `closePosition`,
   `liquidate` and `executeTrigger` first charge every epoch that has fallen due. A pure roll in `processEpoch`
   pays no bounty, because skipping it never lets debt go unaccrued.
4. **An expired position that is also below the liquidation threshold settles as a liquidation, not an expiry.**
   The same applies to a triggered stop-loss below the threshold. A trader therefore cannot use a stop order to
   avoid the liquidation penalty.
5. **`addMargin` repays vault principal directly.** It lowers B, which reduces both the liquidation threshold and
   the base for rollover fees. M₀ grows by the same amount, so the trader gets it back before the profit split.
6. **No oracle fees.** The TWAP is read from storage; there is no per-transaction price update to pay for. The
   keeper pays gas for recording.
7. **There is no "claim to another address" path.** With one, a trader on the Circle blocklist could route
   deferred payouts to a clean address.
8. **The protocol builds every swap itself.** Callers pass only `minAmountOut`; `PositionManager` encodes the
   `V4SwapRouter.swapExactIn` call on the asset's pool (the oracle's pool key) with the position's proxy as recipient.
   This removes arbitrary router calldata and the old race where the UI had to predict the next proxy address.
9. **Our own v4 router instead of UniversalRouter.** The proxy grants a plain exact ERC-20 approval and revokes it
    after the swap; `V4SwapRouter` pulls with `transferFrom` and settles with the PoolManager, so no Permit2. Only
    the current router is whitelisted: `setSwapRouter` removes the previous one.
10. **USDC is enforced at deployment.** The constructor and initializer require `0x3600…0000` whenever the chain
    ID is 5042 or 5042002, and they also check that the token has 6 decimals.
11. **The LP vault applies a virtual-share offset of 6** against first-depositor inflation attacks, so `spUSDC`
    shares have 12 decimals.

## LP lifecycle: exit queue, stress bonus and solvency gate

Spec: issue #1. Deposits are synchronous; redemptions are asynchronous (ERC-7540). Traders pay nothing for any of
this, and no part of it can block, delay or reduce a trader payout.

1. **Request.** `requestRedeem(shares, controller, owner)` escrows the shares in a FIFO queue for `redeemCooldown`
   (30 days). From that moment the shares **stop earning**: the payout is capped at their value when requested,
   while losses during the wait still apply.
2. **Stress penalty.** The pool is *stressed* when utilisation is at or above `stressUtilizationBps` (80%; the hard
   allocation cap stays at 85%). A request made while stressed also forfeits `exitPenaltyBps` (25%) of the yield
   earned *before* the request. It never touches principal: the payout is floored at `min(cost basis, value)`.
3. **Fulfil.** Anyone can call `processRedemptions(n)`. Matured requests are paid FIFO, with partial fills, out of
   `fulfilmentBudget()`, which is free liquidity minus the PositionManager's worst-case stressed LP loss (net of
   insurance). The payout is reserved as local USDC; the controller claims with `redeem`/`withdraw`. Cancelling a
   pending request also forfeits any queue-period gain.
4. **Bonus pot.** Every forfeit (queue gain, stress penalty, cancel, broken ticket) goes into `bonusPot`. While
   stressed, `depositWithBonus` locks a new deposit for `bonusDuration` (90 days) and streams the pot to it
   (`pot / 90 days` per second, capped at 20% APR per ticket). At maturity anyone can call `claimTicket`; the bonus
   is minted as `spUSDC`. `breakTicket` unlocks early and returns the accrued bonus to the pot. The scheme is
   zero-sum: bonuses are only ever paid from the pot.
5. **Solvency gate.** `PositionManager.stressedLPLoss()` bounds the LP loss if every asset dropped by its
   `stressShockBps` (20%) and every position were liquidated at maximum slippage. Positions sit above
   `V = B + D + mu*N`, so the loss per position is at most `B * k(asset, tier)`. The bound is exact from
   per-(asset, tier) borrowed aggregates, with no loop over positions. It assumes keepers liquidate promptly.
6. **Priority.** New trader allocations cannot use liquidity owed to pending requests (`AllocationBlockedByQueue`).

Every parameter is owner-configurable within bounds (`setQueueParams`, `setBonusParams`, the per-asset shock in
`setAsset`). Existing requests and tickets keep the terms they were created with.

## Known gaps before audit

- **The TWAP trusts its recorders.** Recording is permissioned (see the oracle section). A malicious or compromised
  recorder can bias the TWAP by up to `maxTickDelta` per observation, and if every recorder stops, the protocol
  stops pricing. The trust-minimised alternative is a v4 pool with an oracle hook, which needs its own liquidity.
- **Thin pools.** At the time of writing the WETH/USDC pool holds about $15k and cirBTC/USDC about $8k. That is fine
  for $5–$10 positions, but a few thousand dollars moves either price by several percent, and the TWAP only delays
  a sustained manipulation (10 minutes), it does not prevent it. Keep exposure caps far below pool depth.
- USDC is assumed to equal $1. There is no external oracle cross-check.
- `executeTrigger` lets the trader or an operator raise `trailingStopPrice`. There is no on-chain high-water tracking.
- MetaMorpho integration is kept but is not covered by the fork tests (the default deployment uses no Morpho vault).
- The solvency-gate bound assumes keepers liquidate promptly. A position left below its threshold can lose more
  than the bound predicts.
- New allocations are blocked by *all* pending requests, not just matured ones. This is more conservative than
  the spec.
