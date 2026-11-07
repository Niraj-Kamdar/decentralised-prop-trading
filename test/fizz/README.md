# Fizz Stateful Invariant Fuzz Suite

Comprehensive stateful property and invariant fuzzing suite for the Decentralised Prop-Trading Protocol (`LPVault`, `PositionManager`, `InsuranceReserve`, `UniV4TwapOracle`, `V4SwapRouter`, `TraderProxy`), targeting **Foundry Invariant Engine**, **Medusa**, and **Echidna**.

---

## Architecture Overview

```
                                      ┌──────────────┐
                                      │   Base.sol   │
                                      └──────┬───────┘
                                             │
                                      ┌──────▼───────┐
                                      │Snapshots.sol │
                                      └──────┬───────┘
                                             │
                                      ┌──────▼───────┐
                                      │Properties.sol│
                                      └──────┬───────┘
                                             │
                                      ┌──────▼───────┐
                                      │ Handlers.sol │
                                      └──────┬───────┘
                        ┌────────────────────┴────────────────────┐
                        │                                         │
              ┌─────────▼────────┐                      ┌─────────▼────────┐
              │ FoundryTester.sol│                      │  FuzzTester.sol  │
              │ (Foundry Units)  │                      │ (Foundry/Medusa/ │
              └──────────────────┘                      │     Echidna)     │
                                                        └──────────────────┘
```

### Components

1. **`test/fizz/Base.sol`**:
   - Deploys full test fixture with mocks:
     - `MockUSDC`: 6-decimal Circle-style token
     - `MockToken`: `weth` (18 decimals) and `cirBTC` (8 decimals)
     - `MockMetaMorpho`: ERC-4626 vault simulation for idle USDC yield
     - `MockOracle`: Spot/TWAP valuation for spot collateral
     - `MockRouter`: Exact-input spot swap execution engine
     - `MockPoolManager`: Uniswap v4 `IPoolManager` implementation with `extsload` state retrieval and flash/swap support
   - Deploys core protocol contracts:
     - `LPVault` (behind `ERC1967Proxy`)
     - `PositionManager` (behind `ERC1967Proxy`)
     - `InsuranceReserve`
     - `UniV4TwapOracle`
     - `V4SwapRouter`
   - Configures risk parameters, leverage tiers (5x and 10x), liquidation parameters, and redemption queue parameters.
   - Sets up multi-actor system (`Alice`, `Bob`, `Charlie`, and `Keeper`) with pre-funded balances and token allowances.

2. **`test/fizz/Actor.sol`**:
   - Multi-user proxy contract simulating concurrent LP depositors, leveraged traders, and liquidation keepers.
   - Supports arbitrary external calls, flash loan borrower callbacks, and ERC-721/ERC-1155 receivers.

3. **`test/fizz/Snapshots.sol`**:
   - Pre/post transaction balance and liability capture.
   - Tracks actor balances, vault total assets, total borrowed principal, and insurance reserve accounting.

4. **`test/fizz/Handlers.sol`**:
   State machine transition handlers partitioned into Clamped (bounded fuzz inputs) and Unclamped (raw fuzz inputs) layers:
   - **LP Handlers**:
     - `deposit_clamped` / `deposit_unclamped`: Deposits USDC into vault for shares
     - `mint_clamped` / `mint_unclamped`: Mints vault shares by depositing exact USDC
     - `requestRedeem_clamped` / `requestRedeem_unclamped`: Enqueues redemption requests into FIFO queue
     - `processRedemptions_clamped` / `processRedemptions_unclamped`: Permissionlessly fulfills mature queue requests
     - `redeem_clamped` / `redeem_unclamped`: Claims fulfilled redemptions for assets
     - `withdraw_clamped` / `withdraw_unclamped`: Claims fulfilled redemptions for exact assets
     - `depositWithBonus_clamped` / `depositWithBonus_unclamped`: Locks LP deposit during stressed conditions for bonus rewards
     - `claimTicket_clamped` / `claimTicket_unclamped`: Claims mature bonus ticket rewards
     - `breakTicket_clamped` / `breakTicket_unclamped`: Prematurely exits bonus ticket, forfeiting accrued bonus to pot
   - **Trader Handlers**:
     - `openPosition_clamped` / `openPosition_unclamped`: Opens 5x or 10x leveraged spot long positions on ETH or BTC
     - `addMargin_clamped` / `addMargin_unclamped`: Adds margin to active position, repaying vault principal directly
     - `rollPosition_clamped` / `rollPosition_unclamped`: Rolls over position epoch, paying rollover fee or auto-closing
     - `closePosition_clamped` / `closePosition_unclamped`: Closes open position, swaps collateral, and repays vault principal
   - **Keeper Handlers**:
     - `recordOracleObservation_clamped` / `recordOracleObservation_unclamped`: Keeper records Uniswap v4 TWAP tick observations and adjusts market prices
     - `liquidatePosition_clamped` / `liquidatePosition_unclamped`: Permissionlessly liquidates undercollateralized positions
     - `accrueBonus_clamped` / `accrueBonus_unclamped`: Pokes bonus pot streaming accrual
     - `rebalance_clamped` / `rebalance_unclamped`: Enforces idle liquidity buffer vs Morpho supply
   - **Environment Handlers**:
     - `setCurrentActor`: Switches active caller among configured actors
     - `warpTime_clamped`: Warps time to trigger maturities, cooldowns, and epoch transitions

