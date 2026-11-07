# Invariant Map

> Fulcrum | 40 guards | 16 inferred | 3 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (isDenied[msg.sender]) revert Denied(msg.sender);` · `src/PositionManager.sol:324` · Denylist check preventing restricted addresses from opening new leveraged positions

#### G-2
`if (!lv.enabled || p.tier > lv.maxLeverage || p.margin > lv.maxMargin) revert LevelLimitExceeded(lvl);` · `src/PositionManager.sol:327` · Risk-tier guard bounding trader leverage and margin by on-chain level

#### G-3
`if (!t.enabled) revert InvalidTier(p.tier);` · `src/PositionManager.sol:330` · Parameter validation ensuring selected leverage tier is active

#### G-4
`if (!a.enabled) revert AssetNotEnabled(p.spotToken);` · `src/PositionManager.sol:332` · Asset whitelist guard ensuring only supported spot tokens are traded

#### G-5
`if (swapRouter == address(0)) revert SwapRouterNotSet();` · `src/PositionManager.sol:333` · Protocol wiring guard ensuring active router is configured

#### G-6
`if (notional < minNotional) revert BelowMinNotional(notional);` · `src/PositionManager.sol:337` · Economic floor guard ensuring position size justifies keeper liquidation bounties

#### G-7
`if (exposureAfter > cap) revert ExposureCapExceeded(p.spotToken, exposureAfter, cap);` · `src/PositionManager.sol:342` · Systemic risk bound limiting open notional per asset to vault capacity share

#### G-8
`if (entryMark * BPS < notional * (BPS - maxEntrySlippageBps)) revert EntryPriceDeviation(entryMark, notional);` · `src/PositionManager.sol:357` · Sandwich and pool-manipulation defense verifying execution price vs TWAP mark

#### G-9
`if (entryMark <= threshold) revert UnhealthyAtOpen(entryMark, threshold);` · `src/PositionManager.sol:359` · Immediate insolvency guard preventing creation of undercollateralized positions

#### G-10
`if (_positions[posId].status != PositionStatus.OPEN) revert PositionNotOpen(posId);` · `src/PositionManager.sol:305` · State machine guard restricting operations to active open positions

#### G-11
`if (msg.sender != trader && !isOperator[trader][msg.sender]) revert NotAuthorized();` · `src/PositionManager.sol:315` · Custody access control restricting trade management to owner or approved operator

#### G-12
`if (amount == 0 || amount > pos.borrowedPrincipal) revert InvalidAmount();` · `src/PositionManager.sol:404` · Conservation bound ensuring margin top-up does not exceed outstanding borrowed debt

#### G-13
`if (block.timestamp < pos.epochEndTime) revert EpochNotEnded(pos.epochEndTime);` · `src/PositionManager.sol:457` · Temporal lock preventing keeper premature expiry closure before 7-day period

#### G-14
`if (mark > threshold) revert NotLiquidatable(mark, threshold);` · `src/PositionManager.sol:477` · Solvency condition guard gating liquidation to positions at or below maintenance line

#### G-15
`if (!hit) revert TriggerNotHit(price);` · `src/PositionManager.sol:490` · Conditional execution guard gating automated stop loss or take profit orders

#### G-16
`if (amount == 0) revert NothingToClaim();` · `src/PositionManager.sol:443` · Pull payout accounting guard preventing zero-value transfers

#### G-17
`if (token == address(0) || token == address(usdc)) revert InvalidAsset();` · `src/PositionManager.sol:576` · Asset registration sanity check rejecting zero address and quote asset

#### G-18
`if (maxExposureBps > BPS || stressShockBps > MAX_STRESS_SHOCK_BPS) revert InvalidParams();` · `src/PositionManager.sol:577` · Parameter range bound capping asset concentration and stress shock values

#### G-19
`if (tier < 2 || cfg.maintenanceBps == 0 || cfg.maintenanceBps >= BPS / tier) revert InvalidTier(tier);` · `src/PositionManager.sol:684` · Mathematical solvency guard ensuring maintenance margin is strictly below initial margin

#### G-20
`if (msg.sender != owner() && msg.sender != guardian) revert NotAuthorized();` · `src/PositionManager.sol:669` · Emergency access control restricting pause authority to owner and guardian

#### G-21
`if (receiver != address(this)) costBasis[receiver] += assets;` · `src/LPVault.sol:321` · Principal tracking guard updating recipient cost basis on deposits

#### G-22
`if (shares == 0) revert InvalidAmount();` · `src/LPVault.sol:351` · Zero-share validation guard on redemption requests

#### G-23
`if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();` · `src/LPVault.sol:353` · ERC-7540 authorization guard restricting withdrawal requests to owner or operator

#### G-24
`if (r.status != RequestStatus.PENDING) revert RequestNotPending(requestId);` · `src/LPVault.sol:384` · State machine guard preventing double cancellation or cancelling fulfilled requests

#### G-25
`if (r.maturesAt > block.timestamp) break;` · `src/LPVault.sol:431` · Temporal cooldown gate enforcing 30-day delay in FIFO redemption processing

#### G-26
`if (shares == 0 || shares > cShares) revert ExceedsClaimable(shares, cShares);` · `src/LPVault.sol:461` · Bounded claim guard preventing extraction beyond fulfilled and claimable shares

#### G-27
`if (!isStressed()) revert NotStressed();` · `src/LPVault.sol:543` · Market state precondition restricting bonus pot deposits to stressed pools (≥80% utilization)

#### G-28
`if (assets < minBonusDeposit) revert BelowMinBonusDeposit(assets, minBonusDeposit);` · `src/LPVault.sol:544` · Minimum capital requirement for bonus yield deposits

#### G-29
`if (block.timestamp < t.maturesAt) revert TicketNotMatured(t.maturesAt);` · `src/LPVault.sol:569` · Temporal lockup guard enforcing 90-day commitment on bonus ticket claims

#### G-30
`if (block.timestamp >= t.maturesAt) revert TicketMatured(t.maturesAt);` · `src/LPVault.sol:587` · State condition guard forcing matured tickets through claim rather than early break

#### G-31
`if (borrowedAfter > cap) revert UtilizationCapExceeded(borrowedAfter, cap);` · `src/LPVault.sol:631` · Liquidity preservation guard enforcing 85% utilization ceiling on vault assets

#### G-32
`if (amount > allocatable) revert AllocationBlockedByQueue(amount, allocatable);` · `src/LPVault.sol:635` · Priority ranking guard ensuring pending LP redemptions block new margin loans

#### G-33
`if (principalReturned > principalBorrowed || principalBorrowed > totalBorrowedPrincipal) revert RepayExceedsBorrowed();` · `src/LPVault.sol:652-653` · Principal conservation guard preventing over-repayment of borrowed debt

#### G-34
`if (totalBorrowedPrincipal != 0) revert InvalidParams();` · `src/LPVault.sol:679` · Operational integrity guard preventing position manager migration with outstanding loans

#### G-35
`if (positionManager != address(0)) revert AlreadySet();` · `src/InsuranceReserve.sol:44` · One-shot latch preventing redirection of insurance reserve backstop

#### G-36
`if (amount > opsTreasuryBalance) revert InsufficientOpsBalance();` · `src/InsuranceReserve.sol:79` · Segregated accounting guard protecting insurance pool from governance treasury withdrawals

#### G-37
`if (!IRouterRegistry(manager).isWhitelistedRouter(router)) revert RouterNotWhitelisted(router);` · `src/TraderProxy.sol:43` · Router whitelist guard restricting proxy swaps to approved addresses

#### G-38
`if (inAfter + amountIn != inBefore) revert InputNotFullySpent(amountIn, inBefore - inAfter);` · `src/TraderProxy.sol:56` · Input conservation guard ensuring exact consumption of trade principal

#### G-39
`if (amountOut < minOut) revert InsufficientOutput(minOut, amountOut);` · `src/TraderProxy.sol:60` · Balance-delta output verification preventing swap proceeds redirection

#### G-40
`if (answer <= 0) revert InvalidPrice(asset, answer);` · `src/ChainlinkOracle.sol:78` · Oracle sanity check rejecting non-positive feed answers

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Conservation` · On-chain: **Yes**

