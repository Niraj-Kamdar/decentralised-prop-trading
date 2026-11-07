// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.sol";
import {Properties} from "./Properties.sol";
import {vm} from "./utils/Hevm.sol";
import {LPVault} from "../../src/LPVault.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice Stateful state machine transition handlers for LPs, Traders, Keepers, and environment
abstract contract Handlers is Properties {

    function clamp(uint256 val, uint256 low, uint256 high) internal returns (uint256) {
        return clampBetween(val, low, high);
    }

    // ―――――――――――――――――――――― Environment Handlers ――――――――――――――――――――――

    function setCurrentActor(uint256 entropy) public {
        actor = actors[entropy % actors.length];
    }

    function warpTime_clamped(uint256 secondsToWarp) public {
        secondsToWarp = clamp(secondsToWarp, 1 minutes, 7 days);
        skipTime(secondsToWarp);
    }

    // ―――――――――――――――――――――――――― LP Handlers ―――――――――――――――――――――――――――

    function deposit_clamped(uint256 assets) public {
        assets = clamp(assets, 1e6, 50_000e6);
        uint256 maxDep = vault.maxDeposit(actor);
        if (assets > maxDep) assets = maxDep;
        if (assets == 0) return;
        usdc.mint(actor, assets);
        deposit_unclamped(assets);
    }

    function deposit_unclamped(uint256 assets) public asActor {
        vault.deposit(assets, actor);
        ghosts.ghost_totalDeposited += assets;
    }

    function mint_clamped(uint256 shares) public {
        shares = clamp(shares, 1e6, 50_000e6);
        uint256 maxM = vault.maxMint(actor);
        if (shares > maxM) shares = maxM;
        if (shares == 0) return;
        uint256 assetsNeeded = vault.previewMint(shares);
        usdc.mint(actor, assetsNeeded);
        mint_unclamped(shares);
    }

    function mint_unclamped(uint256 shares) public asActor {
        uint256 assets = vault.mint(shares, actor);
        ghosts.ghost_totalDeposited += assets;
    }

    function requestRedeem_clamped(uint256 sharesRatio) public {
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        uint256 frac = clamp(sharesRatio, 1, 100);
        uint256 shares = (bal * frac) / 100;
        if (shares == 0) return;
        requestRedeem_unclamped(shares);
    }

    function requestRedeem_unclamped(uint256 shares) public asActor {
        uint256 reqId = vault.requestRedeem(shares, actor, actor);
        requestIds.push(reqId);
    }

    function processRedemptions_clamped(uint256 maxRequests) public {
        maxRequests = clamp(maxRequests, 1, 10);
        processRedemptions_unclamped(maxRequests);
    }

    function processRedemptions_unclamped(uint256 maxRequests) public {
        vault.processRedemptions(maxRequests);
    }

    function redeem_clamped(uint256 sharesRatio) public {
        uint256 maxR = vault.maxRedeem(actor);
        if (maxR == 0) return;
        uint256 frac = clamp(sharesRatio, 1, 100);
        uint256 shares = (maxR * frac) / 100;
        if (shares == 0) return;
        redeem_unclamped(shares);
    }

    function redeem_unclamped(uint256 shares) public asActor {
        uint256 assetsOut = vault.redeem(shares, actor, actor);
        ghosts.ghost_totalWithdrawn += assetsOut;
    }

    function withdraw_clamped(uint256 assetsRatio) public {
        uint256 maxW = vault.maxWithdraw(actor);
        if (maxW == 0) return;
        uint256 frac = clamp(assetsRatio, 1, 100);
        uint256 assets = (maxW * frac) / 100;
        if (assets == 0) return;
        withdraw_unclamped(assets);
    }

    function withdraw_unclamped(uint256 assets) public asActor {
        vault.withdraw(assets, actor, actor);
        ghosts.ghost_totalWithdrawn += assets;
    }

    function depositWithBonus_clamped(uint256 assets) public {
        if (!vault.isStressed()) return;
        uint256 minB = vault.minBonusDeposit();
        uint256 maxD = vault.maxDeposit(actor);
        if (maxD < minB) return;
        uint256 cap = maxD < 20_000e6 ? maxD : 20_000e6;
        if (cap < minB) return;
        assets = clamp(assets, minB, cap);
        usdc.mint(actor, assets);
        depositWithBonus_unclamped(assets);
    }

    function depositWithBonus_unclamped(uint256 assets) public asActor {
        uint256 ticketId = vault.depositWithBonus(assets, actor);
        ticketIds.push(ticketId);
        ghosts.ghost_totalDeposited += assets;
    }

    function claimTicket_clamped(uint256 ticketIndex) public {
        if (ticketIds.length == 0) return;
        uint256 ticketId = ticketIds[ticketIndex % ticketIds.length];
        LPVault.BonusTicket memory t = vault.getTicket(ticketId);
        if (!t.active || block.timestamp < t.maturesAt) return;
        claimTicket_unclamped(ticketId);
    }

    function claimTicket_unclamped(uint256 ticketId) public {
        vault.claimTicket(ticketId);
    }

    function breakTicket_clamped(uint256 ticketIndex) public {
        if (ticketIds.length == 0) return;
        uint256 ticketId = ticketIds[ticketIndex % ticketIds.length];
        LPVault.BonusTicket memory t = vault.getTicket(ticketId);
        if (!t.active || block.timestamp >= t.maturesAt) return;
        breakTicket_unclamped(ticketId);
    }

    function breakTicket_unclamped(uint256 ticketId) public {
        LPVault.BonusTicket memory t = vault.getTicket(ticketId);
        vm.startPrank(t.owner);
        vault.breakTicket(ticketId);
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Trader Handlers ―――――――――――――――――――――――――

    function openPosition_clamped(uint8 assetChoice, uint128 margin, uint8 tierChoice, bool autoRollover) public {
        address spot = (assetChoice % 2 == 0) ? address(weth) : address(cirBTC);
        uint8 tier = (tierChoice % 2 == 0) ? 5 : 10;
        margin = uint128(clamp(uint256(margin), 100e6, 5_000e6));
        uint256 borrowed = uint256(margin) * (tier - 1);
        uint256 avail = vault.availableLiquidity();
        if (avail < 500e6) return;
        if (borrowed > avail) {
            margin = uint128(avail / (tier - 1));
            if (uint256(margin) * tier < 500e6) return;
        }
        usdc.mint(actor, margin);
        openPosition_unclamped(spot, margin, tier, autoRollover);
    }

    function openPosition_unclamped(address spotToken, uint128 margin, uint8 tier, bool autoRollover)
        public
        asActor
        returns (uint256 posId)
    {
        PositionManager.OpenParams memory p = PositionManager.OpenParams({
            spotToken: spotToken,
            tier: tier,
            margin: margin,
            autoRollover: autoRollover,
            minAmountOut: 0
        });
        posId = pm.openPosition(p);
        openPositions.push(posId);
        uint256 borrowed = uint256(margin) * (tier - 1);
        ghosts.ghost_totalMargin += margin;
        ghosts.ghost_totalBorrowed += borrowed;
        ghosts.ghost_openPositionsCount += 1;
    }

    function addMargin_clamped(uint256 posIndex, uint128 amount) public {
        if (openPositions.length == 0) return;
        uint256 posId = openPositions[posIndex % openPositions.length];
        PositionManager.Position memory pos = pm.getPosition(posId);
        if (pos.status != PositionManager.PositionStatus.OPEN) return;
        if (pos.borrowedPrincipal == 0) return;
        amount = uint128(clamp(uint256(amount), 1e6, uint256(pos.borrowedPrincipal)));
        usdc.mint(pos.trader, amount);
        addMargin_unclamped(posId, amount);
    }

    function addMargin_unclamped(uint256 posId, uint128 amount) public {
        PositionManager.Position memory pos = pm.getPosition(posId);
        vm.startPrank(pos.trader);
        pm.addMargin(posId, amount);
        vm.stopPrank();
        ghosts.ghost_totalMargin += amount;
        ghosts.ghost_totalBorrowed -= amount;
    }

    function rollPosition_clamped(uint256 posIndex) public {
        if (openPositions.length == 0) return;
        uint256 posId = openPositions[posIndex % openPositions.length];
        PositionManager.Position memory pos = pm.getPosition(posId);
        if (pos.status != PositionManager.PositionStatus.OPEN) return;
        if (block.timestamp < pos.epochEndTime) {
            skipTime(pos.epochEndTime - block.timestamp + 1);
        }
        rollPosition_unclamped(posId);
    }

    function rollPosition_unclamped(uint256 posId) public {
        PositionManager.Position memory posBefore = pm.getPosition(posId);
        pm.processEpoch(posId, 0);
        PositionManager.Position memory posAfter = pm.getPosition(posId);
        if (posAfter.status != PositionManager.PositionStatus.OPEN) {
            _removePosition(posId);
            ghosts.ghost_openPositionsCount -= 1;
            ghosts.ghost_totalBorrowed -= posBefore.borrowedPrincipal;
            if (ghosts.ghost_totalMargin >= posBefore.userMargin) {
                ghosts.ghost_totalMargin -= posBefore.userMargin;
            } else {
                ghosts.ghost_totalMargin = 0;
            }
        }
    }

    function closePosition_clamped(uint256 posIndex, uint256 slippageBps) public {
        if (openPositions.length == 0) return;
        uint256 posId = openPositions[posIndex % openPositions.length];
        PositionManager.Position memory pos = pm.getPosition(posId);
        if (pos.status != PositionManager.PositionStatus.OPEN) return;
        slippageBps = clamp(slippageBps, 0, 100);
        uint256 minOut = (pm.markValue(posId) * (10_000 - slippageBps)) / 10_000;
        closePosition_unclamped(posId, minOut);
    }

    function closePosition_unclamped(uint256 posId, uint256 minOut) public {
        PositionManager.Position memory pos = pm.getPosition(posId);
        vm.startPrank(pos.trader);
        pm.closePosition(posId, minOut);
        vm.stopPrank();
        _removePosition(posId);
        ghosts.ghost_openPositionsCount -= 1;
        ghosts.ghost_totalBorrowed -= pos.borrowedPrincipal;
        if (ghosts.ghost_totalMargin >= pos.userMargin) {
            ghosts.ghost_totalMargin -= pos.userMargin;
        } else {
            ghosts.ghost_totalMargin = 0;
        }
    }

    // ―――――――――――――――――――――――― Keeper Handlers ――――――――――――――――――――――――

    function recordOracleObservation_clamped(int24 tickDelta, uint256 cirBtcPrice, uint256 wethPrice) public {
        cirBtcPrice = clamp(cirBtcPrice, 20_000, 80_000);
        wethPrice = clamp(wethPrice, 1_200, 4_500);
        _setPrices(cirBtcPrice, wethPrice);

        address[] memory assetList = new address[](2);
        assetList[0] = address(weth);
        assetList[1] = address(cirBTC);
        int24[] memory expectedTicks = new int24[](2);
        expectedTicks[0] = tickDelta;
        expectedTicks[1] = tickDelta;

        recordOracleObservation_unclamped(assetList, expectedTicks);
    }

    function recordOracleObservation_unclamped(address[] memory assetList, int24[] memory expectedTicks)
        public
        asKeeper
    {
        uniOracle.record(assetList, expectedTicks);
    }

    function liquidatePosition_clamped(uint256 posIndex) public {
        if (openPositions.length == 0) return;
        uint256 posId = openPositions[posIndex % openPositions.length];
        if (!pm.isLiquidatable(posId)) return;
        liquidatePosition_unclamped(posId);
    }

    function liquidatePosition_unclamped(uint256 posId) public {
        PositionManager.Position memory pos = pm.getPosition(posId);
        uint256 insBalBefore = insurance.insurancePoolBalance();
        pm.liquidate(posId, 0);
        _removePosition(posId);
        ghosts.ghost_openPositionsCount -= 1;
        ghosts.ghost_totalBorrowed -= pos.borrowedPrincipal;
        if (ghosts.ghost_totalMargin >= pos.userMargin) {
            ghosts.ghost_totalMargin -= pos.userMargin;
        } else {
            ghosts.ghost_totalMargin = 0;
        }
        uint256 insBalAfter = insurance.insurancePoolBalance();
        if (insBalAfter > insBalBefore) {
            ghosts.ghost_insuranceFunded += (insBalAfter - insBalBefore);
        }
    }

    function accrueBonus_clamped() public {
        accrueBonus_unclamped();
    }

    function accrueBonus_unclamped() public {
        vault.accrueBonus();
    }

    function rebalance_clamped() public {
        rebalance_unclamped();
    }

    function rebalance_unclamped() public {
        vault.rebalance();
    }
}
