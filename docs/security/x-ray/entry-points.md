# Entry Point Map

> Fulcrum | 60 entry points | 25 permissionless | 11 role-gated | 24 admin-only

---

## Protocol Flow Paths

### Setup (Owner)

`ChainlinkOracle.setFeed()` → `PositionManager.initialize()` → `PositionManager.setSwapRouter()` → `PositionManager.setAsset()` → `PositionManager.setLevel()` → `LPVault.initialize()` → `LPVault.setPositionManager()` → `InsuranceReserve.setPositionManager()`

### LP Flow (Standard)

`[owner setup above]` → `LPVault.deposit()` / `LPVault.mint()`  ◄── under deposit caps, not denied
                            ├─→ `LPVault.requestRedeem()`  ◄── escrow shares into queue
                            │     ├─→ [30-day cooldown passes] → `LPVault.processRedemptions()` → `LPVault.redeem()` / `LPVault.withdraw()`
                            │     └─→ `LPVault.cancelRedeemRequest()`  ◄── forfeits queue gains to pot
                            └─→ `LPVault.rebalance()`  ◄── idle funds to Morpho

### LP Flow (Stressed Pool)

`[pool utilization ≥ 80%]` → `LPVault.depositWithBonus()`  ◄── locks shares for 90 days
                                  ├─→ [90 days pass] → `LPVault.claimTicket()`  ◄── unlocks shares + bonus shares
                                  └─→ `LPVault.breakTicket()`  ◄── forfeits accrued bonus back to pot

### Trader Flow

`[LP liquidity exists]` → `PositionManager.openPosition()`  ◄── margin in, borrows from vault, buys spot on v4
                              ├─→ `PositionManager.addMargin()`  ◄── repays borrowed principal
                              ├─→ `PositionManager.setOrders()`  ◄── set SL / TP / trailing floor
                              ├─→ `PositionManager.setAutoRollover()`  ◄── toggles auto rollover
                              └─→ `PositionManager.closePosition()`  ◄── unwinds spot, settles waterfall

### Keeper Maintenance & Liquidation Flow

`[open position]` → [epoch passes] → `PositionManager.processEpoch()`  ◄── rolls debt or closes for bounty
                 ├─→ [mark ≤ threshold] → `PositionManager.liquidate()`  ◄── liquidates, bounty to keeper, remainder to insurance
                 └─→ [trigger hit] → `PositionManager.executeTrigger()`  ◄── executes SL/TP/trailing stop

---

## Permissionless

### `LPVault.deposit(uint256 assets, address receiver)`

| Aspect | Detail |
|--------|--------|
| Visibility | public, nonReentrant |
| Caller | Liquidity Provider |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ LPVault._checkNotDenied() → ERC4626Upgradeable.deposit() → LPVault._supplyIdle() → IERC4626(morphoVault).deposit()` |
| State modified | `costBasis[receiver]`, `_balances[receiver]`, `_totalSupply`, `morphoVault` balance |
| Value flow | USDC: sender → LPVault (and excess → MetaMorpho) |
| Reentrancy guard | yes |

### `LPVault.mint(uint256 shares, address receiver)`

| Aspect | Detail |
|--------|--------|
| Visibility | public, nonReentrant |
| Caller | Liquidity Provider |
| Parameters | `shares` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ LPVault._checkNotDenied() → ERC4626Upgradeable.mint() → LPVault._supplyIdle()` |
| State modified | `costBasis[receiver]`, `_balances[receiver]`, `_totalSupply` |
| Value flow | USDC: sender → LPVault (and excess → MetaMorpho) |
| Reentrancy guard | yes |

### `LPVault.requestRedeem(uint256 shares, address controller, address owner)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | LP Shareholder or Approved Operator |
| Parameters | `shares` (user-controlled), `controller` (user-controlled), `owner` (user-controlled) |
| Call chain | `→ LPVault._basisPortion() → LPVault._transfer() → queue push` |
| State modified | `costBasis[owner]`, `_requests[requestId]`, `_queue`, `pendingRedeemAssets`, `totalPendingShares`, `_balances` |
| Value flow | spUSDC shares: owner → LPVault (escrow) |
| Reentrancy guard | yes |