> `totalAssets() == _liquidUsdc() + _morphoAssets() + totalBorrowedPrincipal - (_calculateLockedProfit() + reservedForClaims + bonusPot + bonusAccrued)`

**Derivation** — Δ-pair and accounting deduction in `src/LPVault.sol:244-248`. Every source of assets is summed and all earmarked liabilities and unvested profits are subtracted.

**If violated** — Share price inflates or dilutes artificially; early exiting LPs could claim funds earmarked for claims or bonus pots, leaving remaining LPs undercapitalized.

---

#### I-2

`Conservation` · On-chain: **Yes**

> `reservedForClaims == Σ claimableAssets[controller]`

**Derivation** — Δ-pair: `reservedForClaims += payout` matches `claimableAssets[controller] += payout` at `src/LPVault.sol:861,864` on fulfillment; `reservedForClaims -= assets` matches `claimableAssets[controller] -= assets` at `src/LPVault.sol:895-896` on claim.

**If violated** — Mismatch between physical local USDC reserved and claimable rights of exiting LPs; could cause claim transactions to revert due to insufficient local cash.

---

#### I-3

`Conservation` · On-chain: **Yes**

> `totalPendingShares == Σ _requests[id].shares for all PENDING requests`

**Derivation** — Δ-pair across all three request lifecycle write sites: `totalPendingShares += shares` on enqueue (`src/LPVault.sol:375`), `totalPendingShares -= shares` on cancel (`src/LPVault.sol:405`), and `totalPendingShares -= fill` on fulfillment (`src/LPVault.sol:873`).

