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

    function test_queueClaim_pullsFromMorpho() public {
        uint256 shares = vault.convertToShares(50_000e6);
        vm.prank(lp);
        vault.requestRedeem(shares, lp, lp);
        skip(30 days);
        vault.processRedemptions(10);
        assertGe(usdc.balanceOf(address(vault)), vault.reservedForClaims());

        uint256 claimable = vault.maxRedeem(lp);
        vm.prank(lp);
        uint256 assets = vault.redeem(claimable, lp, lp);
        assertApproxEqAbs(assets, 50_000e6, 1);
        assertApproxEqAbs(usdc.balanceOf(lp), 50_000e6, 1);
        assertApproxEqAbs(vault.totalAssets(), 50_000e6, 1);
    }

    function test_morphoYield_accruesToLPs() public {
        usdc.mint(address(morpho), 950e6); // ~1% yield on the 95k supplied
        assertApproxEqAbs(vault.totalAssets(), LP_DEPOSIT + 950e6, 1);
    }

    function test_fulfilment_cappedByFreeLiquidity() public {
        vm.prank(owner);
        pm.setAsset(address(cbBTC), true, 10_000, 0); // zero shock isolates the liquidity cap
        _open(9_000e6, 10, true); // 81k lent out, 19k free

        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        uint256 id = vault.requestRedeem(shares, lp, lp);
        skip(30 days);
        vault.processRedemptions(10);

        // Budget = free liquidity minus the residual stressed loss (one keeper bounty).
        assertApproxEqAbs(vault.maxWithdraw(lp), 19_000e6 - 5e6, 2);
        assertGt(vault.getRedeemRequest(id).shares, 0, "remainder stays queued");
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
        _setPrice(address(cbBTC), 60_000); // V = 12k: U3 = 12k - 9k = 3k, profit = 2k, LP cut 12% = 240

        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100_000e6, attacker);
        vm.stopPrank();

        uint256 s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s);

        vm.prank(attacker);
        vault.requestRedeem(shares, attacker, attacker);
        skip(30 days);
        vault.processRedemptions(10);
        uint256 claimShares = vault.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 assetsOut = vault.redeem(claimShares, attacker, attacker);
        assertLe(assetsOut, 100_000e6);

        // The 240 LP cut vests while the attacker's escrowed shares are still outstanding: the honest LP keeps
        // their half, and the attacker's half is forfeited to the bonus pot instead of leaving with them.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), LP_DEPOSIT + 120e6, 1e6);
        assertApproxEqAbs(vault.bonusPot(), 120e6, 1e6);
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
