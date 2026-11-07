# Fulcrum — Consolidated Smart Contract Security Audit Report
> **Target Branch**: `feat/core-contracts` (`89b28d8` — Upstream Default Branch)  
> **Production Deployment Target**: Base Mainnet MVP (`DeployBase.s.sol` / `ProtocolDeployer.deployBase`)  
> **Active Oracle Architecture**: **Chainlink Oracle** (`ChainlinkOracle.sol`), replacing Uniswap v4 TWAP.

---

### Critical Architectural Clarification: Chainlink vs. Uniswap v4 TWAP

On the latest default branch (`feat/core-contracts`), the active deployment for Base mainnet (`DeployBase.s.sol`) uses **Chainlink feeds** (`ChainlinkOracle.sol`) and **does NOT use Uniswap v4 TWAP recording** (`UniV4TwapOracle.sol` was the prototype for Arc testnet and is inactive in Base production).

#### What This Changes in the Security Profile:
1. **ELIMINATED**: The `UniV4TwapOracle._record` tick deviation DoS (1% sample rejection) and the 10-minute series reset (`TwapNotReady`) do NOT affect the Base mainnet MVP.
2. **ACTIVE CRITICAL CONCERN #1 — Missing L2 Sequencer Uptime Feed**: `ChainlinkOracle.sol` does not query Chainlink's Base Sequencer Uptime Feed. During and immediately following a Base sequencer downtime or restart, stale prices are served, exposing the protocol to front-running and unfair liquidations.
3. **ACTIVE CRITICAL CONCERN #2 — Chainlink Oracle vs. Uniswap v4 Pool Liquidity Disconnect**: `PositionManager._exitAndSettle` calculates `floorOut = chainlinkMark * (1 - maxLiqSlippageBps)`. The spot swap executes on Uniswap v4 via `V4SwapRouter`. If the Uniswap v4 pool liquidity is shallow or deviates >2% from Chainlink's index price, `TraderProxy.executeSwap` reverts with `InsufficientOutput`, freezing liquidations and accumulating unbacked bad debt.
4. **ACTIVE CRITICAL CONCERN #3 — Core Vault & Position Flow Flaws**: The severe vulnerabilities in `LPVault` (redemption queue deadlock, cap bypass, bonus pot stream freeze, dilution on 0 assets) and `PositionManager` (free leverage on non-autoRollover positions, equity confiscation) remain fully active and critical.

---

## Executive Summary

The multi-agent security audit identified **14 distinct high-impact vulnerabilities** and **5 architectural leads** across the protocol core contracts (`LPVault.sol`, `PositionManager.sol`, `UniV4TwapOracle.sol`, `InsuranceReserve.sol`, `TraderProxy.sol`, `V4SwapRouter.sol`, `ChainlinkOracle.sol`).

### Primary Risk Vectors
1. **Liquidation Denial of Service During Volatility (Critical):** `PositionManager._exitAndSettle` rigidly enforces slippage against the lagging 10-minute TWAP (`mark * (1 - 2%)`). During rapid market drops, the spot price drops faster than the TWAP, or position unwinding causes price impact >2%, making all liquidations revert with `InsufficientOutput`. Liquidations stay frozen, saddling the vault with unliquidated bad debt.
2. **Oracle DoS Freezing Liquidations Protocol-Wide (High):** `UniV4TwapOracle._record` drops observations if live tick deviates >100 ticks (1%) from expected tick. An attacker can displace the pool tick by 1% on recorder turns to block observations; after 90s all TWAP reads revert (`TwapStale`), and after 300s the oracle resets its series, causing a 10-minute total protocol freeze (`TwapNotReady`).
3. **Permanent Deadlock of LP Redemption Queue (High):** In `LPVault.processRedemptions`, `fulfilmentBudget` requires `freeLiquidity > netStressLoss * gateCoverageBps / BPS`. Under high leverage and utilization, `fulfilmentBudget == 0`, halting redemption processing permanently since healthy positions with `autoRollover = true` roll forever without forced closure.
4. **Deposit Cap Bypass & Address Limits Evasion (High):** `LPVault.depositWithBonus` passes `address(this)` as receiver to `_deposit`, so `costBasis[user]` is never incremented, allowing depositors to bypass `perAddressCap` without limit.
5. **Streaming Bonus Pot Freezing & Zero Emission (High):** `LPVault._accrueBonus` advances `lastBonusUpdate = block.timestamp` even when emission increment truncates to 0, permanently destroying streaming rewards on frequent calls.
6. **Free Borrowing Yield Evasion on Expired Positions (High):** `PositionManager._pendingEpochs` returns `(0, 0)` whenever `!pos.autoRollover`, allowing expired positions to avoid all rollover fees while continuing to lock borrowed vault principal.
7. **Extreme Dilution on Zero Total Assets (High):** `LPVault.claimTicket` divides by `totalAssets() + 1` when converting bonus shares. If `totalAssets() == 0`, it mints astronomical shares, granting >99.999% of the vault to a ticket claimer.
8. **Emergency Morpho Migration Lockout (High):** `LPVault.migrateMorphoVault` attempts 100% share redemption immediately. If MetaMorpho is paused, compromised, or illiquid, governance cannot migrate or disconnect the vault.

---

## Detailed Findings by Audit Discipline

## Access Control & Periphery

FINDING | contract: UniV4TwapOracle | function: _record | bug_class: oracle-manipulation-dos | group_key: UniV4TwapOracle | _record | oracle-manipulation-dos
path: Attacker swaps in pool to alter tick by >100 ticks → recorder calls record with previous-block expected tick → abs(live - expectedTick) exceeds maxRecordDeviation → sample is rejected without writing observation → oracle becomes stale (TwapStale) after 90 seconds or resets series after 300 seconds (TwapNotReady) → all liquidations and positions freeze
proof: The parameter maxRecordDeviation defaults to 100 ticks (~1%). When a recorder submits expectedTick = 200000, an attacker front-runs with a small pool swap moving the live tick to 200101. In _record, abs(200101 - 200000) = 101 > 100, which emits SampleRejected and returns without recording. If repeated across 90 seconds, twapTick reverts with TwapStale(last.timestamp), preventing PositionManager.liquidate and closePosition from executing. After 300 seconds (maxObservationGap), dt > 300 causes restarted = true, resetting seriesStart to the current block and causing twapTick to revert with TwapNotReady for an additional 600 seconds (10 minutes).
description: An attacker front-runs oracle updates with small pool swaps to force sample rejection and freeze protocol liquidations.
fix: Compute a weighted or clamped update rather than rejecting observations completely when live ticks diverge from expected ticks.

