# X-Ray Report

> **Upstream Default Branch**: `feat/core-contracts` (`89b28d8`)  
> **Production Deployment**: Base Mainnet MVP (`DeployBase.s.sol`) with **Chainlink Oracle** (`ChainlinkOracle.sol`), not TWAP.


> Fulcrum | 1981 nSLOC | df74b20 (`audit/security-review`) | foundry | 07/11/26

---

## 1. Protocol Overview

**What it does:** Decentralized spot prop trading engine providing 5x–10x margin leverage via smart-wallet proxies backed by an ERC-7540 asynchronous LP liquidity vault.

- **Users**: Prop traders seeking spot leverage on ETH/BTC; LPs earning yield from rollover fees and profit splits.
- **Core flow**: Trader deposits USDC margin; PositionManager borrows vault capital, deploys a TraderProxy clone, and executes spot swaps on Uniswap v4.
- **Key mechanism**: Isolated per-position EIP-1167 custody containers, 7-day epochs with lazy rollover debt, and ERC-7540 FIFO redemption queues with solvency gating.
- **Token model**: USDC debt/quote currency; spUSDC (ERC-4626/ERC-7540) vault LP shares; wrapped spot assets (WETH, cbBTC).
- **Admin model**: Two-step owner (`Ownable2Step`) with UUPS proxy upgradeability across core contracts; emergency guardian with pause authority.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| **Trading & Custody** | `PositionManager`, `TraderProxy` | 710 | Coordinates leverage, clone lifecycle, margin loans, triggers, and settlements |
| **Vault & Liquidity** | `LPVault` | 719 | ERC-4626/ERC-7540 pool managing idle MetaMorpho yield, exit queues, and solvency gating |
| **Oracle & Pricing** | `ChainlinkOracle`, `UniV4TwapOracle` | 341 | Multi-asset price feeds (Chainlink primary, Uniswap v4 TWAP secondary) |
| **Execution & Backstop** | `V4SwapRouter`, `InsuranceReserve`, `ArcConstants` | 150 | Uniswap v4 pool swap router, bad-debt reserve, and network constants |

### Backwards-Compatibility Code

- `UniV4TwapOracle.sol` — Replaced by `ChainlinkOracle` in the current MVP architecture plan (`docs/superpowers/plans/2026-11-07-base-mainnet-mvp.md`); retained in codebase as an alternative oracle feed implementation.

### How It Fits Together

The core trick: Isolated EIP-1167 smart-wallet clones hold spot tokens directly, allowing leveraged exposure without synthetic counterparty risk while bounding pool losses.

### Position Opening
```
Trader -> PositionManager.openPosition(margin, 5x, WETH)
           ├─ Clones.cloneDeterministic() -> deploys isolated TraderProxy
           ├─ LPVault.allocateToPosition(borrowed) -> transfers USDC to TraderProxy
           ├─ TraderProxy.executeSwap() -> V4SwapRouter.swapExactIn() -> Uniswap v4 pool
           └─ IOracle.valueInUsdc() -> verifies execution price within 1% of oracle mark
```
*TraderProxy verifies input is fully consumed and output meets minOut; position is recorded with 7-day epoch.*

### Position Closing & Waterfall Settlement
```
Trader/Keeper -> PositionManager.closePosition(posId) / liquidate(posId)
                  ├─ TraderProxy.executeSwap() -> sells spot back to USDC
                  ├─ TraderProxy.sweep() -> returns USDC to PositionManager
                  ├─ PositionManager._settle() -> pays keeper bounty, repays LPVault principal
                  ├─ InsuranceReserve.coverShortfall() -> covers bad debt if proceeds < borrowed
                  └─ LPVault.repayFromPosition() -> credits rollover yield and vests profits
```
*Settlement waterfall prioritizes keeper bounty and LP principal recovery before profit splits or liquidation penalties.*

### Asynchronous LP Redemptions
```
LP -> LPVault.requestRedeem(shares) -> escrows spUSDC shares into 30-day FIFO queue
       ... [30 days elapse] ...
Keeper/User -> LPVault.processRedemptions(maxRequests)
                ├─ LPVault.fulfilmentBudget() -> gates payout against PositionManager.netStressLoss()
                ├─ LPVault._fulfil() -> burns shares, reserves local USDC, registers claimable assets
                └─ LPVault.redeem() -> LP claims USDC
```
*Queued shares stop earning; early exit while pool is stressed forfeits 25% of pre-request yield to the bonus pot.*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Leveraged Spot Trading Protocol** with **ERC-7540 Asynchronous Liquidity Vault** characteristics