### `LPVault.cancelRedeemRequest(uint256 requestId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Request Controller or Operator |
| Parameters | `requestId` (user-controlled) |
| Call chain | `→ LPVault._checkController() → LPVault._accrueBonus() → LPVault._burn() [if profit] → LPVault._transfer()` |
| State modified | `_requests[requestId]`, `pendingRedeemAssets`, `totalPendingShares`, `costBasis[controller]`, `bonusPot`, `_balances` |
| Value flow | spUSDC shares: LPVault → controller (forfeited upside burned to bonusPot) |
| Reentrancy guard | yes |

### `LPVault.processRedemptions(uint256 maxRequests)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone / Keeper Bot |
| Parameters | `maxRequests` (user-controlled) |
| Call chain | `→ LPVault.fulfilmentBudget() → LPVault._fulfil() → LPVault._accrueBonus() → LPVault._burn() → LPVault._ensureLocal()` |
| State modified | `queueHead`, `_requests`, `bonusPot`, `reservedForClaims`, `claimableShares`, `claimableAssets`, `pendingRedeemAssets`, `totalPendingShares` |
| Value flow | None direct; moves internal accounting from pending to claimable, pulls USDC from MetaMorpho if needed |
| Reentrancy guard | yes |

### `LPVault.redeem(uint256 shares, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | public, nonReentrant |
| Caller | Controller or Approved Operator |
| Parameters | `shares` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ LPVault._checkController() → LPVault._claim() → IERC20(asset).safeTransfer()` |
| State modified | `claimableShares[controller]`, `claimableAssets[controller]`, `reservedForClaims` |
| Value flow | USDC: LPVault → receiver |
| Reentrancy guard | yes |

### `LPVault.withdraw(uint256 assets, address receiver, address controller)`

| Aspect | Detail |
|--------|--------|
| Visibility | public, nonReentrant |
| Caller | Controller or Approved Operator |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled), `controller` (user-controlled) |
| Call chain | `→ LPVault._checkController() → LPVault._claim() → IERC20(asset).safeTransfer()` |
| State modified | `claimableShares[controller]`, `claimableAssets[controller]`, `reservedForClaims` |
| Value flow | USDC: LPVault → receiver |
| Reentrancy guard | yes |

### `LPVault.depositWithBonus(uint256 assets, address receiver)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Depositor |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ LPVault._checkNotDenied() → LPVault._accrueBonus() → LPVault._deposit() → store ticket` |
| State modified | `_tickets[ticketId]`, `totalTicketWeight`, `nextTicketId`, `_balances[this]`, `_totalSupply`, `costBasis` |
| Value flow | USDC: sender → LPVault |
| Reentrancy guard | yes |

### `LPVault.claimTicket(uint256 ticketId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone |
| Parameters | `ticketId` (user-controlled) |
| Call chain | `→ LPVault._closeTicket() → LPVault._accrueBonus() → LPVault._mint() → LPVault._transfer()` |
| State modified | `_tickets[ticketId].active`, `totalTicketWeight`, `bonusAccrued`, `costBasis[owner]`, `_balances`, `_totalSupply` |
| Value flow | spUSDC shares: LPVault → ticket owner (and bonus shares minted) |
| Reentrancy guard | yes |

### `LPVault.breakTicket(uint256 ticketId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Ticket Owner |
| Parameters | `ticketId` (user-controlled) |
| Call chain | `→ LPVault._closeTicket() → LPVault._transfer()` |
| State modified | `_tickets[ticketId].active`, `totalTicketWeight`, `bonusAccrued`, `bonusPot`, `costBasis[owner]`, `_balances` |
| Value flow | spUSDC shares: LPVault → ticket owner (accrued bonus forfeited to bonusPot) |
| Reentrancy guard | yes |

### `LPVault.donateToBonusPot(uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone |
| Parameters | `amount` (user-controlled) |
| Call chain | `→ LPVault._accrueBonus() → IERC20(asset).safeTransferFrom()` |
| State modified | `bonusPot` |
| Value flow | USDC: sender → LPVault |
| Reentrancy guard | yes |

### `LPVault.accrueBonus()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone |
| Parameters | None |
| Call chain | `→ LPVault._accrueBonus()` |
| State modified | `accBonusPerWeight`, `bonusPot`, `bonusAccrued`, `lastBonusUpdate` |
| Value flow | None |
| Reentrancy guard | yes |

### `LPVault.rebalance()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone |
| Parameters | None |
| Call chain | `→ LPVault._supplyIdle() → IERC4626(morphoVault).deposit()` |
| State modified | USDC balance of LPVault, Morpho vault shares |
| Value flow | USDC: LPVault → MetaMorpho |
| Reentrancy guard | yes |

### `LPVault.setOperator(address operator, bool approved)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Shareholder |
| Parameters | `operator` (user-controlled), `approved` (user-controlled) |
| Call chain | Direct storage write |
| State modified | `isOperator[msg.sender][operator]` |
| Value flow | None |
| Reentrancy guard | no |

### `PositionManager.openPosition(OpenParams calldata p)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Trader |
| Parameters | `p.spotToken` (user-controlled), `p.tier` (user-controlled), `p.margin` (user-controlled), `p.autoRollover` (user-controlled), `p.minAmountOut` (user-controlled) |
| Call chain | `→ Clones.cloneDeterministic() → usdc.safeTransferFrom() → LPVault.allocateToPosition() → PositionManager._swap() → TraderProxy.executeSwap() → V4SwapRouter.swapExactIn() → IOracle.valueInUsdc()` |
| State modified | `assetExposure[spotToken]`, `borrowedByAssetTier[spotToken][tier]`, `openPositionCount`, `positionCount`, `_positions[posId]` |
| Value flow | USDC: sender → TraderProxy clone; USDC: LPVault → TraderProxy clone; Spot Token: Uniswap v4 → TraderProxy clone |
| Reentrancy guard | yes |

### `PositionManager.claimTraderPayout()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Trader with pending pull payout |
| Parameters | None |
| Call chain | `→ usdc.safeTransfer()` |
| State modified | `claimableUSDC[msg.sender]`, `totalClaimable` |
| Value flow | USDC: PositionManager → msg.sender |
| Reentrancy guard | yes |

### `PositionManager.setOperator(address operator, bool allowed)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Trader |
| Parameters | `operator` (user-controlled), `allowed` (user-controlled) |
| Call chain | Direct storage write |
| State modified | `isOperator[msg.sender][operator]` |
| Value flow | None |
| Reentrancy guard | no |

### `PositionManager.processEpoch(uint256 posId, uint256 minAmountOut)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone / Keeper Bot |
| Parameters | `posId` (user-controlled), `minAmountOut` (user-controlled) |
| Call chain | `→ PositionManager._catchUpEpochs() → IOracle.valueInUsdc() → PositionManager._exitAndSettle() → TraderProxy.executeSwap() → TraderProxy.sweep() → PositionManager._settle() → LPVault.repayFromPosition() → InsuranceReserve.fund()` |
| State modified | `_positions[posId]`, `assetExposure`, `borrowedByAssetTier`, `openPositionCount`, `traderStats[trader]` |
| Value flow | Spot Token: TraderProxy → Uniswap v4; USDC: Uniswap v4 → TraderProxy → PositionManager; USDC bounty: PositionManager → msg.sender; USDC: PositionManager → LPVault / InsuranceReserve / Trader |
| Reentrancy guard | yes |

### `PositionManager.liquidate(uint256 posId, uint256 minAmountOut)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone / Keeper Bot |
| Parameters | `posId` (user-controlled), `minAmountOut` (user-controlled) |
| Call chain | `→ PositionManager._catchUpEpochs() → IOracle.valueInUsdc() → PositionManager._exitAndSettle() → TraderProxy.executeSwap() → TraderProxy.sweep() → PositionManager._settle()` |
| State modified | `_positions[posId].status = LIQUIDATED`, `assetExposure`, `borrowedByAssetTier`, `openPositionCount`, `traderStats[trader]` |
| Value flow | Spot Token: TraderProxy → Uniswap v4; USDC: Uniswap v4 → PositionManager; USDC bounty: PositionManager → msg.sender; USDC: PositionManager → LPVault / InsuranceReserve |
| Reentrancy guard | yes |

### `PositionManager.executeTrigger(uint256 posId, uint256 minAmountOut)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Anyone / Keeper Bot |
| Parameters | `posId` (user-controlled), `minAmountOut` (user-controlled) |
| Call chain | `→ IOracle.getPrice() → PositionManager._catchUpEpochs() → PositionManager._exitAndSettle()` |
| State modified | `_positions[posId].status`, `assetExposure`, `borrowedByAssetTier`, `openPositionCount`, `traderStats[trader]` |
| Value flow | Spot Token: TraderProxy → Uniswap v4; USDC: PositionManager → keeper / LPVault / trader / insurance |
| Reentrancy guard | yes |

### `PositionManager.pause()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Owner or Guardian |
| Parameters | None |
| Call chain | `→ PausableUpgradeable._pause()` |
| State modified | `_paused` flag |
| Value flow | None |
| Reentrancy guard | no |

### `InsuranceReserve.donate(uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `amount` (user-controlled) |
| Call chain | `→ usdc.safeTransferFrom()` |
| State modified | `insurancePoolBalance` |
| Value flow | USDC: sender → InsuranceReserve |
| Reentrancy guard | no |

### `V4SwapRouter.swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone / TraderProxy |
| Parameters | `key` (user-controlled), `zeroForOne` (user-controlled), `amountIn` (user-controlled), `minAmountOut` (user-controlled), `recipient` (user-controlled) |
| Call chain | `→ IPoolManager.unlock() → V4SwapRouter.unlockCallback() → IPoolManager.swap() → IPoolManager.sync() → IPoolManager.settle() → IPoolManager.take()` |
| State modified | External PoolManager balances |
| Value flow | TokenIn: msg.sender → PoolManager; TokenOut: PoolManager → recipient |
| Reentrancy guard | no |

### `V4SwapRouter.unlockCallback(bytes calldata data)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Uniswap v4 PoolManager (`onlyPoolManager`) |
| Parameters | `data` (protocol-derived / encoded) |
| Call chain | Internal router execution callback |
| State modified | None on router |
| Value flow | Token settlement with PoolManager |
| Reentrancy guard | no |

---

## Role-Gated

### `Trader / Operator`

#### `PositionManager.closePosition(uint256 posId, uint256 minAmountOut)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, `onlyOpen(posId)`, `onlyTraderOrOperator(posId)` |
| Caller | Trader or Approved Operator |
| Parameters | `posId` (user-controlled), `minAmountOut` (user-controlled) |
| Call chain | `→ PositionManager._catchUpEpochs() → IOracle.valueInUsdc() → PositionManager._exitAndSettle() → TraderProxy.executeSwap() → TraderProxy.sweep() → PositionManager._settle() → LPVault.repayFromPosition()` |
| State modified | `_positions[posId].status = CLOSED`, `assetExposure`, `borrowedByAssetTier`, `openPositionCount`, `traderStats[trader]` |
| Value flow | Spot Token: TraderProxy → Uniswap v4; USDC: Uniswap v4 → PositionManager → LPVault / Trader / InsuranceReserve |
| Reentrancy guard | yes |

#### `PositionManager.addMargin(uint256 posId, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, `onlyOpen(posId)`, `onlyTraderOrOperator(posId)` |
| Caller | Trader or Approved Operator |
| Parameters | `posId` (user-controlled), `amount` (user-controlled) |
| Call chain | `→ usdc.safeTransferFrom() → PositionManager._repayVault() → LPVault.repayFromPosition()` |
| State modified | `pos.borrowedPrincipal`, `pos.userMargin`, `borrowedByAssetTier`, `LPVault.totalBorrowedPrincipal` |
| Value flow | USDC: msg.sender → PositionManager → LPVault |
| Reentrancy guard | yes |

#### `PositionManager.setAutoRollover(uint256 posId, bool enabled)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyOpen(posId)`, `onlyTraderOrOperator(posId)` |
| Caller | Trader or Approved Operator |
| Parameters | `posId` (user-controlled), `enabled` (user-controlled) |
| Call chain | Direct storage write |
| State modified | `_positions[posId].autoRollover` |
| Value flow | None |
| Reentrancy guard | no |

#### `PositionManager.setOrders(uint256 posId, uint128 stopLoss, uint128 takeProfit, uint128 trailingStop)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyOpen(posId)`, `onlyTraderOrOperator(posId)` |
| Caller | Trader or Approved Operator |
| Parameters | `posId` (user-controlled), `stopLoss` (user-controlled), `takeProfit` (user-controlled), `trailingStop` (user-controlled) |
| Call chain | Direct storage write |
| State modified | `_positions[posId].stopLossPrice`, `_positions[posId].takeProfitPrice`, `_positions[posId].trailingStopPrice` |
| Value flow | None |
| Reentrancy guard | no |

### `PositionManager`

#### `LPVault.allocateToPosition(address proxy, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, `onlyPositionManager` |
| Caller | PositionManager |
| Parameters | `proxy` (protocol-derived), `amount` (protocol-derived) |
| Call chain | `→ LPVault._ensureLiquidity() → IERC20(asset).safeTransfer(proxy, amount)` |
| State modified | `totalBorrowedPrincipal`, local USDC balance (and MetaMorpho withdrawal if needed) |
| Value flow | USDC: LPVault → TraderProxy clone |
| Reentrancy guard | yes |

#### `LPVault.repayFromPosition(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, `onlyPositionManager` |
| Caller | PositionManager |
| Parameters | `principalReturned` (protocol-derived), `principalBorrowed` (protocol-derived), `yieldEarned` (protocol-derived) |
| Call chain | `→ IERC20(asset).safeTransferFrom() → LPVault._lockProfit() → LPVault._supplyIdle()` |
| State modified | `totalBorrowedPrincipal`, `lockedProfit`, `lastProfitUnlockTime`, local USDC balance |
| Value flow | USDC: PositionManager → LPVault |
| Reentrancy guard | yes |

#### `InsuranceReserve.fund(uint256 toInsurance, uint256 treasuryCut)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyPositionManager` |
| Caller | PositionManager |
| Parameters | `toInsurance` (protocol-derived), `treasuryCut` (protocol-derived) |
| Call chain | `→ usdc.safeTransferFrom()` |
| State modified | `insurancePoolBalance`, `opsTreasuryBalance` |
| Value flow | USDC: PositionManager → InsuranceReserve |
| Reentrancy guard | no |

#### `InsuranceReserve.coverShortfall(uint256 deficit)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyPositionManager` |
| Caller | PositionManager |
| Parameters | `deficit` (protocol-derived) |
| Call chain | `→ usdc.safeTransfer(msg.sender, covered)` |
| State modified | `insurancePoolBalance` |
| Value flow | USDC: InsuranceReserve → PositionManager |
| Reentrancy guard | no |

#### `TraderProxy.executeSwap(address router, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyManager` |
| Caller | PositionManager |
| Parameters | `router` (protocol-derived), `tokenIn` (protocol-derived), `tokenOut` (protocol-derived), `amountIn` (protocol-derived), `minOut` (protocol-derived), `data` (protocol-derived) |
| Call chain | `→ IRouterRegistry.isWhitelistedRouter() → tin.forceApprove() → router.call(data) → balance delta checks` |
| State modified | Token allowances, token balances on proxy |
| Value flow | TokenIn: TraderProxy → Router; TokenOut: Router → TraderProxy |
| Reentrancy guard | no |

#### `TraderProxy.sweep(address token, address to, uint256 amount)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, `onlyManager` |
| Caller | PositionManager |
| Parameters | `token` (protocol-derived), `to` (protocol-derived), `amount` (protocol-derived) |
| Call chain | `→ IERC20(token).safeTransfer(to, amount)` |
| State modified | Token balance on proxy |
| Value flow | Token: TraderProxy → PositionManager |
| Reentrancy guard | no |

### `Recorder`

#### `UniV4TwapOracle.record(address[] calldata assetList, int24[] calldata expectedTicks)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Whitelisted Recorder (`isRecorder[msg.sender]`) |
| Parameters | `assetList` (keeper-provided), `expectedTicks` (keeper-provided) |
| Call chain | `→ UniV4TwapOracle._record() → IPoolManager.getSlot0()` |
| State modified | `_observations[asset]`, `_feeds[asset].index`, `_feeds[asset].count`, `_feeds[asset].seriesStart` |
| Value flow | None |
| Reentrancy guard | no |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `PositionManager` | `setAsset()` | `address token, bool enabled, uint16 maxExposureBps, uint16 stressShockBps` | `assetConfigs[token]`, `_assetList`, `_assetListed` |
| `PositionManager` | `setSwapRouter()` | `address router` | `swapRouter`, `isWhitelistedRouter[router]` |
| `PositionManager` | `setTier()` | `uint8 tier, TierConfig cfg` | `tiers[tier]`, `_tierList`, `_tierListed` |
| `PositionManager` | `setLevel()` | `uint8 level, LevelConfig cfg` | `levels[level]` |
| `PositionManager` | `setTraderLevel()` | `address trader, uint8 level` | `traderStats[trader]` |
| `PositionManager` | `setDenied()` | `address account, bool denied` | `isDenied[account]` |
| `PositionManager` | `setRiskParams()` | `uint256 rolloverAprBps_, uint256 lpRolloverShareBps_, uint256 minNotional_, uint256 keeperBounty_, uint256 maxEntrySlippageBps_, uint256 maxExitSlippageBps_, uint256 maxLiqSlippageBps_` | Seven risk parameter storage variables |
| `PositionManager` | `setOracle()` | `IOracle oracle_` | `oracle` |
| `PositionManager` | `setGuardian()` | `address guardian_` | `guardian` |
| `PositionManager` | `unpause()` | None | `_paused = false` |
| `PositionManager` | `upgradeToAndCall()` | `address newImplementation, bytes data` | ERC-1967 implementation slot |
| `LPVault` | `setDepositCaps()` | `uint256 total, uint256 perAddress` | `depositCap`, `perAddressCap` |
| `LPVault` | `setPositionManager()` | `address pm` | `positionManager` (requires `totalBorrowedPrincipal == 0`) |
| `LPVault` | `setParams()` | `uint256 localBufferBps_, uint256 maxUtilizationBps_, uint256 profitUnlockDuration_` | `localBufferBps`, `maxUtilizationBps`, `profitUnlockDuration`, checkpoints `lockedProfit` |
| `LPVault` | `setQueueParams()` | `uint256 redeemCooldown_, uint256 stressUtilizationBps_, uint256 exitPenaltyBps_, uint256 gateCoverageBps_` | Four queue parameter storage variables |
| `LPVault` | `setBonusParams()` | `uint256 bonusDuration_, uint256 bonusEmissionPeriod_, uint256 maxBonusAprBps_, uint256 minBonusDeposit_` | Four bonus parameter storage variables |
| `LPVault` | `migrateMorphoVault()` | `IERC4626 newVault` | `morphoVault`, reallocates liquidity |
| `LPVault` | `upgradeToAndCall()` | `address newImplementation, bytes data` | ERC-1967 implementation slot |
| `InsuranceReserve` | `setPositionManager()` | `address pm` | `positionManager` (one-shot, reverts if `!= address(0)`) |
| `InsuranceReserve` | `withdrawOps()` | `address to, uint256 amount` | `opsTreasuryBalance` |
| `ChainlinkOracle` | `setFeed()` | `address asset, AggregatorV3Interface aggregator, uint32 maxStaleness, PoolKey key` | `_feeds[asset]` |
| `UniV4TwapOracle` | `setFeed()` | `address asset, PoolKey key` | `_feeds[asset]`, `_assets` |
| `UniV4TwapOracle` | `disableFeed()` | `address asset` | `_feeds[asset].enabled = false` |
| `UniV4TwapOracle` | `setRecorder()` | `address recorder, bool allowed` | `isRecorder[recorder]` |
| `UniV4TwapOracle` | `setParams()` | `uint32 twapWindow_, uint32 minObservationInterval_, uint32 maxStaleness_, uint32 maxObservationGap_, int24 maxTickDelta_, int24 maxRecordDeviation_` | Six TWAP oracle parameters |

---

## Initialization

One-time setup entry points guarded by `initializer`:

- `PositionManager.initialize(IERC20 usdc_, ILPVault lpVault_, IInsuranceReserve insurance_, IOracle oracle_, address owner_)`: Configures core contracts, creates `TraderProxy` template implementation, assigns default tiers (5x, 10x) and risk parameters.
- `LPVault.initialize(IERC20 usdc_, IERC4626 morphoVault_, address owner_)`: Initializes ERC-20 (`spUSDC`) and ERC-4626 token mechanics, sets 12h profit unlock duration, 85% utilization cap, and 30-day exit queue defaults.