FINDING | contract: PositionManager | function: _exitAndSettle | bug_class: liquidation-slippage-deadlock | group_key: PositionManager | _exitAndSettle | liquidation-slippage-deadlock
path: Asset spot price drops quickly in pool → position becomes liquidatable → keeper calls liquidate(posId, 0) → _exitAndSettle strictly enforces minOut >= mark * (1 - maxLiqSlippageBps) → pool swap returns less than floorOut due to drop or price impact → V4SwapRouter and TraderProxy revert with InsufficientOutput → position cannot be liquidated → protocol incurs bad debt
proof: Suppose 10-minute TWAP marks ETH at $3,000. In a rapid market drop, the Uniswap v4 spot price falls to $2,880 (4% below TWAP). A 10 ETH position is liquidatable. A keeper calls liquidate(posId, 0). Line 738 computes floorOut = 10 * 3000 * (10000 - 200) / 10000 = $29,400. In _swap, V4SwapRouter executes the swap and receives $28,800. Line 91 of V4SwapRouter checks if amountOut < minAmountOut ($28,800 < $29,400) and reverts with InsufficientOutput(29400, 28800). The keeper cannot supply a lower minAmountOut because line 739 forces minOut = minAmountOut > floorOut ? minAmountOut : floorOut. The liquidation cannot execute until TWAP declines.
description: Keepers cannot liquidate underwater positions during sharp market declines because the oracle slippage floor forces the swap to revert.
fix: Allow keepers to execute liquidations with configurable slippage parameters or adopt a Dutch auction format for bad-debt avoidance.

FINDING | contract: PositionManager | function: _pendingEpochs | bug_class: interest-accrual-evasion | group_key: PositionManager | _pendingEpochs | interest-accrual-evasion
path: Trader opens position with autoRollover = false → epoch duration of 7 days passes → keepers delay or omit calling processEpoch → trader holds borrowed vault funds for multiple weeks → trader invokes closePosition → _pendingEpochs returns zero debt because autoRollover is false → trader pays zero interest for overdue epochs → vault LPs forfeit borrowing yield
guard_gap: Line 700 checks `if (!pos.autoRollover || block.timestamp < pos.epochEndTime) return (0, 0);`, while the contract documentation specifies that late keepers must never grant free leverage to borrowers.
proof: Alice opens a leveraged position with autoRollover = false, borrowing 10,000 USDC. Her epoch expires at block.timestamp = openedAt + 7 days. Keepers fail to call processEpoch due to low keeper bounty or high network gas. Alice keeps the position open until day 28 and calls closePosition. Line 700 evaluates !pos.autoRollover as true and returns (debt = 0, epochs = 0). Line 708 in _catchUpEpochs adds zero to accruedRolloverDebt. In _settle, rolloverPaid = 0 and lpYield = 0. Alice borrows 10,000 USDC of LP principal for 21 overdue days without paying any rollover interest.
description: Traders evade borrowing fees for expired epochs by disabling auto-rollover when keepers delay closing their positions.
fix: Remove the !pos.autoRollover gate in _pendingEpochs so overdue positions accrue debt regardless of auto-rollover settings.

FINDING | contract: LPVault | function: migrateMorphoVault | bug_class: external-vault-lockout | group_key: LPVault | migrateMorphoVault | external-vault-lockout
path: Integrated MetaMorpho vault pauses withdrawals or incurs bad debt → vault owner calls migrateMorphoVault to disconnect or replace it → line 746 calls old.redeem for all vault shares → external call reverts due to pause or lack of liquidity → migrateMorphoVault reverts → LPVault remains linked to failing vault → _ensureLocal reverts on subsequent allocations and redemption fulfillments
proof: LPVault deposits excess USDC into morphoVault. If morphoVault experiences a security pause or liquidity deficit, old.redeem(shares, address(this), address(this)) on line 746 reverts. The owner calls migrateMorphoVault(IERC4626(address(0))) to decouple the protocol from the external vault. Because the function requires immediate and full redemption of all held shares, the entire migration transaction reverts. Consequently, morphoVault cannot be removed, and any subsequent call to allocateToPosition or processRedemptions that requires local USDC liquidity reverts inside _ensureLocal.
description: The owner cannot migrate away from a paused or illiquid external vault because the function attempts an atomic full redemption.
fix: Permit governance to update morphoVault to a new address or address(0) without requiring an immediate 100% share redemption.

LEAD | contract: PositionManager | function: openPosition | bug_class: oracle-lag-trade-blocking | group_key: PositionManager | openPosition | oracle-lag-trade-blocking
code_smells: Line 357 evaluates if (entryMark * BPS < notional * (BPS - maxEntrySlippageBps)) revert EntryPriceDeviation(entryMark, notional). When spot market prices increase rapidly above the 10-minute TWAP, spotAmount bought at current market rates produces an entryMark lower than the notional floor evaluated at the lagging TWAP.
description: Traders cannot open leveraged long positions during rapid price increases because the lagging TWAP triggers an entry slippage reversion.

LEAD | contract: ChainlinkOracle | function: getPrice | bug_class: chainlink-round-validation | group_key: ChainlinkOracle | getPrice | chainlink-round-validation
code_smells: Line 77 queries latestRoundData without checking answeredInRound >= roundId, and does not verify whether the returned answer hits aggregator minAnswer or maxAnswer circuit breaker bounds.
description: The oracle accepts stale round data and clamp-bounded prices because it does not validate round progression or aggregator circuit breakers.

LEAD | contract: PositionManager | function: _authorizeUpgrade | bug_class: upgradeable-storage-gap | group_key: PositionManager | _authorizeUpgrade | upgradeable-storage-gap
code_smells: PositionManager and LPVault inherit OpenZeppelin upgradeable contracts and define custom storage layouts without declaring a __gap variable at the end of their storage definitions.
description: Future upgrades risk storage collisions because the upgradeable contracts do not reserve storage gap space.


---

## Economic Security & Trust Gaps

# Security Audit Findings: Economic Security, Asymmetry, and Trust Gaps

## Confirmed Findings

FINDING | contract: PositionManager | function: _exitAndSettle | bug_class: oracle-slippage-lock | group_key: PositionManager | _exitAndSettle | oracle-slippage-lock
seam: economics×asymmetry
actor: keeper / liquidator
pair_or_branch: live pool spot price vs historical TWAP minimum output floor
asymmetry: liquidation swap executes at spot pool price but requires minimum output from 10-minute TWAP
path: keeper → liquidate → _exitAndSettle → _swap → TraderProxy.executeSwap → reverts with InsufficientOutput
proof: Assume ETH drops 5% in 5 minutes from 3,000 to 2,850 USDC. The 10-minute TWAP oracle returns 2,962.50 USDC. In _exitAndSettle, floorOut is mark * (10,000 - maxLiqSlippageBps) / 10,000 = 2,962.50 * 0.98 = 2,903.25 USDC. TraderProxy executes swapExactIn on Uniswap v4 pool where spot is 2,850 USDC. amountOut is 2,850 USDC < minOut (2,903.25 USDC). TraderProxy reverts with InsufficientOutput(2903250000, 2850000000). Liquidations permanently fail while price declines faster than 2% per 10 minutes, generating massive bad debt for the vault.
description: The liquidation path checks slippage against the lagging TWAP, so a liquidator cannot liquidate positions during fast market drops.
fix: Allow liquidations to execute against spot pool price with a bounded deviation from the Chainlink or real-time oracle price.