**If violated** — Internal accounting desync between global pending shares and request queue state, corrupting vault share supply checks.

---

#### I-4

`Bound` · On-chain: **Yes**

> `totalBorrowedPrincipal <= totalAssets() * maxUtilizationBps / BPS`

**Derivation** — Guard-lift: `src/LPVault.sol:630-631` enforces `borrowedAfter <= cap` on every borrowing event (`allocateToPosition`). Repayments only decrement `totalBorrowedPrincipal` (`src/LPVault.sol:658`).

**If violated** — Vault liquidity completely lent out to margin positions, leaving zero buffer for normal operational flows and increasing bank-run exposure.

---

#### I-5

`Bound` · On-chain: **Yes**

> `assetExposure[token] <= lpVault.totalAssets() * assetConfigs[token].maxExposureBps / BPS`

**Derivation** — Guard-lift: `src/PositionManager.sol:341-342` validates `exposureAfter <= cap` at position creation (`openPosition`). Positions closing decrement exposure (`src/PositionManager.sol:743`).

**If violated** — Protocol becomes over-concentrated in a single volatile spot asset, overwhelming Uniswap v4 pool depth during mass liquidations.

---

#### I-6

`Conservation` · On-chain: **Yes**

> `totalBorrowedPrincipal == Σ borrowedByAssetTier[token][tier]`

**Derivation** — Δ-pair verified across all three position lifecycle events: incremented together at `openPosition:344` (`borrowedByAssetTier += borrowed`, `allocateToPosition(borrowed)`), decremented together at `addMargin:409`, and decremented together at `_exitAndSettle:744`.

**If violated** — `stressedLPLoss()` calculations would misestimate worst-case portfolio drawdown, causing the redemption solvency gate to misprice fulfillment budgets.

---

#### I-7

`Ratio` · On-chain: **Yes**

> `liquidationThreshold == borrowedPrincipal + accruedRolloverDebt + (notional * maintenanceBps) / BPS`

**Derivation** — Exact mathematical ratio evaluated at `src/PositionManager.sol:693-696`. Snapshot of `borrowedPrincipal` and `accruedRolloverDebt` incorporates lazy catch-up epochs before comparison.

**If violated** — Liquidations trigger prematurely on healthy trades, or fail to trigger when positions become underwater, shifting bad debt onto LPs.

---

#### I-8

`StateMachine` · On-chain: **Yes**

> `PositionStatus.NONE (0) → OPEN (1) → CLOSED (2) | LIQUIDATED (3)` with no path back to `OPEN`

**Derivation** — State-machine edge: `status` transitions from `NONE` to `OPEN` at `src/PositionManager.sol:368`, and transitions from `OPEN` to `CLOSED` or `LIQUIDATED` at `src/PositionManager.sol:742`. Modifiers `onlyOpen` prevent re-entry.

**If violated** — Closed or liquidated positions could be modified, double-closed, or manipulated to re-extract margin.

---

