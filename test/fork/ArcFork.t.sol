// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkBase} from "./ForkBase.t.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {UniV4TwapOracle} from "../../src/UniV4TwapOracle.sol";
import {V4SwapRouter} from "../../src/V4SwapRouter.sol";

/// @notice End-to-end against Arc mainnet state: real pools, real liquidity, real fees.
contract ArcForkTest is ForkBase {
    // ------------------------------------------------------------------ oracle

    function test_fork_twapMatchesSpotAfterWarmUp() public view {
        for (uint256 i; i < 2; ++i) {
            address a = _assets()[i];
            assertTrue(d.oracle.isReady(a));
            assertEq(d.oracle.twapTick(a), d.oracle.spotTick(a)); // nobody traded on the fork
            assertEq(d.oracle.getPrice(a), d.oracle.spotPrice(a));
        }
        uint256 eth = d.oracle.getPrice(WETH);
        uint256 btc = d.oracle.getPrice(CIRBTC);
        assertGt(eth, 500e18);
        assertLt(eth, 20_000e18);
        assertGt(btc, 10_000e18);
        assertLt(btc, 500_000e18);
        // 1 WETH and 1 cirBTC valued in 6-decimal USDC.
        assertEq(d.oracle.valueInUsdc(WETH, 1e18), eth / 1e12);
        assertEq(d.oracle.valueInUsdc(CIRBTC, 1e8), btc / 1e12);
    }

    function test_fork_twapNotReadyThenStale() public {
        // A fresh feed must collect a full window first.
        d.oracle.setFeed(WETH, _key(WETH));
        _record();
        vm.expectPartialRevert(UniV4TwapOracle.TwapNotReady.selector);
        d.oracle.getPrice(WETH);

        _advance(600, 10);
        d.oracle.getPrice(WETH);

        // Recorder outage: stale after maxStaleness...
        vm.warp(vm.getBlockTimestamp() + d.oracle.maxStaleness() + 1);
        vm.expectPartialRevert(UniV4TwapOracle.TwapStale.selector);
        d.oracle.getPrice(WETH);

        // ...and a gap beyond maxObservationGap restarts the series rather than extrapolating across it.
        vm.warp(vm.getBlockTimestamp() + d.oracle.maxObservationGap());
        _record();
        vm.expectPartialRevert(UniV4TwapOracle.TwapNotReady.selector);
        d.oracle.getPrice(WETH);
    }

    function test_fork_onlyRecordersRecord() public {
        address[] memory a = _assets();
        int24[] memory t = new int24[](2);
        vm.expectRevert(UniV4TwapOracle.NotRecorder.selector);
        d.oracle.record(a, t);
    }

    /// The attack a permissionless recorder would allow: pump, record, dump in one transaction.
    function test_fork_sandwichedSampleIsRejected() public {
        int24 honest = d.oracle.spotTick(WETH);
        int24 twapBefore = d.oracle.twapTick(WETH);
        vm.warp(vm.getBlockTimestamp() + 10);

        _movePool(WETH, _tickFor(WETH, 1_000)); // +10% just before the keeper's record lands
        address[] memory a = new address[](1);
        a[0] = WETH;
        int24[] memory t = new int24[](1);
        t[0] = honest;
        vm.recordLogs();
        vm.prank(keeper);
        d.oracle.record(a, t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], UniV4TwapOracle.SampleRejected.selector);
        _movePool(WETH, honest); // attacker unwinds

        assertEq(d.oracle.latestObservation(WETH).tick, honest);
        assertEq(d.oracle.twapTick(WETH), twapBefore);
    }

    /// A sustained move is followed, but each observation can move at most `maxTickDelta`.
    function test_fork_twapFollowsRealMoveWithClamp() public {
        int24 start = d.oracle.spotTick(WETH);
        int24 target = _tickFor(WETH, -2_000); // -20%
        _movePool(WETH, target);
        int24 live = d.oracle.spotTick(WETH);
        assertApproxEqAbs(live, target, 30);

        _advance(10, 10);
        assertEq(d.oracle.latestObservation(WETH).tick, start - d.oracle.maxTickDelta());

        _advance(700, 10);
        assertEq(d.oracle.twapTick(WETH), live);
    }

    // ------------------------------------------------------------------ router

    function test_fork_routerSwapsAgainstRealPool() public {
        address user = makeAddr("user");
        _mintUsdc(user, 100e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(d.router), 100e6);
        uint256 out = d.router.swapExactIn(_key(WETH), false, 100e6, 0, user);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(user), out);
        assertEq(IERC20(USDC).balanceOf(user), 0);
        assertEq(IERC20(USDC).allowance(user, address(d.router)), 0);
        // $100 at the TWAP, less 0.25% LP fee, the 0.04% protocol fee and a little price impact.
        uint256 valued = d.oracle.valueInUsdc(WETH, out);
        assertGt(valued, 99e6);
        assertLt(valued, 100e6);
    }

    function test_fork_routerEnforcesMinOut() public {
        address user = makeAddr("user");
        _mintUsdc(user, 100e6);
        PoolKey memory key = _key(CIRBTC);
        vm.startPrank(user);
        IERC20(USDC).approve(address(d.router), 100e6);
        vm.expectPartialRevert(V4SwapRouter.InsufficientOutput.selector);
        d.router.swapExactIn(key, false, 100e6, type(uint128).max, user);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ positions

    function test_fork_openEthAndBtcLongs() public {
        uint256 e = _open(WETH, 10e6, 10);
        uint256 b = _open(CIRBTC, 10e6, 5);

        PositionManager.Position memory pe = d.pm.getPosition(e);
        PositionManager.Position memory pb = d.pm.getPosition(b);
        assertEq(pe.notional, 100e6);
        assertEq(pe.borrowedPrincipal, 90e6);
        assertEq(pb.notional, 50e6);
        assertEq(pb.borrowedPrincipal, 40e6);
        assertEq(IERC20(WETH).balanceOf(pe.proxy), pe.spotAmount);
        assertEq(IERC20(CIRBTC).balanceOf(pb.proxy), pb.spotAmount);

        // Marked at the TWAP within the 1% entry allowance; pool fees are the only cost (no protocol entry fee).
        assertGt(d.pm.markValue(e), 99e6);
        assertGt(d.pm.markValue(b), 49.5e6);
        assertFalse(d.pm.isLiquidatable(e));
        assertEq(d.vault.totalBorrowedPrincipal(), 130e6);
    }

    function test_fork_openRejectsManipulatedPool() public {
        // The trader (or a sandwicher) pumps the pool just before the open: the TWAP has not moved, so the fill
        // is worth less than the notional at the TWAP and the open reverts instead of overpaying with LP money.
        _movePool(CIRBTC, _tickFor(CIRBTC, 300));
        vm.prank(trader);
        vm.expectPartialRevert(PositionManager.EntryPriceDeviation.selector);
        d.pm
            .openPosition(
                PositionManager.OpenParams({
                    spotToken: CIRBTC, tier: 10, margin: 10e6, autoRollover: true, minAmountOut: 0
                })
            );
    }

    function test_fork_closeInProfitAfterRally() public {
        uint256 id = _open(WETH, 10e6, 10);
        uint256 traderBefore = IERC20(USDC).balanceOf(trader);
        uint256 assetsBefore = d.vault.totalAssets();

        _movePool(WETH, _tickFor(WETH, 500)); // ETH +5%
        _advance(700, 10); // TWAP catches up

        vm.prank(trader);
        d.pm.closePosition(id, 0);

        uint256 payout = IERC20(USDC).balanceOf(trader) - traderBefore;
        // 10x on +5% minus round-trip pool fees: roughly margin $10 + ~$4 profit after the 12% LP / 3% treasury cut.
        assertGt(payout, 12e6);
        assertLt(payout, 16e6);
        assertEq(uint8(d.pm.getPosition(id).status), uint8(PositionManager.PositionStatus.CLOSED));
        assertEq(d.vault.totalBorrowedPrincipal(), 0);
        skip(12 hours); // LP share of profit vests
        assertGt(d.vault.totalAssets(), assetsBefore);
    }

    function test_fork_closeBlockedWhilePoolDumpedBelowTwap() public {
        uint256 id = _open(CIRBTC, 10e6, 5);
        // Someone dumps the pool 5% (or the trader does, hoping to shift the loss to LPs): the exit must fill
        // within 1% of the TWAP, so the close reverts until the pool recovers or the TWAP catches up.
        _movePool(CIRBTC, _tickFor(CIRBTC, -500));
        vm.prank(trader);
        vm.expectRevert();
        d.pm.closePosition(id, 0);
    }

    function test_fork_liquidationAfterCrash() public {
        uint256 id = _open(WETH, 10e6, 10);
        assertFalse(d.pm.isLiquidatable(id));

        _movePool(WETH, _tickFor(WETH, -800)); // ETH -8%: below the 10x threshold (B + 2% of N)
        // The TWAP lags: not liquidatable yet.
        assertFalse(d.pm.isLiquidatable(id));
        _advance(700, 10);
        assertTrue(d.pm.isLiquidatable(id));

        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(d.vault));
        vm.prank(keeper);
        d.pm.liquidate(id, 0);

        assertEq(uint8(d.pm.getPosition(id).status), uint8(PositionManager.PositionStatus.LIQUIDATED));
        assertEq(IERC20(USDC).balanceOf(keeper) - keeperBefore, 0.1e6);
        assertEq(d.vault.totalBorrowedPrincipal(), 0);
        // Principal came back in full (any shortfall would have been covered by insurance or booked as loss).
        assertGe(IERC20(USDC).balanceOf(address(d.vault)) - vaultUsdcBefore, 90e6);
    }

    function test_fork_stopLossTrigger() public {
        uint256 id = _open(CIRBTC, 10e6, 5);
        uint256 p = d.oracle.getPrice(CIRBTC);
        vm.prank(trader);
        d.pm.setOrders(id, uint128(p * 97 / 100), 0, 0);

        _movePool(CIRBTC, _tickFor(CIRBTC, -400));
        _advance(700, 10);

        uint256 before = IERC20(USDC).balanceOf(trader);
        vm.prank(keeper);
        d.pm.executeTrigger(id, 0);
        assertEq(uint8(d.pm.getPosition(id).status), uint8(PositionManager.PositionStatus.CLOSED));
        assertGt(IERC20(USDC).balanceOf(trader) - before, 7e6); // 5x on -4%: ~$10 - $2 - fees
    }

    function test_fork_addMarginThenEpochRoll() public {
        uint256 id = _open(WETH, 10e6, 10);
        vm.prank(trader);
        d.pm.addMargin(id, 20e6);
        assertEq(d.pm.getPosition(id).borrowedPrincipal, 70e6);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        _warmUp(); // the keeper series restarted after the week-long gap
        vm.prank(keeper);
        d.pm.processEpoch(id, 0);
        PositionManager.Position memory pos = d.pm.getPosition(id);
        assertEq(uint8(pos.status), uint8(PositionManager.PositionStatus.OPEN));
        assertEq(pos.accruedRolloverDebt, d.pm.epochRolloverFee(70e6));
    }
}