Operates real-asset leverage by borrowing vault liquidity to purchase spot inventory via AMM pools, creating bidirectional exposure between AMM execution slippage and vault solvency.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| **Trader** | Untrusted | Opens leveraged positions, adds margin, sets SL/TP orders, closes positions, claims deferred payouts |
| **Liquidity Provider** | Untrusted | Deposits USDC, mints spUSDC, queues redemptions, claims fulfilled withdrawals, locks in bonus pot |
| **Keeper Bot** | Bounded (incentivized) | Calls `liquidate()`, `processEpoch()`, `executeTrigger()`, and `processRedemptions()` for bounties |
| **Oracle Recorder** | Bounded (whitelisted) | Submits periodic tick observations to `UniV4TwapOracle`; clamped by `maxTickDelta` |
| **Guardian** | Bounded (pause-only) | Emergency authority to invoke `PositionManager.pause()`; cannot unpause or access funds |
| **Owner / Governance** | Trusted | Instant operational setters (caps, tiers, feeds, routers) and UUPS proxy upgrade authority |

**Adversary Ranking**:
1. **Manipulative Trader / Sandwicher** — Seeks to exploit AMM pool slippage, stale oracle feeds, or sandwich proxy entry/exit swaps.
2. **Compromised / Colluding Keeper** — Attempts to front-run liquidations, censor healthy roll closures, or exploit bounty calculations.
3. **Run-on-the-Vault LP** — Attempts to extract liquidity ahead of bad debt realization by gaming queue cancellation or stress mechanics.
4. **Compromised Admin Key** — Can execute instant implementation upgrades or redirect oracle and router endpoints.

### Trust Boundaries

- **UUPS Upgrade Boundary** — Owner holds instant implementation upgrade rights on `PositionManager` and `LPVault` without a timelock; compromises result in complete protocol takeover.
- **PositionManager ↔ LPVault** — Bounded by `onlyPositionManager`; `allocateToPosition` enforces an 85% utilization cap and respects queue priority (`AllocationBlockedByQueue`).
- **PositionManager ↔ TraderProxy** — Clones execute swaps strictly via `isWhitelistedRouter` and enforce post-swap balance checks (`TraderProxy.sol:56-60`).
- **Oracle Boundary** — `ChainlinkOracle` validates non-zero price and `maxStaleness` but does not verify L2 Sequencer uptime.

### Key Attack Surfaces

- **Oracle staleness on L2 sequencer restart** &nbsp;&#91;[X-6](invariants.md#x-6)&#93; — ChainlinkOracle:77-84 validates staleness against block.timestamp without querying an L2 sequencer uptime feed; worth checking if transactions can execute at pre-outage prices.

- **Market gap liquidation bad debt** &nbsp;&#91;[I-14](invariants.md#i-14), [E-4](invariants.md#e-4)&#93; — stressedLPLoss:535-558 assumes positions are liquidated promptly at the maintenance line; worth tracing whether flash crashes leave unrecovered bad debt exceeding the InsuranceReserve.

- **Thin AMM liquidity slippage extraction** &nbsp;&#91;[G-8](invariants.md#g-8), [I-5](invariants.md#i-5)&#93; — PositionManager._swap:716-727 allows up to 1% slippage against oracle mark; worth confirming if repetitive trading in thin v4 pools can extract LP principal over time.

- **LP redemption solvency gate deadlock** &nbsp;&#91;[I-9](invariants.md#i-9), [X-4](invariants.md#x-4)&#93; — LPVault.fulfilmentBudget:280-284 halts redemption fulfillments when free liquidity falls below netStressLoss; worth checking whether a persistent large open trade indefinitely traps queued LP exits.

- **Instant UUPS upgradeability without timelock** &nbsp;&#91;[I-15](invariants.md#i-15)&#93; — PositionManager._authorizeUpgrade:677 and LPVault._authorizeUpgrade:757 execute upgrades instantly via onlyOwner; worth verifying governance timelock protections prior to mainnet launch.

- **MetaMorpho idle yield withdrawal freeze** &nbsp;&#91;[I-1](invariants.md#i-1)&#93; — LPVault._ensureLocal:795-802 reverts if MetaMorpho cannot supply requested liquidity; worth checking if external vault illiquidity blocks margin allocations.

### Upgrade Architecture Concerns

- **No Timelock on UUPS Upgrades** — `PositionManager` and `LPVault` allow immediate implementation upgrades via `upgradeToAndCall`, leaving no review window for users.
- **Proxy Implementation Deployment** — `PositionManager.initialize:281` deploys `TraderProxy` as a template clone; upgrade implementations must preserve immutable manager logic.

