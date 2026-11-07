// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract PositionManagerFixesTest is BaseTest {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Issue 1: Free leverage on non-autoRollover expired positions
    // =========================================================================

    function test_nonAutoRollover_overdueDebtAccrues() public {
        // Open position with autoRollover = false, margin = 100 USDC, tier = 10 (borrowed = 900 USDC)
        uint256 posId = _open(100e6, 10, false);
        uint256 feePerEpoch = pm.epochRolloverFee(900e6);

        // Advance 21 days (7 days epoch duration + 14 days overdue = 2 overdue epochs)
        skip(21 days);
        _setPrice(address(cbBTC), 50_000);

        // liquidationThreshold must reflect the 2 overdue epochs of rollover debt
        uint256 expectedDebt = feePerEpoch * 2;
        uint256 threshold = pm.liquidationThreshold(posId);
        // threshold = borrowed (900) + maintenance (1000 * 2% = 20) + debt (2 * feePerEpoch)
        assertEq(threshold, 920e6 + expectedDebt);

        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 s = _exitSwap(posId, 100);

        // Keeper processes the expired position
        vm.prank(keeper);
        pm.processEpoch(posId, s);

        // Trader payout: 1000 - 5 bounty - 900 borrowed - expectedDebt = 95 - expectedDebt
        uint256 expectedPayout = 95e6 - expectedDebt;
        assertEq(usdc.balanceOf(trader) - traderBefore, expectedPayout);
        assertEq(usdc.balanceOf(keeper), 5e6);
        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.CLOSED));
    }

    // =========================================================================
    // Issue 2: Rollover debt catch-up beyond 52 epochs
    // =========================================================================

    function test_catchUpEpochs_beyond52Epochs() public {
        uint256 posId = _open(100e6, 10, true);
        uint256 feePerEpoch = pm.epochRolloverFee(900e6);

        // Advance 60 epochs (60 * 7 days)
        skip(60 * 7 days);
        _setPrice(address(cbBTC), 60_000); // position in profit to settle all debt

        // Prior to fix, epochs was capped at MAX_EPOCH_CATCH_UP (52)
        // With fix, all 60 epochs must be accrued and charged
        uint256 totalDebt = feePerEpoch * 60;
        uint256 threshold = pm.liquidationThreshold(posId);
        assertEq(threshold, 920e6 + totalDebt);

        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.accruedRolloverDebt, totalDebt);
        assertEq(uint8(pos.status), uint8(PositionManager.PositionStatus.CLOSED));
    }

    // =========================================================================
    // Issue 3: Confiscation of remaining equity when borrowed principal is zero
    // =========================================================================

    function test_zeroBorrowed_equityNotConfiscatedOnLiquidation() public {
        // Open 5x position: margin = 100 USDC, borrowed = 400 USDC, notional = 500 USDC
        uint256 posId = _open(100e6, 5, false);

        // Trader pays off 100% of borrowed principal via addMargin
        vm.prank(trader);
        pm.addMargin(posId, 400e6);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.borrowedPrincipal, 0);
        assertEq(pos.userMargin, 500e6);

        // Drop price so position hits liquidation threshold (threshold = 0 + 500 * 4% = 20 USDC)
        // Mark drops to 20 USDC
        _setPrice(address(cbBTC), 2_000); // 500 * (2,000 / 50,000) = 20 USDC
        assertTrue(pm.isLiquidatable(posId));

        uint256 s = _exitSwap(posId, 200); // ~19.6 USDC out
        uint256 traderBefore = usdc.balanceOf(trader);
        uint256 keeperBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        pm.liquidate(posId, s);

        // In the old code: 100% of remaining proceeds was confiscated to insurance as penalty!
        // In the fixed code: keeper gets bounty (5 USDC), trader receives remaining funds (20 - 5 = 15 USDC), penalty = 0.
        assertEq(insurance.insurancePoolBalance(), 0); // No confiscation to insurance!
        assertEq(usdc.balanceOf(keeper) - keeperBefore, 5e6);
        assertEq(usdc.balanceOf(trader) - traderBefore, 15e6);
    }

    // =========================================================================
    // Issue 4: Keeper bounty cannot inflate shortfall beyond actual position loss
    // =========================================================================

    function test_keeperBounty_cannotInflateShortfallWhenProceedsBelowBorrowed() public {
        uint256 posId = _open(100e6, 10, true);

        // Gap down so position has actual loss vs borrowed principal (borrowed = 900 USDC, mark = 850 USDC)
        _setPrice(address(cbBTC), 42_500); // V = 850 USDC
        uint256 s = _exitSwap(posId, 200);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 vaultBefore = vault.totalAssets();

        vm.prank(keeper);
        pm.liquidate(posId, s);

        // When proceeds < borrowed, keeper bounty cannot inflate shortfall
        // Keeper receives 0 bounty from proceeds (available net proceeds = 0)
        assertEq(usdc.balanceOf(keeper) - keeperBefore, 0);
        // Shortfall absorbed by LPs is exactly actual loss (900 - 850 = 50 USDC), not 55 USDC!
        assertEq(vaultBefore - vault.totalAssets(), 50e6);
    }

    function test_keeperBounty_cappedAtExcessAboveBorrowed() public {
        uint256 posId = _open(100e6, 10, true);

        // Set price so proceeds are 903 USDC (borrowed = 900 USDC, excess = 3 USDC, keeperBounty = 5 USDC)
        _setPrice(address(cbBTC), 45_150); // V = 903 USDC
        uint256 s = _exitSwap(posId, 0); // 903 USDC

        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 vaultBefore = vault.totalAssets();

        vm.prank(keeper);
        pm.liquidate(posId, s);

        // Keeper bounty should be capped at 3 USDC (available excess above borrowed)
        assertEq(usdc.balanceOf(keeper) - keeperBefore, 3e6);
        // Vault should receive full 900 USDC principal -> shortfall is 0!
        assertEq(vault.totalAssets(), vaultBefore);
    }

    // =========================================================================
    // Issue 5: Sweep residual tokens and airdrops on exit
    // =========================================================================

    function test_sweepResidualUSDCAndSpotAirdropOnExit() public {
        uint256 posId = _open(100e6, 5, false);
        address proxy = pm.getPosition(posId).proxy;

        // Send 10 USDC dust to proxy
        usdc.mint(proxy, 10e6);

        // Send 0.05 cbBTC airdrop to proxy
        cbBTC.mint(proxy, 5_000_000); // 0.05 cbBTC (8 decimals)

        uint256 traderCbBtcBefore = cbBTC.balanceOf(trader);
        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        // Both USDC and cbBTC balances of proxy must be completely swept (0 balance)
        assertEq(usdc.balanceOf(proxy), 0);
        assertEq(cbBTC.balanceOf(proxy), 0);

        // Trader must receive the 0.05 cbBTC airdrop
        assertEq(cbBTC.balanceOf(trader) - traderCbBtcBefore, 5_000_000);

        // Trader receives normal close proceeds + 10 USDC dust swept from proxy
        // 500 entry - 400 borrowed = 100 margin. With +10 USDC dust swept, trader gets 110 USDC (less profit cut if in profit)
        assertGt(usdc.balanceOf(trader) - traderUsdcBefore, 100e6);
    }

    // =========================================================================
    // Issue 6: Flexible liquidation slippage
    // =========================================================================

    function test_flexibleLiquidationSlippage_allowsKeeperMinOut() public {
        uint256 posId = _open(100e6, 10, true);

        // Price drops to 46_000 (mark = 920 USDC == liquidationThreshold)
        _setPrice(address(cbBTC), 46_000);
        assertTrue(pm.isLiquidatable(posId));

        // Router executes swap with 5% slippage (output = 920 * 95% = 874 USDC)
        // With rigid maxLiqSlippageBps (200 bps = 2%), floorOut is 920 * 98% = 901.6 USDC
        // In the old code, if minOut was bounded by floorOut, passing minAmountOut = 874 USDC would still revert with InsufficientOutput!
        router.setPrice(address(cbBTC), 43_700 * 1e18); // 95% of 46,000
        uint256 expectedOut = oracle.valueInUsdc(address(cbBTC), pm.getPosition(posId).spotAmount) * 95 / 100;

        // Keeper specifies flexible minAmountOut = 874 USDC
        vm.prank(keeper);
        pm.liquidate(posId, expectedOut);

        assertEq(uint8(pm.getPosition(posId).status), uint8(PositionManager.PositionStatus.LIQUIDATED));
    }

    function test_flexibleLiquidationSlippage_defaultFloorWhenZeroPassed() public {
        uint256 posId = _open(100e6, 10, true);

        _setPrice(address(cbBTC), 46_000);
        assertTrue(pm.isLiquidatable(posId));

        // When 0 is passed, it uses floorOut = mark * (1 - 2%)
        // If router price drops 5%, swap should revert with InsufficientOutput
        router.setPrice(address(cbBTC), 43_700 * 1e18); // 95%

        vm.prank(keeper);
        vm.expectRevert();
        pm.liquidate(posId, 0); // reverts because 0 falls back to floorOut
    }

    // =========================================================================
    // Issue 7: Storage gap
    // =========================================================================

    function test_storageGap_upgradePreservesStorage() public {
        uint256 id = _open(100e6, 5, false);

        // Deploy new implementation of PositionManager
        PositionManager newImpl = new PositionManager();
        vm.prank(owner);
        pm.upgradeToAndCall(address(newImpl), "");

        PositionManager.Position memory pos = pm.getPosition(id);
        assertEq(pos.trader, trader);
        assertEq(pos.notional, 500e6);
        assertEq(pos.userMargin, 100e6);
        assertEq(pos.borrowedPrincipal, 400e6);
    }
}