FINDING | contract: UniV4TwapOracle | function: record | bug_class: oracle-dos | group_key: UniV4TwapOracle | record | oracle-dos
seam: access×economics
actor: pool trader / attacker
pair_or_branch: normal recording vs deviated pool sample
asymmetry: recorder expects previous block tick but live tick is shifted by 1%
path: attacker → pool swap → recorder calls record → _record emits SampleRejected → maxObservationGap exceeded → series restart → twapTick reverts TwapNotReady
proof: Attacker shifts Uniswap v4 pool tick by 101 ticks (~1.01%) prior to recorder execution. In _record, _abs(int256(live) - expectedTick) = 101 > maxRecordDeviation (100). The function emits SampleRejected and returns without recording. Attacker maintains deviation or repeats for 300 seconds (maxObservationGap). The subsequent observation triggers dt > maxObservationGap, setting f.seriesStart = block.timestamp. In twapTick, block.timestamp < f.seriesStart + twapWindow (600 seconds) reverts with TwapNotReady. All liquidations, closes, and triggers revert for 10 minutes, allowing underwater positions to accumulate unliquidated bad debt.
description: An attacker manipulates the pool tick during recorder calls to reject samples, so they halt all liquidations for ten minutes.
fix: Replace recorder-based tick rejection with median observations across multiple blocks, or remove the strict deviation check.

FINDING | contract: ChainlinkOracle | function: getPrice | bug_class: stale-oracle-read | group_key: ChainlinkOracle | getPrice | stale-oracle-read
seam: access×economics
actor: trader / liquidator
pair_or_branch: normal network execution vs post-outage sequencer restart
asymmetry: L2 execution resumes before Chainlink feeds update without checking sequencer uptime feed
path: trader → openPosition/closePosition → oracle.getPrice → Chainlink aggregator returns pre-outage price
proof: On Base mainnet (chainId 8453), the optimistic sequencer can experience downtime. When the sequencer restarts, transactions execute before Chainlink nodes post fresh rounds. ChainlinkOracle.sol queries latestRoundData without checking the Base Sequencer Uptime Feed. Callers execute liquidations or open leveraged positions against stale prices before market updates take effect.
description: The oracle does not check the Base sequencer uptime feed, so callers execute trades at stale prices after a sequencer outage.
fix: Check the Chainlink Sequencer Uptime Feed and enforce a grace period before reading prices on Base.

FINDING | contract: LPVault | function: depositWithBonus | bug_class: cap-bypass | group_key: LPVault | depositWithBonus | cap-bypass
seam: access×asymmetry
actor: LP depositor
pair_or_branch: standard deposit vs depositWithBonus
asymmetry: deposit updates costBasis[receiver] but depositWithBonus passes address(this) to _deposit which skips costBasis tracking
path: depositor → depositWithBonus → _deposit(sender, address(this)) → costBasis[receiver] unchanged → maxDeposit unchanged → repeated deposit
proof: Per-address deposit cap is set to 10,000 USDC. User deposits 10,000 USDC via depositWithBonus. Line 548 calls _deposit(msg.sender, address(this), assets, shares). Inside _deposit, line 321 executes if (receiver != address(this)) costBasis[receiver] += assets. Because receiver is address(this), costBasis[user] remains 0. Line 541 queries maxDeposit(user), which computes remainAddr = capAddr - costBasis[user] = 10,000 USDC. The user calls depositWithBonus repeatedly to deposit 100,000 USDC, completely bypassing perAddressCap.
description: The function passes the vault address as the receiver, so an attacker deposits unlimited bonus assets without hitting the address cap.
fix: Increase the cost basis of the receiver address inside depositWithBonus instead of bypassing it.

FINDING | contract: LPVault | function: _accrueBonus | bug_class: precision-truncation | group_key: LPVault | _accrueBonus | precision-truncation
seam: economics×asymmetry
actor: any caller / bot
pair_or_branch: long time delta emission vs sub-second / frequent poke emission
asymmetry: emission amount truncates to zero but lastBonusUpdate advances unconditionally
path: caller → accrueBonus → _accrueBonus → _pendingEmission returns (0, 0) → lastBonusUpdate updated to block.timestamp → bonus pot never emits
proof: Total bonusPot is 5e6 (5 USDC), bonusEmissionPeriod is 90 days (7,776,000 seconds). A caller or bot invokes accrueBonus() every 2 seconds. dt = 2. stream = pot.mulDiv(dt, period) = (5e6 * 2) / 7,776,000 = 10e6 / 7,776,000 = 1. If totalTicketWeight is 20,000e6, increment = stream.mulDiv(1e18, weight) = (1 * 1e18) / 20,000e6 = 50,000,000. For smaller pots (e.g. pot = 2e6), stream = (2e6 * 2) / 7,776,000 = 0. In _accrueBonus, lastBonusUpdate = block.timestamp executes regardless. Elapsed time is erased with zero emission, permanently preventing the pot from distributing bonus rewards.
description: The contract updates the last timestamp even when zero bonus emits, so frequent calls permanently freeze the bonus pot.
fix: Update lastBonusUpdate only when the emission increment is more than zero.

FINDING | contract: PositionManager | function: _pendingEpochs | bug_class: free-leverage | group_key: PositionManager | _pendingEpochs | free-leverage
seam: access×asymmetry
actor: trader
pair_or_branch: autoRollover true vs autoRollover false
asymmetry: auto-rolling positions accrue rollover debt lazily while non-auto-rolling expired positions accrue zero debt
path: trader → setAutoRollover(posId, false) → epoch ends → weeks pass → closePosition → _pendingEpochs returns 0 → zero rollover fee paid
proof: Trader opens 10x position with 1,000 USDC margin and 9,000 USDC borrowed principal. Trader sets autoRollover = false. Position epoch ends at T. Keepers fail to force-close for 4 weeks (4 epochs). Line 700 checks if (!pos.autoRollover || block.timestamp < pos.epochEndTime) return (0, 0). Because autoRollover is false, _pendingEpochs returns debt = 0. Trader calls closePosition at T + 4 weeks. Trader pays 0 rollover fees despite holding 9,000 USDC of vault capital for an extra month. Vault LPs lose 9,000 * 8% * (28 / 365) = 55.23 USDC in expected yield.
description: A trader disables auto-rollover on an expired position, so they borrow the vault capital for elapsed epochs without paying rollover fees.
fix: Accrue rollover debt for all elapsed epochs on open positions regardless of the autoRollover setting.

