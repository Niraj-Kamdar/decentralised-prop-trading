// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPyth} from "./interfaces/IPyth.sol";

/// @title OracleVerifier
/// @notice Wick-safe Pyth pull-oracle wrapper: staleness <= 5s and confidence <= 50 bps, prices normalised to 1e18.
/// @dev Pyth update fees are paid in the native gas token. On Arc the native balance and the 0x3600 ERC-20
///      balance are the same USDC, so callers fund the fee by an ordinary ERC-20 transfer to this contract
///      (no payable function anywhere in the protocol). Only authorised consumers may spend that balance.
contract OracleVerifier is Ownable2Step {
    uint32 public constant MAX_STALENESS_CAP = 5; // seconds
    uint16 public constant MAX_CONF_BPS_CAP = 50; // 0.5%
    uint256 private constant BPS = 10_000;

    struct Feed {
        bytes32 priceId;
        uint32 maxStaleness;
        uint16 maxConfBps;
        uint8 tokenDecimals;
        bool enabled;
    }

    IPyth public immutable pyth;
    mapping(address asset => Feed) public feeds;
    mapping(address consumer => bool) public isConsumer;

    event FeedSet(address indexed asset, bytes32 priceId, uint32 maxStaleness, uint16 maxConfBps);
    event FeedDisabled(address indexed asset);
    event ConsumerSet(address indexed consumer, bool allowed);

    error FeedNotEnabled(address asset);
    error InvalidFeedParams();
    error StalePrice(uint256 publishTime, uint256 nowTs);
    error NonPositivePrice();
    error ConfidenceTooWide(uint256 confBps);
    error UnsupportedExponent(int32 expo);
    error NotConsumer();

    constructor(IPyth pyth_, address owner_) Ownable(owner_) {
        pyth = pyth_;
    }

    function setConsumer(address consumer, bool allowed) external onlyOwner {
        isConsumer[consumer] = allowed;
        emit ConsumerSet(consumer, allowed);
    }

    function setFeed(address asset, bytes32 priceId, uint32 maxStaleness, uint16 maxConfBps) external onlyOwner {
        if (
            asset == address(0) || priceId == bytes32(0) || maxStaleness == 0 || maxStaleness > MAX_STALENESS_CAP
                || maxConfBps == 0 || maxConfBps > MAX_CONF_BPS_CAP
        ) revert InvalidFeedParams();
        feeds[asset] = Feed({
            priceId: priceId,
            maxStaleness: maxStaleness,
            maxConfBps: maxConfBps,
            tokenDecimals: IERC20Metadata(asset).decimals(),
            enabled: true
        });
        emit FeedSet(asset, priceId, maxStaleness, maxConfBps);
    }

    function disableFeed(address asset) external onlyOwner {
        feeds[asset].enabled = false;
        emit FeedDisabled(asset);
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }

    /// @notice Push fresh Pyth updates on-chain, paying the fee from this contract's native (USDC) balance.
    function updatePrices(bytes[] calldata updateData) external {
        if (!isConsumer[msg.sender]) revert NotConsumer();
        uint256 fee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeeds{value: fee}(updateData);
    }

    /// @notice USD price of one whole `asset` token, 18 decimals. Reverts when stale or too uncertain.
    function getPrice(address asset) public view returns (uint256 price18) {
        Feed memory f = feeds[asset];
        if (!f.enabled) revert FeedNotEnabled(asset);
        IPyth.Price memory p = pyth.getPriceUnsafe(f.priceId);

        if (p.publishTime + f.maxStaleness < block.timestamp) revert StalePrice(p.publishTime, block.timestamp);
        if (p.price <= 0) revert NonPositivePrice();

        uint256 raw = uint256(uint64(p.price));
        uint256 confBps = Math.mulDiv(uint256(p.conf), BPS, raw, Math.Rounding.Ceil);
        if (confBps > f.maxConfBps) revert ConfidenceTooWide(confBps);

        if (p.expo > 0 || p.expo < -18) revert UnsupportedExponent(p.expo);
        price18 = raw * 10 ** uint256(int256(18 + p.expo));
    }

    /// @notice USDC (6 decimals) mark value of `amount` native units of `asset`, rounded down.
    function valueInUsdc(address asset, uint256 amount) external view returns (uint256) {
        uint256 price18 = getPrice(asset);
        // amount * price18 / 10^tokenDecimals gives 18-dec USD; divide by 1e12 for 6-dec USDC.
        return Math.mulDiv(amount, price18, 10 ** (uint256(feeds[asset].tokenDecimals) + 12));
    }
}
