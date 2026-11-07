// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseMainnet} from "./lib/BaseMainnet.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";

/// @notice Deploys and wires the protocol on Base mainnet: one LP vault, WETH and cbBTC spot longs traded on their
///         Uniswap v4 USDC pools and priced via Chainlink feeds. The deployer is the temporary owner;
///         ownership is then handed to governance via Ownable2Step (governance must call acceptOwnership()).
///
/// Required env: GOVERNANCE, GUARDIAN
/// Optional env: IDLE_VAULT (USDC ERC-4626 vault; default none = single-vault mode)
///
///   forge script script/DeployBase.s.sol --rpc-url base --broadcast --account <deployer>
contract DeployBase is Script {
    function run() external returns (ProtocolDeployer.BaseDeployment memory d) {
        require(block.chainid == BaseMainnet.CHAIN_ID, "not Base mainnet");
        address governance = vm.envAddress("GOVERNANCE");
        address guardian = vm.envAddress("GUARDIAN");
        IERC4626 idleVault = IERC4626(vm.envOr("IDLE_VAULT", address(0)));

        vm.startBroadcast();
        address deployer = msg.sender;
        d = ProtocolDeployer.deployBase(deployer, idleVault);
        d.pm.setGuardian(guardian);
        if (governance != deployer) ProtocolDeployer.handOff(d, governance);
        vm.stopBroadcast();

        console2.log("ChainlinkOracle ", address(d.oracle));
        console2.log("V4SwapRouter    ", address(d.router));
        console2.log("LPVault (proxy) ", address(d.vault));
        console2.log("InsuranceReserve", address(d.insurance));
        console2.log("PositionManager ", address(d.pm));
        console2.log("TraderProxy impl", d.pm.proxyImplementation());

        string memory j = "base_mainnet";
        vm.serializeAddress(j, "chainlinkOracle", address(d.oracle));
        vm.serializeAddress(j, "v4SwapRouter", address(d.router));
        vm.serializeAddress(j, "lpVault", address(d.vault));
        vm.serializeAddress(j, "insuranceReserve", address(d.insurance));
        vm.serializeAddress(j, "positionManager", address(d.pm));
        vm.serializeAddress(j, "traderProxyImpl", d.pm.proxyImplementation());
        string memory json = vm.serializeAddress(j, "governance", governance);
        vm.writeJson(json, "deployments/base-mainnet.json");
    }
}
