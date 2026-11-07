// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {TraderProxy} from "../src/TraderProxy.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockRouter} from "./mocks/Mocks.sol";

contract PositionManagerTest is BaseTest {
    // $100 margin x10 at BTC = $50k -> N = $1,000, B = $900, Q = 0.02 BTC, buffer = $20, V_liq = $920.

    function test_open_10x() public {
        uint256 posId = _open(100e6, 10, true);
        PositionManager.Position memory pos = pm.getPosition(posId);

        assertEq(pos.trader, trader);
        assertEq(pos.notional, 1_000e6);
        assertEq(pos.userMargin, 100e6);
        assertEq(pos.borrowedPrincipal, 900e6);
        assertEq(pos.spotAmount, 2_000_000); // 0.02 cbBTC
        assertEq(pos.epochEndTime, block.timestamp + 7 days);
        assertEq(cbBTC.balanceOf(pos.proxy), 2_000_000);
        assertEq(usdc.balanceOf(pos.proxy), 0);
        assertEq(vault.totalBorrowedPrincipal(), 900e6);
        assertEq(vault.totalAssets(), LP_DEPOSIT); // lending is asset-neutral
        assertEq(pm.assetExposure(address(cbBTC)), 1_000e6);
        assertEq(pm.liquidationThreshold(posId), 920e6);
    }

    function test_open_5x_threshold() public {
        uint256 posId = _open(200e6, 5, true);
        // N = 1000, B = 800, buffer = 4% = 40 -> 840 (-16% drawdown)
        assertEq(pm.liquidationThreshold(posId), 840e6);
    }

    function test_open_revertsBelowMinNotional() public {
        _expectOpenRevert(49e6, 10, abi.encodeWithSelector(PositionManager.BelowMinNotional.selector, 490e6));
    }

    function test_open_revertsOnInvalidTier() public {
        _expectOpenRevert(100e6, 7, abi.encodeWithSelector(PositionManager.InvalidTier.selector, 7));
    }

    function test_open_revertsOnEntryPriceDeviation() public {
        router.setFeeBps(200); // 2% worse than oracle > 1% max entry deviation
        _expectOpenRevert(
            100e6, 10, abi.encodeWithSelector(PositionManager.EntryPriceDeviation.selector, 980e6, 1_000e6)
        );
    }

    function test_open_revertsOverExposureCap() public {
        // 35% of $100k TVL = $35k notional cap.
        _expectOpenRevert(
            4_000e6,
            10,
            abi.encodeWithSelector(PositionManager.ExposureCapExceeded.selector, address(cbBTC), 40_000e6, 35_000e6)
        );
    }

    function test_open_revertsOverUtilizationCap() public {
        vm.prank(owner);
        pm.setAsset(address(cbBTC), true, 10_000, 2_000);
        _open(9_000e6, 10, true); // B = 81k <= 85k
        _expectOpenRevert(500e6, 10, ""); // 81k + 4.5k > 85k (LPVault.UtilizationCapExceeded)
    }

    function test_paused_blocksOpenButNotClose() public {
        uint256 posId = _open(100e6, 10, true);
        vm.prank(owner);
        pm.pause();

        _expectOpenRevert(100e6, 10, abi.encodeWithSelector(Pausable.EnforcedPause.selector));

        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);
        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.CLOSED));
    }

    // ------------------------------------------------------------------ settlement waterfall

    function test_close_inProfit_10xSplit() public {
        uint256 posId = _open(100e6, 10, true);
        _setPrice(address(cbBTC), 55_000); // V = 1100

        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        // U3 = 1100 - 900 = 200, profit = 100 -> LP 12, treasury 3, trader 100 + 85.
        assertEq(usdc.balanceOf(trader) - traderBefore, 185e6);
        assertEq(insurance.insurancePoolBalance(), 1.5e6);
        assertEq(insurance.opsTreasuryBalance(), 1.5e6);
        assertEq(vault.totalBorrowedPrincipal(), 0);
        assertEq(pm.assetExposure(address(cbBTC)), 0);

        // LP yield is vesting, not instant.
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        skip(6 hours);
        assertEq(vault.totalAssets(), LP_DEPOSIT + 6e6);
        skip(6 hours);
        assertEq(vault.totalAssets(), LP_DEPOSIT + 12e6);
    }

    function test_close_inProfit_5xSplit() public {
        uint256 posId = _open(200e6, 5, true);
        _setPrice(address(cbBTC), 55_000); // V = 1100, B = 800, U3 = 300, profit = 100

        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        assertEq(usdc.balanceOf(trader) - traderBefore, 285e6); // 200 + 85
        assertEq(insurance.insurancePoolBalance() + insurance.opsTreasuryBalance(), 3e6);
        skip(12 hours);
        assertEq(vault.totalAssets(), LP_DEPOSIT + 12e6);
    }

    function test_close_atLoss() public {
        uint256 posId = _open(100e6, 10, true);
        _setPrice(address(cbBTC), 47_500); // V = 950 -> U3 = 50

        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        assertEq(usdc.balanceOf(trader) - traderBefore, 50e6);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        assertEq(insurance.insurancePoolBalance(), 0);
    }

    function test_close_onlyTraderOrOperator() public {
        uint256 posId = _open(100e6, 10, true);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(keeper);
        vm.expectRevert(PositionManager.NotAuthorized.selector);
        pm.closePosition(posId, s);

        vm.prank(trader);
        pm.setOperator(keeper, true);
        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(keeper);
        pm.closePosition(posId, s);
        assertEq(usdc.balanceOf(trader) - traderBefore, 100e6); // payout always to trader
    }

    // ------------------------------------------------------------------ attack surfaces

    function test_close_enforcesTwapFloorEvenWithZeroMinOut() public {
        uint256 posId = _open(100e6, 10, true);
        // The pool now fills 3% below the TWAP: worse than the 1% exit allowance, so the close must revert even
        // though the trader asked for no minimum at all.
        router.setFeeBps(300);
        uint256 floor = _exitSwap(posId, 100);
        vm.prank(trader);
        vm.expectPartialRevert(TraderProxy.SwapCallFailed.selector);
        pm.closePosition(posId, 0);

        // A trader-supplied minimum above the floor tightens it.
        router.setFeeBps(0);
        vm.prank(trader);
        vm.expectPartialRevert(TraderProxy.SwapCallFailed.selector);
        pm.closePosition(posId, floor * 2);

        vm.prank(trader);
        pm.closePosition(posId, 0);
        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.CLOSED));
    }

    function test_close_rejectsRedirectedRouterOutput() public {
        uint256 posId = _open(100e6, 10, true);
        // A router that pays someone other than the proxy: the proxy's own balance check catches it.
        router.setRedirect(trader);
        uint256 floor = _exitSwap(posId, 100);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(TraderProxy.InsufficientOutput.selector, floor, 0));
        pm.closePosition(posId, 0);
    }

    function test_proxy_onlyManager() public {
        uint256 posId = _open(100e6, 10, true);
        PositionManager.Position memory pos = pm.getPosition(posId);
        vm.prank(trader);
        vm.expectRevert(TraderProxy.OnlyManager.selector);
        TraderProxy(pos.proxy).sweep(address(cbBTC), trader, pos.spotAmount);
    }

    function test_rejectsNativeValue() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = address(pm).call{value: 1}("");
        assertFalse(ok);
        vm.prank(trader);
        (ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ liquidation

    function test_liquidate_exactThreshold() public {
        uint256 posId = _open(100e6, 10, true);

        _setPrice(address(cbBTC), 46_001); // V = 920.02 > 920
        uint256 s0 = _exitSwap(posId, 200);
        vm.prank(keeper);
        vm.expectRevert();
        pm.liquidate(posId, s0);

        _setPrice(address(cbBTC), 46_000); // V = 920 == V_liq
        assertTrue(pm.isLiquidatable(posId));
        uint256 s = _exitSwap(posId, 200);
        vm.prank(keeper);
        pm.liquidate(posId, s);

        // 920 out: keeper 5, LP 900, penalty 15 -> insurance.
        assertEq(usdc.balanceOf(keeper), 5e6);
        assertEq(insurance.insurancePoolBalance(), 15e6);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.LIQUIDATED));
    }

    function test_liquidate_badDebt_insuranceThenLP() public {
        uint256 posId = _open(100e6, 10, true);

        usdc.mint(address(this), 20e6);
        usdc.approve(address(insurance), 20e6);
        insurance.donate(20e6);

        _setPrice(address(cbBTC), 42_500); // gap down: V = 850
        uint256 s = _exitSwap(posId, 200);
        vm.prank(keeper);
        pm.liquidate(posId, s);

        // 850 < 900 -> actual loss 50; bounty cannot inflate shortfall beyond actual position loss.
        // shortfall 50; insurance covers 20; LPs eat 30 (not 35).
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(insurance.insurancePoolBalance(), 0);
        assertEq(vault.totalBorrowedPrincipal(), 0);
        assertEq(vault.totalAssets(), LP_DEPOSIT - 30e6);
    }

    // ------------------------------------------------------------------ epochs

    function test_processEpoch_rollsWithDebt() public {
        uint256 posId = _open(100e6, 10, true);

        uint256 early = _exitSwap(posId, 100);
        vm.expectRevert();
        pm.processEpoch(posId, early);

        skip(7 days);
        _setPrice(address(cbBTC), 50_000);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(keeper);
        pm.processEpoch(posId, s);

        PositionManager.Position memory pos = pm.getPosition(posId);
        // 900 * 8% * 7/365 = 1.380821.. -> rounded up
        assertEq(pos.accruedRolloverDebt, 1_380_822);
        assertEq(pos.epochEndTime, pos.openedAt + 14 days);
        assertEq(uint8(pos.status), uint8(PositionManager.PositionStatus.OPEN));
        assertEq(pm.liquidationThreshold(posId), 921_380_822); // spec example: $921.38
    }

    function test_processEpoch_expiryClose_withBounty() public {
        uint256 posId = _open(100e6, 10, false);
        skip(7 days);
        _setPrice(address(cbBTC), 50_000);

        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(keeper);
        pm.processEpoch(posId, s);

        // 1000 - 5 bounty - 900 = 95 back to trader, no rollover debt.
        assertEq(usdc.balanceOf(keeper), 5e6);
        assertEq(usdc.balanceOf(trader) - traderBefore, 95e6);
        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.CLOSED));
    }

    function test_lateKeeper_debtStillAccrues() public {
        uint256 posId = _open(100e6, 10, true);
        skip(21 days); // epochs starting at day 7, 14 and 21 are due
        _setPrice(address(cbBTC), 55_000);

        uint256 fee = pm.epochRolloverFee(900e6);
        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        // U3 = 1100 - 900 - 3*fee; profit = U3 - 100; trader gets 100 + 85% of profit.
        uint256 profit = 200e6 - 3 * fee - 100e6;
        uint256 expected = 100e6 + profit - profit * 1_200 / 10_000 - profit * 300 / 10_000;
        assertEq(usdc.balanceOf(trader) - traderBefore, expected);
    }

    function test_rolloverDebt_split80_20() public {
        uint256 posId = _open(100e6, 10, true);
        skip(7 days);
        _setPrice(address(cbBTC), 50_000);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        uint256 fee = 1_380_822;
        uint256 lpPart = fee * 8_000 / 10_000;
        assertEq(insurance.insurancePoolBalance(), fee - lpPart);
        skip(12 hours);
        assertEq(vault.totalAssets(), LP_DEPOSIT + lpPart);
    }

    // ------------------------------------------------------------------ triggers, margin, payouts

    function test_stopLossTrigger() public {
        uint256 posId = _open(100e6, 10, true);
        vm.prank(trader);
        pm.setOrders(posId, 48_000e18, 0, 0);

        _setPrice(address(cbBTC), 48_500);
        uint256 s0 = _exitSwap(posId, 100);
        vm.prank(keeper);
        vm.expectRevert();
        pm.executeTrigger(posId, s0);

        _setPrice(address(cbBTC), 47_000); // V = 940
        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(keeper);
        pm.executeTrigger(posId, s);

        assertEq(usdc.balanceOf(keeper), 5e6);
        assertEq(usdc.balanceOf(trader) - traderBefore, 35e6); // 940 - 5 - 900
    }

    function test_addMargin_paysDownPrincipal() public {
        uint256 posId = _open(100e6, 10, true);
        vm.prank(trader);
        pm.addMargin(posId, 50e6);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.borrowedPrincipal, 850e6);
        assertEq(pos.userMargin, 150e6);
        assertEq(vault.totalBorrowedPrincipal(), 850e6);
        assertEq(pm.liquidationThreshold(posId), 870e6);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
    }

    function test_blocklistedTrader_payoutDeferredThenClaimed() public {
        uint256 posId = _open(100e6, 10, false);
        usdc.setBlocklisted(trader, true);

        skip(7 days);
        _setPrice(address(cbBTC), 50_000);
        uint256 s = _exitSwap(posId, 100);
        vm.prank(keeper);
        pm.processEpoch(posId, s); // must not revert

        assertEq(pm.claimableUSDC(trader), 95e6);
        assertEq(usdc.balanceOf(address(pm)), 95e6);

        usdc.setBlocklisted(trader, false);
        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        pm.claimTraderPayout();
        assertEq(usdc.balanceOf(trader) - before, 95e6);
        assertEq(pm.totalClaimable(), 0);
    }

    function test_swapRouter_onlyCurrentRouterWhitelisted() public {
        address old = address(router);
        MockRouter next = new MockRouter(address(usdc));
        vm.prank(owner);
        pm.setSwapRouter(address(next));
        assertFalse(pm.isWhitelistedRouter(old));
        assertTrue(pm.isWhitelistedRouter(address(next)));
        assertEq(pm.swapRouter(), address(next));
    }

    // ------------------------------------------------------------------ fuzz: conservation

    function testFuzz_settlementConservesUsdc(uint256 priceUsd, bool autoRoll, uint256 daysHeld) public {
        priceUsd = bound(priceUsd, 30_000, 90_000);
        daysHeld = bound(daysHeld, 0, 30);
        uint256 posId = _open(100e6, 10, autoRoll);

        skip(daysHeld * 1 days);
        _setPrice(address(cbBTC), priceUsd);

        uint256 vaultGrossBefore = vault.totalAssets();
        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 insBefore = usdc.balanceOf(address(insurance));
        uint256 out = router.quote(address(cbBTC), address(usdc), pm.getPosition(posId).spotAmount);

        bool liq = pm.isLiquidatable(posId);
        uint256 s = _exitSwap(posId, liq ? 200 : 100);
        vm.prank(liq ? keeper : trader);
        if (liq) pm.liquidate(posId, s);
        else pm.closePosition(posId, s);

        skip(12 hours); // fully vest
        uint256 vaultDelta = vault.totalAssets() + 900e6 - vaultGrossBefore; // vault got back principal +/- yield/loss
        uint256 traderDelta = usdc.balanceOf(trader) - traderBefore;
        uint256 insDelta = usdc.balanceOf(address(insurance)) - insBefore;

        assertEq(vaultDelta + traderDelta + insDelta + usdc.balanceOf(keeper), out, "USDC conservation");
        assertEq(usdc.balanceOf(address(pm)), pm.totalClaimable(), "PM holds only claimables");
        assertEq(usdc.balanceOf(pm.getPosition(posId).proxy), 0, "proxy drained");
        assertEq(vault.totalBorrowedPrincipal(), 0);
        if (!liq) assertGe(vault.totalAssets(), LP_DEPOSIT, "no LP loss on healthy close");
    }
}