FINDING | contract: PositionManager | function: _settle | bug_class: bad-debt-leak | group_key: PositionManager | _settle | bad-debt-leak
seam: economics×asymmetry
actor: keeper / liquidator
pair_or_branch: solvent liquidation vs underwater liquidation
asymmetry: keeper bounty is subtracted from swap proceeds before repaying borrowed principal
path: keeper → liquidate → _settle → u -= keeperBounty → u < borrowed → vault receives deficit as bad debt
proof: Position borrowed principal is 100 USDC. Position is liquidated with swap output usdcOut = 100 USDC. Step 1 deducts keeper bounty: k = Math.min(5e6, 100e6) = 5e6 USDC. Remaining u = 95e6 USDC. In Step 2, u (95e6) < borrowed (100e6). shortfall = 5e6 USDC. If InsuranceReserve balance is 0, lpVault.repayFromPosition receives 95e6 for 100e6 borrowed, realizing 5e6 bad debt. LPs lose 5 USDC to fund the keeper bounty on a position whose collateral fully covered the principal.
description: The settlement function pays the keeper bounty before recovering borrowed principal, so the vault absorbs the bounty as bad debt.
fix: Pay the keeper bounty from margin or insurance rather than deducting it from the borrowed principal recovery.

---

## Leads

LEAD | contract: LPVault | function: _update | bug_class: cap-bypass | group_key: LPVault | _update | cap-bypass
code_smells: _update transfers costBasis proportionally between accounts but never verifies that costBasis[to] remains below perAddressCap
description: A user transfers shares to consolidate balances above the per-address cap, but we did not prove it harms protocol solvency.

LEAD | contract: ChainlinkOracle | function: getPrice | bug_class: oracle-validation | group_key: ChainlinkOracle | getPrice | oracle-validation
code_smells: getPrice validates answer > 0 and maxStaleness, but omits answeredInRound >= roundId and minAnswer/maxAnswer boundary checks
description: The oracle ignores the round completeness check and min-max limits, but we did not prove current Base feeds trigger these bounds.

LEAD | contract: LPVault | function: cancelRedeemRequest | bug_class: basis-desync | group_key: LPVault | cancelRedeemRequest | basis-desync
code_smells: cancelRedeemRequest burns appreciation shares when valueNow > assetsAtRequest, but restores 100% of r.basis to controller
description: A user cancels a request after share appreciation and burns shares, but they regain their full basis.


---

## Math Precision & Boundaries

# Audit Findings: Math, Numerical Gap & Boundary

## Executive Summary
This audit represents the combined analysis of the `math-precision-agent`, `numerical-gap-agent`, and `boundary-agent` across all contracts in `src/` and `script/`:
- `src/LPVault.sol`
- `src/PositionManager.sol`
- `src/InsuranceReserve.sol`
- `src/TraderProxy.sol`
- `src/UniV4TwapOracle.sol`
- `src/V4SwapRouter.sol`
- `src/ChainlinkOracle.sol`
- `src/libraries/ArcConstants.sol`

We investigated rounding directions, unsafe typecasting, epoch time and rollover boundary arithmetic, division-before-multiplication precision loss, and boundary conditions in queues, bonus tickets, and liquidation thresholds.

---

FINDING | contract: LPVault | function: _accrueBonus | bug_class: precision-loss | group_key: LPVault | _accrueBonus | precision-loss
seam: boundary×precision
boundary: LPVault.accrueBonus() permissionless external call / frequent user interactions
assumption: Calling _accrueBonus() checkpoints time and continuously distributes streaming bonus yield
actual: When dt or ticket weight is small, increment truncates to zero but lastBonusUpdate is still updated to block.timestamp, permanently erasing the elapsed seconds
path: caller → LPVault.accrueBonus() → _accrueBonus() → lastBonusUpdate = block.timestamp → bonus yield discarded
proof: In LPVault.sol:914-936:
`cap = weight.mulDiv(maxBonusAprBps * dt, BPS * 365 days)`.
With `maxBonusAprBps = 2,000` (20% APR), `BPS * 365 days = 315,360,000,000`.
In the MVP configuration (`minBonusDeposit = 10e6`), suppose `weight = 50e6` (50 USDC).
For `dt = 1` second (block time on L2 / Arc):
`cap = 50e6 * 2000 * 1 / 315,360,000,000 = 100,000,000,000 / 315,360,000,000 = 0`.
`increment = 0`.
In `_accrueBonus`:
```solidity
(uint256 increment, uint256 emitted) = _pendingEmission();
lastBonusUpdate = block.timestamp;
if (increment == 0) return;
```
`lastBonusUpdate` is updated to `block.timestamp` even though `increment == 0`. The elapsed second `dt` is permanently erased without any yield accrued. Any caller calling `accrueBonus()` (or triggering it via deposit/cancel) every block resets `lastBonusUpdate` continuously, ensuring `accBonusPerWeight` never increases and ticket holders receive 0 rewards over the entire 90-day period.
description: A frequent caller resets the last bonus timestamp without an increase, so ticket holders lose their streaming rewards.
fix: Only update the last update timestamp when the accrued bonus increment is more than zero.

FINDING | contract: LPVault | function: cancelRedeemRequest | bug_class: asymmetric-accounting | group_key: LPVault | cancelRedeemRequest | asymmetric-accounting
seam: precision×invariant
boundary: LPVault.cancelRedeemRequest() when valueNow > r.assetsAtRequest
assumption: The cancelled request's cost basis is restored in proportion to the shares returned to the user
actual: 100% of r.basis is credited to costBasis[controller] even though a fraction of shares was burned as a forfeit
path: user → LPVault.requestRedeem() → vault earns yield → user → LPVault.cancelRedeemRequest() → costBasis restored 100% while shares burned → inflated basis per share
proof: In LPVault.sol:388-411:
1. User deposits 10,000 USDC, receiving 10,000e12 shares. `costBasis[user] = 10,000e6`.
2. User calls `requestRedeem(10,000e12, user, user)`. `r.shares = 10,000e12`, `r.basis = 10,000e6`, `r.assetsAtRequest = 10,000e6`. `costBasis[user]` becomes 0.
3. Vault earns profit, doubling the share price. Now 10,000e12 shares are worth 20,000e6 USDC (`valueNow = 20,000e6`).
4. User calls `cancelRedeemRequest(requestId)`:
   `keep = 10,000e12 * 10,000e6 / 20,000e6 = 5,000e12 shares`.
   `burnShares = 10,000e12 - 5,000e12 = 5,000e12 shares`.
   `_burn(address(this), 5000e12)` burns 50% of the user's shares.
   Line 406 executes:
   `costBasis[controller] += r.basis;` -> `costBasis[controller] += 10,000e6`!
5. User now holds only 5,000e12 shares, but has 10,000e6 USDC cost basis ($2.00 basis per share instead of $1.00).
6. When the user subsequently exits during pool stress, `_quote` checks `assetsAtRequest > basis`. Since `assetsAtRequest (10,000e6) <= basis (10,000e6)`, `penalty = 0`. The user completely evades the 25% exit penalty and receives an artificially doubled principal floor protection.
description: The function restores full cost basis when it burns shares, so an exiting user evades the stressed penalty.
fix: Scale the restored cost basis down by the fraction of shares the user keeps.

