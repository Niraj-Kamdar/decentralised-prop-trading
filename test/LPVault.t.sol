// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";

contract LPVaultTest is BaseTest {
    function test_deposit_suppliesExcessToMorpho() public view {
        // 5% local buffer, 95% to Morpho.
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);
        assertEq(morpho.convertToAssets(morpho.balanceOf(address(vault))), 95_000e6);
        assertEq(vault.totalAssets(), LP_DEPOSIT);
    }

    function test_withdraw_pullsFromMorpho() public {
        vm.prank(lp);
        vault.withdraw(50_000e6, lp, lp);
        assertEq(usdc.balanceOf(lp), 50_000e6);
        assertEq(vault.totalAssets(), 50_000e6);
    }

    function test_morphoYield_accruesToLPs() public {
        usdc.mint(address(morpho), 950e6); // ~1% yield on the 95k supplied
        assertApproxEqAbs(vault.totalAssets(), LP_DEPOSIT + 950e6, 1);
    }

    function test_maxWithdraw_cappedByLiquidity() public {
        vm.prank(owner);
        pm.setAsset(address(cirBTC), true, 10_000);
        _open(9_000e6, 10, true); // 81k lent out

        uint256 maxW = vault.maxWithdraw(lp);
        assertEq(maxW, LP_DEPOSIT - 81_000e6);
        vm.prank(lp);
        vm.expectRevert();
        vault.withdraw(maxW + 1, lp, lp);
        vm.prank(lp);
        vault.withdraw(maxW, lp, lp);
    }

    function test_onlyPositionManagerHooks() public {
        vm.expectRevert(LPVault.OnlyPositionManager.selector);
        vault.allocateToPosition(address(this), 1e6);
        vm.expectRevert(LPVault.OnlyPositionManager.selector);
        vault.repayFromPosition(0, 0, 0);
    }

    /// LP-03: depositing right before a profitable close and withdrawing right after captures nothing.
    function test_profitVesting_defeatsSandwich() public {
        uint256 posId = _open(1_000e6, 10, true); // N = 10k
        _setPrice(address(cirBTC), 60_000); // V = 12k: U3 = 12k - 9k = 3k, profit = 2k, LP cut 12% = 240

        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100_000e6, attacker);
        vm.stopPrank();

        PositionManager.SwapInstruction memory s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s, _noUpdate());

        vm.prank(attacker);
        uint256 assetsOut = vault.redeem(shares, attacker, attacker);
        assertLe(assetsOut, 100_000e6);

        // Honest LP still receives the full 12% cut once vested.
        skip(12 hours);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), LP_DEPOSIT + 240e6, 1);
    }

    function test_setParams_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setParams(500, 9_600, 12 hours);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setParams(500, 8_500, 0);
        vault.setParams(1_000, 8_000, 6 hours);
        vm.stopPrank();
        assertEq(vault.localBufferBps(), 1_000);
    }

    function test_cannotSwapManagerWithOpenLoans() public {
        _open(100e6, 10, true);
        vm.prank(owner);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setPositionManager(address(0xBEEF));
    }
}
