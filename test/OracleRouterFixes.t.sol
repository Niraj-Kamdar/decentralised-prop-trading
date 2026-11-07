// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ChainlinkOracle, AggregatorV2V3Interface} from "../src/ChainlinkOracle.sol";
import {V4SwapRouter} from "../src/V4SwapRouter.sol";
import {MockUSDC, MockToken, MockAggregator} from "./mocks/Mocks.sol";

/// @notice Minimal mock PoolManager to control swap deltas for V4SwapRouter unit testing
contract MockPoolManagerForRouter {
    using SafeERC20 for IERC20;

    BalanceDelta public nextDelta;

    function setDelta(BalanceDelta delta) external {
        nextDelta = delta;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        returns (BalanceDelta)
    {
        return nextDelta;
    }

    function sync(Currency) external {}

    function settle() external pure returns (uint256) {
        return 0;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
    }
}

contract OracleRouterFixesTest is Test {
    using SafeERC20 for IERC20;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    MockUSDC internal usdc;
    MockToken internal weth;
    MockAggregator internal ethFeed;
    MockAggregator internal seqFeed;

    ChainlinkOracle internal oracle;

    MockPoolManagerForRouter internal mockPm;
    V4SwapRouter internal router;
    PoolKey internal key;
    bool internal zeroForOne;

    event SequencerUptimeFeedSet(address indexed feed, uint256 gracePeriod);

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC();
        weth = new MockToken("Wrapped Ether", "WETH", 18);

        ethFeed = new MockAggregator(8);
        seqFeed = new MockAggregator(0);

        ethFeed.setAnswer(2_500e8, block.timestamp);
        // Sequencer UP: answer = 0, startedAt = 7200 seconds ago
        seqFeed.setRoundData(1, 0, block.timestamp - 7200, block.timestamp - 7200, 1);

        vm.startPrank(owner);
        oracle = new ChainlinkOracle(address(usdc), owner);

        address c0 = address(usdc) < address(weth) ? address(usdc) : address(weth);
        address c1 = address(usdc) < address(weth) ? address(weth) : address(usdc);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        oracle.setFeed(address(weth), ethFeed, 3600, key);
        vm.stopPrank();

        // If c0 is USDC and c1 is WETH, zeroForOne means USDC -> WETH
        zeroForOne = Currency.unwrap(key.currency0) == address(usdc);

        mockPm = new MockPoolManagerForRouter();
        router = new V4SwapRouter(IPoolManager(address(mockPm)));

        usdc.mint(user, 10_000e6);
        weth.mint(user, 10e18);
        usdc.mint(address(mockPm), 10_000e6);
        weth.mint(address(mockPm), 10e18);

        vm.startPrank(user);
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // 1. Sequencer Uptime Feed Tests
    // =========================================================================

    function test_setSequencerUptimeFeed_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SequencerUptimeFeedSet(address(seqFeed), 3600);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        assertEq(address(oracle.sequencerUptimeFeed()), address(seqFeed));
        assertEq(oracle.sequencerGracePeriod(), 3600);
    }

    function test_sequencerDown_reverts() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        // Sequencer DOWN (answer = 1)
        seqFeed.setRoundData(2, 1, block.timestamp, block.timestamp, 2);

        vm.expectRevert(ChainlinkOracle.SequencerDown.selector);
        oracle.getPrice(address(weth));
    }

    function test_sequencerGracePeriodNotElapsed_reverts() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        // Sequencer just restarted (answer = 0, startedAt = block.timestamp)
        seqFeed.setRoundData(2, 0, block.timestamp, block.timestamp, 2);

        // 1800s elapsed (< 3600s grace period)
        vm.warp(block.timestamp + 1800);

        vm.expectRevert(ChainlinkOracle.GracePeriodNotOver.selector);
        oracle.getPrice(address(weth));
    }

    function test_sequencerStartedAtZero_reverts() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        // Uninitialized startedAt
        seqFeed.setRoundData(1, 0, 0, block.timestamp, 1);

        vm.expectRevert(ChainlinkOracle.GracePeriodNotOver.selector);
        oracle.getPrice(address(weth));
    }

    function test_sequencerUp_gracePeriodElapsed_success() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);

        // Sequencer became UP at t = 100_000
        uint256 restartTime = block.timestamp;
        seqFeed.setRoundData(2, 0, restartTime, restartTime, 2);

        // Warp exactly 3600 seconds
        vm.warp(restartTime + 3600);
        ethFeed.setAnswer(2_500e8, block.timestamp);

        uint256 price = oracle.getPrice(address(weth));
        assertEq(price, 2_500e18);
    }

    function test_sequencerFeedUnset_skipsCheck() public {
        // Sequencer down on feed, but feed is NOT set in oracle
        seqFeed.setRoundData(1, 1, block.timestamp, block.timestamp, 1);
        assertEq(address(oracle.sequencerUptimeFeed()), address(0));

        uint256 price = oracle.getPrice(address(weth));
        assertEq(price, 2_500e18);
    }

    function test_sequencerFeedCleared_skipsCheck() public {
        vm.startPrank(owner);
        oracle.setSequencerUptimeFeed(address(seqFeed), 3600);
        // Clear it
        oracle.setSequencerUptimeFeed(address(0), 3600);
        vm.stopPrank();

        seqFeed.setRoundData(1, 1, block.timestamp, block.timestamp, 1);
        uint256 price = oracle.getPrice(address(weth));
        assertEq(price, 2_500e18);
    }

    // =========================================================================
    // 2. Round Completeness Validation Tests
    // =========================================================================

    function test_roundIdMismatch_reverts() public {
        // answeredInRound < roundId indicates incomplete round
        ethFeed.setRoundData(5, 2_500e8, block.timestamp, block.timestamp, 4);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.RoundNotComplete.selector, address(weth), uint80(5), uint80(4))
        );
        oracle.getPrice(address(weth));
    }

    function test_updatedAtZero_reverts() public {
        // updatedAt == 0 indicates incomplete/unreported round
        ethFeed.setRoundData(1, 2_500e8, block.timestamp, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.RoundNotComplete.selector, address(weth), uint80(1), uint80(1))
        );
        oracle.getPrice(address(weth));
    }

    function test_roundComplete_succeeds() public {
        ethFeed.setRoundData(5, 2_500e8, block.timestamp, block.timestamp, 5);
        uint256 price = oracle.getPrice(address(weth));
        assertEq(price, 2_500e18);
    }

    // =========================================================================
    // 3. V4SwapRouter Safe Delta Output Cast Tests
    // =========================================================================

    function test_router_negativeOutput_revertsInsufficientOutput() public {
        // Swap expects output on amount1 (zeroForOne) or amount0 (!zeroForOne).
        // Negative delta on output currency: dOut = -10
        BalanceDelta delta = zeroForOne ? toBalanceDelta(-100, -10) : toBalanceDelta(-10, -100);
        mockPm.setDelta(delta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(V4SwapRouter.InsufficientOutput.selector, 50, 0));
        router.swapExactIn(key, zeroForOne, 100, 50, recipient);
    }

    function test_router_negativeOutput_withZeroMinOut_revertsInsufficientOutput() public {
        // Even when minAmountOut is 0, negative output must NOT underflow to 2^256 - 1
        BalanceDelta delta = zeroForOne ? toBalanceDelta(-100, -1) : toBalanceDelta(-1, -100);
        mockPm.setDelta(delta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(V4SwapRouter.InsufficientOutput.selector, 0, 0));
        router.swapExactIn(key, zeroForOne, 100, 0, recipient);
    }

    function test_router_zeroOutput_revertsInsufficientOutput() public {
        // Zero swap output: dOut = 0
        BalanceDelta delta = zeroForOne ? toBalanceDelta(-100, 0) : toBalanceDelta(0, -100);
        mockPm.setDelta(delta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(V4SwapRouter.InsufficientOutput.selector, 50, 0));
        router.swapExactIn(key, zeroForOne, 100, 50, recipient);
    }

    function test_router_positiveOutputBelowMin_reverts() public {
        // Positive output dOut = 40, but minAmountOut = 50
        BalanceDelta delta = zeroForOne ? toBalanceDelta(-100, 40) : toBalanceDelta(40, -100);
        mockPm.setDelta(delta);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(V4SwapRouter.InsufficientOutput.selector, 50, 40));
        router.swapExactIn(key, zeroForOne, 100, 50, recipient);
    }

    function test_router_validOutput_succeeds() public {
        // Positive output dOut = 95, minAmountOut = 90
        BalanceDelta delta = zeroForOne ? toBalanceDelta(-100, 95) : toBalanceDelta(95, -100);
        mockPm.setDelta(delta);

        IERC20 outToken = IERC20(Currency.unwrap(zeroForOne ? key.currency1 : key.currency0));
        uint256 recipientBalBefore = outToken.balanceOf(recipient);

        vm.prank(user);
        uint256 amountOut = router.swapExactIn(key, zeroForOne, 100, 90, recipient);

        assertEq(amountOut, 95);
        uint256 recipientBalAfter = outToken.balanceOf(recipient);
        assertEq(recipientBalAfter - recipientBalBefore, 95);
    }
}
