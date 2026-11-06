// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TraderProxy} from "./TraderProxy.sol";
import {ArcConstants} from "./libraries/ArcConstants.sol";
import {
    ILPVault,
    IInsuranceReserve,
    IOracleVerifier,
    ITraderProxy,
    IRouterRegistry,
    IRiskView
} from "./interfaces/IProtocol.sol";

/// @title PositionManager
/// @notice Orchestrates leveraged spot positions: clone-per-position custody, vault borrowing, 7-day epochs with
///         lazy 8% APR rollover debt, oracle-gated liquidations, and the settlement / bad-debt waterfall.
/// @dev No function is payable and there is no receive(): native USDC (18-dec msg.value) is always rejected.
contract PositionManager is IRouterRegistry, IRiskView, Ownable2Step, Pausable, ReentrancyGuard {
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

    struct SwapInstruction {
        address router;
        uint256 minAmountOut;
        bytes data; // raw calldata executed on `router` by the TraderProxy
    }

    struct OpenParams {
        address spotToken;
        uint8 tier;
        uint128 margin;
        bool autoRollover;
        SwapInstruction swap;
        bytes[] priceUpdateData;
    }

    // ---------------------------------------------------------------------
    // Immutables & storage
    // ---------------------------------------------------------------------

    IERC20 public immutable usdc;
    ILPVault public immutable lpVault;
    IInsuranceReserve public immutable insurance;
    IOracleVerifier public immutable oracle;
    address public immutable proxyImplementation;

    address public guardian;

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

    uint256 public rolloverAprBps = 800;
    uint256 public lpRolloverShareBps = 8_000;
    uint256 public minNotional = 500e6;
    uint256 public keeperBounty = 5e6;
    uint256 public maxEntrySlippageBps = 100;
    uint256 public maxExitSlippageBps = 100;
    uint256 public maxLiqSlippageBps = 200;

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
    event RouterSet(address indexed router, bool allowed);
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
    error RouterNotWhitelisted(address router);
    error BelowMinNotional(uint256 notional);
    error ExposureCapExceeded(address token, uint256 exposureAfter, uint256 cap);
    error EntryPriceDeviation(uint256 markValue, uint256 notional);
    error UnhealthyAtOpen(uint256 markValue, uint256 threshold);
    error MinOutBelowOracleBound(uint256 minOut, uint256 bound);
    error PositionNotOpen(uint256 posId);
    error NotAuthorized();
    error EpochNotEnded(uint64 epochEndTime);
    error NotLiquidatable(uint256 markValue, uint256 threshold);
    error TriggerNotHit(uint256 price);
    error InvalidAmount();
    error InvalidParams();
    error NothingToClaim();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(IERC20 usdc_, ILPVault lpVault_, IInsuranceReserve insurance_, IOracleVerifier oracle_, address owner_)
        Ownable(owner_)
    {
        if (
            address(usdc_) == address(0) || address(lpVault_) == address(0) || address(insurance_) == address(0)
                || address(oracle_) == address(0)
        ) revert ZeroAddress();
        if (ArcConstants.isArc() && address(usdc_) != ArcConstants.USDC) revert InvalidAsset();
        if (IERC20Metadata(address(usdc_)).decimals() != ArcConstants.USDC_DECIMALS) revert InvalidAsset();

        usdc = usdc_;
        lpVault = lpVault_;
        insurance = insurance_;
        oracle = oracle_;
        proxyImplementation = address(new TraderProxy(address(this)));

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
        if (!isWhitelistedRouter[p.swap.router]) revert RouterNotWhitelisted(p.swap.router);

        uint256 margin = p.margin;
        uint256 notional = margin * p.tier;
        if (notional < minNotional) revert BelowMinNotional(notional);
        uint256 borrowed = notional - margin;

        _updateOracle(p.priceUpdateData);

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

        uint256 spotAmount = ITraderProxy(proxy)
            .executeSwap(p.swap.router, address(usdc), p.spotToken, notional, p.swap.minAmountOut, p.swap.data);

        // Oracle sanity: a self-sandwiched entry would hand LP principal to the attacker's pool.
        uint256 markValue = oracle.valueInUsdc(p.spotToken, spotAmount);
        if (markValue * BPS < notional * (BPS - maxEntrySlippageBps)) revert EntryPriceDeviation(markValue, notional);
        uint256 threshold = borrowed + Math.mulDiv(notional, t.maintenanceBps, BPS);
        if (markValue <= threshold) revert UnhealthyAtOpen(markValue, threshold);

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
    /// @dev The trader's `minAmountOut` must sit within `maxExitSlippageBps` of the oracle mark, otherwise a trader
    ///      could dump the spot into their own manipulated pool and push the loss onto LP principal.
    function closePosition(uint256 posId, SwapInstruction calldata swap, bytes[] calldata priceUpdateData)
        external
        nonReentrant
        onlyOpen(posId)
        onlyTraderOrOperator(posId)
    {
        Position storage pos = _positions[posId];
        _updateOracle(priceUpdateData);
        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        _exitAndSettle(posId, pos, swap, mark, maxExitSlippageBps, CloseReason.MANUAL, false);
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
    function processEpoch(uint256 posId, SwapInstruction calldata swapIfClosing, bytes[] calldata priceUpdateData)
        external
        nonReentrant
        onlyOpen(posId)
    {
        Position storage pos = _positions[posId];
        if (block.timestamp < pos.epochEndTime) revert EpochNotEnded(pos.epochEndTime);
        _updateOracle(priceUpdateData);

        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        bool liquidatable = mark <= _liquidationThreshold(pos);

        if (pos.autoRollover && !liquidatable) return; // rolled; no bounty for a pure roll

        if (liquidatable) {
            _exitAndSettle(posId, pos, swapIfClosing, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
        } else {
            _exitAndSettle(posId, pos, swapIfClosing, mark, maxExitSlippageBps, CloseReason.EXPIRY, true);
        }
    }

    /// @notice KP-01: permissionless liquidation once V(t) <= B + D_roll + N * mu.
    function liquidate(uint256 posId, SwapInstruction calldata swap, bytes[] calldata priceUpdateData)
        external
        nonReentrant
        onlyOpen(posId)
    {
        Position storage pos = _positions[posId];
        _updateOracle(priceUpdateData);
        _catchUpEpochs(posId, pos);

        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        uint256 threshold = _liquidationThreshold(pos);
        if (mark > threshold) revert NotLiquidatable(mark, threshold);

        _exitAndSettle(posId, pos, swap, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
    }

    /// @notice Keeper execution of a trader's stop-loss / take-profit / trailing floor.
    function executeTrigger(uint256 posId, SwapInstruction calldata swap, bytes[] calldata priceUpdateData)
        external
        nonReentrant
        onlyOpen(posId)
    {
        Position storage pos = _positions[posId];
        _updateOracle(priceUpdateData);

        uint256 price = oracle.getPrice(pos.spotToken);
        bool hit = (pos.stopLossPrice != 0 && price <= pos.stopLossPrice)
            || (pos.takeProfitPrice != 0 && price >= pos.takeProfitPrice)
            || (pos.trailingStopPrice != 0 && price <= pos.trailingStopPrice);
        if (!hit) revert TriggerNotHit(price);

        _catchUpEpochs(posId, pos);
        uint256 mark = oracle.valueInUsdc(pos.spotToken, pos.spotAmount);
        if (mark <= _liquidationThreshold(pos)) {
            _exitAndSettle(posId, pos, swap, mark, maxLiqSlippageBps, CloseReason.LIQUIDATION, true);
        } else {
            _exitAndSettle(posId, pos, swap, mark, maxExitSlippageBps, CloseReason.TRIGGER, true);
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
        // Requires an oracle feed to exist (OracleVerifier.getPrice reverts otherwise when used).
        AssetConfig memory cfg =
            AssetConfig({enabled: enabled, maxExposureBps: maxExposureBps, stressShockBps: stressShockBps});
        assetConfigs[token] = cfg;
        if (!_assetListed[token]) {
            _assetListed[token] = true;
            _assetList.push(token);
        }
        emit AssetSet(token, cfg);
    }

    function setRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isWhitelistedRouter[router] = allowed;
        emit RouterSet(router, allowed);
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

    /// @dev Pyth fee is charged to the caller in ERC-20 USDC and sent to the OracleVerifier, whose native
    ///      balance on Arc is that same USDC; it then pays Pyth in native units.
    function _updateOracle(bytes[] calldata updateData) internal {
        if (updateData.length == 0) return;
        uint256 nativeFee = oracle.getUpdateFee(updateData);
        uint256 usdcFee = Math.ceilDiv(nativeFee, 1e12); // 18-dec native -> 6-dec ERC-20, rounded up
        if (usdcFee > 0) usdc.safeTransferFrom(msg.sender, address(oracle), usdcFee);
        oracle.updatePrices(updateData);
    }

    function _exitAndSettle(
        uint256 posId,
        Position storage pos,
        SwapInstruction calldata swap,
        uint256 mark,
        uint256 slippageBps,
        CloseReason reason,
        bool forced
    ) internal {
        uint256 bound = Math.mulDiv(mark, BPS - slippageBps, BPS);
        if (swap.minAmountOut < bound) revert MinOutBelowOracleBound(swap.minAmountOut, bound);

        bool isLiquidation = reason == CloseReason.LIQUIDATION;
        pos.status = isLiquidation ? PositionStatus.LIQUIDATED : PositionStatus.CLOSED;
        assetExposure[pos.spotToken] -= pos.notional;
        borrowedByAssetTier[pos.spotToken][pos.tier] -= pos.borrowedPrincipal;
        --openPositionCount;

        address proxy = pos.proxy;
        uint256 usdcOut = ITraderProxy(proxy)
            .executeSwap(swap.router, pos.spotToken, address(usdc), pos.spotAmount, swap.minAmountOut, swap.data);
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