FINDING | contract: PositionManager | function: _pendingEpochs | bug_class: missing-accrual | group_key: PositionManager | _pendingEpochs | missing-accrual
seam: boundary×invariant
boundary: PositionManager._pendingEpochs() branch when pos.autoRollover == false
assumption: Positions that have passed epochEndTime accumulate rollover debt lazily until keepers force-close them
actual: The function explicitly checks `if (!pos.autoRollover) return (0, 0)`, completely exempting manual positions from debt accrual past expiry
path: trader → PositionManager.openPosition(autoRollover: false) → epoch expires → time passes → trader / keeper → closePosition / processEpoch → accruedRolloverDebt is 0 → trader borrows free
proof: In PositionManager.sol:699-704:
```solidity
function _pendingEpochs(Position memory pos) internal view returns (uint256 debt, uint256 epochs) {
    if (!pos.autoRollover || block.timestamp < pos.epochEndTime) return (0, 0);
    epochs = (block.timestamp - pos.epochEndTime) / EPOCH_DURATION + 1;
    if (epochs > MAX_EPOCH_CATCH_UP) epochs = MAX_EPOCH_CATCH_UP;
    debt = epochRolloverFee(pos.borrowedPrincipal) * epochs;
}
```
Line 706 docstring states: "Lazily accrues rollover debt for every elapsed epoch so late keepers never grant free leverage."
Yet, if `autoRollover == false`, `_pendingEpochs` returns `(0, 0)`.
Concrete scenario:
1. Trader opens a position with $B = 10,000$ USDC and `autoRollover = false`. Epoch 1 ends at $T_1$.
2. No keeper calls `processEpoch` immediately; 4 weeks pass.
3. Trader calls `closePosition(posId)` or keeper calls `processEpoch(posId)`.
4. `_catchUpEpochs` calls `_pendingEpochs`, which returns 0 debt.
5. In `_settle`, `rolloverPaid = Math.min(pos.accruedRolloverDebt, u) = 0`.
6. LPs receive 0 rollover yield for the 4 weeks of borrowed capital.
7. Furthermore, in `liquidationThreshold(posId)` / `isLiquidatable(posId)`, `extraDebt` evaluates to 0, artificially depressing the liquidation threshold and preventing keepers from liquidating underwater expired positions.
description: The function returns zero debt when auto-rollover is false, so late positions borrow vault funds for free.
fix: Accrue elapsed epoch fees for every open position regardless of the auto-rollover flag.

FINDING | contract: PositionManager | function: _catchUpEpochs | bug_class: truncation-leak | group_key: PositionManager | _catchUpEpochs | truncation-leak
seam: boundary×precision
boundary: PositionManager._catchUpEpochs() when elapsed epochs > MAX_EPOCH_CATCH_UP (52)
assumption: A long-held position can be caught up without gas griefing while ensuring all rollover debt is settled
actual: When elapsed epochs exceed 52, epochs are clamped to 52, leaving the remaining epochs uncharged during immediate close or liquidation
path: long position (> 52 epochs) → closePosition() / liquidate() → _catchUpEpochs charges only 52 epochs → _exitAndSettle executes in same tx → remaining epochs uncharged
proof: In PositionManager.sol:701-712:
`epochs = (block.timestamp - pos.epochEndTime) / EPOCH_DURATION + 1;`
`if (epochs > MAX_EPOCH_CATCH_UP) epochs = MAX_EPOCH_CATCH_UP;`
`pos.epochEndTime += uint64(epochs * EPOCH_DURATION);`
Concrete values:
1. Position has `borrowedPrincipal = 10,000e6` USDC and `autoRollover = true`.
2. 70 epochs elapse ($\approx 490$ days).
3. Keeper calls `liquidate(posId)` or trader calls `closePosition(posId)`.
4. `_catchUpEpochs` is called once:
   `epochs` is clamped to 52.
   `debt = epochRolloverFee(10,000e6) * 52 = 797.808180e6`.
   `pos.accruedRolloverDebt` increases by 52 epochs of fees.
   `pos.epochEndTime` is incremented by $52 \times 7\text{ days}$.
   `pos.epochEndTime` is still 18 epochs in the past!
5. In the same call, `_exitAndSettle` executes immediately and terminates the position.
6. The remaining 18 epochs of rollover debt ($18 \times 15.342465\text{e6} = 276.164370\text{e6}$ USDC) are never charged or paid to LPs.
description: The function caps accrued epochs at fifty-two, so positions open for longer escape paying full rollover fees.
fix: Process all elapsed epochs in a loop before position settlement.

FINDING | contract: LPVault | function: claimTicket | bug_class: zero-total-assets-dilution | group_key: LPVault | claimTicket | zero-total-assets-dilution
seam: three-way
boundary: LPVault.claimTicket() when totalAssets() == 0
assumption: Pricing bonusShares before clearing bonusAccrued preserves fair exchange rate
actual: When totalAssets() == 0 due to unrealized bad debt deductions, _convertToShares divides by 1, minting astronomical shares that dilute all existing LPs to zero
path: vault suffers bad debt → gross <= deductions → totalAssets() == 0 → claimTicket() → _convertToShares(reward) = reward * (totalSupply + 10^6) → _mint() → 99.999% vault ownership
proof: In LPVault.sol:244-248 and 574-577:
`totalAssets() = gross > deductions ? gross - deductions : 0`.
Suppose `gross = 50,000e6` USDC, and `deductions = reservedForClaims (40,000e6) + bonusAccrued (10,000e6) = 50,000e6`.
`totalAssets()` returns 0.
Existing LPs hold `totalSupply() = 1,000,000e12` shares.
A ticket matures with `reward = 1,000e6` USDC from `bonusAccrued`.
Line 574:
`bonusShares = _convertToShares(1,000e6, Math.Rounding.Floor);`
OpenZeppelin ERC4626 formula:
`assets.mulDiv(totalSupply() + 10**6, totalAssets() + 1, Floor)`
$= 1,000 \times 10^6 \times (1,000,000 \times 10^{12} + 10^6) / (0 + 1) = 10^{27}$ shares!
Line 575-576:
`bonusAccrued -= 1,000e6;`
`_mint(t.owner, 10^27);`
`totalAssets()` now becomes $1,000e6$ USDC.
`totalSupply()` is now $10^{27} + 10^{18} \approx 10^{27}$ shares.
The ticket claimer owns $99.999999999\%$ of the entire vault, wiping out all previous depositors.
description: A ticket owner claims rewards when vault assets equal zero, so the contract mints extreme shares and dilutes all depositors.
fix: Revert ticket claims when total assets in the vault are zero.

