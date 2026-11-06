// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";

contract WithdrawalQueueTest is BaseTest {
    address internal lp2 = makeAddr("lp2");

    function setUp() public override {
        super.setUp();
        usdc.mint(lp2, 100_000e6);
        vm.prank(lp2);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, who, who);
    }

    function _requestAssets(address who, uint256 assets) internal returns (uint256) {
        return _request(who, vault.convertToShares(assets));
    }

    /// @dev Time travel and refresh oracle publish times (Pyth data must be <= 5s old).
    function _skip(uint256 dt) internal {
        skip(dt);
        _setPrice(address(cirBTC), 50_000);
        _setPrice(address(weth), 2_500);
    }

    function _yield(uint256 amount) internal {
        usdc.mint(address(morpho), amount);
    }

    function _loss(uint256 amount) internal {
        vm.prank(address(morpho));
        usdc.transfer(address(0xdead), amount);
    }

    function _setShock(uint16 shockBps) internal {
        vm.prank(owner);
        pm.setAsset(address(cirBTC), true, 10_000, shockBps);
    }

    function _closeAtMark(uint256 posId) internal {
        PositionManager.SwapInstruction memory s = _exitSwap(posId, 100);
        vm.prank(trader);
        pm.closePosition(posId, s, _noUpdate());
    }

    function _claimAll(address who) internal returns (uint256 assets) {
        uint256 shares = vault.maxRedeem(who);
        vm.prank(who);
        assets = vault.redeem(shares, who, who);
    }

    // ------------------------------------------------------------------ queue basics

    function test_request_escrowsShares() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        uint256 id = _request(lp, shares);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.pendingRedeemRequest(id, lp), shares);
        assertApproxEqAbs(vault.costBasis(lp), 50_000e6, 1);
        assertApproxEqAbs(vault.getRedeemRequest(id).basis, 50_000e6, 1);
        assertEq(vault.queueLength(), 1);
    }

    function test_notMatured_isNotFulfilled() public {
        _requestAssets(lp, 10_000e6);
        _skip(30 days - 1);
        assertEq(vault.processRedemptions(10), 0);
        _skip(1);
        assertEq(vault.processRedemptions(10), 1);
    }

    function test_queuedShares_stopEarning_gainGoesToPot() public {
        _request(lp, vault.balanceOf(lp) / 2); // 50k
        _yield(10_000e6); // pool 100k -> 110k
        _skip(30 days);
        vault.processRedemptions(10);

        assertApproxEqAbs(vault.maxWithdraw(lp), 50_000e6, 2, "payout capped at value when requested");
        assertApproxEqAbs(vault.bonusPot(), 5_000e6, 2, "queue-period gain forfeited to the pot");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), 55_000e6, 2, "staying half keeps its gain");
        assertApproxEqAbs(_claimAll(lp), 50_000e6, 2);
    }

    function test_lossesStillBorneWhileQueued() public {
        _request(lp, vault.balanceOf(lp) / 2);
        _loss(10_000e6); // pool 100k -> 90k
        _skip(30 days);
        vault.processRedemptions(10);
        assertApproxEqAbs(vault.maxWithdraw(lp), 45_000e6, 2);
        assertEq(vault.bonusPot(), 0);
    }

    function test_cancel_forfeitsQueueGain() public {
        uint256 id = _request(lp, vault.balanceOf(lp) / 2);
        _yield(10_000e6);
        vm.prank(lp);
        vault.cancelRedeemRequest(id);

        assertApproxEqAbs(vault.bonusPot(), 5_000e6, 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), 105_000e6, 2);
        assertApproxEqAbs(vault.costBasis(lp), 100_000e6, 1, "basis restored");
        assertEq(vault.pendingRedeemAssets(), 0);
        vm.expectRevert(abi.encodeWithSelector(LPVault.RequestNotPending.selector, id));
        vm.prank(lp);
        vault.cancelRedeemRequest(id);
    }

    function test_claimByAssets_andOperator() public {
        vm.prank(lp);
        vault.setOperator(lp2, true);
        uint256 shares = vault.convertToShares(10_000e6);
        vm.prank(lp2);
        vault.requestRedeem(shares, lp, lp);
        _skip(30 days);
        vault.processRedemptions(10);

        vm.prank(lp2);
        vault.withdraw(4_000e6, lp2, lp); // operator claims part of it to itself
        assertEq(usdc.balanceOf(lp2), 100_000e6 + 4_000e6);
        uint256 rest = vault.maxWithdraw(lp);
        vm.prank(lp);
        vault.withdraw(rest, lp, lp);
        assertEq(vault.maxRedeem(lp), 0);
        assertEq(vault.reservedForClaims(), 0);
    }

    function test_unauthorisedRequestAndClaimRevert() public {
        vm.expectRevert(LPVault.NotAuthorized.selector);
        vm.prank(lp2);
        vault.requestRedeem(1e12, lp2, lp);

        _requestAssets(lp, 1_000e6);
        _skip(30 days);
        vault.processRedemptions(10);
        vm.expectRevert(LPVault.NotAuthorized.selector);
        vm.prank(lp2);
        vault.redeem(1, lp2, lp);
    }

    function test_previewsRevert_andInterfaces() public {
        vm.expectRevert(LPVault.SyncRedeemDisabled.selector);
        vault.previewRedeem(1);
        vm.expectRevert(LPVault.SyncRedeemDisabled.selector);
        vault.previewWithdraw(1);
        assertTrue(vault.supportsInterface(0x620ee8e4));
        assertTrue(vault.supportsInterface(0xe3bc4e65));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function test_basisMovesWithTransfers() public {
        uint256 half = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        vault.transfer(lp2, half);
        assertApproxEqAbs(vault.costBasis(lp), 50_000e6, 1);
        assertApproxEqAbs(vault.costBasis(lp2), 50_000e6, 1);
    }

    // ------------------------------------------------------------------ stress penalty

    function test_stressedExit_penalisesEarnedYieldOnly() public {
        _yield(10_000e6); // lp: basis 100k, value 110k
        _setShock(0);
        _open(9_800e6, 10, true); // B = 88.2k -> U = 80.2%
        assertTrue(vault.isStressed());

        uint256 id = _request(lp, vault.balanceOf(lp) / 10); // value 11k, basis 10k, earned 1k
        assertTrue(vault.getRedeemRequest(id).stressedAtRequest);
        _skip(30 days);
        vault.processRedemptions(10);

        // 25% of the 1k earned yield is forfeited; principal and the rest are paid.
        assertApproxEqAbs(vault.maxWithdraw(lp), 10_750e6, 2);
        assertApproxEqAbs(vault.bonusPot(), 250e6, 2);
    }

    function test_stressedExit_penaltyNeverCutsPrincipal() public {
        _yield(10_000e6);
        _setShock(0);
        _open(9_800e6, 10, true);
        _request(lp, vault.balanceOf(lp) / 10); // value 11k, basis 10k

        _loss(8_000e6); // pool 110k -> 102k: request now worth ~10.2k
        _skip(30 days);
        vault.processRedemptions(10);

        // 10.2k - 250 penalty would dip below the 10k basis, so the payout is floored at principal.
        assertApproxEqAbs(vault.maxWithdraw(lp), 10_000e6, 2);
    }

    function test_unstressedExit_hasNoPenalty() public {
        _yield(10_000e6);
        uint256 id = _request(lp, vault.balanceOf(lp) / 10);
        assertFalse(vault.getRedeemRequest(id).stressedAtRequest);
        _skip(30 days);
        vault.processRedemptions(10);
        assertApproxEqAbs(vault.maxWithdraw(lp), 11_000e6, 2);
        assertEq(vault.bonusPot(), 0);
    }

    // ------------------------------------------------------------------ solvency gate

    function test_stressedLPLoss_matchesFormula() public {
        _setShock(2_000);
        _open(9_000e6, 10, true); // B = 81k
        // k = s' - (1 - s') * mu * L/(L-1), 1 - s' = 0.8 * 0.98 = 0.784 -> k = 0.216 - 0.0174222 = 0.1985778
        assertApproxEqAbs(pm.stressedLPLoss(), 16_084_800_000 + 5e6, 1e6);

        _openAs(trader, address(weth), 1_000e6, 5, true); // B = 4k at 5x: k = 0.216 - 0.784 * 0.04 * 1.25 = 0.1768
        assertApproxEqAbs(pm.stressedLPLoss(), 16_084_800_000 + 707_200_000 + 10e6, 1e6);

        vm.startPrank(owner);
        usdc.mint(owner, 1_000e6);
        usdc.approve(address(insurance), 1_000e6);
        insurance.donate(1_000e6);
        vm.stopPrank();
        assertApproxEqAbs(pm.stressedNetLoss(), 16_084_800_000 + 707_200_000 + 10e6 - 1_000e6, 1e6);
    }

    function test_riskAggregates_trackOpenAddMarginClose() public {
        uint256 posId = _open(1_000e6, 10, true);
        assertEq(pm.borrowedByAssetTier(address(cirBTC), 10), 9_000e6);
        assertEq(pm.openPositionCount(), 1);
        vm.prank(trader);
        pm.addMargin(posId, 1_000e6);
        assertEq(pm.borrowedByAssetTier(address(cirBTC), 10), 8_000e6);
        _closeAtMark(posId);
        assertEq(pm.borrowedByAssetTier(address(cirBTC), 10), 0);
        assertEq(pm.openPositionCount(), 0);
        assertEq(pm.stressedLPLoss(), 0);
    }

    function test_gate_partialFill_fifo_thenDrainsWhenPositionCloses() public {
        _setShock(2_000);
        uint256 posId = _open(9_000e6, 10, true); // free 19k, stressed loss ~16.09k -> budget ~2.91k
        uint256 a = _requestAssets(lp, 5_000e6);
        uint256 b = _requestAssets(lp, 10_000e6);
        _skip(30 days);
        vault.processRedemptions(10);

        uint256 budgetPaid = vault.maxWithdraw(lp);
        assertApproxEqAbs(budgetPaid, 19_000e6 - 16_089_800_000, 2e6);
        assertGt(vault.getRedeemRequest(a).shares, 0, "head partially filled");
        assertEq(vault.getRedeemRequest(b).filledShares, 0, "FIFO: second untouched");

        _closeAtMark(posId);
        vault.processRedemptions(10);
        assertApproxEqAbs(vault.maxWithdraw(lp), 15_000e6, 2e6);
        assertEq(vault.queueLength(), 0);
    }

    function test_gate_closed_traderStillClosesAndGetsPaid() public {
        _setShock(5_000); // stressed loss ~40k > 19k free
        uint256 posId = _open(9_000e6, 10, true);
        _request(lp, vault.balanceOf(lp));
        _skip(30 days);

        vm.expectEmit(false, false, false, false, address(vault));
        emit LPVault.RedemptionsGated(0, 0);
        assertEq(vault.processRedemptions(10), 0);
        assertEq(vault.fulfilmentBudget(), 0);

        // Trader closes at a profit while the gate is shut: payout is unaffected.
        _setPrice(address(cirBTC), 55_000); // +10%: V = 99k
        uint256 before = usdc.balanceOf(trader);
        _closeAtMark(posId);
        assertGt(usdc.balanceOf(trader) - before, 9_000e6, "margin plus profit share paid");

        assertEq(vault.processRedemptions(10), 1, "gate reopens once the risk is gone");
    }

    function test_allocationBlockedByPendingQueue() public {
        _requestAssets(lp, 95_000e6);
        PositionManager.OpenParams memory p = _params(address(cirBTC), 1_000e6, 10, true);
        vm.expectPartialRevert(LPVault.AllocationBlockedByQueue.selector);
        vm.prank(trader);
        pm.openPosition(p);
    }

    // ------------------------------------------------------------------ bonus

    function _stressAndFundPot(uint256 pot) internal {
        _setShock(0);
        _open(9_000e6, 10, true); // U = 81%
        if (pot == 0) return;
        usdc.mint(address(this), pot);
        usdc.approve(address(vault), pot);
        vault.donateToBonusPot(pot);
    }

    function test_depositWithBonus_requiresStress() public {
        vm.expectRevert(LPVault.NotStressed.selector);
        vm.prank(lp2);
        vault.depositWithBonus(10_000e6, lp2);
    }

    function test_depositWithBonus_belowMinimumReverts() public {
        _stressAndFundPot(0);
        vm.expectPartialRevert(LPVault.BelowMinBonusDeposit.selector);
        vm.prank(lp2);
        vault.depositWithBonus(999e6, lp2);
    }

    function test_bonusTicket_earnsCappedRate_andCompounds() public {
        _stressAndFundPot(1_000e6);
        vm.prank(lp2);
        uint256 id = vault.depositWithBonus(10_000e6, lp2);
        assertEq(vault.balanceOf(lp2), 0, "shares locked");

        vm.expectRevert();
        vault.claimTicket(id);

        _skip(90 days);
        uint256 expected = uint256(10_000e6) * 2_000 * 90 days / (10_000 * 365 days); // 20% APR cap = ~493.15
        assertApproxEqAbs(vault.pendingBonus(id), expected, 2);
        vault.claimTicket(id); // permissionless after maturity

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp2)), 10_000e6 + expected, 3);
        assertApproxEqAbs(vault.bonusPot(), 1_000e6 - expected, 2, "excess over the cap stays in the pot");
        assertApproxEqAbs(vault.costBasis(lp2), 10_000e6 + expected, 2);
    }

    function test_bonusTicket_break_forfeitsToPot() public {
        _stressAndFundPot(1_000e6);
        vm.prank(lp2);
        uint256 id = vault.depositWithBonus(10_000e6, lp2);
        _skip(45 days);
        assertGt(vault.pendingBonus(id), 0);

        vm.expectRevert(LPVault.NotAuthorized.selector);
        vault.breakTicket(id);
        vm.prank(lp2);
        vault.breakTicket(id);

        assertApproxEqAbs(vault.bonusPot(), 1_000e6, 2, "all bonus returned to the pot");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp2)), 10_000e6, 2);
    }

    function test_bonusPot_streamsAcrossTickets_zeroSum() public {
        _stressAndFundPot(100e6);
        vm.prank(owner);
        vault.setQueueParams(30 days, 6_000, 2_500, 10_000); // keep the pool "stressed" across both deposits
        vm.prank(lp2);
        uint256 a = vault.depositWithBonus(10_000e6, lp2);
        usdc.mint(keeper, 10_000e6);
        vm.startPrank(keeper);
        usdc.approve(address(vault), type(uint256).max);
        uint256 b = vault.depositWithBonus(10_000e6, keeper);
        vm.stopPrank();

        _skip(180 days);
        vault.claimTicket(a);
        vault.claimTicket(b);
        uint256 paidA = vault.convertToAssets(vault.balanceOf(lp2)) - 10_000e6;
        uint256 paidB = vault.convertToAssets(vault.balanceOf(keeper)) - 10_000e6;
        assertApproxEqAbs(paidA, paidB, 2);
        assertLe(paidA + paidB, 100e6, "never more than the pot");
        assertApproxEqAbs(paidA + paidB + vault.bonusPot(), 100e6, 3);
    }

    function test_exitForfeits_fundNewLpBonus() public {
        _request(lp, vault.balanceOf(lp) / 2);
        _yield(2_000e6);
        _skip(30 days);
        vault.processRedemptions(10); // forfeits ~1k into the pot
        uint256 pot = vault.bonusPot();
        assertApproxEqAbs(pot, 1_000e6, 2);

        _setShock(0);
        _open(4_800e6, 10, true); // B = 43.2k of ~51k -> U ~84.7%
        assertTrue(vault.isStressed());
        vm.prank(lp2);
        uint256 id = vault.depositWithBonus(5_000e6, lp2);
        _skip(90 days);
        vault.claimTicket(id);
        assertGt(vault.convertToAssets(vault.balanceOf(lp2)), 5_000e6);
    }

    // ------------------------------------------------------------------ params

    function test_queueParams_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setQueueParams(12 hours, 8_000, 2_500, 10_000);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setQueueParams(30 days, 9_000, 2_500, 10_000); // above the 85% hard cap
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setQueueParams(30 days, 8_000, 6_000, 10_000);
        vault.setQueueParams(14 days, 7_500, 1_000, 15_000);
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setParams(500, 7_000, 12 hours); // hard cap below stress threshold
        vm.expectRevert(LPVault.InvalidParams.selector);
        vault.setBonusParams(10 days, 90 days, 2_000, 1_000e6);
        vault.setBonusParams(60 days, 30 days, 3_000, 500e6);
        vm.stopPrank();
        assertEq(vault.redeemCooldown(), 14 days);
        assertEq(vault.bonusDuration(), 60 days);
    }

    // ------------------------------------------------------------------ fuzz

    /// Payout bounds and conservation across random yield / loss / stress / partial-liquidity paths.
    function testFuzz_exitPricing_bounds(uint96 yieldAmt, uint96 lossAmt, uint8 fracPct, bool stressed) public {
        uint256 y = bound(yieldAmt, 0, 50_000e6);
        uint256 frac = bound(fracPct, 1, 100);
        _yield(y);
        uint256 posId;
        if (stressed) {
            _setShock(0);
            posId = _open(9_000e6, 10, true); // U = 81% when no yield
        }
        uint256 shares = vault.balanceOf(lp) * frac / 100;
        uint256 basisBefore = vault.costBasis(lp);
        uint256 id = _request(lp, shares);
        LPVault.RedeemRequestData memory r = vault.getRedeemRequest(id);
        assertLe(r.basis, basisBefore);

        uint256 l = bound(lossAmt, 0, (y + 100_000e6) / 20);
        if (l > 0 && l < morpho.totalAssets()) _loss(l);
        _skip(30 days);
        if (stressed) _closeAtMark(posId); // makes the full request fulfillable
        vault.processRedemptions(10);

        uint256 payout = vault.maxWithdraw(lp);
        assertLe(payout, r.assetsAtRequest, "never above value at request");
        // Principal floor: the pot only holds this request's forfeit, so gross value at fulfilment = payout + pot.
        if (vault.getRedeemRequest(id).status == LPVault.RequestStatus.FULFILLED) {
            uint256 gross_ = payout + vault.bonusPot();
            uint256 capped = gross_ < r.assetsAtRequest ? gross_ : r.assetsAtRequest;
            uint256 floorAmt = r.basis < capped ? r.basis : capped;
            assertGe(payout + 1, floorAmt, "penalty never cuts principal");
        }
        // Conservation: gross holdings cover totalAssets plus every earmarked liability.
        uint256 gross = usdc.balanceOf(address(vault)) + morpho.convertToAssets(morpho.balanceOf(address(vault)))
            + vault.totalBorrowedPrincipal();
        assertGe(gross + 1, vault.totalAssets() + vault.reservedForClaims() + vault.bonusPot() + vault.bonusAccrued());
        assertGe(usdc.balanceOf(address(vault)), vault.reservedForClaims(), "claims always payable");
        assertApproxEqAbs(_claimAll(lp), payout, 0);
    }
}
