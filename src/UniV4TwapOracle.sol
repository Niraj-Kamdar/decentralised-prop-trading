// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IOracle} from "./interfaces/IProtocol.sol";

/// @title UniV4TwapOracle
/// @notice Time-weighted average price (default 10 minutes) of each spot asset against USDC, measured on the
///         Uniswap v4 pool the protocol trades through. Prices are USD per whole token, 18 decimals (USDC = $1).
///
/// @dev Uniswap v4 pools keep no price history, so this contract keeps it: a ring buffer of tick observations,
///      integrated like the v3 oracle (each observation's tick is held until the next one). Two rules make the
///      series hard to manipulate with a single atomic transaction:
///
///      1. **Only whitelisted recorders write observations.** Anyone could otherwise push the pool, record and swap
///         back in one transaction, cheaply walking the TWAP away. A recorder passes the tick it saw at the end of
///         the previous block; a sample whose live tick deviates by more than `maxRecordDeviation` is rejected, so a
///         sandwich of the recorder's own transaction can move a sample only within that tolerance.
///      2. **Every observation is clamped** to `maxTickDelta` from the previous one, bounding the damage of any
///         single bad sample and of a compromised recorder.
///
///      The price is unusable (reverts) while the series is younger than `twapWindow` or when the newest
///      observation is older than `maxStaleness`. A gap longer than `maxObservationGap` restarts the series, so the
///      TWAP never silently extrapolates across a long recorder outage.
contract UniV4TwapOracle is IOracle, Ownable2Step {
    using StateLibrary for IPoolManager;

    uint16 public constant CARDINALITY = 128;
    uint32 public constant MIN_WINDOW = 60;
    uint32 public constant MAX_WINDOW = 1 hours;

    struct Observation {
        uint32 timestamp;
        int24 tick; // pool tick (currency1 per currency0), clamped
        int56 tickCumulative; // sum of tick * seconds up to `timestamp`
    }

    struct Feed {
        PoolKey key;
        PoolId poolId;
        bool assetIsCurrency0;
        uint8 assetDecimals;
        bool enabled;
        uint16 index; // physical slot of the newest observation
        uint16 count; // observations written, capped at CARDINALITY
        uint32 seriesStart; // timestamp of the first observation of the current continuous series
    }

    IPoolManager public immutable poolManager;
    address public immutable usdc;
    uint8 public immutable usdcDecimals;

    uint32 public twapWindow = 600;
    uint32 public minObservationInterval = 5;
    uint32 public maxStaleness = 90;
    uint32 public maxObservationGap = 300;
    int24 public maxTickDelta = 500; // ~5% per observation
    int24 public maxRecordDeviation = 100; // ~1% between the recorder's expected tick and the live tick

    mapping(address asset => Feed) internal _feeds;
    mapping(address asset => Observation[CARDINALITY]) internal _observations;
    mapping(address recorder => bool) public isRecorder;
    address[] internal _assets;

    event FeedSet(address indexed asset, PoolId indexed poolId, bool assetIsCurrency0);
    event FeedDisabled(address indexed asset);
    event RecorderSet(address indexed recorder, bool allowed);
    event ParamsSet(
        uint32 twapWindow,
        uint32 minObservationInterval,
        uint32 maxStaleness,
        uint32 maxObservationGap,
        int24 maxTickDelta,
        int24 maxRecordDeviation
    );
    event Observed(address indexed asset, uint32 timestamp, int24 liveTick, int24 recordedTick, bool seriesRestarted);
    event SampleRejected(address indexed asset, int24 liveTick, int24 expectedTick);

    error FeedNotEnabled(address asset);
    error InvalidFeed();
    error InvalidParams();
    error NotRecorder();
    error LengthMismatch();
    error TwapNotReady(uint256 readyAt);
    error TwapStale(uint256 lastObservation);

    constructor(IPoolManager poolManager_, address usdc_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0) || usdc_ == address(0)) revert InvalidFeed();
        poolManager = poolManager_;
        usdc = usdc_;
        usdcDecimals = IERC20Metadata(usdc_).decimals();
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    /// @notice Price `asset` on the v4 pool `key`, which must pair it with USDC. Restarts the asset's series.
    function setFeed(address asset, PoolKey calldata key) external onlyOwner {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool assetIs0 = c0 == asset && c1 == usdc;
        if (!assetIs0 && !(c1 == asset && c0 == usdc)) revert InvalidFeed();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert InvalidFeed(); // pool not initialised

        Feed storage f = _feeds[asset];
        if (f.key.tickSpacing == 0) _assets.push(asset);
        f.key = key;
        f.poolId = id;
        f.assetIsCurrency0 = assetIs0;
        f.assetDecimals = IERC20Metadata(asset).decimals();
        f.enabled = true;
        f.index = 0;
        f.count = 0;
        f.seriesStart = 0;
        emit FeedSet(asset, id, assetIs0);
    }

    function disableFeed(address asset) external onlyOwner {
        _feeds[asset].enabled = false;
        emit FeedDisabled(asset);
    }

    function setRecorder(address recorder, bool allowed) external onlyOwner {
        isRecorder[recorder] = allowed;
        emit RecorderSet(recorder, allowed);
    }

    function setParams(
        uint32 twapWindow_,
        uint32 minObservationInterval_,
        uint32 maxStaleness_,
        uint32 maxObservationGap_,
        int24 maxTickDelta_,
        int24 maxRecordDeviation_
    ) external onlyOwner {
        if (
            twapWindow_ < MIN_WINDOW || twapWindow_ > MAX_WINDOW || minObservationInterval_ == 0
                || uint256(CARDINALITY - 1) * minObservationInterval_ < twapWindow_ || maxStaleness_ == 0
                || maxStaleness_ > maxObservationGap_ || maxObservationGap_ <= minObservationInterval_
                || maxTickDelta_ <= 0 || maxRecordDeviation_ <= 0
        ) revert InvalidParams();
        twapWindow = twapWindow_;
        minObservationInterval = minObservationInterval_;
        maxStaleness = maxStaleness_;
        maxObservationGap = maxObservationGap_;
        maxTickDelta = maxTickDelta_;
        maxRecordDeviation = maxRecordDeviation_;
        emit ParamsSet(
            twapWindow_, minObservationInterval_, maxStaleness_, maxObservationGap_, maxTickDelta_, maxRecordDeviation_
        );
    }

    // ---------------------------------------------------------------------
    // Recording
    // ---------------------------------------------------------------------

    /// @notice Record one observation per asset. `expectedTicks[i]` is the pool tick the recorder read at the end
    ///         of the previous block; a live tick further than `maxRecordDeviation` from it is skipped, not written.
    /// @dev Never reverts on a single bad sample, so one manipulated pool cannot stop the others from updating.
    function record(address[] calldata assetList, int24[] calldata expectedTicks) external {
        if (!isRecorder[msg.sender]) revert NotRecorder();
        if (assetList.length != expectedTicks.length) revert LengthMismatch();
        for (uint256 i; i < assetList.length; ++i) {
            _record(assetList[i], expectedTicks[i]);
        }
    }

    function _record(address asset, int24 expectedTick) internal {
        Feed storage f = _feeds[asset];
        if (!f.enabled) revert FeedNotEnabled(asset);
        (, int24 live,,) = poolManager.getSlot0(f.poolId);
        if (_abs(int256(live) - expectedTick) > uint256(int256(maxRecordDeviation))) {
            emit SampleRejected(asset, live, expectedTick);
            return;
        }

        uint32 nowTs = uint32(block.timestamp);
        Observation[CARDINALITY] storage obs = _observations[asset];

        if (f.count == 0) {
            obs[0] = Observation({timestamp: nowTs, tick: live, tickCumulative: 0});
            f.index = 0;
            f.count = 1;
            f.seriesStart = nowTs;
            emit Observed(asset, nowTs, live, live, true);
            return;
        }

        Observation memory last = obs[f.index];
        uint32 dt = nowTs - last.timestamp;
        if (dt < minObservationInterval) return;

        int24 recorded = _clamp(live, last.tick - maxTickDelta, last.tick + maxTickDelta);
        bool restarted = dt > maxObservationGap;
        if (restarted) f.seriesStart = nowTs;

        uint16 next = (f.index + 1) % CARDINALITY;
        obs[next] = Observation({
            timestamp: nowTs, tick: recorded, tickCumulative: last.tickCumulative + int56(last.tick) * int56(uint56(dt))
        });
        f.index = next;
        if (f.count < CARDINALITY) ++f.count;
        emit Observed(asset, nowTs, live, recorded, restarted);
    }

    // ---------------------------------------------------------------------
    // Prices
    // ---------------------------------------------------------------------

    /// @inheritdoc IOracle
    function getPrice(address asset) public view returns (uint256 price18) {
        Feed storage f = _feeds[asset];
        return _tickToPrice18(f, twapTick(asset));
    }

    /// @inheritdoc IOracle
    function valueInUsdc(address asset, uint256 amount) external view returns (uint256) {
        Feed storage f = _feeds[asset];
        uint256 price18 = _tickToPrice18(f, twapTick(asset));
        return Math.mulDiv(amount, price18, 10 ** (uint256(f.assetDecimals) + 18 - usdcDecimals));
    }

    /// @notice Arithmetic-mean pool tick over the last `twapWindow` seconds (rounded towards negative infinity).
    function twapTick(address asset) public view returns (int24) {
        Feed storage f = _feeds[asset];
        if (!f.enabled) revert FeedNotEnabled(asset);
        if (f.count == 0) revert TwapNotReady(type(uint256).max);

        Observation[CARDINALITY] storage obs = _observations[asset];
        Observation memory last = obs[f.index];
        if (block.timestamp > uint256(last.timestamp) + maxStaleness) revert TwapStale(last.timestamp);
        uint256 window = twapWindow;
        uint256 readyAt = uint256(f.seriesStart) + window;
        if (block.timestamp < readyAt) revert TwapNotReady(readyAt);

        uint32 target = uint32(block.timestamp - window);
        int56 cumNow = last.tickCumulative + int56(last.tick) * int56(uint56(uint32(block.timestamp) - last.timestamp));
        int56 cumThen = _cumulativeAt(obs, f, target);

        int56 delta = cumNow - cumThen;
        int56 avg = delta / int56(uint56(window));
        if (delta < 0 && delta % int56(uint56(window)) != 0) --avg;
        return int24(avg);
    }

    /// @notice Current pool price (USD per whole token, 1e18). Display only: never used for risk decisions.
    function spotPrice(address asset) external view returns (uint256) {
        Feed storage f = _feeds[asset];
        if (!f.enabled) revert FeedNotEnabled(asset);
        (, int24 tick,,) = poolManager.getSlot0(f.poolId);
        return _tickToPrice18(f, tick);
    }

    /// @notice Current pool tick, e.g. for a recorder building its `expectedTicks`.
    function spotTick(address asset) external view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(_feeds[asset].poolId);
    }

    /// @notice Whether `getPrice(asset)` would currently succeed.
    function isReady(address asset) external view returns (bool) {
        Feed storage f = _feeds[asset];
        if (!f.enabled || f.count == 0) return false;
        Observation memory last = _observations[asset][f.index];
        return block.timestamp <= uint256(last.timestamp) + maxStaleness
            && block.timestamp >= uint256(f.seriesStart) + twapWindow;
    }

    /// @inheritdoc IOracle
    function poolKey(address asset) external view returns (PoolKey memory) {
        Feed storage f = _feeds[asset];
        if (!f.enabled) revert FeedNotEnabled(asset);
        return f.key;
    }

    function feed(address asset)
        external
        view
        returns (
            PoolId poolId,
            bool assetIsCurrency0,
            uint8 assetDecimals,
            bool enabled,
            uint16 count,
            uint32 seriesStart
        )
    {
        Feed storage f = _feeds[asset];
        return (f.poolId, f.assetIsCurrency0, f.assetDecimals, f.enabled, f.count, f.seriesStart);
    }

    function latestObservation(address asset) external view returns (Observation memory) {
        return _observations[asset][_feeds[asset].index];
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Cumulative tick at `target`, interpolated between the surrounding observations. The window is always
    ///      covered: `seriesStart <= target` and the buffer spans at least (CARDINALITY - 1) * minObservationInterval
    ///      >= twapWindow seconds.
    function _cumulativeAt(Observation[CARDINALITY] storage obs, Feed storage f, uint32 target)
        internal
        view
        returns (int56)
    {
        uint256 n = f.count;
        uint256 oldest = n < CARDINALITY ? 0 : (uint256(f.index) + 1) % CARDINALITY;
        // Binary search for the newest observation with timestamp <= target.
        uint256 lo;
        uint256 hi = n - 1;
        if (obs[oldest].timestamp > target) revert TwapNotReady(uint256(obs[oldest].timestamp) + twapWindow);
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (obs[(oldest + mid) % CARDINALITY].timestamp <= target) lo = mid;
            else hi = mid - 1;
        }
        Observation memory a = obs[(oldest + lo) % CARDINALITY];
        return a.tickCumulative + int56(a.tick) * int56(uint56(target - a.timestamp));
    }

    /// @dev USD (1e18) per whole asset token at pool tick `tick`, with USDC = $1.
    function _tickToPrice18(Feed storage f, int24 tick) internal view returns (uint256) {
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64); // currency1 raw per currency0 raw, Q128
        uint256 scale = 10 ** (uint256(f.assetDecimals) + 18 - usdcDecimals);
        return f.assetIsCurrency0 ? Math.mulDiv(priceX128, scale, 1 << 128) : Math.mulDiv(1 << 128, scale, priceX128);
    }

    function _clamp(int24 x, int24 lo, int24 hi) internal pure returns (int24) {
        if (lo < TickMath.MIN_TICK) lo = TickMath.MIN_TICK;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        return x < lo ? lo : x > hi ? hi : x;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