FINDING | contract: V4SwapRouter | function: unlockCallback | bug_class: unsafe-typecast | group_key: V4SwapRouter | unlockCallback | unsafe-typecast
seam: boundary×precision
boundary: V4SwapRouter.unlockCallback() casting int128 dOut to uint256
assumption: In an exact-input swap, the output delta dOut is always non-negative
actual: If dOut is negative due to a fee or hook deficit, casting int256(dOut) to uint256 underflows to ~2^256 - 1, corrupting slippage checks
path: PoolManager.swap() → negative dOut → uint256(int256(dOut)) underflows to 2^256 - 1 → passes minAmountOut check → poolManager.take reverts on huge uint256
proof: In V4SwapRouter.sol:87-91:
`(int128 dIn, int128 dOut) = d.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());`
`uint256 amountOut = uint256(int256(dOut));`
`if (amountOut < d.minAmountOut) revert InsufficientOutput(d.minAmountOut, amountOut);`
In Solidity 0.8+, casting a negative signed integer to an unsigned integer (e.g. `uint256(int256(-1))`) does not revert with Panic(0x11); it wraps directly to $2^{256} - 1$.
If `dOut` is negative (e.g. -1), `amountOut` becomes $2^{256} - 1$, bypassing the slippage guard `amountOut < d.minAmountOut` before attempting to call `poolManager.take(cout, d.recipient, amountOut)`.
description: The callback casts a negative delta to an unsigned integer, so a failing swap bypasses the minimum output check.
fix: Verify that the output delta is positive before casting to an unsigned integer.

FINDING | contract: LPVault | function: _basisPortion | bug_class: rounding-direction | group_key: LPVault | _basisPortion | rounding-direction
seam: precision×invariant
boundary: LPVault._basisPortion() ceiling division
assumption: Ceiling division protects against basis leakage during transfers
actual: Rounding up the basis reduction deducts more basis than the transfer proportion, prematurely exhausting an LP's cost basis on dust transfers
path: user transfers small share amount → costBasis rounds up deduction → remaining shares hold zero costBasis → stressed exit treats principal as profit
proof: In LPVault.sol:828-834:
`return Math.min(basis, basis.mulDiv(shares, bal, Math.Rounding.Ceil));`
Concrete values:
1. LP holds 1,000 shares and has `costBasis = 1` wei of USDC (e.g. from residual balance or rounding dust).
2. LP transfers 1 share to another account:
   `_basisPortion = Math.min(1, 1.mulDiv(1, 1000, Ceil)) = 1`.
   `costBasis[LP] -= 1` -> `costBasis[LP] = 0`.
3. The LP still holds 999 shares (99.9% of their original holdings), but their `costBasis` is now 0.
4. When the LP exits during stress, `_quote` checks `assetsAtRequest > basis`. Since `basis == 0`, their entire 999 shares are marked as pure profit, incurring a 25% exit penalty on principal that was never earned yield.
description: The helper rounds up the basis reduction on transfers, so a small transfer drains the user's principal floor.
fix: Round the basis reduction down during share transfers to preserve user cost basis.

FINDING | contract: UniV4TwapOracle | function: _tickToPrice18 | bug_class: rounding-direction | group_key: UniV4TwapOracle | _tickToPrice18 | rounding-direction
seam: precision×invariant
boundary: UniV4TwapOracle._tickToPrice18() when f.assetIsCurrency0 == false
assumption: Asset prices in USD round down consistently across both pool orientations
actual: Inverting priceX128 via division by a floor-rounded denominator causes the resulting price to round up instead of down
path: tick → priceX128 floor division → division by priceX128 → price18 rounds up → oracle overvalues asset collateral
proof: In UniV4TwapOracle.sol:340-345:
`uint256 priceX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64);`
`return f.assetIsCurrency0 ? Math.mulDiv(priceX128, scale, 1 << 128) : Math.mulDiv(1 << 128, scale, priceX128);`
When `assetIsCurrency0 == true`, `priceX128` is in the numerator; floor rounding in line 342 and line 344 causes `price18` to round DOWN.
When `assetIsCurrency0 == false`, `priceX128` is in the denominator. Floor division in line 342 rounds `priceX128` DOWN. Dividing by a smaller denominator in line 344 increases the quotient, causing `price18` to round UP.
When `PositionManager` evaluates collateral value during liquidation checks (`isLiquidatable`), rounding the price UP overvalues the position's spot assets, preventing liquidations at the exact boundary.
description: The formula divides by a rounded down price, so currency one asset feeds round prices up instead of down.
fix: Round the inverted price down to maintain conservative asset valuation.

LEAD | contract: ChainlinkOracle | function: getPrice | bug_class: unvalidated-round | group_key: ChainlinkOracle | getPrice | unvalidated-round
code_smells: missing answeredInRound >= roundId check in latestRoundData() consumption
description: The oracle does not check that round id equals answered in round, so the contract accepts incomplete round answers.

LEAD | contract: PositionManager | function: setTraderLevel | bug_class: unvalidated-state | group_key: PositionManager | setTraderLevel | unvalidated-state
code_smells: no validation that levels[level].enabled is true
description: The owner can set a trader level to an unconfigured level, so the trader cannot open any positions.


---

## Execution Traces, Flow Gaps & Invariants

# Findings: Execution Trace, Flow Gap, Invariants & First Principles

FINDING | contract: PositionManager | function: liquidate | bug_class: oracle-slippage-liquidation-dos | group_key: PositionManager | liquidate | oracle-slippage-liquidation-dos
input: posId with live spot price more than 2% below the 10-minute TWAP, or position size causing >2% pool price impact
assumption: live pool swap output will always be within 2% of the lagging 10-minute TWAP mark
seam: three-way (execution trace × periphery × first principles)
violated_principle: liquidators must be able to liquidate underwater positions to prevent bad debt from exceeding margin
invariant: liquidation swaps must execute whenever mark <= liquidationThreshold
violation_path: position drops below liquidation threshold → keeper calls liquidate(posId, 0) → _exitAndSettle computes floorOut = mark * 98% → swap on live Uniswap v4 pool yields less than floorOut → executeSwap reverts with InsufficientOutput
path: keeper → liquidate → _exitAndSettle → _swap → TraderProxy.executeSwap → V4SwapRouter.swapExactIn → InsufficientOutput revert → liquidation blocked
proof: Given posId with 100 WETH spot. TWAP oracle marks WETH at $2,750 (mark = $275,000). Threshold is $276,000, so mark <= threshold. maxLiqSlippageBps = 200, so floorOut = $275,000 * 98% = $269,500 ($2,695/WETH). Live pool spot price is $2,650/WETH. Selling 100 WETH yields $260,000 USDC. TraderProxy.executeSwap checks amountOut (260,000) < minOut (269,500) and reverts with InsufficientOutput(269500000000, 260000000000). The liquidation cannot complete, and the vault accumulates unbacked bad debt as spot continues falling.
description: The contract enforces a 2% minimum swap output against a lagging 10-minute TWAP, so keepers cannot liquidate positions during rapid market drops.
fix: Allow keepers to pass swap slippage limits based on live pool liquidity, and add partial liquidations.

