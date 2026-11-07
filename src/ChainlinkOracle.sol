// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IOracle} from "./interfaces/IProtocol.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface AggregatorV2V3Interface is AggregatorV3Interface {}

contract ChainlinkOracle is IOracle, Ownable2Step {
    struct Feed {
        AggregatorV3Interface aggregator;
        uint32 maxStaleness;
        uint8 assetDecimals;
        uint8 feedDecimals;
        PoolKey key;
    }

    address public immutable usdc;
    uint8 public immutable usdcDecimals;

    AggregatorV2V3Interface public sequencerUptimeFeed;
    uint256 public sequencerGracePeriod;

    mapping(address asset => Feed) internal _feeds;

    event FeedSet(address indexed asset, AggregatorV3Interface aggregator, uint32 maxStaleness);
    event SequencerUptimeFeedSet(address indexed feed, uint256 gracePeriod);

    error InvalidFeed();
    error FeedNotSet(address asset);
    error InvalidPrice(address asset, int256 answer);
    error StalePrice(address asset, uint256 updatedAt);
    error RoundNotComplete(address asset, uint80 roundId, uint80 answeredInRound);
    error SequencerDown();
    error GracePeriodNotOver();

    constructor(address usdc_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || owner_ == address(0)) revert InvalidFeed();
        usdc = usdc_;
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        sequencerGracePeriod = 3600;
    }

    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyOwner {
        sequencerUptimeFeed = AggregatorV2V3Interface(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerUptimeFeedSet(feed, gracePeriod);
    }

    function setFeed(address asset, AggregatorV3Interface aggregator, uint32 maxStaleness, PoolKey calldata key)
        external
        onlyOwner
    {
        if (address(aggregator) == address(0) || maxStaleness == 0 || asset == address(0)) revert InvalidFeed();

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (!((c0 == asset && c1 == usdc) || (c0 == usdc && c1 == asset))) revert InvalidFeed();

        uint8 feedDec = aggregator.decimals();
        if (feedDec > 18) revert InvalidFeed();
        uint8 assetDec = IERC20Metadata(asset).decimals();

        _feeds[asset] = Feed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            assetDecimals: assetDec,
            feedDecimals: feedDec,
            key: key
        });

        emit FeedSet(asset, aggregator, maxStaleness);
    }

    function getPrice(address asset) public view returns (uint256 price18) {
        Feed storage f = _feeds[asset];
        if (address(f.aggregator) == address(0)) revert FeedNotSet(asset);

        if (address(sequencerUptimeFeed) != address(0)) {
            (, int256 seqStatus, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
            if (seqStatus == 1) revert SequencerDown();
            if (startedAt == 0 || block.timestamp < startedAt || block.timestamp - startedAt < sequencerGracePeriod) {
                revert GracePeriodNotOver();
            }
        }

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = f.aggregator.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (updatedAt == 0 || answeredInRound < roundId) {
            revert RoundNotComplete(asset, roundId, answeredInRound);
        }
        if (block.timestamp < updatedAt || block.timestamp - updatedAt > f.maxStaleness) {
            revert StalePrice(asset, updatedAt);
        }

        return uint256(answer) * (10 ** (18 - f.feedDecimals));
    }

    function valueInUsdc(address asset, uint256 amount) external view returns (uint256 usdcValue) {
        Feed storage f = _feeds[asset];
        if (address(f.aggregator) == address(0)) revert FeedNotSet(asset);
        uint256 price18 = getPrice(asset);
        return Math.mulDiv(amount, price18, 10 ** (uint256(f.assetDecimals) + 18 - usdcDecimals));
    }

    function poolKey(address asset) external view returns (PoolKey memory) {
        Feed storage f = _feeds[asset];
        if (address(f.aggregator) == address(0)) revert FeedNotSet(asset);
        return f.key;
    }
}
