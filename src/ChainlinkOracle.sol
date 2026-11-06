// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract ChainlinkOracle is Ownable2Step {
    struct Feed {
        address aggregator;
        uint8 assetDecimals;
    }

    mapping(address => Feed) public feeds;
    uint256 public constant usdcDecimals = 6;

    constructor(address owner_) Ownable2Step() {
        require(owner_ != address(0), "Owner cannot be zero address");
        _transferOwnership(owner_);
    }

    function setFeed(address asset, address aggregator) external onlyOwner {
        uint8 feedDec = IAggregatorV3(aggregator).decimals();
        uint8 assetDec = IERC20Metadata(asset).decimals();
        feeds[asset] = Feed(aggregator, assetDec);
    }

    function getPrice(address asset) public view returns (uint256) {
        Feed memory f = feeds[asset];
        (, int256 price, , uint256 updatedAt, ) = IAggregatorV3(f.aggregator).latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt < 1 days, "Stale price");
        return uint256(price) * 10**(18 - IAggregatorV3(f.aggregator).decimals());
    }

    function valueInUsdc(address asset, uint256 amount) external view returns (uint256) {
        Feed memory f = feeds[asset];
        uint256 price18 = getPrice(asset);
        return Math.mulDiv(amount, price18, 10**(f.assetDecimals + 18 - usdcDecimals));
    }
}