# Threat Model: Fulcrum Protocol

> In-depth architectural threat analysis, actor taxonomy, trust boundaries, and composability attack vectors.

---

## 1. Protocol Architecture & Classification

Fulcrum is classified as a **Leveraged Spot Trading Protocol** hybrid with an **ERC-4626 / ERC-7540 Asynchronous Liquidity Vault** and an **Isolated Smart-Wallet Custody Engine**.

```
┌────────────────────────────────────────────────────────────────────────┐
│                               FULCRUM                                  │
├───────────────────────────────┬────────────────────────────────────────┤
│ Trading & Custody Subsystem   │ Vault & Liquidity Subsystem            │
│ - PositionManager (UUPS)      │ - LPVault (spUSDC, UUPS, ERC-7540)     │
│ - TraderProxy (EIP-1167)      │ - MetaMorpho Idle Yield (ERC-4626)     │
│ - V4SwapRouter (Uniswap v4)   │ - InsuranceReserve (First-loss buffer) │
│ - Chainlink & V4 TWAP Oracles │ - Stressed Exit Queue & Bonus Pot      │
└───────────────────────────────┴────────────────────────────────────────┘
```

### Architectural Archetypes:
1. **Leveraged Spot Prop Trading**: Traders deposit USDC collateral (margin) and choose 5x or 10x leverage. The protocol borrows `(tier - 1) * margin` from the `LPVault` and deploys it into a dedicated, isolated `TraderProxy` clone. The proxy executes an exact-input swap into spot ETH or BTC on Uniswap v4.
2. **Asynchronous ERC-7540 Redemption Vault**: LPs supply USDC into `LPVault` and receive `spUSDC`. Redemptions are asynchronous (`requestRedeem` followed by a 30-day cooldown and `processRedemptions`), enforcing a FIFO queue that protects against bank runs while utilizing a dynamic solvency gate (`netStressLoss`).
3. **Loss-Waterfall & Backstop**: Bad debt is absorbed hierarchically: (1) trader margin, (2) `InsuranceReserve`, and (3) `LPVault` principal.

---

## 2. Threat Actors & Adversary Hierarchy

| Threat Actor | Motivation | Capabilities & Vectors | Assumed Trust |
|--------------|------------|------------------------|---------------|
| **Malicious Trader** | Capital extraction, slippage theft, unbacked leverage | Open positions, manipulate low-liquidity v4 pools, sandwich proxy swaps, evade rollover debt, exploit tier levels | Untrusted |
| **Toxic Borrower / Sandwicher** | Drain LP liquidity | Manipulate Uniswap v4 spot price right before `openPosition` or `closePosition` to force unfavorable fills on vault funds | Untrusted |
| **Compromised / Offline Keeper** | Bounties, griefing, protocol disruption | Front-run liquidations, intentionally delay `processEpoch` or `liquidate`, omit TWAP updates, censor executions | Bounded (incentive-driven) |
| **Hostile LP / Bank-Run Initiator** | Evade market losses, drain liquidity ahead of insolvency | Deposit before large closes, request exit ahead of distressed positions, break bonus tickets | Untrusted |
| **Malicious / Compromised Owner** | Protocol hijack, parameter manipulation | Upgrade UUPS proxy implementations instantly, redirect oracles, alter tiers, change fee split, withdraw ops treasury | Trusted (Requires Multi-Sig / Timelock) |
| **Compromised Guardian** | Protocol disruption | Invoke `PositionManager.pause()`, freezing new position openings | Bounded |
| **L2 / External Infrastructure Attacker** | Oracle arbitrage, sequencer manipulation | Exploit L2 sequencer downtime or restart delays to execute stale-price liquidations and entries | Untrusted |

---

## 3. Trust Boundaries & Privileged Vectors

### TB-1: Governance / Admin Authority (`onlyOwner`)
- **Components**: `PositionManager`, `LPVault`, `InsuranceReserve`, `ChainlinkOracle`, `UniV4TwapOracle`.
- **Powers**:
  - Instant implementation upgrade via UUPS (`upgradeToAndCall`) without timelock.
  - Risk parameters (`maxUtilizationBps`, `rolloverAprBps`, `maxEntrySlippageBps`, `maxLiqSlippageBps`).
  - Oracle replacement via `PositionManager.setOracle()`.
  - Swap router replacement via `PositionManager.setSwapRouter()`.
  - Operations treasury withdrawals (`InsuranceReserve.withdrawOps`).
- **Mitigation & Posture**: Contracts inherit OpenZeppelin `Ownable2StepUpgradeable`. Ownership transfer requires two-step acceptance. However, **no timelock** is currently enforced on operational actions or code upgrades.