### Protocol-Type Concerns

**As a Leveraged Spot Trading Protocol:**
- `PositionManager._liquidationThreshold:693-696` calculates maintenance margin off initial notional rather than current value; worth verifying threshold sensitivity as debt rolls over.
- `PositionManager._catchUpEpochs:706-712` caps epoch catch-up at 52; abandoned positions held beyond 1 year stop compounding rollover debt.

**As an ERC-7540 Asynchronous Vault:**
- `LPVault._quote:884-890` caps exiting share value at request-time assets while applying yield penalties; worth verifying cost-basis rounding across pro-rata transfers (`LPVault._update:327-334`).

### Temporal Risk Profile

**Deployment & Initialization:**
- `InsuranceReserve.setPositionManager:43-48` and `LPVault.setPositionManager:676-682` are one-shot latches; must be wired atomically during deployment.

**Market Stress:**
- Utilization ≥80% transitions the vault into stress mode (`isStressed()`), triggering 25% yield forfeitures on exits and enabling the bonus pot deposit mechanism.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Uniswap v4 PoolManager** — via `V4SwapRouter:46-68`
> - Assumes: Pools exist and contain sufficient liquidity for single-hop swaps.
> - Validates: Pre-swap exact approval and post-swap balance deltas on `TraderProxy`.
> - Mutability: Immutable core contract.
> - On failure: Reverts swap execution, protecting position collateral.

> **Chainlink AggregatorV3** — via `ChainlinkOracle:73-84`
> - Assumes: Valid round responses with `answer > 0` and timestamp within `maxStaleness`.
> - Validates: Positive price check and staleness threshold; lacks sequencer feed check.
> - Mutability: Governed feed configuration via `setFeed`.
> - On failure: Reverts with `InvalidPrice` or `StalePrice`, halting new opens and liquidations.

> **MetaMorpho (ERC-4626)** — via `LPVault:795-821`
> - Assumes: Instant redemption liquidity up to `maxWithdraw()`.
> - Validates: Wrapped in `try/catch` on deposit; unwrapped withdrawal on demand.
> - Mutability: Governed migration via `migrateMorphoVault`.
> - On failure: Deposit failure emits event; withdrawal failure reverts `_ensureLocal`.