FINDING | contract: LPVault | function: processRedemptions | bug_class: queue-solvency-deadlock | group_key: LPVault | processRedemptions | queue-solvency-deadlock
input: mature redeem requests in queue while totalBorrowedPrincipal produces stressedNetLoss >= freeLiquidity
assumption: free liquidity will naturally exceed the stressed loss requirement, or borrowers will close positions
seam: execution × first principles
violated_principle: LPs must be able to redeem their capital after the mandatory cooldown period
invariant: matured exit queue requests must be processed over time without indefinite deadlock
violation_path: borrowers open positions up to 80% utilization with autoRollover = true → PM calculates stressedNetLoss = 240,000 on 800,000 debt → vault has 200,000 freeLiquidity → fulfilmentBudget() = 0 → processRedemptions breaks with gated = true → auto-rolling positions never expire → queue remains blocked forever
path: LP → requestRedeem → wait 30 days → keeper → processRedemptions → fulfilmentBudget() == 0 → break → zero redemptions processed
proof: Total assets = 1,000,000 USDC. Borrowed principal = 800,000 USDC (80% utilization). Free liquidity = 200,000 USDC. Stress shock = 30%, maxLiqSlippage = 2%. For 10x leverage, stressed loss factor is 29.88% of borrowed principal. stressedLPLoss = 800,000 * 29.88% = 239,040 USDC. Insurance pool balance = 0, so netStressLoss = 239,040 USDC. gateCoverageBps = 10,000 (100%), so required = 239,040 USDC. fulfilmentBudget() computes free (200,000) > required (239,040) ? free - required : 0, returning 0. In processRedemptions: budget == 0 triggers gated = true and breaks immediately. queueHead never advances. Because PositionManager.processEpoch automatically rolls healthy positions indefinitely (line 463: if (pos.autoRollover && !liquidatable) return;), borrowers have no obligation to close, leaving LP withdrawals permanently deadlocked.
description: The queue halts when stress loss exceeds free liquidity, and auto-rolling healthy positions allow borrowers to lock vault capital indefinitely.
fix: Set a maximum lifetime for auto-rolling positions, and allow queued redemptions to trigger position wind-downs.

FINDING | contract: UniV4TwapOracle | function: _record | bug_class: oracle-rejection-dos | group_key: UniV4TwapOracle | _record | oracle-rejection-dos
input: attacker executes a Uniswap v4 pool swap before the recorder transaction, shifting the tick by >maxRecordDeviation (100 ticks)
assumption: live tick will remain within 1% of the recorder's expected tick from the previous block
seam: execution trace × periphery
violated_principle: the oracle must record price observations to prevent staleness and maintain liquidation availability
invariant: the oracle must maintain updatedAt within maxStaleness (90s) during active markets
violation_path: recorder broadcasts record(assetList, expectedTicks) → attacker frontruns with swap shifting pool tick by 101 ticks → _record checks _abs(live - expectedTick) > 100 → emits SampleRejected and returns without writing observation → attacker backruns swap → attacker repeats for 90 seconds → last.timestamp exceeds maxStaleness → twapTick reverts with TwapStale → all liquidations and closes fail
path: attacker → frontrun swap → recorder.record → SampleRejected → no observation written → 90 seconds pass → twapTick → TwapStale revert → PositionManager.liquidate reverts
proof: maxRecordDeviation = 100 (~1%). maxStaleness = 90 seconds. A recorder observes tick 10,000 at block N and submits record([asset], [10000]). In block N+1, an attacker frontruns with a swap moving the live tick to 10,105. Inside _record, _abs(10105 - 10000) = 105 > maxRecordDeviation (100). The function emits SampleRejected(asset, 10105, 10000) and returns immediately. No observation is written to _observations[asset]. The attacker swaps back. Repeating this for 90 seconds causes block.timestamp > last.timestamp + 90. When any user or keeper calls PositionManager.liquidate, closePosition, or executeTrigger, twapTick reverts with TwapStale(last.timestamp), completely freezing protocol risk functions.
description: An attacker shifts the pool tick by 1% to trigger sample rejection, which makes the oracle stale and halts all liquidations.
fix: Remove the silent sample rejection, and write clamped observations without discarding updates.

FINDING | contract: PositionManager | function: _settle | bug_class: unleveraged-margin-confiscation | group_key: PositionManager | _settle | unleveraged-margin-confiscation
input: posId where the trader repaid 100% of borrowed principal via addMargin, and spot price drops below notional * maintenanceBps
assumption: liquidation only occurs on debt-leveraged positions and remaining equity is just dust above debt
seam: execution × first principles
violated_principle: a user with zero borrowed debt should not lose their entire unleveraged equity to an insurance penalty
invariant: penalty must not exceed borrowed principal plus maintenance buffer
violation_path: trader opens 5x position (margin 10,000, borrowed 40,000) → trader calls addMargin(posId, 40,000) → borrowedPrincipal becomes 0, userMargin becomes 50,000 → vault is fully repaid → spot price drops 96% to 1,900 → liquidation threshold is 0 + (50,000 * 4%) = 2,000 → mark <= threshold triggers liquidate → _settle sees isLiquidation = true → sets penalty = u (1,895) and traderPayout = 0 → entire remaining equity sent to insurance pool
path: trader → addMargin (repaying 100% debt) → price drops → keeper → liquidate → _settle → isLiquidation branch → penalty = u → toInsurance += u → trader receives 0
proof: Trader opens 5x position with margin = 10,000 USDC, borrowed = 40,000 USDC, notional = 50,000 USDC. Trader calls addMargin(posId, 40,000 USDC). pos.borrowedPrincipal becomes 0, pos.userMargin becomes 50,000 USDC. The vault receives 40,000 USDC principal repayment. Later, spot value drops to 1,900 USDC. _liquidationThreshold computes borrowed (0) + debt (0) + notional * 4% (2,000) = 2,000 USDC. Because 1,900 <= 2,000, liquidate is called. After 5 USDC keeper bounty, u = 1,895 USDC. In _settle (line 797): if (isLiquidation) { penalty = u; toInsurance += u; }. traderPayout remains 0. The protocol confiscates 1,895 USDC of the trader's unleveraged funds into the insurance fund despite having zero outstanding debt.
description: The settlement function takes all remaining margin as a penalty on liquidation, even when the trader paid all debt with addMargin.
fix: Cap the liquidation penalty to the borrowed debt plus maintenance margin, and refund the remaining margin to the trader.

