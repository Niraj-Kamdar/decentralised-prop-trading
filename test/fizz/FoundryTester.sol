// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Handlers} from "./Handlers.sol";

/// @notice Contract to be used for quick testing with Foundry
contract FoundryTester is Test, Handlers {
    function setUp() public {
        setup();
    }

    function test_smoke_sequence() public {
        // 1. LP deposit
        deposit_clamped(50_000e6);

        // 2. Open position
        openPosition_clamped(0, 1_000e6, 5, true);

        // 3. Roll position / warp
        warpTime_clamped(1 days);

        // 4. Invariants check
        property_vaultSolvency();
        property_noUnbackedLoans();
        property_queueOrderPreserved();
        property_insuranceNonNegative();
        property_marginHealthMaintained();
        property_bonusPotConserved();
    }

    function test_lp_redemption_flow() public {
        deposit_clamped(20_000e6);
        requestRedeem_clamped(50);
        warpTime_clamped(8 days);
        processRedemptions_clamped(5);
        redeem_clamped(100);

        property_vaultSolvency();
        property_queueOrderPreserved();
    }

    function test_trader_leverage_flow() public {
        openPosition_clamped(1, 500e6, 10, true);
        addMargin_clamped(0, 200e6);
        closePosition_clamped(0, 10);

        property_vaultSolvency();
        property_noUnbackedLoans();
    }
}
