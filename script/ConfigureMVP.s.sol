// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";

/// @notice Retunes a deployed protocol for the small-vault MVP: a ~$100 vault where traders open $5-$10 positions.
///         Must be broadcast by the current owner (governance) of PositionManager and LPVault.
///
/// The defaults (minNotional $500, keeper bounty $5, 35% per-asset exposure cap, $1,000 minimum bonus deposit) make
/// a $100 vault unusable: a $10 x 5 position is below the minimum, and a $5 bounty would eat half a $10 margin.
///
/// Required env: POSITION_MANAGER, LP_VAULT, ASSETS (comma-separated spot token addresses)
/// Optional env: MIN_NOTIONAL (6-dec, default 25e6 = $5 at 5x), KEEPER_BOUNTY (default 0.10e6),
///               MAX_EXPOSURE_BPS (default 10_000), MIN_BONUS_DEPOSIT (default 10e6)
///
///   forge script script/ConfigureMVP.s.sol --rpc-url arc_mainnet --broadcast --account <owner>
contract ConfigureMVP is Script {
    function run() external {
        PositionManager pm = PositionManager(vm.envAddress("POSITION_MANAGER"));
        LPVault vault = LPVault(vm.envAddress("LP_VAULT"));
        address[] memory assets = vm.envAddress("ASSETS", ",");

        uint256 minNotional = vm.envOr("MIN_NOTIONAL", uint256(25e6));
        uint256 keeperBounty = vm.envOr("KEEPER_BOUNTY", uint256(0.1e6));
        uint16 maxExposureBps = uint16(vm.envOr("MAX_EXPOSURE_BPS", uint256(10_000)));
        uint256 minBonusDeposit = vm.envOr("MIN_BONUS_DEPOSIT", uint256(10e6));

        vm.startBroadcast();

        // Keep every economic parameter except the size floor and the keeper bounty.
        pm.setRiskParams(
            pm.rolloverAprBps(),
            pm.lpRolloverShareBps(),
            minNotional,
            keeperBounty,
            pm.maxEntrySlippageBps(),
            pm.maxExitSlippageBps(),
            pm.maxLiqSlippageBps()
        );

        // With $100 of assets a 35% cap allows only $35 of notional per market; one $5 x 10 trade needs $50.
        for (uint256 i; i < assets.length; ++i) {
            (bool enabled,, uint16 shock) = pm.assetConfigs(assets[i]);
            require(enabled, "asset not enabled");
            pm.setAsset(assets[i], true, maxExposureBps, shock);
        }

        vault.setBonusParams(
            vault.bonusDuration(), vault.bonusEmissionPeriod(), vault.maxBonusAprBps(), minBonusDeposit
        );

        vm.stopBroadcast();

        console2.log("minNotional     ", minNotional);
        console2.log("keeperBounty    ", keeperBounty);
        console2.log("maxExposureBps  ", maxExposureBps);
        console2.log("minBonusDeposit ", minBonusDeposit);
    }
}
