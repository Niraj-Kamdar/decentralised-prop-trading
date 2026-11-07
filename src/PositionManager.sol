// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ArcConstants} from "./libraries/ArcConstants.sol";
import {
    ILPVault,
    IInsuranceReserve,
    IOracle,
    IV4SwapRouter,
    ITraderProxy,
    IRouterRegistry,
    IRiskView,
    IDenylist
} from "./interfaces/IProtocol.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title PositionManager
/// @notice Orchestrates leveraged spot positions: clone-per-position custody, vault borrowing, 7-day epochs with
///         lazy 8% APR rollover debt, oracle-gated liquidations, and the settlement / bad-debt waterfall.
///         Spot is bought and sold on the asset's Uniswap v4 pool and marked at that pool's 10-minute TWAP.
/// @dev No function is payable and there is no receive(): native USDC (18-dec msg.value) is always rejected.
contract PositionManager is
    IRouterRegistry,
    IRiskView,
    IDenylist,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant YEAR = 365 days;
    /// @dev Bound on epochs accrued in one call so a long-abandoned position can always be processed.
    uint256 public constant MAX_EPOCH_CATCH_UP = 52;
    uint256 public constant MAX_STRESS_SHOCK_BPS = 9_000;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum PositionStatus {
        NONE,
        OPEN,
        CLOSED,
        LIQUIDATED
    }

    enum CloseReason {
        MANUAL,
        EXPIRY,
        TRIGGER,
        LIQUIDATION
    }

    struct Position {
        address trader;
        address proxy;
        address spotToken;
        uint8 tier;
        bool autoRollover;
        PositionStatus status;
        uint128 notional; // N, 6-dec USDC, fixed at open (drives the maintenance buffer)
        uint128 userMargin; // M_0 (+ addMargin top-ups)
        uint128 borrowedPrincipal; // B (reduced by addMargin)
        uint128 accruedRolloverDebt; // D_roll
        uint256 spotAmount; // Q, spot-token native decimals
        uint64 openedAt;
        uint64 epochEndTime;
        uint128 stopLossPrice; // 1e18 USD; 0 = unset
        uint128 takeProfitPrice; // 1e18 USD; 0 = unset
        uint128 trailingStopPrice; // 1e18 USD floor, raised by trader/session key; 0 = unset
    }

    struct TierConfig {
        bool enabled;
        uint16 maintenanceBps; // mu
    }

    struct LevelConfig {
        bool enabled;
        uint8 maxLeverage; // highest `tier` this level may open
        uint128 maxMargin; // 6-dec USDC per position
        uint16 lpProfitBps;
        uint16 treasuryProfitBps;
        uint32 promoteMinTrades; // closes since entering this level
        uint128 promoteMinPnl; // realized pnl since entering this level, 6-dec
        uint128 demoteMaxLoss; // demote when pnl <= -demoteMaxLoss; 0 = never
    }

    struct TraderStats {
        uint8 level;
        uint32 trades;
        int128 pnl;
    }

    struct AssetConfig {
        bool enabled;
        uint16 maxExposureBps; // open-interest cap as share of LPVault.totalAssets()
        uint16 stressShockBps; // adverse price move assumed by the LP withdrawal solvency gate
    }

    struct OpenParams {
        address spotToken;
        uint8 tier;
        uint128 margin;
        bool autoRollover;
        uint256 minAmountOut; // minimum spot tokens bought; the TWAP entry check applies on top
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IERC20 public usdc;
    ILPVault public lpVault;
    IInsuranceReserve public insurance;
    IOracle public oracle;
    address public proxyImplementation;

    address public guardian;
    /// @notice The V4SwapRouter every position trades through; the only router TraderProxy clones may call.
    address public swapRouter;

    uint256 public positionCount;
    mapping(uint256 posId => Position) internal _positions;

    mapping(uint8 tier => TierConfig) public tiers;
    mapping(address token => AssetConfig) public assetConfigs;
    mapping(address token => uint256) public assetExposure; // sum of open notional
    mapping(address router => bool) public isWhitelistedRouter;
    mapping(address trader => mapping(address operator => bool)) public isOperator;

    /// @dev Per-(asset, tier) borrowed principal; drives the worst-case LP loss bound read by the LP vault gate.
    mapping(address token => mapping(uint8 tier => uint256)) public borrowedByAssetTier;
    uint256 public openPositionCount;
    address[] internal _assetList;
    uint8[] internal _tierList;
    mapping(address token => bool) internal _assetListed;
    mapping(uint8 tier => bool) internal _tierListed;

    mapping(address trader => uint256) public claimableUSDC;
    uint256 public totalClaimable;

    uint256 public rolloverAprBps;
    uint256 public lpRolloverShareBps;
    uint256 public minNotional;
    uint256 public keeperBounty;
    uint256 public maxEntrySlippageBps;
    uint256 public maxExitSlippageBps;
    uint256 public maxLiqSlippageBps;

    mapping(uint8 level => LevelConfig) public levels;
    mapping(address trader => TraderStats) public traderStats;
    mapping(address account => bool) public isDenied;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PositionOpened(
        uint256 indexed posId,
        address indexed trader,
        address indexed spotToken,
        address proxy,
        uint8 tier,
        uint256 margin,
        uint256 borrowed,
        uint256 spotAmount,
        uint64 epochEndTime
    );
    event EpochRolled(uint256 indexed posId, uint256 epochsAccrued, uint256 accruedRolloverDebt, uint64 epochEndTime);
    event PositionClosed(
        uint256 indexed posId, CloseReason reason, uint256 usdcOut, uint256 traderPayout, address indexed executor
    );
    event PositionLiquidated(
        uint256 indexed posId, address indexed keeper, uint256 usdcOut, uint256 markValue, uint256 penalty
    );
    event BadDebt(uint256 indexed posId, uint256 shortfall, uint256 coveredByInsurance);
    event MarginAdded(uint256 indexed posId, uint256 amount, uint256 borrowedAfter);
    event AutoRolloverSet(uint256 indexed posId, bool autoRollover);
    event OrdersSet(uint256 indexed posId, uint128 stopLoss, uint128 takeProfit, uint128 trailingStop);
    event OperatorSet(address indexed trader, address indexed operator, bool allowed);
    event PayoutDeferred(address indexed trader, uint256 amount);
    event PayoutClaimed(address indexed trader, uint256 amount);
    event TierSet(uint8 indexed tier, TierConfig config);
    event LevelChanged(address indexed trader, uint8 fromLevel, uint8 toLevel);
    event LevelSet(uint8 indexed level, LevelConfig config);
    event DeniedSet(address indexed account, bool denied);
    event AssetSet(address indexed token, AssetConfig config);
    event SwapRouterSet(address indexed router);
    event ProxyImplementationSet(address indexed impl);
    event OracleSet(address oracle);
    event GuardianSet(address indexed guardian);
    event RiskParamsSet(
        uint256 rolloverAprBps,
        uint256 lpRolloverShareBps,
        uint256 minNotional,
        uint256 keeperBounty,
        uint256 maxEntrySlippageBps,
        uint256 maxExitSlippageBps,
        uint256 maxLiqSlippageBps
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidAsset();
    error InvalidTier(uint8 tier);
    error AssetNotEnabled(address token);
    error SwapRouterNotSet();
    error BelowMinNotional(uint256 notional);
    error ExposureCapExceeded(address token, uint256 exposureAfter, uint256 cap);
    error EntryPriceDeviation(uint256 markValue, uint256 notional);
    error UnhealthyAtOpen(uint256 markValue, uint256 threshold);
    error PositionNotOpen(uint256 posId);
    error NotAuthorized();
    error EpochNotEnded(uint64 epochEndTime);
    error NotLiquidatable(uint256 markValue, uint256 threshold);
    error TriggerNotHit(uint256 price);
    error InvalidAmount();
    error InvalidParams();
    error NothingToClaim();
    error Denied(address account);
    error LevelLimitExceeded(uint8 level);
    error ProxyImplementationNotSet();

    // ---------------------------------------------------------------------
    // Construction & Initialization
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 usdc_,
        ILPVault lpVault_,
        IInsuranceReserve insurance_,
        IOracle oracle_,
        address owner_
    ) external initializer {
        if (
            address(usdc_) == address(0) || address(lpVault_) == address(0) || address(insurance_) == address(0)
                || address(oracle_) == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        if (ArcConstants.isArc() && address(usdc_) != ArcConstants.USDC) revert InvalidAsset();
        if (IERC20Metadata(address(usdc_)).decimals() != ArcConstants.USDC_DECIMALS) revert InvalidAsset();

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        usdc = usdc_;
        lpVault = lpVault_;
        insurance = insurance_;
        oracle = oracle_;

        rolloverAprBps = 800;
        lpRolloverShareBps = 8_000;
        minNotional = 500e6;
        keeperBounty = 5e6;
        maxEntrySlippageBps = 100;
        maxExitSlippageBps = 100;
        maxLiqSlippageBps = 200;

        _setTier(5, TierConfig({enabled: true, maintenanceBps: 400}));
        _setTier(10, TierConfig({enabled: true, maintenanceBps: 200}));
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOpen(uint256 posId) {
        _requireOpen(posId);
        _;
    }

    function _requireOpen(uint256 posId) internal view {
        if (_positions[posId].status != PositionStatus.OPEN) revert PositionNotOpen(posId);
    }

    modifier onlyTraderOrOperator(uint256 posId) {
        _requireTraderOrOperator(posId);
        _;
    }

    function _requireTraderOrOperator(uint256 posId) internal view {
        address trader = _positions[posId].trader;
        if (msg.sender != trader && !isOperator[trader][msg.sender]) revert NotAuthorized();
    }

    // ---------------------------------------------------------------------
    // Trader actions
    // ---------------------------------------------------------------------

    /// @notice TR-01: lock `margin` USDC, borrow `margin * (tier - 1)` from the LP vault and buy spot.
    function openPosition(OpenParams calldata p) external nonReentrant whenNotPaused returns (uint256 posId) {
        if (isDenied[msg.sender]) revert Denied(msg.sender);
        uint8 lvl = traderStats[msg.sender].level;
        LevelConfig storage lv = levels[lvl];
        if (!lv.enabled || p.tier > lv.maxLeverage || p.margin > lv.maxMargin) revert LevelLimitExceeded(lvl);

        TierConfig memory t = tiers[p.tier];
        if (!t.enabled) revert InvalidTier(p.tier);
        AssetConfig memory a = assetConfigs[p.spotToken];
        if (!a.enabled) revert AssetNotEnabled(p.spotToken);
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        if (proxyImplementation == address(0)) revert ProxyImplementationNotSet();

        uint256 margin = p.margin;
        uint256 notional = margin * p.tier;
        if (notional < minNotional) revert BelowMinNotional(notional);
        uint256 borrowed = notional - margin;

        uint256 exposureAfter = assetExposure[p.spotToken] + notional;
        uint256 cap = (lpVault.totalAssets() * a.maxExposureBps) / BPS;
        if (exposureAfter > cap) revert ExposureCapExceeded(p.spotToken, exposureAfter, cap);
        assetExposure[p.spotToken] = exposureAfter;
        borrowedByAssetTier[p.spotToken][p.tier] += borrowed;
        ++openPositionCount;

        posId = ++positionCount;
        address proxy = Clones.cloneDeterministic(proxyImplementation, bytes32(posId));

        usdc.safeTransferFrom(msg.sender, proxy, margin);
        lpVault.allocateToPosition(proxy, borrowed);

        uint256 spotAmount = _swap(proxy, address(usdc), p.spotToken, notional, p.minAmountOut);

        // TWAP sanity: a self-sandwiched entry would hand LP principal to the attacker's pool.
        uint256 entryMark = oracle.valueInUsdc(p.spotToken, spotAmount);
        if (entryMark * BPS < notional * (BPS - maxEntrySlippageBps)) revert EntryPriceDeviation(entryMark, notional);
        uint256 threshold = borrowed + (notional * t.maintenanceBps) / BPS;
        if (entryMark <= threshold) revert UnhealthyAtOpen(entryMark, threshold);

        uint64 epochEnd = uint64(block.timestamp + EPOCH_DURATION);
        Position storage pos = _positions[posId];
        pos.trader = msg.sender;
        pos.proxy = proxy;
        pos.spotToken = p.spotToken;
        pos.tier = p.tier;
        pos.autoRollover = p.autoRollover;
        pos.status = PositionStatus.OPEN;
        pos.notional = uint128(notional);
        pos.userMargin = uint128(margin);
        pos.borrowedPrincipal = uint128(borrowed);
        pos.spotAmount = spotAmount;
        pos.openedAt = uint64(block.timestamp);
        pos.epochEndTime = epochEnd;

        emit PositionOpened(posId, msg.sender, p.spotToken, proxy, p.tier, margin, borrowed, spotAmount, epochEnd);
    }

    /// @notice TR-03: unwind 100% of spot and settle. Works while paused.
    /// @dev The swap must return at least `mark * (1 - maxExitSlippageBps)` at the TWAP, otherwise a trader could dump
    ///      the spot into their own manipulated pool and push the loss onto LP principal. `minAmountOut` can only
    ///      tighten that floor (pass 0 to use the oracle floor alone).
    function closePosition(uint256 posId, uint256 minAmountOut)
        external
        nonReentrant
        onlyOpen(posId)
        onlyTraderOrOperator(posId)
    {
        Position storage pos = _positions[posId];
        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        _exitAndSettle(posId, pos, minAmountOut, mark, maxExitSlippageBps, CloseReason.MANUAL, false);
    }

    /// @notice TR-04: top up collateral. The top-up repays vault principal directly, lowering B (and the
    ///         rollover fee base and liquidation threshold) while raising the margin returned before profit split.
    function addMargin(uint256 posId, uint256 amount)
        external
        nonReentrant
        onlyOpen(posId)
        onlyTraderOrOperator(posId)
    {
        Position storage pos = _positions[posId];
        if (amount == 0 || amount > pos.borrowedPrincipal) revert InvalidAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        pos.borrowedPrincipal -= uint128(amount);
        pos.userMargin += uint128(amount);
        borrowedByAssetTier[pos.spotToken][pos.tier] -= amount;

        _repayVault(amount, amount, 0);
        emit MarginAdded(posId, amount, pos.borrowedPrincipal);
    }

    function setAutoRollover(uint256 posId, bool enabled) external onlyOpen(posId) onlyTraderOrOperator(posId) {
        _positions[posId].autoRollover = enabled;
        emit AutoRolloverSet(posId, enabled);
    }

    /// @notice TR-03: keeper-executable stop-loss / take-profit / trailing floor (1e18 USD per whole token).
    function setOrders(uint256 posId, uint128 stopLoss, uint128 takeProfit, uint128 trailingStop)
        external
        onlyOpen(posId)
        onlyTraderOrOperator(posId)
    {
        Position storage pos = _positions[posId];
        pos.stopLossPrice = stopLoss;
        pos.takeProfitPrice = takeProfit;
        pos.trailingStopPrice = trailingStop;
        emit OrdersSet(posId, stopLoss, takeProfit, trailingStop);
    }

    /// @notice Authorise a session key / bot to manage (never withdraw from) the caller's positions.
    function setOperator(address operator, bool allowed) external {
        isOperator[msg.sender][operator] = allowed;
        emit OperatorSet(msg.sender, operator, allowed);
    }

    /// @notice TR-05: pull settled USDC that could not be pushed (e.g. Circle blocklist at settlement time).
    /// @dev Deliberately pays only `msg.sender`; a claim-to-other-address path would bypass the USDC blocklist.
    function claimTraderPayout() external nonReentrant {
        uint256 amount = claimableUSDC[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableUSDC[msg.sender] = 0;
        totalClaimable -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit PayoutClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Keeper actions
    // ---------------------------------------------------------------------

    /// @notice KP-02: at/after epoch end, roll (if autoRollover and healthy) or force-close for a bounty.
    function processEpoch(uint256 posId, uint256 minAmountOut) external nonReentrant onlyOpen(posId) {
        Position storage pos = _positions[posId];
        if (block.timestamp < pos.epochEndTime) revert EpochNotEnded(pos.epochEndTime);

        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        bool liquidatable = mark <= _liquidationThreshold(pos);

        if (pos.autoRollover && !liquidatable) return; // rolled; no bounty for a pure roll

        uint256 slip = liquidatable ? maxLiqSlippageBps : maxExitSlippageBps;
        CloseReason reason = liquidatable ? CloseReason.LIQUIDATION : CloseReason.EXPIRY;
        _exitAndSettle(posId, pos, minAmountOut, mark, slip, reason, true);
    }

    /// @notice KP-01: permissionless liquidation once V(t) <= B + D_roll + N * mu.
    function liquidate(uint256 posId, uint256 minAmountOut) external nonReentrant onlyOpen(posId) {
        Position storage pos = _positions[posId];
        _catchUpEpochs(posId, pos);

        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        uint256 threshold = _liquidationThreshold(pos);
        if (mark > threshold) revert NotLiquidatable(mark, threshold);

        _exitAndSettle(posId, pos, minAmountOut, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
    }

    /// @notice Keeper execution of a trader's stop-loss / take-profit / trailing floor.
    function executeTrigger(uint256 posId, uint256 minAmountOut) external nonReentrant onlyOpen(posId) {
        Position storage pos = _positions[posId];

        uint256 price = oracle.getPrice(pos.spotToken);
        bool hit = (pos.stopLossPrice != 0 && price <= pos.stopLossPrice)
            || (pos.takeProfitPrice != 0 && price >= pos.takeProfitPrice)
            || (pos.trailingStopPrice != 0 && price <= pos.trailingStopPrice);
        if (!hit) revert TriggerNotHit(price);

        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        bool liq = mark <= _liquidationThreshold(pos);
        uint256 slip = liq ? maxLiqSlippageBps : maxExitSlippageBps;
        CloseReason reason = liq ? CloseReason.LIQUIDATION : CloseReason.TRIGGER;
        _exitAndSettle(posId, pos, minAmountOut, mark, slip, reason, true);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPosition(uint256 posId) external view returns (Position memory) {
        return _positions[posId];
    }

    /// @notice V_liq = B + D_roll + N * mu, including epochs that are due but not yet processed.
    function liquidationThreshold(uint256 posId) external view returns (uint256) {
        Position memory pos = _positions[posId];
        (uint256 extraDebt,) = _pendingEpochs(pos);
        pos.accruedRolloverDebt += uint128(extraDebt);
        return _liquidationThreshold(pos);
    }

    function markValue(uint256 posId) external view returns (uint256) {
        Position storage pos = _positions[posId];
        return oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
    }

    function isLiquidatable(uint256 posId) external view returns (bool) {
        Position memory pos = _positions[posId];
        if (pos.status != PositionStatus.OPEN) return false;
        (uint256 extraDebt,) = _pendingEpochs(pos);
        pos.accruedRolloverDebt += uint128(extraDebt);
        return oracle.valueInUsdc(pos.spotToken, pos.spotAmount) <= _liquidationThreshold(pos);
    }

    function predictProxyAddress(uint256 posId) external view returns (address) {
        if (proxyImplementation == address(0)) revert ProxyImplementationNotSet();
        return Clones.predictDeterministicAddress(proxyImplementation, bytes32(posId));
    }

    /// @notice Worst-case LP principal loss if every asset moved down by its `stressShockBps` and every position
    ///         were liquidated at the worst allowed slippage.
    /// @dev Assumes keepers keep live positions above their liquidation threshold: V >= B + D + mu*N. Since
    ///      addMargin only lowers B while N is fixed, N >= B*L/(L-1), so each position's loss is bounded by
    ///      B * k(asset, tier) with k = s' - (1 - s') * mu * L / (L - 1), where 1 - s' = (1 - shock)(1 - liqSlip).
    ///      The bound is linear in B, so per-(asset, tier) aggregates give it exactly without iterating positions.
    function stressedLPLoss() public view returns (uint256 loss) {
        uint256 keep = BPS - maxLiqSlippageBps;
        uint256 nAssets = _assetList.length;
        uint256 nTiers = _tierList.length;
        for (uint256 i; i < nAssets; ++i) {
            address token = _assetList[i];
            uint256 survive = (BPS - assetConfigs[token].stressShockBps) * keep; // (1 - s'), BPS^2-scaled
            uint256 sPrime = BPS * BPS - survive;
            for (uint256 j; j < nTiers; ++j) {
                uint8 tier = _tierList[j];
                uint256 borrowed = borrowedByAssetTier[token][tier];
                if (borrowed == 0) continue;
                uint256 cushion = Math.mulDiv(survive, uint256(tiers[tier].maintenanceBps) * tier, BPS * (tier - 1));
                if (sPrime <= cushion) continue;
                loss += Math.mulDiv(borrowed, sPrime - cushion, BPS * BPS, Math.Rounding.Ceil);
            }
        }
        loss += openPositionCount * keeperBounty;
    }

    /// @inheritdoc IRiskView
    function stressedNetLoss() external view returns (uint256) {
        uint256 loss = stressedLPLoss();
        uint256 cover = insurance.insurancePoolBalance();
        return loss > cover ? loss - cover : 0;
    }

    /// @notice Rollover fee for one 7-day epoch on `borrowed` principal (rounded up in favour of LPs).
    function epochRolloverFee(uint256 borrowed) public view returns (uint256) {
        return Math.mulDiv(borrowed, rolloverAprBps * EPOCH_DURATION, BPS * YEAR, Math.Rounding.Ceil);
    }

    // ---------------------------------------------------------------------
    // Governance (AD-01 / AD-02)
    // ---------------------------------------------------------------------

    function setAsset(address token, bool enabled, uint16 maxExposureBps, uint16 stressShockBps) external onlyOwner {
        if (token == address(0) || token == address(usdc)) revert InvalidAsset();
        if (maxExposureBps > BPS || stressShockBps > MAX_STRESS_SHOCK_BPS) revert InvalidParams();
        // Requires an oracle feed: the asset's v4 pool is read from the oracle for every swap.
        AssetConfig memory cfg =
            AssetConfig({enabled: enabled, maxExposureBps: maxExposureBps, stressShockBps: stressShockBps});
        assetConfigs[token] = cfg;
        if (!_assetListed[token]) {
            _assetListed[token] = true;
            _assetList.push(token);
        }
        emit AssetSet(token, cfg);
    }

    /// @notice Point every future swap at `router`. The previous router loses its whitelist entry at once, so an
    ///         open position always unwinds through the current router.
    function setSwapRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        address old = swapRouter;
        if (old != address(0)) isWhitelistedRouter[old] = false;
        isWhitelistedRouter[router] = true;
        swapRouter = router;
        emit SwapRouterSet(router);
    }

    function setTier(uint8 tier, TierConfig calldata cfg) external onlyOwner {
        _setTier(tier, cfg);
    }

    function setLevel(uint8 level, LevelConfig calldata cfg) external onlyOwner {
        if (uint256(cfg.lpProfitBps) + cfg.treasuryProfitBps > BPS || (cfg.enabled && cfg.maxLeverage < 2)) {
            revert InvalidParams();
        }
        levels[level] = cfg;
        emit LevelSet(level, cfg);
    }

    function setTraderLevel(address trader, uint8 level) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();
        uint8 from = traderStats[trader].level;
        traderStats[trader] = TraderStats({level: level, trades: 0, pnl: 0});
        emit LevelChanged(trader, from, level);
    }

    function setDenied(address account, bool denied) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isDenied[account] = denied;
        emit DeniedSet(account, denied);
    }

    function setRiskParams(
        uint256 rolloverAprBps_,
        uint256 lpRolloverShareBps_,
        uint256 minNotional_,
        uint256 keeperBounty_,
        uint256 maxEntrySlippageBps_,
        uint256 maxExitSlippageBps_,
        uint256 maxLiqSlippageBps_
    ) external onlyOwner {
        if (
            rolloverAprBps_ > 5_000 || lpRolloverShareBps_ > BPS || minNotional_ == 0 || keeperBounty_ > 100e6
                || maxEntrySlippageBps_ > 500 || maxExitSlippageBps_ > 500 || maxLiqSlippageBps_ > 1_000
        ) revert InvalidParams();
        rolloverAprBps = rolloverAprBps_;
        lpRolloverShareBps = lpRolloverShareBps_;
        minNotional = minNotional_;
        keeperBounty = keeperBounty_;
        maxEntrySlippageBps = maxEntrySlippageBps_;
        maxExitSlippageBps = maxExitSlippageBps_;
        maxLiqSlippageBps = maxLiqSlippageBps_;
        emit RiskParamsSet(
            rolloverAprBps_,
            lpRolloverShareBps_,
            minNotional_,
            keeperBounty_,
            maxEntrySlippageBps_,
            maxExitSlippageBps_,
            maxLiqSlippageBps_
        );
    }

    function setProxyImplementation(address impl) external onlyOwner {
        if (impl == address(0)) revert ZeroAddress();
        proxyImplementation = impl;
        emit ProxyImplementationSet(impl);
    }

    function setOracle(IOracle oracle_) external onlyOwner {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice Pauses new openings only; closes, liquidations, epochs and claims stay live.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotAuthorized();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _setTier(uint8 tier, TierConfig memory cfg) internal {
        if (tier < 2 || cfg.maintenanceBps == 0 || cfg.maintenanceBps >= BPS / tier) revert InvalidTier(tier);
        tiers[tier] = cfg;
        if (!_tierListed[tier]) {
            _tierListed[tier] = true;
            _tierList.push(tier);
        }
        emit TierSet(tier, cfg);
    }

    function _liquidationThreshold(Position memory pos) internal view returns (uint256) {
        return uint256(pos.borrowedPrincipal) + pos.accruedRolloverDebt
            + (uint256(pos.notional) * tiers[pos.tier].maintenanceBps) / BPS;
    }

    /// @dev Debt and epoch count due for an auto-rolling position whose epoch(s) have elapsed.
    function _pendingEpochs(Position memory pos) internal view returns (uint256 debt, uint256 epochs) {
        if (block.timestamp < pos.epochEndTime) return (0, 0);
        if (pos.autoRollover) {
            epochs = (block.timestamp - pos.epochEndTime) / EPOCH_DURATION + 1;
        } else {
            epochs = Math.ceilDiv(block.timestamp - pos.epochEndTime, EPOCH_DURATION);
        }
        debt = epochRolloverFee(pos.borrowedPrincipal) * epochs;
    }

    /// @dev Lazily accrues rollover debt for every elapsed epoch so late keepers never grant free leverage.
    function _catchUpEpochs(uint256 posId, Position storage pos) internal {
        (uint256 debt, uint256 epochs) = _pendingEpochs(pos);
        if (epochs == 0) return;
        pos.accruedRolloverDebt += uint128(debt);
        pos.epochEndTime += uint64(epochs * EPOCH_DURATION);
        emit EpochRolled(posId, epochs, pos.accruedRolloverDebt, pos.epochEndTime);
    }

    /// @dev Exact-input swap of the proxy's `tokenIn` on the asset's v4 pool (the USDC side is always the other).
    function _swap(address proxy, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        address router = swapRouter;
        if (router == address(0)) revert SwapRouterNotSet();
        address spot = tokenIn == address(usdc) ? tokenOut : tokenIn;
        PoolKey memory key = oracle.poolKey(spot);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        bytes memory data = abi.encodeCall(IV4SwapRouter.swapExactIn, (key, zeroForOne, amountIn, minOut, proxy));
        return ITraderProxy(proxy).executeSwap(router, tokenIn, tokenOut, amountIn, minOut, data);
    }

    function _exitAndSettle(
        uint256 posId,
        Position storage pos,
        uint256 minAmountOut,
        uint256 mark,
        uint256 slippageBps,
        CloseReason reason,
        bool forced
    ) internal {
        uint256 floorOut = (mark * (BPS - slippageBps)) / BPS;
        bool isLiquidation = reason == CloseReason.LIQUIDATION;
        uint256 minOut;
        if (isLiquidation) {
            minOut = minAmountOut > 0 ? minAmountOut : floorOut;
        } else {
            minOut = minAmountOut > floorOut ? minAmountOut : floorOut;
        }

        pos.status = isLiquidation ? PositionStatus.LIQUIDATED : PositionStatus.CLOSED;
        assetExposure[pos.spotToken] -= pos.notional;
        borrowedByAssetTier[pos.spotToken][pos.tier] -= pos.borrowedPrincipal;
        --openPositionCount;

        address proxy = pos.proxy;
        _swap(proxy, pos.spotToken, address(usdc), pos.spotAmount, minOut);

        uint256 usdcBal = usdc.balanceOf(proxy);
        if (usdcBal > 0) {
            ITraderProxy(proxy).sweep(address(usdc), address(this), usdcBal);
        }

        uint256 spotBal = IERC20(pos.spotToken).balanceOf(proxy);
        if (spotBal > 0) {
            ITraderProxy(proxy).sweep(pos.spotToken, pos.trader, spotBal);
        }

        (uint256 traderPayout, uint256 penalty) = _settle(posId, pos, usdcBal, forced, isLiquidation);

        _recordResult(pos.trader, int256(traderPayout) - int256(uint256(pos.userMargin)));

        if (isLiquidation) {
            emit PositionLiquidated(posId, msg.sender, usdcBal, mark, penalty);
        } else {
            emit PositionClosed(posId, reason, usdcBal, traderPayout, msg.sender);
        }
    }

    /// @dev Settlement & bad-debt waterfall (spec section 3).
    function _settle(uint256 posId, Position storage pos, uint256 usdcOut, bool forced, bool isLiquidation)
        internal
        returns (uint256 traderPayout, uint256 penalty)
    {
        uint256 borrowed = pos.borrowedPrincipal;
        uint256 u = usdcOut;

        // Step 1: keeper bounty.
        if (forced) {
            uint256 availableForBounty = usdcOut > borrowed ? usdcOut - borrowed : 0;
            uint256 k = Math.min(keeperBounty, availableForBounty);
            if (k > 0) {
                u -= k;
                usdc.safeTransfer(msg.sender, k);
            }
        }

        // Step 2: LP principal recovery / bad debt.
        if (u < borrowed) {
            uint256 shortfall = borrowed - u;
            uint256 covered = insurance.coverShortfall(shortfall);
            _repayVault(u + covered, borrowed, 0);
            emit BadDebt(posId, shortfall, covered);
            return (0, 0);
        }
        u -= borrowed;

        // Step 3: rollover debt, 80% LP / 20% insurance.
        uint256 rolloverPaid = Math.min(uint256(pos.accruedRolloverDebt), u);
        u -= rolloverPaid;
        uint256 lpYield = (rolloverPaid * lpRolloverShareBps) / BPS;
        uint256 toInsurance = rolloverPaid - lpYield;
        uint256 treasuryCut;

        // Step 4: liquidation penalty vs. trader payout & profit split.
        if (isLiquidation && borrowed > 0) {
            penalty = u;
            toInsurance += u;
        } else {
            uint256 margin = pos.userMargin;
            if (u <= margin) {
                traderPayout = u;
            } else {
                uint256 profit = u - margin;
                LevelConfig storage l = levels[traderStats[pos.trader].level];
                uint256 lpCut = (profit * l.lpProfitBps) / BPS;
                treasuryCut = (profit * l.treasuryProfitBps) / BPS;
                lpYield += lpCut;
                traderPayout = u - lpCut - treasuryCut;
            }
        }

        _repayVault(borrowed, borrowed, lpYield);
        if (toInsurance + treasuryCut > 0) {
            usdc.forceApprove(address(insurance), toInsurance + treasuryCut);
            insurance.fund(toInsurance, treasuryCut);
        }
        if (traderPayout > 0) _disburseToTrader(pos.trader, traderPayout);
    }

    function _recordResult(address trader, int256 pnl) internal {
        TraderStats storage s = traderStats[trader];
        s.trades += 1;
        s.pnl += int128(pnl);
        LevelConfig storage l = levels[s.level];
        uint8 from = s.level;
        uint8 to = from;
        if (from > 0 && l.demoteMaxLoss > 0 && s.pnl <= -int256(uint256(l.demoteMaxLoss))) {
            to = from - 1;
        } else if (
            from < type(uint8).max && levels[from + 1].enabled && s.trades >= l.promoteMinTrades
                && s.pnl >= int256(uint256(l.promoteMinPnl))
        ) {
            to = from + 1;
        }
        if (to != from) {
            s.level = to;
            s.trades = 0;
            s.pnl = 0;
            emit LevelChanged(trader, from, to);
        }
    }

    function _repayVault(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned) internal {
        uint256 inflow = principalReturned + yieldEarned;
        if (inflow > 0) usdc.forceApprove(address(lpVault), inflow);
        lpVault.repayFromPosition(principalReturned, principalBorrowed, yieldEarned);
    }

    /// @dev Push payout; if USDC reverts (e.g. trader blocklisted mid-position) credit a pull balance instead,
    ///      so liquidations and expiries can never be bricked by a single recipient.
    function _disburseToTrader(address trader, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(usdc).call(abi.encodeCall(IERC20.transfer, (trader, amount)));
        if (ok && (ret.length == 0 ? address(usdc).code.length > 0 : abi.decode(ret, (bool)))) return;
        claimableUSDC[trader] += amount;
        totalClaimable += amount;
        emit PayoutDeferred(trader, amount);
    }

    // ---------------------------------------------------------------------
    // Upgrade Gap
    // ---------------------------------------------------------------------

    uint256[50] private __gap;
}
