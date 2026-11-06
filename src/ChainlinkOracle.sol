// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IOracle} from "./interfaces/IProtocol.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract ChainlinkOracle is IOracle, Ownable2Step {
    struct Feed {
        AggregatorV3Interface aggregator;
        uint32 maxStaleness;
        PoolKey poolKey;
        uint8 assetDecimals;
        uint8 feedDecimals;
    }

    mapping(address => Feed) public feeds;

    error FeedNotSet(address asset);
    error InvalidPrice(address asset, int256 price);
    error StalePrice(address asset, uint256 updatedAt);
    error InvalidFeed();

    event FeedSet(address indexed asset, AggregatorV3Interface aggregator, uint32 maxStaleness);

    constructor(address usdc_, address owner_) Ownable2Step() {
        _transferOwnership(owner_);
    }

    function setFeed(address asset, AggregatorV3Interface aggregator, uint32 maxStaleness, PoolKey calldata key) external onlyOwner {
        if (address(aggregator) == address(0) || maxStaleness == 0) revert InvalidFeed();
        if (key.currency0.toId() != keccak256(abi.encode(asset)) && key.currency1.toId() != keccak256(abi.encode(asset))) revert InvalidFeed();
        
        feeds[asset] = Feed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            poolKey: key,
            assetDecimals: IERC20Metadata(asset).decimals(),
            feedDecimals: aggregator.decimals()
        });
        emit FeedSet(asset, aggregator, maxStaleness);
    }

    function getPrice(address asset) external view returns (uint256) {
        Feed memory f = feeds[asset];
        if (address(f.aggregator) == address(0)) revert FeedNotSet(asset);

        ( , int256 answer, , uint256 updatedAt, ) = f.aggregator.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice(asset, updatedAt);

        return uint256(answer) * 10**(18 - f.feedDecimals);
    }

    function valueInUsdc(address asset, uint256 amount) external view returns (uint256) {
        return (amount * this.getPrice(asset)) / 10**(feeds[asset].assetDecimals + 18 - 6);
    }

    function poolKey(address asset) external view returns (PoolKey memory) {
        if (address(feeds[asset].aggregator) == address(0)) revert FeedNotSet(asset);
        return feeds[asset].poolKey;
    }
}