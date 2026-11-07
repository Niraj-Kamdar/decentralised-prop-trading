// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Handlers} from "./Handlers.sol";

/// @notice Entry point for fuzzing tests (Foundry invariant / Medusa / Echidna)
contract FuzzTester is Test, Handlers {
    constructor() payable {
        setup();
        targetContract(address(this));
    }

    function setUp() public {
        setup();
        targetContract(address(this));
    }

    // Invariant wrappers for Foundry invariant engine
    function invariant_vaultSolvency() public {
        property_vaultSolvency();
    }

    function invariant_noUnbackedLoans() public {
        property_noUnbackedLoans();
    }

    function invariant_queueOrderPreserved() public {
        property_queueOrderPreserved();
    }

    function invariant_insuranceNonNegative() public {
        property_insuranceNonNegative();
    }

    function invariant_marginHealthMaintained() public {
        property_marginHealthMaintained();
    }

    function invariant_bonusPotConserved() public {
        property_bonusPotConserved();
    }
}