### TB-2: PositionManager ↔ LPVault Boundary
- **Components**: `LPVault.allocateToPosition` and `LPVault.repayFromPosition`.
- **Constraint**: Strict `onlyPositionManager` modifier.
- **Guarantee**:
  - `allocateToPosition` enforces hard utilization cap (85%) and prioritizes queued LP redemptions (`amount <= free - pendingRedeemAssets`).
  - `repayFromPosition` is decoupled from the exit queue and cannot be blocked by LP queue state or stress conditions.

### TB-3: PositionManager ↔ TraderProxy ↔ Uniswap v4 Router
- **Components**: `TraderProxy.executeSwap` and `TraderProxy.sweep`.
- **Constraint**: `onlyManager` modifier.
- **Security Protections**:
  - Clones are deployed deterministically with `posId` salt.
  - `TraderProxy` validates that `msg.sender == manager` and that the router is registered in `IRouterRegistry(manager).isWhitelistedRouter(router)`.
  - Exact allowance management: `tin.forceApprove(router, amountIn)` followed by `tin.forceApprove(router, 0)`.
  - Exact balance-delta checks: Verifies that input token was completely consumed (`inAfter + amountIn == inBefore`) and that actual output received by the proxy meets `minOut`.

### TB-4: Oracle Trust Boundary
- **Components**: `ChainlinkOracle` and `UniV4TwapOracle`.
- **Constraint**:
  - `ChainlinkOracle` validates `answer > 0` and `block.timestamp - updatedAt <= maxStaleness`.
  - `UniV4TwapOracle` requires whitelisted recorders, clamps tick moves to `maxTickDelta` (~5%), and verifies `maxRecordDeviation` (~1%).
- **Residual Risk**: Neither oracle checks the L2 Sequencer Uptime Feed.

---

## 4. Key Attack Surfaces & Vector Catalog