FINDING | contract: PositionManager | function: _exitAndSettle | bug_class: trapped-proxy-tokens | group_key: PositionManager | _exitAndSettle | trapped-proxy-tokens
input: position closure where TraderProxy holds token dust, positive swap slippage, or secondary token distributions
assumption: TraderProxy will only ever hold exact usdcOut of USDC and zero other tokens after exit swap
seam: execution × periphery
violated_principle: all assets held in isolated proxy containers must be recovered upon closure
invariant: closed proxy balances of all ERC-20 tokens must equal zero
violation_path: proxy holds spotToken, USDC, or airdropped tokens → closePosition executes _exitAndSettle → _swap returns usdcOut → proxy.sweep(usdc, manager, usdcOut) sweeps only usdcOut → pos.status set to CLOSED → no other sweep function exists in PositionManager → proxy is permanently closed and leftover tokens remain trapped forever
path: trader → closePosition → _exitAndSettle → proxy.sweep(usdc, this, usdcOut) → pos.status = CLOSED → residual tokens locked forever
proof: TraderProxy has only two external functions: executeSwap and sweep(token, to, amount), both guarded by onlyManager. PositionManager calls TraderProxy.sweep in exactly one place: line 749 of PositionManager.sol (ITraderProxy(proxy).sweep(address(usdc), address(this), usdcOut);). It sweeps only address(usdc) and only exact usdcOut. If the proxy receives an airdrop on its spot token, receives positive slippage on prior swaps, or holds any residual balance, PositionManager provides no function to sweep those tokens. Once _exitAndSettle finishes, pos.status is set to CLOSED or LIQUIDATED, causing all future calls with posId to revert on onlyOpen. All trapped funds in the deterministic clone are permanently lost.
description: The manager only sweeps the exact output USDC amount during closure, so excess spot tokens and airdrops remain permanently trapped.
fix: Transfer all remaining tokens from the proxy during closure, and add an owner sweep function for closed proxies.

FINDING | contract: LPVault | function: cancelRedeemRequest | bug_class: cost-basis-inflation | group_key: LPVault | cancelRedeemRequest | cost-basis-inflation
input: cancelRedeemRequest called on a request where valueNow > assetsAtRequest
assumption: cost basis should be restored in full even when a portion of requested shares are burned
seam: execution × first principles
violated_principle: cost basis must track actual capital deposited and must decrease proportionally when shares are burned
invariant: costBasis[account] <= total value of shares held by account
violation_path: user deposits 10,000 assets for 10,000 shares (basis 10,000) → user calls requestRedeem(10,000) → costBasis decremented by 10,000 → shares appreciate to 20,000 value → user calls cancelRedeemRequest → 5,000 shares burned for bonusPot → user keeps 5,000 shares → line 406 adds full r.basis (10,000) to costBasis → user now has 5,000 shares with 10,000 basis → user evades exit penalty on next redeem
path: user → requestRedeem → share price doubles → cancelRedeemRequest → burnShares burned → costBasis[controller] += r.basis (10,000) → inflated basis
proof: Alice deposits 10,000 USDC and receives 10,000 shares (costBasis = 10,000). Alice calls requestRedeem(10,000, Alice, Alice). r.shares = 10,000, r.basis = 10,000, r.assetsAtRequest = 10,000. Vault share value doubles so 10,000 shares are worth 20,000 USDC. Alice calls cancelRedeemRequest(1). keep = 10,000 * 10,000 / 20,000 = 5,000 shares. burnShares = 5,000 shares are burned and 10,000 forfeit is added to bonusPot. Alice receives 5,000 shares back. Line 406 executes: costBasis[controller] += r.basis;, restoring 10,000 basis to Alice. Alice now owns 5,000 shares worth 10,000 USDC with a cost basis of 10,000 USDC ($2.00/share basis instead of $1.00/share). When Alice later redeems while the pool is stressed, _quote evaluates assetsAtRequest (10,000) <= basis (10,000), resulting in penalty = 0. Alice evades the 25% exit penalty (2,500 USDC) that other stressed LPs must pay.
description: The cancel function restores the full cost basis after burning appreciated shares, so the controller avoids future exit penalties.
fix: Restore the cost basis pro rata with the ratio of kept shares to total requested shares.

FINDING | contract: UniV4TwapOracle | function: _record | bug_class: stale-clamp-on-restart | group_key: UniV4TwapOracle | _record | stale-clamp-on-restart
input: record called after an outage where dt > maxObservationGap (300 seconds)
assumption: the previous observation tick remains a valid reference for clamping after a long outage
seam: execution × periphery
violated_principle: a restarted oracle series must record current market reality rather than clamping to historical data
invariant: recorded tick must reflect live market prices after a recorder outage
violation_path: recorder goes offline for 1 day → live tick drops from 20,000 to 15,000 → recorder calls record → dt > maxObservationGap triggers restarted = true and sets seriesStart = nowTs → line 206 clamps live tick to last.tick (20,000) ± 500 = 19,500 → new series starts at 19,500 instead of 15,000 → TWAP is severely distorted for hours
path: recorder outage (dt > 300s) → recorder calls record → _record clamps live against stale last.tick → series restarts with distorted tick → TWAP deviates from market
proof: maxObservationGap = 300 seconds. maxTickDelta = 500 ticks (~5%). Suppose last recorded tick was 20,000. The recorder goes offline for 1 day (dt = 86,400s). During this time, the market crashes to tick 15,000 (~40% drop). When the recorder resumes and calls _record, dt > maxObservationGap sets restarted = true and f.seriesStart = nowTs. However, line 206 executes: int24 recorded = _clamp(live, last.tick - maxTickDelta, last.tick + maxTickDelta);. recorded is clamped to 20,000 - 500 = 19,500. obs[next].tick is set to 19,500. Even though the series restarted, it starts at 19,500 instead of the real live tick 15,000. It requires dozens of subsequent observation steps over extended time to reach 15,000, creating an artificially high TWAP that exposes the protocol to toxic arbitrage.
description: When recording restarts after an outage, the oracle clamps the live tick to the old observation from the previous series.
fix: Initialize the new series with the live tick without clamping when the observation gap elapses.

LEAD | contract: ChainlinkOracle | function: getPrice | bug_class: sequencer-uptime-missing | group_key: ChainlinkOracle | getPrice | sequencer-uptime-missing
code_smells: latestRoundData does not check answeredInRound >= roundId, and lacks integration with the L2 Sequencer Uptime Feed on Base mainnet.
description: The oracle ignores sequencer uptime feeds and incomplete rounds on Base. Stale prices can pass validation during sequencer outages.

LEAD | contract: PositionManager | function: _pendingEpochs | bug_class: debt-cap-forgiveness | group_key: PositionManager | _pendingEpochs | debt-cap-forgiveness
code_smells: MAX_EPOCH_CATCH_UP hardcaps accrued epochs to 52, forgiving interest on long-abandoned positions.
description: The contract caps accrued rollover epochs at 52. Unpaid interest past one year is forgiven and dilutes vault lenders.

LEAD | contract: PositionManager | function: _authorizeUpgrade | bug_class: missing-storage-gap | group_key: PositionManager | _authorizeUpgrade | missing-storage-gap
code_smells: UUPS upgradeable contracts PositionManager and LPVault do not define __gap storage arrays.
description: The upgradeable contracts omit storage gap arrays. Future upgrades to base contracts can corrupt storage.


---