#### I-9

`StateMachine` · On-chain: **Yes**

> `RequestStatus.NONE (0) → PENDING (1) → FULFILLED (2) | CANCELLED (3)` with no reversal

**Derivation** — State-machine edge: `status` set to `PENDING` at `src/LPVault.sol:367`, set to `CANCELLED` at `src/LPVault.sol:407`, or set to `FULFILLED` at `src/LPVault.sol:870`.

**If violated** — Cancelled or fulfilled withdrawal tickets could be re-processed in the FIFO queue, draining liquidity.

---

#### I-10

`Temporal` · On-chain: **Yes**

> `processEpoch` execution requires `block.timestamp >= pos.epochEndTime`

**Derivation** — Temporal predicate: `if (block.timestamp < pos.epochEndTime) revert EpochNotEnded(pos.epochEndTime);` at `src/PositionManager.sol:457`.

**If violated** — Keepers could force-close active trader positions before their 7-day epoch matures, stealing trader margin and pocketing bounties.

---

#### I-11

`Temporal` · On-chain: **Yes**

> `processRedemptions` fulfilment requires `block.timestamp >= r.maturesAt`

**Derivation** — Temporal predicate: `if (r.maturesAt > block.timestamp) break;` at `src/LPVault.sol:431`.

**If violated** — Exiting LPs could bypass the 30-day cooldown, front-running market crashes and leaving slower LPs to absorb bad debt.

---

#### I-12

`Bound` · On-chain: **Yes**

> `bonusPot + bonusAccrued` liability deduction strictly insulates standard LPs from bonus emissions

**Derivation** — Accounting bound: `bonusPot` is funded by yield forfeits or donations (`src/LPVault.sol:400,602,859`), emitted into `bonusAccrued` (`src/LPVault.sol:935`), and deducted from `totalAssets` (`src/LPVault.sol:246`).

**If violated** — Standard passive LPs would subsidize bonus pot yields, diluting their share value.

---

#### I-13

`Conservation` · On-chain: **Yes**

> Pro-rata cost basis is conserved across user-to-user share transfers: `Δ(costBasis[from]) = -moved, Δ(costBasis[to]) = +moved`

**Derivation** — Δ-pair: `_update()` in `src/LPVault.sol:327-334` calculates `moved = _basisPortion(from, value)` and applies equal and opposite updates to both accounts.

**If violated** — Secondary market share buyers could evade stress exit penalties or inherit inflated principal protection baselines.

---

#### I-14

`Bound` · On-chain: **No**

> `stressedLPLoss()` assumes keepers liquidate positions promptly at `liquidationThreshold`

**Derivation** — Mathematical assumption in `src/PositionManager.sol:535-538`. If the spot price gaps down precipitously across blocks before keepers execute, actual bad debt exceeds the modeled cushion.

**If violated** — The LP redemption solvency gate overestimates remaining pool solvency, fulfilling exit requests that later cause insolvency for remaining LPs.

---

#### I-15

`StateMachine` · On-chain: **Yes**

> `InsuranceReserve.positionManager` and `LPVault.positionManager` are write-once or zero-debt gated

**Derivation** — Latches: `src/InsuranceReserve.sol:44` (`require(positionManager == address(0))`) and `src/LPVault.sol:679` (`require(totalBorrowedPrincipal == 0)`).

**If violated** — Rogue admin could rewire the backstop or vault to an arbitrary contract, orphaning active margin loans.

---

#### I-16

`Bound` · On-chain: **Yes**

> `TraderProxy` input token is 100% consumed during swap: `inAfter + amountIn == inBefore`

**Derivation** — Verbatim guard-lift at `src/TraderProxy.sol:56` executed inside every position swap.

**If violated** — Router could leave unspent input tokens inside the proxy clone, orphaning margin capital.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes**

> `PositionManager` borrows from `LPVault` only when unencumbered liquidity exceeds pending redemption queue liabilities

**Caller side** — `src/PositionManager.sol:351` calls `lpVault.allocateToPosition(proxy, borrowed)`

**Callee side** — `src/LPVault.sol:634-635` checks `amount <= free - pendingRedeemAssets`, reverting with `AllocationBlockedByQueue` if violated

**If violated** — Trader borrowing consumes liquidity promised to queued LPs, trapping withdrawing depositors.

