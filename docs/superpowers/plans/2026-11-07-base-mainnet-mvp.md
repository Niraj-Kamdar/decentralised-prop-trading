# Base Mainnet MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the protocol to Base mainnet as a capped MVP: upgradeable PositionManager, Chainlink pricing, on-chain trader levels with auto promotion/demotion, configurable vault caps, a denylist, and a keeper that liquidates.

**Architecture:** `PositionManager` becomes a UUPS proxy (like `LPVault` already is) so new params ship as upgrades. A new `ChainlinkOracle` implements the existing `IOracle` and replaces `UniV4TwapOracle` (it still returns the Uniswap v4 `PoolKey` used for swaps). A trader **level** (experience) is added next to the existing **tier** (leverage): the level gates max margin and max leverage and sets the profit cut; it updates automatically on every close/liquidation. `LPVault` enforces owner-settable total and per-address deposit caps and reads the denylist from `PositionManager`.

**Tech Stack:** Solidity 0.8.28, Foundry (via_ir, cancun), OpenZeppelin 5 (+ upgradeable), Uniswap v4 core, Chainlink AggregatorV3 (inline interface, no new dependency), viem keeper (`frontend/scripts/keeper.ts`).

**Spec:** Agreed in conversation on 2026-11-07 (no separate doc). Decisions it fixed:
- Base mainnet; long only; assets ETH (WETH) and BTC (cbBTC) only.
- Vault total cap $10,000, per-address cap $100 (1% of the cap) — both owner-configurable.
- Idle USDC keeps earning yield via the existing ERC-4626 idle-vault slot (`morphoVault`, any USDC ERC-4626 — MetaMorpho or Aave's static aUSDC wrapper).
- Every admin function is `onlyOwner` on `Ownable2Step`; owner is a Safe. No timelock for MVP.
- `PositionManager` is UUPS.
- Trader levels: start at level 0 with low margin and a higher profit cut; auto-promote and auto-demote on-chain; all level params configurable.
- Denylist: function only, checked on deposit and open; closing/redeeming always works.
- Liquidation prices from Chainlink with a staleness check. Dropped for MVP: sequencer feed, TWAP cross-check, sanctions oracle, min hold time, drawdown tracking, ERC-7201.

## Global Constraints

- Storage is append-only in both upgradeable contracts; never reorder or remove a storage variable.
- Every new admin setter is `onlyOwner` and emits an event.
- No new dependencies (Chainlink interface is declared inline).
- `PositionManager` runtime size must stay under 24,576 bytes (`forge build --sizes`); currently 18,851.
- Commits: conventional, domain scopes (`feat(position-manager):`, `feat(vault):`, `feat(oracle):`, `feat(deploy):`, `feat(keeper):`), no AI mentions, no Co-Authored-By, `git add` named files only, never commit `.claude/`, `CLAUDE.md`, `todo/`, `test.log`.
- Work on branch `feat/base-mainnet-mvp` cut from `feat/core-contracts`.

## Review Focus

1. **Empty vault / exact-cap deposits** — first deposit into an empty vault must succeed up to `min(depositCap, perAddressCap)`; a deposit landing exactly on a cap succeeds; one wei over reverts. Test: `test_caps_firstDepositAndExactBoundary` (Task 4).
2. **Bad Chainlink answers** — zero/negative answer and stale `updatedAt` must revert, never price at 0 (which would make every position liquidatable). Tests: `test_getPrice_revertsOnNonPositive`, `test_getPrice_revertsWhenStale` (Task 2).
3. **Level edges** — level 0 never demotes; the top enabled level never promotes; disabling a level blocks opens for traders on it but not their closes. Tests: `test_level0_neverDemotes`, `test_topLevel_neverPromotes`, `test_disabledLevel_blocksOpenNotClose` (Task 3).
4. **Denied users can always exit** — a denied trader can still close/be liquidated and a denied LP can still request redeem. Tests: `test_denied_canStillClose` (Task 3), `test_denied_lpCanStillRequestRedeem` (Task 4).
5. **Upgrade safety** — open positions survive `upgradeToAndCall`; non-owner cannot upgrade; the implementation cannot be initialized directly. Tests: `test_upgrade_preservesPositions`, `test_upgrade_onlyOwner`, `test_impl_cannotInitialize` (Task 1).

---

### Task 1: PositionManager → UUPS

**Files:**
- Modify: `src/PositionManager.sol` (inheritance, constructor → `initialize`, immutables → storage, field initializers → `initialize`, add `setOracle`, `_authorizeUpgrade`)
- Modify: `test/Base.t.sol` (deploy via `ERC1967Proxy`; add `_deployPM` helper)
- Modify: `test/MVPConfig.t.sol:34-40` (use `_deployPM`)
- Modify: `script/lib/ProtocolDeployer.sol:52-54` (deploy via proxy)
- Test: `test/PositionManagerUpgrade.t.sol` (new)

**Interfaces:**
- Produces:
  - `function initialize(IERC20 usdc_, ILPVault lpVault_, IInsuranceReserve insurance_, IOracle oracle_, address owner_) external initializer`
  - `function setOracle(IOracle oracle_) external onlyOwner` — reverts `ZeroAddress`; emits `OracleSet(address oracle)`
  - `usdc`, `lpVault`, `insurance`, `oracle`, `proxyImplementation` keep their public getter names and types (now storage).
  - Test helper in `BaseTest`: `function _deployPM(IOracle o) internal returns (PositionManager)` — deploys impl + `ERC1967Proxy`, called while pranked as `owner`.

- [ ] **Step 0: Branch**

```bash
git checkout -b feat/base-mainnet-mvp
```

- [ ] **Step 1: Write the failing tests** in `test/PositionManagerUpgrade.t.sol` (extends `BaseTest`)

```solidity
function test_upgrade_preservesPositions() public {
    uint256 id = _open(1_000e6, 5, false);
    vm.prank(owner);
    pm.upgradeToAndCall(address(new PositionManager()), "");
    assertEq(pm.getPosition(id).trader, trader);
    assertEq(pm.minNotional(), 500e6);           // field defaults survived (set in initialize)
    vm.prank(trader);
    pm.closePosition(id, 0);                     // still operable through the old proxy clone
}

function test_upgrade_onlyOwner() public {
    address impl = address(new PositionManager());
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
    vm.prank(trader);
    pm.upgradeToAndCall(impl, "");
}

function test_impl_cannotInitialize() public {
    PositionManager impl = new PositionManager();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    impl.initialize(IERC20(address(usdc)), ILPVault(address(vault)), IInsuranceReserve(address(insurance)), IOracle(address(oracle)), owner);
}

function test_setOracle_onlyOwner() public {
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
    vm.prank(trader);
    pm.setOracle(IOracle(address(1)));
}
```

- [ ] **Step 2: Run** `forge test --match-contract PositionManagerUpgrade` — Expected: compile FAIL (`initialize`/`upgradeToAndCall`/`setOracle` not found).

- [ ] **Step 3: Implement in `src/PositionManager.sol`**
  - Inherit `Initializable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable` (same import paths `LPVault.sol` uses) instead of the non-upgradeable trio.
  - `constructor() { _disableInitializers(); }`
  - Move constructor body into `initialize`; call `__Ownable_init(owner_)`, `__Pausable_init()`, `__ReentrancyGuard_init()`.
  - The five immutables become plain storage at the **top** of the storage block (fresh deployment, no layout to preserve yet). `proxyImplementation = address(new TraderProxy(address(this)))` stays inside `initialize` so `address(this)` is the proxy.
  - The seven risk-param field initializers (`rolloverAprBps = 800` … `maxLiqSlippageBps = 200`) are assigned in `initialize` with the same values — field initializers do not run behind a proxy.
  - `function _authorizeUpgrade(address) internal override onlyOwner {}`

- [ ] **Step 4: Switch deployments to the proxy** — `BaseTest.setUp`, `MVPConfigTest.setUp`, `ProtocolDeployer.deployArc` all use `ERC1967Proxy(new PositionManager(), abi.encodeCall(PositionManager.initialize, (...)))`. Add `_deployPM` to `BaseTest` and use it in both tests.

- [ ] **Step 5: Run** `forge test` — Expected: all existing tests + 4 new PASS (fork tests skip without RPC).

- [ ] **Step 6: Size check** `forge build --sizes | grep PositionManager` — Expected: runtime < 24,576.

- [ ] **Step 7: Commit**

```bash
git add src/PositionManager.sol test/Base.t.sol test/MVPConfig.t.sol test/PositionManagerUpgrade.t.sol script/lib/ProtocolDeployer.sol
git commit -m "feat(position-manager): make PositionManager UUPS-upgradeable with settable oracle"
```

---

### Task 2: ChainlinkOracle

**Files:**
- Create: `src/ChainlinkOracle.sol`
- Modify: `test/mocks/Mocks.sol` (add `MockAggregator`)
- Test: `test/ChainlinkOracle.t.sol`

**Interfaces:**
- Consumes: `IOracle` (`src/interfaces/IProtocol.sol`) — unchanged.
- Produces:
  - `interface AggregatorV3Interface { function decimals() external view returns (uint8); function description() external view returns (string memory); function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }` (declared in `ChainlinkOracle.sol`)
  - `contract ChainlinkOracle is IOracle, Ownable2Step` with `constructor(address usdc_, address owner_)`
  - `function setFeed(address asset, AggregatorV3Interface aggregator, uint32 maxStaleness, PoolKey calldata key) external onlyOwner` — reverts `InvalidFeed()` if aggregator is zero, `maxStaleness == 0`, or `key`'s two currencies are not `{asset, usdc}`; caches `IERC20Metadata(asset).decimals()` and `aggregator.decimals()`; emits `FeedSet(asset, aggregator, maxStaleness)`.
  - `getPrice(asset)` → 1e18 USD per whole token. Errors: `FeedNotSet(asset)`, `InvalidPrice(asset, answer)` for `answer <= 0`, `StalePrice(asset, updatedAt)` when `block.timestamp - updatedAt > maxStaleness`.
  - `valueInUsdc(asset, amount) = amount * price18 / 10**(assetDecimals + 18 - 6)` (same formula as `UniV4TwapOracle`).
  - `poolKey(asset)` → stored key; reverts `FeedNotSet`.
  - Test mock: `MockAggregator(uint8 decimals_)` with `setAnswer(int256 answer, uint256 updatedAt)`.

- [ ] **Step 1: Write the failing tests** in `test/ChainlinkOracle.t.sol` (plain `Test`; deploy `MockUSDC`, `MockToken("WETH",18)`, `MockToken("cbBTC",8)`, two `MockAggregator(8)`)

```solidity
function test_getPrice_scalesTo1e18() public {        // ETH $2,500.12345678, BTC $60,000
    eth.setAnswer(2_500_12345678, block.timestamp);
    assertEq(o.getPrice(address(weth)), 2_500.12345678e18);
}
function test_valueInUsdc_handlesDecimals() public {   // 2 WETH @ $2,500 = 5,000e6 ; 0.5 cbBTC @ $60,000 = 30,000e6
    assertEq(o.valueInUsdc(address(weth), 2e18), 5_000e6);
    assertEq(o.valueInUsdc(address(cbbtc), 0.5e8), 30_000e6);
}
function test_getPrice_revertsOnNonPositive() public { // answer 0 and -1 → InvalidPrice
}
function test_getPrice_revertsWhenStale() public {     // maxStaleness 3600: updatedAt = now-3600 ok, now-3601 → StalePrice
}
function test_unsetFeed_reverts() public {             // getPrice/poolKey on unknown asset → FeedNotSet
}
function test_setFeed_rejectsKeyWithoutUsdc() public { // key {weth, cbbtc} → InvalidFeed
}
function test_setFeed_onlyOwner() public {
}
```

- [ ] **Step 2: Run** `forge test --match-contract ChainlinkOracle` — Expected: compile FAIL.
- [ ] **Step 3: Implement** `src/ChainlinkOracle.sol` and `MockAggregator` per Interfaces. Scaling: `uint256(answer) * 10**(18 - feedDecimals)` (feed decimals ≤ 18 enforced in `setFeed`).
- [ ] **Step 4: Run** `forge test --match-contract ChainlinkOracle` — Expected: 7 PASS.
- [ ] **Step 5: Commit** (`BaseTest` keeps `MockOracle`; Task 5's fork test covers the real wiring)

```bash
git add src/ChainlinkOracle.sol test/ChainlinkOracle.t.sol test/mocks/Mocks.sol
git commit -m "feat(oracle): add Chainlink oracle with staleness check and v4 pool routing"
```

---

### Task 3: Trader levels + denylist in PositionManager

**Files:**
- Modify: `src/PositionManager.sol`
- Modify: `src/interfaces/IProtocol.sol` (add `IDenylist`)
- Modify: `test/Base.t.sol` (configure a permissive level 0 so existing tests keep passing)
- Modify: `test/PositionManager.t.sol:83-121` (`test_close_inProfit_10xSplit`, `test_close_inProfit_5xSplit` now assert the level cut)
- Test: `test/TraderLevels.t.sol`

**Interfaces:**
- Consumes: Task 1 storage layout (append new storage **after** `maxLiqSlippageBps`).
- Produces:

```solidity
interface IDenylist { function isDenied(address account) external view returns (bool); }   // IProtocol.sol

struct LevelConfig {
    bool enabled;
    uint8 maxLeverage;        // highest `tier` this level may open
    uint128 maxMargin;        // 6-dec USDC per position
    uint16 lpProfitBps;
    uint16 treasuryProfitBps;
    uint32 promoteMinTrades;  // closes since entering this level
    uint128 promoteMinPnl;    // realized pnl since entering this level, 6-dec
    uint128 demoteMaxLoss;    // demote when pnl <= -demoteMaxLoss; 0 = never
}
struct TraderStats { uint8 level; uint32 trades; int128 pnl; }

mapping(uint8 level => LevelConfig) public levels;
mapping(address trader => TraderStats) public traderStats;
mapping(address account => bool) public isDenied;     // PositionManager is IDenylist

function setLevel(uint8 level, LevelConfig calldata cfg) external onlyOwner;   // InvalidParams if lp+treasury > BPS or maxLeverage < 2; emits LevelSet
function setTraderLevel(address trader, uint8 level) external onlyOwner;       // manual override, resets stats; emits LevelChanged
function setDenied(address account, bool denied) external onlyOwner;           // emits DeniedSet
event LevelChanged(address indexed trader, uint8 fromLevel, uint8 toLevel);
error Denied(address account);
error LevelLimitExceeded(uint8 level);
```

- `TierConfig` loses `lpProfitBps` / `treasuryProfitBps` (the cut now comes from the level); `_setTier` drops their check; initialize sets `tiers[5] = {true, 400}`, `tiers[10] = {true, 200}`.
- No level is configured in `initialize`; the deployer sets them (Task 5). Opening with no enabled level 0 reverts `LevelLimitExceeded(0)`.

- [ ] **Step 1: Write the failing tests** in `test/TraderLevels.t.sol`. In `setUp`, after `super.setUp()`, owner sets:
  - L0 `{true, 5, 100e6, 1_500, 500, 2, 10e6, 0}`
  - L1 `{true, 10, 1_000e6, 1_000, 300, 2, 50e6, 20e6}`
  - L2 disabled.

  Profits/losses are produced with `_setPrice` between open and close.

```solidity
function test_open_respectsLevelLimits() public {
    // L0: 10x → LevelLimitExceeded(0); margin 101e6 → LevelLimitExceeded(0); 100e6 @ 5x ok
}
function test_profitCut_usesLevel() public {
    // L0 trader closes with profit P: lp gets 15% of P, treasury 5%, trader the rest
}
function test_promotes_afterTradesAndPnl() public {
    // two profitable closes totalling >= 10e6 → traderStats.level == 1, trades == 0, pnl == 0, emits LevelChanged(trader,0,1)
}
function test_noPromotion_whenPnlShort() public {
    // two closes, pnl 9e6 → still level 0, trades == 2
}
function test_demotes_onLoss() public {
    // owner setTraderLevel(trader,1); a close losing >= 20e6 → level 0
}
function test_liquidation_countsAsFullMarginLoss() public {
    // liquidated position records pnl == -int(userMargin)
}
function test_level0_neverDemotes() public {
    // large loss at L0 → still level 0
}
function test_topLevel_neverPromotes() public {
    // at L1 (L2 disabled) with huge pnl → stays 1
}
function test_disabledLevel_blocksOpenNotClose() public {
    // open at L0, owner disables L0, open again → LevelLimitExceeded(0); closePosition still succeeds
}
function test_denied_cannotOpen() public {
    // setDenied(trader,true) → openPosition reverts Denied(trader)
}
function test_denied_canStillClose() public {
    // open, deny, close succeeds and pays out
}
function test_levelAdmin_onlyOwner() public {
    // setLevel / setTraderLevel / setDenied from trader → OwnableUnauthorizedAccount
}
```

- [ ] **Step 2: Run** `forge test --match-contract TraderLevels` — Expected: compile FAIL.

- [ ] **Step 3: Implement**
  - `openPosition`: first `if (isDenied[msg.sender]) revert Denied(msg.sender);` then `LevelConfig memory lv = levels[traderStats[msg.sender].level]; if (!lv.enabled || p.tier > lv.maxLeverage || p.margin > lv.maxMargin) revert LevelLimitExceeded(level);`
  - `_settle`: replace `TierConfig memory t = tiers[pos.tier]` with the trader's current `LevelConfig`.
  - `_exitAndSettle`: after `_settle`, call `_recordResult(pos.trader, int256(traderPayout) - int256(uint256(pos.userMargin)))` (bad debt and liquidation have `traderPayout == 0`).
  - `_recordResult` (the only non-obvious algorithm):

```solidity
function _recordResult(address trader, int256 pnl) internal {
    TraderStats storage s = traderStats[trader];
    s.trades += 1;
    s.pnl += pnl.toInt128();
    LevelConfig memory l = levels[s.level];
    uint8 from = s.level;
    uint8 to = from;
    if (from > 0 && l.demoteMaxLoss > 0 && s.pnl <= -int256(uint256(l.demoteMaxLoss))) to = from - 1;
    else if (from < type(uint8).max && levels[from + 1].enabled && s.trades >= l.promoteMinTrades
        && s.pnl >= int256(uint256(l.promoteMinPnl))) to = from + 1;
    if (to != from) { s.level = to; s.trades = 0; s.pnl = 0; emit LevelChanged(trader, from, to); }
}
```

- [ ] **Step 4: Keep old tests green** — inside `BaseTest._deployPM` (so `MVPConfigTest` gets it too) set L0 `{true, 10, type(uint128).max, 1_200, 300, 0, 0, 0}` so the 10x tests keep the 12%/3% split; update `test_close_inProfit_5xSplit` to expect 12%/3% (cut no longer depends on leverage).

- [ ] **Step 5: Run** `forge test` — Expected: all PASS. `forge build --sizes | grep PositionManager` < 24,576.

- [ ] **Step 6: Commit**

```bash
git add src/PositionManager.sol src/interfaces/IProtocol.sol test/Base.t.sol test/PositionManager.t.sol test/TraderLevels.t.sol
git commit -m "feat(position-manager): add trader levels with auto promotion/demotion and a denylist"
```

---

### Task 4: LPVault deposit caps + denylist

**Files:**
- Modify: `src/LPVault.sol` (append storage after `_tickets`; `initialize`; `deposit`/`mint`/`depositWithBonus`; add `maxDeposit`/`maxMint` overrides; setter)
- Test: `test/VaultCaps.t.sol`

**Interfaces:**
- Consumes: `IDenylist` (Task 3) via `positionManager`.
- Produces:
  - `uint256 public depositCap; uint256 public perAddressCap;` — `initialize` sets both to `type(uint256).max`.
  - `function setDepositCaps(uint256 total, uint256 perAddress) external onlyOwner` — emits `DepositCapsSet(total, perAddress)`.
  - `maxDeposit(receiver) = min(depositCap - totalAssets() (0 if ≥), perAddressCap - costBasis[receiver] (0 if ≥))`; `maxMint(receiver) = convertToShares(maxDeposit(receiver))`.
  - `error Denied(address account);` — `deposit`, `mint`, `depositWithBonus` revert if `msg.sender` or `receiver` is denied (`positionManager != address(0) && IDenylist(positionManager).isDenied(x)`).
  - `depositWithBonus` also reverts `ERC4626ExceededMaxDeposit` when `assets > maxDeposit(receiver)`.

- [ ] **Step 1: Write the failing tests** in `test/VaultCaps.t.sol` (extends `BaseTest`; in `setUp` owner calls `vault.setDepositCaps(LP_DEPOSIT + 10_000e6, 100e6)` so the existing `lp` deposit fits)

```solidity
function test_caps_firstDepositAndExactBoundary() public {
    // fresh vault via ERC1967Proxy with caps (10_000e6, 100e6): alice deposits 100e6 ok; +1 wei → ERC4626ExceededMaxDeposit
}
function test_totalCap_blocksWhenFull() public {
    // fill to depositCap from many addresses; next 1e6 → revert; maxDeposit == 0
}
function test_perAddressCap_tracksCostBasis() public {
    // deposit 60e6 then 40e6 ok, then 1 → revert; after transferring all shares away, can deposit again
}
function test_mint_respectsCaps() public {
    // mint(convertToShares(101e6)) → ERC4626ExceededMaxMint
}
function test_raiseCaps_unblocks() public {
    // full → owner raises caps → deposit succeeds
}
function test_denied_cannotDeposit() public {
    // pm.setDenied(alice,true): deposit as alice → Denied(alice); deposit by bob for receiver alice → Denied(alice)
}
function test_denied_lpCanStillRequestRedeem() public {
    // lp deposits, gets denied, requestRedeem succeeds
}
function test_setDepositCaps_onlyOwner() public {
}
```

- [ ] **Step 2: Run** `forge test --match-contract VaultCaps` — Expected: compile FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `forge test` — Expected: all PASS. `forge build --sizes | grep LPVault` < 24,576 (currently 21,165).
- [ ] **Step 5: Commit**

```bash
git add src/LPVault.sol test/VaultCaps.t.sol
git commit -m "feat(vault): add owner-configurable total and per-address deposit caps and denylist check"
```

> ponytail: per-address cap is bypassable with many wallets, and `depositWithBonus` escrows under the vault so it skips the per-address check; the total cap still bounds loss. Track per-depositor when caps get large.

---

### Task 5: Base deployment + fork test

**Files:**
- Create: `script/lib/BaseMainnet.sol` (constants + pool keys)
- Modify: `script/lib/ProtocolDeployer.sol` (add `deployBase`)
- Create: `script/DeployBase.s.sol`
- Create: `test/fork/BaseFork.t.sol`
- Modify: `foundry.toml` (`base = "${BASE_RPC_URL}"` under `[rpc_endpoints]`)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `struct BaseDeployment { ChainlinkOracle oracle; V4SwapRouter router; LPVault vault; InsuranceReserve insurance; PositionManager pm; }`, `ProtocolDeployer.deployBase(address owner, IERC4626 idleVault) returns (BaseDeployment memory)`, and a `handOff(BaseDeployment memory, address governance)` overload. `deployArc` is untouched apart from Task 1.

`BaseMainnet.sol` constants (verify each on basescan / data.chain.link before deploying; the fork test asserts them):

| Name | Value |
|---|---|
| `CHAIN_ID` | `8453` |
| `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `WETH` | `0x4200000000000000000000000000000000000006` |
| `CBBTC` | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| `POOL_MANAGER` | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| `ETH_USD_FEED` | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| `BTC_USD_FEED` | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` (cbBTC priced at BTC/USD) |
| `MAX_STALENESS` | `3600` (feeds heartbeat 1200s — confirm on data.chain.link) |

`deployBase` configuration (values from the spec; all changeable later by the owner):
- `ChainlinkOracle.setFeed` for WETH and cbBTC with the pool keys below.
- `LPVault.initialize(USDC, idleVault, owner)`; `setDepositCaps(10_000e6, 100e6)`.
- `pm.setRiskParams(800, 8_000, 50e6, 0.5e6, 100, 100, 200)` (min notional $50, keeper bounty $0.50).
- `pm.setAsset(WETH, true, 3_500, 2_000)`, `pm.setAsset(CBBTC, true, 3_500, 2_000)`.
- Levels: L0 `{true, 5, 50e6, 1_500, 500, 5, 25e6, 0}`, L1 `{true, 10, 250e6, 1_000, 300, 10, 100e6, 50e6}`, L2 `{true, 10, 1_000e6, 700, 200, 0, 0, 200e6}` (L3 unset ⇒ L2 is top).

- [ ] **Step 1: Find the pool keys.** On a Base fork, for `(WETH, USDC)` and `(CBBTC, USDC)` with `hooks = address(0)`, read `StateLibrary.getLiquidity(poolManager, key.toId())` for fee/tickSpacing pairs `(100,1) (500,10) (3000,60) (10000,200)`; pick the highest liquidity per asset and hard-code it in `BaseMainnet.wethUsdcKey()` / `cbBtcUsdcKey()`.
  **STOP and ask the user** if the best WETH/USDC pool fails the Step 3 price-impact check: Base's deep v4 ETH pool uses native ETH, which `V4SwapRouter` rejects (`NativeCurrencyUnsupported`), and supporting it is a separate change.

- [ ] **Step 2: Write the fork test** `test/fork/BaseFork.t.sol` (skip unless `BASE_RPC_URL` set, like `ForkBase`):

```solidity
function test_feeds_matchDescriptions() public {
    assertEq(AggregatorV3Interface(BaseMainnet.ETH_USD_FEED).description(), "ETH / USD");
    assertEq(AggregatorV3Interface(BaseMainnet.BTC_USD_FEED).description(), "BTC / USD");
}
function test_oracle_pricesSane() public {   // ETH in [$500, $20,000], BTC in [$10,000, $500,000]
}
function test_endToEnd_depositOpenClose() public {
    // deal USDC; lp deposits 100e6; trader opens 50e6 @ 5x on WETH and on cbBTC; closes both;
    // each round trip loses < 2% of notional (price impact + fees) and vault totalAssets >= deposit
}
function test_caps_live() public {          // depositCap == 10_000e6, perAddressCap == 100e6
}
function test_idleVault_assetIsUsdc() public { // only if IDLE_VAULT env set: IERC4626(IDLE_VAULT).asset() == USDC
}
```

- [ ] **Step 3: Run** `BASE_RPC_URL=<url> forge test --match-contract BaseFork -vv` — Expected: all PASS.
- [ ] **Step 4: Write** `script/DeployBase.s.sol` mirroring `script/Deploy.s.sol`: `require(block.chainid == BaseMainnet.CHAIN_ID)`; env `GOVERNANCE` (Safe), `GUARDIAN`, optional `IDLE_VAULT` (USDC ERC-4626 — MetaMorpho or Aave static aUSDC; default none); hand off via `ProtocolDeployer.handOff` (Safe calls `acceptOwnership` on each); log all addresses.
- [ ] **Step 5: Dry run** `forge script script/DeployBase.s.sol --rpc-url base` (no `--broadcast`) — Expected: simulation succeeds and logs 5 addresses.
- [ ] **Step 6: Commit**

```bash
git add script/lib/BaseMainnet.sol script/lib/ProtocolDeployer.sol script/DeployBase.s.sol test/fork/BaseFork.t.sol foundry.toml
git commit -m "feat(deploy): add Base mainnet deployment with Chainlink feeds, caps and trader levels"
```

---

### Task 6: Keeper on Base (drop TWAP recording)

**Files:**
- Modify: `frontend/scripts/keeper.ts` (remove the `record` job and recorder warning)
- Modify: `frontend/src/lib/config.ts` (add a `base` network: id `8453`, name `Base`, rpc `https://mainnet.base.org`, explorer `https://basescan.org`, native currency ETH/18; make `USDC` and `V4_QUOTER` per-network: Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, Base v4 Quoter — look up on docs.uniswap.org "v4 deployments" and paste)

**Interfaces:**
- Consumes: `PositionManager.isLiquidatable/liquidate/processEpoch/executeTrigger` (unchanged names).
- Produces: `NEXT_PUBLIC_NETWORK=base` selects Base for app and keeper.

- [ ] **Step 1:** Edit per Files. The jobs loop becomes `[positions, lpQueue]`.
- [ ] **Step 2: Verify** `cd frontend && npm run typecheck` — Expected: no errors.
- [ ] **Step 3: Smoke run on a local Base fork:** `anvil --fork-url $BASE_RPC_URL`; `forge script script/DeployBase.s.sol --rpc-url http://127.0.0.1:8545 --broadcast` (Task 5); set `NEXT_PUBLIC_POSITION_MANAGER`/`NEXT_PUBLIC_LP_VAULT`/`NEXT_PUBLIC_ORACLE` to the logged addresses and `NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545`; `npm run keeper` for 2 minutes. Expected: no errors, no `record` calls.
- [ ] **Step 4: Commit**

```bash
git add frontend/scripts/keeper.ts frontend/src/lib/config.ts
git commit -m "feat(keeper): run keeper on Base without TWAP recording"
```

---

## Go-live checklist (after all tasks, done by the user)

1. `forge script script/DeployBase.s.sol --rpc-url base --broadcast --verify --account <deployer>`
2. Safe calls `acceptOwnership()` on oracle, vault, insurance, position manager.
3. Start keeper: `NEXT_PUBLIC_NETWORK=base npm run keeper` with a funded key (a little ETH for gas).
4. Seed the vault yourself first; open and close one small position on each asset.

## Out of scope (follow-up plan)

- Frontend UI for Base: regenerate ABIs (`npm run abi`, swap `UniV4TwapOracle` → `ChainlinkOracle` in `extract-abis.mjs`), replace `spotPrice` in `src/lib/oracle.ts`, take the profit cut from `levels(traderStats(addr).level)` instead of `tiers` in `math.ts`/`OrderPanel.tsx`, show level + progress, cap/denied errors.
- Shorts, EURC, timelock, sequencer feed, sanctions oracle.