### AS-1: Oracle Staleness & Absence of L2 Sequencer Uptime Feed
- **Surface**: `ChainlinkOracle.getPrice:73-84`
- **Attack Path**: On L2 deployments (such as Base or Arbitrum), when the sequencer goes offline and recovers, transactions queued in the mempool execute against pre-downtime Chainlink rounds before the oracle updates. Malicious traders or keepers can exploit stale prices to open positions at historical prices or trigger improper liquidations.
- **Severity**: High
- **Target Invariant**: [X-6](invariants.md#x-6)

### AS-2: Keeper Latency & Market Gap Liquidation Shortfall
- **Surface**: `PositionManager.liquidate:471-480`, `PositionManager.stressedLPLoss:533-558`
- **Attack Path**: `stressedLPLoss()` assumes that positions are liquidated when spot value reaches `V_liq = B + D_roll + N * mu`. If the spot price gaps down abruptly across blocks (e.g. flash crash or network congestion), position value can plunge below borrowed debt `B`. Trader margin is wiped, `InsuranceReserve` is exhausted, and unrecovered bad debt is immediately forced onto LPs via `LPVault.repayFromPosition:660`.
- **Severity**: High
- **Target Invariant**: [I-14](invariants.md#i-14), [E-4](invariants.md#e-4)

### AS-3: Thin Uniswap v4 Liquidity & Spot Slippage Griefing
- **Surface**: `PositionManager._swap:716-727`, `PositionManager._exitAndSettle:738-740`
- **Attack Path**: On chains with nascent v4 liquidity (e.g. Arc with thin pools), large market orders move the pool price significantly. A trader or sandwicher can time an entry or exit swap to incur maximum allowed slippage (`maxEntrySlippageBps = 100`, `maxExitSlippageBps = 100`). While entry checks against the TWAP protect against extreme jumps, repetitive trades close to the 1% boundary can extract value over time.
- **Severity**: Medium
- **Target Invariant**: [G-8](invariants.md#g-8), [I-5](invariants.md#i-5)

### AS-4: LP Queue Optionality & Solvency Gate Deadlock
- **Surface**: `LPVault.cancelRedeemRequest:382-414`, `LPVault.processRedemptions:418-450`
- **Attack Path**: An LP submits `requestRedeem()`. During the 30-day window, the pool suffers stress. If the market rebounds, the LP can cancel. The protocol partially mitigates this by burning accrued upside to `bonusPot` (`src/LPVault.sol:392-402`). However, if a massive trader position remains open, `netStressLoss()` keeps the solvency gate closed (`budget == 0`), indefinitely delaying FIFO redemption fulfillment for matured LP requests.
- **Severity**: Medium
- **Target Invariant**: [I-9](invariants.md#i-9), [I-11](invariants.md#i-11), [X-4](invariants.md#x-4)

### AS-5: Instant UUPS Implementation Upgrade
- **Surface**: `PositionManager._authorizeUpgrade:677`, `LPVault._authorizeUpgrade:757`
- **Attack Path**: Both core contracts are UUPS upgradeable proxies governed by `onlyOwner`. A compromised deployer key or multisig signer can immediately replace the logic with a contract that sweeps all LP assets or drains trader proxies.
- **Severity**: High (Centralization Vector)
- **Target Invariant**: [I-15](invariants.md#i-15)

### AS-6: MetaMorpho Re-Hypothecation Dependency
- **Surface**: `LPVault._supplyIdle:806-821`, `LPVault._ensureLocal:795-802`
- **Attack Path**: `LPVault` supplies idle USDC to an external ERC-4626 MetaMorpho vault. If MetaMorpho experiences bad debt or a withdrawal freeze, `LPVault._ensureLocal()` will revert with `InsufficientLiquidity`, blocking new margin loans (`allocateToPosition`) and potentially halting redemptions if local buffers are exhausted.
- **Severity**: Medium
- **Target Invariant**: [I-1](invariants.md#i-1)

---

## 5. Temporal Risk Analysis

### Phase 1: Deployment & System Wiring
- **Risks**:
  - `InsuranceReserve.setPositionManager()` must be called immediately after deployment. If uncalled, an attacker could front-run initialization.
  - `PositionManager.setSwapRouter()` must point to an active, valid `V4SwapRouter`.
  - Implementation contracts must have initializers disabled (`_disableInitializers()` in constructors).

### Phase 2: Steady-State Operations
- **Risks**:
  - 7-day epoch rollovers require periodic execution. `PositionManager._catchUpEpochs()` lazily calculates accrued debt across up to 52 missed epochs, ensuring late keepers do not grant free leverage.
  - Linear profit vesting (12 hours) prevents deposit-close-withdraw sandwich attacks against LP share value.

### Phase 3: Market Stress & High Volatility
- **Risks**:
  - High utilization (≥80%) triggers the stressed regime: exiting LPs forfeit 25% of pre-request earned yield to `bonusPot`.
  - Solvency gate halts redemption payouts if `freeLiquidity <= netStressLoss`.

### Phase 4: Upgrade & Parameter Migration
- **Risks**:
  - Upgrading `PositionManager` or `LPVault` must maintain strict storage layout compatibility. Storage must remain append-only.
  - Migrating `morphoVault` must redeem shares before updating address (`LPVault.migrateMorphoVault:745-748`).

---

## 6. Composability & Dependency Mapping

```
┌────────────────────────────────────────────────────────────────────────┐
│                        EXTERNAL DEPENDENCIES                           │
├─────────────────────┬───────────────────┬──────────────────────────────┤
│ System              │ Integration Point │ Critical Assumptions         │
├─────────────────────┼───────────────────┼──────────────────────────────┤
│ Uniswap v4          │ V4SwapRouter      │ Pool initialized; liquidity  │
│ PoolManager         │ TraderProxy       │ sufficient; exact delta sync │
├─────────────────────┼───────────────────┼──────────────────────────────┤
│ Chainlink Feeds     │ ChainlinkOracle   │ Timely updates; answer > 0;  │
│                     │                   │ staleness <= maxStaleness    │
├─────────────────────┼───────────────────┼──────────────────────────────┤
│ MetaMorpho / 4626   │ LPVault           │ MaxWithdraw accurate;        │
│                     │                   │ instant liquidity available  │
├─────────────────────┼───────────────────┼──────────────────────────────┤
│ Arc USDC            │ All contracts     │ 6 decimals; precompile ERC-20│
│ Precompile (0x3600) │                   │ behavior conforms to standard│
└─────────────────────┴───────────────────┴──────────────────────────────┘
```

1. **Uniswap v4 Core (`IPoolManager`)**:
   - `V4SwapRouter` implements `IUnlockCallback`. Calls `poolManager.unlock()` and executes swaps within the callback.
   - Assumes `currency0` and `currency1` are ERC-20 tokens (rejects native currency).
2. **Chainlink Price Feeds (`AggregatorV3Interface`)**:
   - Assumes decimals ≤ 18; normalizes answers to 1e18 USD.
   - Fails if `answer <= 0` or if `block.timestamp - updatedAt > maxStaleness`.
3. **MetaMorpho (`IERC4626`)**:
   - Assumes underlying asset matches USDC (`morphoVault.asset() == address(usdc)`).
   - Wrapped in `try/catch` on deposit so third-party supply caps do not revert protocol transactions.
4. **Arc USDC Precompile (`0x3600...0000`)**:
   - Rejects native 18-decimal `msg.value`. Exclusively operates over the 6-decimal ERC-20 precompile interface.
