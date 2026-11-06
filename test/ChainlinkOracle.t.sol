// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {ChainlinkOracle, AggregatorV3Interface} from "../src/ChainlinkOracle.sol";
import {MockUSDC, MockToken, MockAggregator} from "./mocks/Mocks.sol";

contract ChainlinkOracleTest is Test {
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    MockUSDC internal usdc;
    MockToken internal weth;
    MockToken internal cbbtc;

    MockAggregator internal ethFeed;
    MockAggregator internal btcFeed;

    ChainlinkOracle internal o;

    function setUp() public {
        vm.warp(10_000);
        usdc = new MockUSDC();
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        cbbtc = new MockToken("Coinbase Wrapped BTC", "cbBTC", 8);

        ethFeed = new MockAggregator(8);
        btcFeed = new MockAggregator(8);

        vm.startPrank(owner);
        o = new ChainlinkOracle(address(usdc), owner);

        PoolKey memory wethKey = PoolKey({
            currency0: Currency.wrap(address(usdc) < address(weth) ? address(usdc) : address(weth)),
            currency1: Currency.wrap(address(usdc) < address(weth) ? address(weth) : address(usdc)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        o.setFeed(address(weth), ethFeed, 3600, wethKey);

        PoolKey memory btcKey = PoolKey({
            currency0: Currency.wrap(address(usdc) < address(cbbtc) ? address(usdc) : address(cbbtc)),
            currency1: Currency.wrap(address(usdc) < address(cbbtc) ? address(cbbtc) : address(usdc)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        o.setFeed(address(cbbtc), btcFeed, 3600, btcKey);
        vm.stopPrank();

        ethFeed.setAnswer(2_500e8, block.timestamp);
        btcFeed.setAnswer(60_000e8, block.timestamp);
    }

    function test_getPrice_scalesTo1e18() public {
        ethFeed.setAnswer(2_500_12345678, block.timestamp);
        assertEq(o.getPrice(address(weth)), 2_500.12345678e18);
    }

    function test_valueInUsdc_handlesDecimals() public {
        assertEq(o.valueInUsdc(address(weth), 2e18), 5_000e6);
        assertEq(o.valueInUsdc(address(cbbtc), 0.5e8), 30_000e6);
    }

    function test_getPrice_revertsOnNonPositive() public {
        ethFeed.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.InvalidPrice.selector, address(weth), int256(0)));
        o.getPrice(address(weth));

        ethFeed.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.InvalidPrice.selector, address(weth), int256(-1)));
        o.getPrice(address(weth));
    }

    function test_getPrice_revertsWhenStale() public {
        ethFeed.setAnswer(2_500e8, block.timestamp - 3600);
        assertEq(o.getPrice(address(weth)), 2_500e18);

        ethFeed.setAnswer(2_500e8, block.timestamp - 3601);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.StalePrice.selector, address(weth), block.timestamp - 3601));
        o.getPrice(address(weth));
    }

    function test_unsetFeed_reverts() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.FeedNotSet.selector, unknown));
        o.getPrice(unknown);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.FeedNotSet.selector, unknown));
        o.poolKey(unknown);
    }

    function test_setFeed_rejectsKeyWithoutUsdc() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(weth) < address(cbbtc) ? address(weth) : address(cbbtc)),
            currency1: Currency.wrap(address(weth) < address(cbbtc) ? address(cbbtc) : address(weth)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracle.InvalidFeed.selector);
        o.setFeed(address(weth), ethFeed, 3600, badKey);
    }

    function test_setFeed_onlyOwner() public {
        PoolKey memory wethKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        o.setFeed(address(weth), ethFeed, 3600, wethKey);
    }
}