5. **Ghost Variables**:
   - `ghost_totalDeposited`: Cumulative assets deposited by LPs
   - `ghost_totalWithdrawn`: Cumulative assets withdrawn by LPs
   - `ghost_totalBorrowed`: Active borrowed principal lent out to positions
   - `ghost_totalMargin`: Active trader margin committed in open positions
   - `ghost_openPositionsCount`: Count of currently open positions
   - `ghost_insuranceFunded`: Cumulative fees and liquidation penalties funded to insurance
   - `ghost_badDebt`: Uncovered liquidation deficits realized as bad debt

---

## Invariant Properties

Defined in `test/fizz/Properties.sol` and exposed to all fuzzing engines:

| Invariant Property | Description | Verification Method |
|---|---|---|
| `property_vaultSolvency` | Vault gross assets (`liquidUsdc + morphoAssets + totalBorrowedPrincipal`) must at all times cover `totalAssets()`, `reservedForClaims()`, and `bonusPot + bonusAccrued`. | `assertGe(gross + 2, totalAssets + reservedForClaims + bonusPot + bonusAccrued)` |
| `property_noUnbackedLoans` | `vault.totalBorrowedPrincipal()` must match the sum of active position borrowings in `PositionManager` and `ghost_totalBorrowed`. | `assertEq(vault.totalBorrowedPrincipal(), sum(borrowedPrincipal))` and `assertEq(vault.totalBorrowedPrincipal(), ghost_totalBorrowed)` |
| `property_queueOrderPreserved` | FIFO redemptions never process a later request before an earlier mature request. | Checks that no request `j > i` is marked `FULFILLED` while request `i` remains mature and `PENDING`. |
| `property_insuranceNonNegative` | Insurance accounting (`insurancePoolBalance + opsTreasuryBalance`) is non-negative and never exceeds the actual USDC held by the insurance contract. | `assertLe(insurancePoolBalance + opsTreasuryBalance, usdc.balanceOf(insurance))` |
| `property_marginHealthMaintained` | Non-liquidated active positions maintain margin ratio above liquidation threshold or can be liquidated without reverting. | For every open position: `!isLiquidatable => markValue > liquidationThreshold` and `isLiquidatable => markValue <= liquidationThreshold`. |
| `property_bonusPotConserved` | Bonus pot balance and accrued bonus are strictly backed by idle + Morpho assets in the vault and cannot be over-allocated. | `assertGe(liquid + morphoAssets, reservedForClaims + bonusPot + bonusAccrued)` |

---

## Running the Fuzz Suite

### 1. Foundry (Smoke & Invariant Campaign)

Run all fizz tests (unit tests and stateful invariant runs):
```bash
forge test --match-path "test/fizz/*" -vvv
```

Run Foundry invariant test contract specifically:
```bash
forge test --match-contract FuzzTester -vvv
```

Run quick debugging / sequence tests:
```bash
forge test --match-contract FoundryTester -vvv
```

### 2. Medusa

Run Medusa fuzzing campaign using the generated configuration:
```bash
medusa fuzz --config medusa.json
```
*(Alternative path: `--config fizz_data/medusa.json`)*

### 3. Echidna

Run Echidna in assertion mode:
```bash
echidna . --contract FuzzTester --config echidna.yaml
```
*(Alternative path: `--config fizz_data/echidna.yaml`)*

---

## Test Results

Foundry smoke and invariant testing completed with **100% pass rate** across all invariant checks and action sequences:

```
Ran 2 test suites:
- FoundryTester: 3 passed, 0 failed (smoke sequence, LP redemption flow, trader leverage flow)
- FuzzTester: 6 passed, 0 failed (all 6 invariant properties verified over 256 runs x 64 call depth)

Suite result: ok. 9 passed; 0 failed; 0 skipped.
```
