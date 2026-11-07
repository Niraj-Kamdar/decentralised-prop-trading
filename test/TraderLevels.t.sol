// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract TraderLevelsTest is BaseTest {
    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        pm.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 5,
                maxMargin: 100e6,
                lpProfitBps: 1_500,
                treasuryProfitBps: 500,
                promoteMinTrades: 2,
                promoteMinPnl: 10e6,
                demoteMaxLoss: 0
            })
        );
        pm.setLevel(
            1,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 10,
                maxMargin: 1_000e6,
                lpProfitBps: 1_000,
                treasuryProfitBps: 300,
                promoteMinTrades: 2,
                promoteMinPnl: 50e6,
                demoteMaxLoss: 20e6
            })
        );
        pm.setLevel(
            2,
            PositionManager.LevelConfig({
                enabled: false,
                maxLeverage: 10,
                maxMargin: 2_000e6,
                lpProfitBps: 700,
                treasuryProfitBps: 200,
                promoteMinTrades: 0,
                promoteMinPnl: 0,
                demoteMaxLoss: 0
            })
        );
        vm.stopPrank();
    }

    function test_open_respectsLevelLimits() public {
        // L0: 10x -> LevelLimitExceeded(0)
        vm.expectRevert(abi.encodeWithSelector(PositionManager.LevelLimitExceeded.selector, 0));
        _open(100e6, 10, false);

        // L0: margin 101e6 -> LevelLimitExceeded(0)
        vm.expectRevert(abi.encodeWithSelector(PositionManager.LevelLimitExceeded.selector, 0));
        _open(101e6, 5, false);

        // 100e6 @ 5x ok
        uint256 id = _open(100e6, 5, false);
        assertEq(pm.getPosition(id).trader, trader);
    }

    function test_profitCut_usesLevel() public {
        // L0: 100e6 @ 5x -> notional 500, borrowed 400.
        // Price rises so V = 550. Profit = 550 - 400 - 100 = 50.
        // L0: 15% lp (7.5e6), 5% treasury (2.5e6), trader payout = 100 + 40 = 140e6.
        uint256 id = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 55_000);

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        pm.closePosition(id, 0);

        assertEq(usdc.balanceOf(trader) - traderBefore, 140e6);
        assertEq(insurance.insurancePoolBalance() + insurance.opsTreasuryBalance(), 2.5e6);
        skip(12 hours);
        assertEq(vault.totalAssets(), LP_DEPOSIT + 7.5e6);
    }

    function test_promotes_afterTradesAndPnl() public {
        // First trade: profit 6e6
        uint256 id1 = _open(100e6, 5, false);
        // Price 50k -> notional 500, spot = 0.01 BTC.
        // Set price to 50,750 -> V = 507.5e6, profit = 7.5e6.
        // Trader gets margin (100) + 80% of 7.5 = 6e6. Net pnl = +6e6.
        _setPrice(address(cbBTC), 50_750);
        vm.prank(trader);
        pm.closePosition(id1, 0);

        (uint8 lvl, uint32 trades, int128 pnl) = pm.traderStats(trader);
        assertEq(lvl, 0);
        assertEq(trades, 1);
        assertEq(pnl, 6e6);

        // Second trade: profit 6e6 -> total pnl = 12e6 >= 10e6 with 2 trades -> promotes to L1
        _setPrice(address(cbBTC), 50_000);
        uint256 id2 = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 50_750);

        vm.expectEmit(true, false, false, true);
        emit PositionManager.LevelChanged(trader, 0, 1);

        vm.prank(trader);
        pm.closePosition(id2, 0);

        (lvl, trades, pnl) = pm.traderStats(trader);
        assertEq(lvl, 1);
        assertEq(trades, 0);
        assertEq(pnl, 0);
    }

    function test_noPromotion_whenPnlShort() public {
        // Trade 1: profit ~4e6
        // 50k -> 50,500: V = 505e6. Profit = 5e6. Trader payout = 100 + 4 = 104e6 (pnl = +4e6).
        uint256 id1 = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 50_500);
        vm.prank(trader);
        pm.closePosition(id1, 0);

        // Trade 2: profit ~4e6 -> total ~8e6 < 10e6
        _setPrice(address(cbBTC), 50_000);
        uint256 id2 = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 50_500);
        vm.prank(trader);
        pm.closePosition(id2, 0);

        (uint8 lvl, uint32 trades, int128 pnl) = pm.traderStats(trader);
        assertEq(lvl, 0);
        assertEq(trades, 2);
        assertTrue(pnl < 10e6);
        assertTrue(pnl > 7e6);
    }

    function test_demotes_onLoss() public {
        vm.prank(owner);
        pm.setTraderLevel(trader, 1);

        // L1: demoteMaxLoss is 20e6.
        // Open 100e6 @ 5x -> notional 500, borrowed 400.
        // Price drops: 50,000 -> 47,500. V = 475. U3 = 475 - 400 = 75. Trader payout = 75.
        // Pnl = 75 - 100 = -25e6 <= -20e6. Demotes to 0.
        uint256 id = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 47_500);

        vm.expectEmit(true, false, false, true);
        emit PositionManager.LevelChanged(trader, 1, 0);

        vm.prank(trader);
        pm.closePosition(id, 0);

        (uint8 lvl, uint32 trades, int128 pnl) = pm.traderStats(trader);
        assertEq(lvl, 0);
        assertEq(trades, 0);
        assertEq(pnl, 0);
    }

    function test_liquidation_countsAsFullMarginLoss() public {
        uint256 id = _open(100e6, 5, false);
        // Price drops below threshold to trigger liquidation
        _setPrice(address(cbBTC), 40_000);

        vm.prank(keeper);
        pm.liquidate(id, 0);

        (, uint32 trades, int128 pnl) = pm.traderStats(trader);
        assertEq(trades, 1);
        assertEq(pnl, -100e6);
    }

    function test_level0_neverDemotes() public {
        uint256 id = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 45_000); // severe loss

        vm.prank(trader);
        pm.closePosition(id, 0);

        (uint8 lvl,, int128 pnl) = pm.traderStats(trader);
        assertEq(lvl, 0);
        assertEq(pnl, -50e6);
    }

    function test_topLevel_neverPromotes() public {
        vm.prank(owner);
        pm.setTraderLevel(trader, 1);

        // Huge profit at L1 (L2 is disabled)
        uint256 id1 = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 100_000);
        vm.prank(trader);
        pm.closePosition(id1, 0);

        uint256 id2 = _open(100e6, 5, false);
        _setPrice(address(cbBTC), 100_000);
        vm.prank(trader);
        pm.closePosition(id2, 0);

        (uint8 lvl, uint32 trades, int128 pnl) = pm.traderStats(trader);
        assertEq(lvl, 1);
        assertEq(trades, 2);
        assertTrue(pnl > 100e6);
    }

    function test_disabledLevel_blocksOpenNotClose() public {
        uint256 id = _open(100e6, 5, false);

        vm.prank(owner);
        pm.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: false,
                maxLeverage: 5,
                maxMargin: 100e6,
                lpProfitBps: 1_500,
                treasuryProfitBps: 500,
                promoteMinTrades: 2,
                promoteMinPnl: 10e6,
                demoteMaxLoss: 0
            })
        );

        // New open fails
        vm.expectRevert(abi.encodeWithSelector(PositionManager.LevelLimitExceeded.selector, 0));
        _open(100e6, 5, false);

        // Existing close succeeds
        vm.prank(trader);
        pm.closePosition(id, 0);
        assertEq(pm.getPosition(id).trader, trader);
    }

    function test_denied_cannotOpen() public {
        vm.prank(owner);
        pm.setDenied(trader, true);

        vm.expectRevert(abi.encodeWithSelector(PositionManager.Denied.selector, trader));
        _open(100e6, 5, false);
    }

    function test_denied_canStillClose() public {
        uint256 id = _open(100e6, 5, false);

        vm.prank(owner);
        pm.setDenied(trader, true);

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        pm.closePosition(id, 0);

        assertTrue(usdc.balanceOf(trader) > traderBefore);
    }

    function test_levelAdmin_onlyOwner() public {
        vm.startPrank(trader);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        pm.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 5,
                maxMargin: 100e6,
                lpProfitBps: 1_500,
                treasuryProfitBps: 500,
                promoteMinTrades: 2,
                promoteMinPnl: 10e6,
                demoteMaxLoss: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        pm.setTraderLevel(trader, 1);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        pm.setDenied(trader, true);

        vm.stopPrank();
    }
}
