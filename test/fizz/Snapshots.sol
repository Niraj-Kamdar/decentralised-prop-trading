// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.sol";

/// @notice Used to take snapshots of the state before and after a function call
abstract contract Snapshots is Base {
    struct State {
        uint256 actorUsdcBalance;
        uint256 actorShareBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalBorrowed;
        uint256 insurancePoolBalance;
        uint256 opsTreasuryBalance;
        uint256 insuranceUsdcBalance;
    }

    State internal stateBefore;
    State internal stateAfter;

    function _takeSnapshot(State storage state) internal {
        if (address(usdc) != address(0)) {
            state.actorUsdcBalance = usdc.balanceOf(actor);
        }
        if (address(vault) != address(0)) {
            state.actorShareBalance = vault.balanceOf(actor);
            state.vaultTotalAssets = vault.totalAssets();
            state.vaultTotalBorrowed = vault.totalBorrowedPrincipal();
        }
        if (address(insurance) != address(0)) {
            state.insurancePoolBalance = insurance.insurancePoolBalance();
            state.opsTreasuryBalance = insurance.opsTreasuryBalance();
            state.insuranceUsdcBalance = usdc.balanceOf(address(insurance));
        }
    }

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter);
    }
}
