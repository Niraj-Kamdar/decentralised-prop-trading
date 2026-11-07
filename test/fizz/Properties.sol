// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
import {LPVault} from "../../src/LPVault.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice Contains the invariant property assertions for the protocol
abstract contract Properties is PropertiesAsserts, Snapshots {

    // ―――――――――――――――――――― Global Properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They are public so fuzzers (Medusa, Echidna, Foundry) can check them.

    /// @notice Vault total assets >= borrowed principal + idle USDC + Morpho assets
    /// @dev Gross holdings must cover totalAssets and reserved liabilities
    function property_vaultSolvency() public {
        uint256 liquid = usdc.balanceOf(address(vault));
        uint256 morphoAssets = morpho.convertToAssets(morpho.balanceOf(address(vault)));
        uint256 borrowed = vault.totalBorrowedPrincipal();
        uint256 gross = liquid + morphoAssets + borrowed;

        gte(
            gross + 2,
            vault.totalAssets() + vault.reservedForClaims() + vault.bonusPot() + vault.bonusAccrued(),
            "Vault gross assets do not cover liabilities"
        );
    }

    /// @notice `totalBorrowed` in vault matches sum of active position borrowings
    function property_noUnbackedLoans() public {
        uint256 sumBorrowed;
        for (uint256 i = 0; i < openPositions.length; i++) {
            PositionManager.Position memory pos = pm.getPosition(openPositions[i]);
            if (pos.status == PositionManager.PositionStatus.OPEN) {
                sumBorrowed += pos.borrowedPrincipal;
            }
        }
        eq(vault.totalBorrowedPrincipal(), sumBorrowed, "Vault totalBorrowed does not match active positions");
        eq(vault.totalBorrowedPrincipal(), ghosts.ghost_totalBorrowed, "Vault totalBorrowed does not match ghost");
    }

    /// @notice FIFO redemptions never process a later request before an earlier mature request
    function property_queueOrderPreserved() public {
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 reqIdA = requestIds[i];
            LPVault.RedeemRequestData memory reqA = vault.getRedeemRequest(reqIdA);
            if (reqA.status == LPVault.RequestStatus.PENDING && block.timestamp >= reqA.maturesAt) {
                for (uint256 j = i + 1; j < requestIds.length; j++) {
                    uint256 reqIdB = requestIds[j];
                    LPVault.RedeemRequestData memory reqB = vault.getRedeemRequest(reqIdB);
                    t(
                        reqB.status != LPVault.RequestStatus.FULFILLED,
                        "Later request fulfilled before earlier mature request"
                    );
                }
            }
        }
    }

    /// @notice Insurance reserve accounting balance >= 0 and never exceeds actual USDC held
    function property_insuranceNonNegative() public {
        uint256 insuranceBal = insurance.insurancePoolBalance();
        uint256 opsBal = insurance.opsTreasuryBalance();
        uint256 totalTracked = insuranceBal + opsBal;
        uint256 actualUsdc = usdc.balanceOf(address(insurance));

        gte(insuranceBal, 0, "Insurance balance negative");
        gte(opsBal, 0, "Ops treasury negative");
        lte(totalTracked, actualUsdc, "Insurance accounting exceeds actual USDC held");
    }

    /// @notice Non-liquidated active positions maintain margin ratio above liquidation threshold
    /// or can be liquidated without reverting
    function property_marginHealthMaintained() public {
        for (uint256 i = 0; i < openPositions.length; i++) {
            uint256 posId = openPositions[i];
            PositionManager.Position memory pos = pm.getPosition(posId);
            if (pos.status == PositionManager.PositionStatus.OPEN) {
                bool liquidatable = pm.isLiquidatable(posId);
                uint256 mark = pm.markValue(posId);
                uint256 liqThreshold = pm.liquidationThreshold(posId);

                if (!liquidatable) {
                    gt(mark, liqThreshold, "Active healthy position has mark <= liqThreshold");
                } else {
                    lte(mark, liqThreshold, "Liquidatable position has mark > liqThreshold");
                }
            }
        }
    }

    /// @notice Bonus pot balance is never over-allocated or under-calculated
    function property_bonusPotConserved() public {
        uint256 pot = vault.bonusPot();
        uint256 accrued = vault.bonusAccrued();
        uint256 liquid = usdc.balanceOf(address(vault));
        uint256 morphoAssets = morpho.convertToAssets(morpho.balanceOf(address(vault)));

        gte(
            liquid + morphoAssets,
            vault.reservedForClaims() + pot + accrued,
            "Vault backing insufficient for bonus commitments"
        );
    }
}
