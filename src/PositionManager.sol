// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {TraderProxy} from "./TraderProxy.sol";
import {ArcConstants} from "./libraries/ArcConstants.sol";
import {
    ILPVault,
    IInsuranceReserve,
    IOracle,
    IV4SwapRouter,
    ITraderProxy,
    IRouterRegistry,
    IRiskView
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
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

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
        uint16 lpProfitBps;
        uint16 treasuryProfitBps;
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
    event AssetSet(address indexed token, AssetConfig config);
    event SwapRouterSet(address indexed router);
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
        proxyImplementation = address(new TraderProxy(address(this)));

        rolloverAprBps = 800;
        lpRolloverShareBps = 8_000;
        minNotional = 500e6;
        keeperBounty = 5e6;
        maxEntrySlippageBps = 100;
        maxExitSlippageBps = 100;
        maxLiqSlippageBps = 200;

        _setTier(5, TierConfig({enabled: true, maintenanceBps: 400, lpProfitBps: 800, treasuryProfitBps: 200}));
        _setTier(10, TierConfig({enabled: true, maintenanceBps: 200, lpProfitBps: 1_200, treasuryProfitBps: 300}));
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOpen(uint256 posId) {
        if (_positions[posId].status != PositionStatus.OPEN) revert PositionNotOpen(posId);
        _;
    }

    modifier onlyTraderOrOperator(uint256 posId) {
        address trader = _positions[posId].trader;
        if (msg.sender != trader && !isOperator[trader][msg.sender]) revert NotAuthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // Trader actions
    // ---------------------------------------------------------------------

    /// @notice TR-01: lock `margin` USDC, borrow `margin * (tier - 1)` from the LP vault and buy spot.
    function openPosition(OpenParams calldata p) external nonReentrant whenNotPaused returns (uint256 posId) {
        TierConfig memory t = tiers[p.tier];
        if (!t.enabled) revert InvalidTier(p.tier);
        AssetConfig memory a = assetConfigs[p.spotToken];
        if (!a.enabled) revert AssetNotEnabled(p.spotToken);
        if (swapRouter == address(0)) revert SwapRouterNotSet();

        uint256 margin = p.margin;
        uint256 notional = margin * p.tier;
        if (notional < minNotional) revert BelowMinNotional(notional);
        uint256 borrowed = notional - margin;

        uint256 exposureAfter = assetExposure[p.spotToken] + notional;
        uint256 cap = Math.mulDiv(lpVault.totalAssets(), a.maxExposureBps, BPS);
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
        uint256 threshold = borrowed + Math.mulDiv(notional, t.maintenanceBps, BPS);
        if (entryMark <= threshold) revert UnhealthyAtOpen(entryMark, threshold);

        uint64 epochEnd = (block.timestamp + EPOCH_DURATION).toUint64();
        _positions[posId] = Position({
            trader: msg.sender,
            proxy: proxy,
            spotToken: p.spotToken,
            tier: p.tier,
            autoRollover: p.autoRollover,
            status: PositionStatus.OPEN,
            notional: notional.toUint128(),
            userMargin: margin.toUint128(),
            borrowedPrincipal: borrowed.toUint128(),
            accruedRolloverDebt: 0,
            spotAmount: spotAmount,
            openedAt: block.timestamp.toUint64(),
            epochEndTime: epochEnd,
            stopLossPrice: 0,
            takeProfitPrice: 0,
            trailingStopPrice: 0
        });

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

        pos.borrowedPrincipal -= amount.toUint128();
        pos.userMargin += amount.toUint128();
        borrowedByAssetTier[pos.spotToken][pos.tier] -= amount;

        usdc.forceApprove(address(lpVault), amount);
        lpVault.repayFromPosition(amount, amount, 0);
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

        if (liquidatable) {
            _exitAndSettle(posId, pos, minAmountOut, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
        } else {
            _exitAndSettle(posId, pos, minAmountOut, mark, maxExitSlippageBps, CloseReason.EXPIRY, true);
        }
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
        if (mark <= _liquidationThreshold(pos)) {
            _exitAndSettle(posId, pos, minAmountOut, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
        } else {
            _exitAndSettle(posId, pos, minAmountOut, mark, maxExitSlippageBps, CloseReason.TRIGGER, true);
        }
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
        pos.accruedRolloverDebt += extraDebt.toUint128();
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
        pos.accruedRolloverDebt += extraDebt.toUint128();
        return oracle.valueInUsdc(pos.spotToken, pos.spotAmount) <= _liquidationThreshold(pos);
    }

    function predictProxyAddress(uint256 posId) external view returns (address) {
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
        if (uint256(cfg.lpProfitBps) + cfg.treasuryProfitBps > BPS) revert InvalidParams();
        tiers[tier] = cfg;
        if (!_tierListed[tier]) {
            _tierListed[tier] = true;
            _tierList.push(tier);
        }
        emit TierSet(tier, cfg);
    }

    function _liquidationThreshold(Position memory pos) internal view returns (uint256) {
        return uint256(pos.borrowedPrincipal) + pos.accruedRolloverDebt
            + Math.mulDiv(pos.notional, tiers[pos.tier].maintenanceBps, BPS);
    }

    /// @dev Debt and epoch count due for an auto-rolling position whose epoch(s) have elapsed.
    function _pendingEpochs(Position memory pos) internal view returns (uint256 debt, uint256 epochs) {
        if (!pos.autoRollover || block.timestamp < pos.epochEndTime) return (0, 0);
        epochs = (block.timestamp - pos.epochEndTime) / EPOCH_DURATION + 1;
        if (epochs > MAX_EPOCH_CATCH_UP) epochs = MAX_EPOCH_CATCH_UP;
        debt = epochRolloverFee(pos.borrowedPrincipal) * epochs;
    }

    /// @dev Lazily accrues rollover debt for every elapsed epoch so late keepers never grant free leverage.
    function _catchUpEpochs(uint256 posId, Position storage pos) internal {
        (uint256 debt, uint256 epochs) = _pendingEpochs(pos);
        if (epochs == 0) return;
        pos.accruedRolloverDebt += debt.toUint128();
        pos.epochEndTime += (epochs * EPOCH_DURATION).toUint64();
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
        uint256 minOut = Math.max(minAmountOut, Math.mulDiv(mark, BPS - slippageBps, BPS));

        bool isLiquidation = reason == CloseReason.LIQUIDATION;
        pos.status = isLiquidation ? PositionStatus.LIQUIDATED : PositionStatus.CLOSED;
        assetExposure[pos.spotToken] -= pos.notional;
        borrowedByAssetTier[pos.spotToken][pos.tier] -= pos.borrowedPrincipal;
        --openPositionCount;

        address proxy = pos.proxy;
        uint256 usdcOut = _swap(proxy, pos.spotToken, address(usdc), pos.spotAmount, minOut);
        ITraderProxy(proxy).sweep(address(usdc), address(this), usdcOut);

        (uint256 traderPayout, uint256 penalty) = _settle(posId, pos, usdcOut, forced, isLiquidation);

        if (isLiquidation) {
            emit PositionLiquidated(posId, msg.sender, usdcOut, mark, penalty);
        } else {
            emit PositionClosed(posId, reason, usdcOut, traderPayout, msg.sender);
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
            uint256 k = Math.min(keeperBounty, u);
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
        uint256 lpYield = Math.mulDiv(rolloverPaid, lpRolloverShareBps, BPS);
        uint256 toInsurance = rolloverPaid - lpYield;
        uint256 treasuryCut;

        // Step 4: liquidation penalty vs. trader payout & profit split.
        if (isLiquidation) {
            penalty = u;
            toInsurance += u;
        } else {
            uint256 margin = pos.userMargin;
            if (u <= margin) {
                traderPayout = u;
            } else {
                uint256 profit = u - margin;
                TierConfig memory t = tiers[pos.tier];
                uint256 lpCut = Math.mulDiv(profit, t.lpProfitBps, BPS);
                treasuryCut = Math.mulDiv(profit, t.treasuryProfitBps, BPS);
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
}