---

#### X-2

On-chain: **Yes**

> `PositionManager` repayment waterfall completely clears borrowed principal in `LPVault` regardless of position profit or loss

**Caller side** — `src/PositionManager.sol:814,848` calls `lpVault.repayFromPosition(principalReturned, borrowed, lpYield)`

**Callee side** — `src/LPVault.sol:658` decrements `totalBorrowedPrincipal -= principalBorrowed`

**If violated** — Ghost principal debt remains on vault balance sheet, permanently restricting future borrowing capacity.

---

#### X-3

On-chain: **Yes**

> `InsuranceReserve` covers shortfalls up to available `insurancePoolBalance` before LPs suffer bad debt

**Caller side** — `src/PositionManager.sol:782` calls `insurance.coverShortfall(shortfall)`

**Callee side** — `src/InsuranceReserve.sol:70-74` sends `covered = min(deficit, insurancePoolBalance)` to `PositionManager`

**If violated** — Bad debt directly hits LP vault share price even when insurance backstop reserves are funded.

---

#### X-4

On-chain: **Yes**

> `LPVault` redemption solvency gate dynamically reads worst-case stress loss from `PositionManager`

**Caller side** — `src/LPVault.sol:276` calls `IRiskView(pm).stressedNetLoss()`

**Callee side** — `src/PositionManager.sol:561-564` calculates `stressedLPLoss() - insurance.insurancePoolBalance()`

**If violated** — LPVault allows full redemptions while open positions are under heavy adverse price moves, leaving remaining LPs holding toxic debt.

---

#### X-5

On-chain: **Yes**

> `LPVault` enforces the same trader denylist registered in `PositionManager`

**Caller side** — `src/LPVault.sol:316` calls `IDenylist(pm).isDenied(account)`

**Callee side** — `src/PositionManager.sol:175` reads `isDenied[account]` mapping

**If violated** — Denied actors barred from leveraged trading could still deposit and extract yield through the liquidity vault.

---

#### X-6

On-chain: **No**

> `PositionManager` assumes price feeds from `IOracle` are active and non-stale, but `ChainlinkOracle` lacks L2 Sequencer Uptime feed validation

**Caller side** — `src/PositionManager.sol:356,391,475` calls `oracle.valueInUsdc()` during open, close, and liquidation

**Callee side** — `src/ChainlinkOracle.sol:79-81` validates `maxStaleness` on `updatedAt`, but does not query the L2 Sequencer feed (Arbitrum/Base)

**If violated** — Upon L2 sequencer restart following downtime, stale prices execute trades and liquidations before market arbitrageurs restore parity.

---

## 4. Economic Invariants

#### E-1

`Conservation` · On-chain: **Yes**

> Zero-sum settlement conservation: In `PositionManager._settle`, token proceeds exactly equal the sum of keeper bounty, vault principal return, bad debt, rollover yield, liquidation penalty, trader payout, and treasury cut

**Follows from** — `I-1` + `X-2` + `X-3`

**If violated** — Value is created from nothing or leaked/trapped in the contract, causing protocol insolvency or unbacked spUSDC shares.

---

#### E-2

`Priority` · On-chain: **Yes**

> Seniority of queued LP capital over new trader leverage: `pendingRedeemAssets` acts as a prior lien on `freeLiquidity`

**Follows from** — `I-4` + `G-32` + `X-1`

**If violated** — New traders front-run exiting LPs by borrowing idle funds, indefinitely delaying LP redemption fulfillment.

---

#### E-3

`Isolation` · On-chain: **Yes**

> Trader settlement isolation: LP exit queue stress, gate closures, or deficits never trap, haircut, or delay settled trader payouts

**Follows from** — `I-1` + `X-2`

**If violated** — Traders closing profitable trades have their payouts withheld or delayed due to internal vault liquidity crises.

---

#### E-4

`Solvency` · On-chain: **No**

> LP principal preservation under sudden price crash: If spot price drops faster than keepers can execute liquidations, loss exceeds `maintenanceBps` buffer and cuts LP principal

**Follows from** — `I-14` + `X-3` + `G-14`

**If violated** — Extreme market gap movements result in unrecovered bad debt exceeding the `InsuranceReserve`, causing irreversible permanent loss to LPs.