**Token Assumptions:**
- USDC (6 decimals): Assumes standard ERC-20 transfer mechanics; on Arc, operates via `0x3600...0000` precompile while rejecting native `msg.value`.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **40 Enforced Guards** (`G-1` … `G-40`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **16 Single-Contract Invariants** (`I-1` … `I-16`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **6 Cross-Contract Invariants** (`X-1` … `X-6`) — caller/callee pairs that cross scope boundaries
> - **4 Economic Invariants** (`E-1` … `E-4`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-6]`, `[I-14]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | Comprehensive `README.md` with architecture diagrams and economic models |
| NatSpec | Adequate (~10 files) | Core public interfaces annotated; NatSpec on functions and events |
| Spec/Whitepaper | Present (per spec) | Detailed MVP specifications in `docs/superpowers/plans/2026-11-07-base-mainnet-mvp.md` |
| Inline Comments | Thorough | Math rationale, waterfall logic, and accounting invariants heavily documented |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 14 | File scan (always reliable) |
| Test functions | 116 | File scan (always reliable) |
| Line coverage | 44.66% overall (92.5% core contracts) | Coverage tool (`forge coverage --ir-minimum`) |
| Branch coverage | 25.91% overall (58.0% core contracts) | Coverage tool (`forge coverage --ir-minimum`) |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 116 | `LPVault`, `PositionManager`, `ChainlinkOracle`, `TraderProxy`, `InsuranceReserve` |
| Stateless Fuzz | 2 | `PositionManager.t.sol`, `WithdrawalQueue.t.sol` |
| Stateful Fuzz (Foundry) | 6 | `InvariantQueue.t.sol` (16,384 calls per invariant across 256 runs) |
| Fork | 4 | `ArcFork.t.sol`, `BaseFork.t.sol` (skipped without live RPC URL) |
| Formal Verification (Halmos/Certora) | 0 | None detected |

### Gaps

- Missing L2 sequencer downtime tests for `ChainlinkOracle`.
- No formal verification or symbolic execution specs on the multi-step settlement waterfall.
- Fork tests for live Uniswap v4 execution require active RPC environment.

---

## 6. Developer & Git History

> Repo shape: normal_dev — Normal development history with 7 source-touching commits over 2 days.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Claude | 8 | +2578 / -239 | 88.5% |
| Niraj Kamdar | 55 | +336 / -76 | 11.5% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 2 | Small team collaboration with AI pair-programming |
| Merge commits | 17 of 63 (27.0%) | Feature branches merged into main with structured review |
| Repo age | 2026-11-06 → 2026-11-07 | 1 day rapid development burst before audit |
| Recent source activity (30d) | 7 commits | High intensity active codebase construction |
| Test co-change rate | 100.0% | Every source-modifying commit modified corresponding tests |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/PositionManager.sol` | 5 | Core risk engine and UUPS migration hotspot |
| `src/LPVault.sol` | 4 | High churn on queue mechanics, caps, and bonus pot |
| `src/interfaces/IProtocol.sol` | 4 | Interface updates for trader levels and risk views |
| `src/ChainlinkOracle.sol` | 1 | Newly introduced oracle adapter |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `dae107b` | 2026-11-06 | Replace Pyth with a Uniswap v4 TWAP oracle and trade through v4 pools | 13 | Pricing refactor, access control, 5 security domains touched |
| `d641ac1` | 2026-11-07 | feat(vault): add owner-configurable total and per-address deposit caps and denylist check | 11 | Caps & denylist gating, balance & transfer logic |
| `d76d339` | 2026-11-06 | Add core contracts for leveraged spot prop trading on Arc | 10 | Initial core protocol deployment |
| `3b8d518` | 2026-11-07 | feat(position-manager): add trader levels with auto promotion/demotion and a denylist | 9 | Level constraints, margin/leverage bounds |
| `8b96353` | 2026-11-07 | feat(oracle): add Chainlink oracle with staleness check and v4 pool routing | 8 | Oracle integration and staleness checks |
| `b641acb` | 2026-11-07 | feat(position-manager): make PositionManager UUPS-upgradeable with settable oracle | 8 | UUPS proxy conversion and access control |
| `a0fedc9` | 2026-11-06 | Add LP withdrawal queue, stress bonus pot and solvency gate | 7 | ERC-7540 queue, bonus pot liabilities, solvency gate |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| `access_control` | 7 | `PositionManager.sol`, `LPVault.sol`, `InsuranceReserve.sol`, `ChainlinkOracle.sol` |
| `oracle_price` | 7 | `PositionManager.sol`, `ChainlinkOracle.sol`, `UniV4TwapOracle.sol` |
| `fund_flows` | 6 | `PositionManager.sol`, `LPVault.sol`, `TraderProxy.sol`, `InsuranceReserve.sol` |
| `liquidation` | 6 | `PositionManager.sol`, `LPVault.sol`, `InsuranceReserve.sol` |
| `state_machines` | 6 | `PositionManager.sol`, `LPVault.sol` |

### Security Observations

- **100% test co-change discipline** — Every commit touching core logic updated corresponding test suites.
- **Rapid feature consolidation** — Entire codebase and major features (UUPS, trader levels, deposit caps, Chainlink oracle) committed in 48 hours.
- **Concentrated authoring** — Claude authored 88.5% of lines added, followed by Niraj Kamdar (11.5%) focusing on governance, levels, and caps.
- **No unresolved technical debt** — Zero `TODO`, `FIXME`, or `HACK` tags detected in source files.

### Cross-Reference Synthesis

- **PositionManager is #1 hotspot and primary attack vector** — 5 source commits, UUPS upgradeability, and settlement waterfall route through it → priority focus on `_settle`, `_exitAndSettle`, and `openPosition`.
- **High test co-change correlates with passing invariant suites** — 6 stateful invariant tests with 16k calls verify queue solvency and absence of dilution under stress.

---

## X-Ray Verdict

**ADEQUATE** — Comprehensive unit, fuzz, and stateful invariant test suites covering core contracts, accompanied by detailed specification docs and clean access boundaries, balanced by recent rapid code evolution and absence of a timelock on UUPS upgradeability.

**Structural facts:**
1. 1981 nSLOC of Solidity across 4 subsystems and 7 core contracts.
2. 2 upgradeable UUPS proxies (`PositionManager`, `LPVault`) governed by two-step ownership without timelocks.
3. 116 unit tests, 2 stateless fuzz tests, and 6 stateful Foundry invariant test suites running 16,384 calls each.
4. Core contract test line coverage exceeds 92.5% (`LPVault` 92.06%, `PositionManager` 92.84%, `ChainlinkOracle` 96.77%).
5. 2 developers authored the repository over 63 commits with 100% test co-change rate on source changes.
