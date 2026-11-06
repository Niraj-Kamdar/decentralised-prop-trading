// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ArcMainnet} from "./lib/ArcMainnet.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";

/// @notice Deploys and wires the protocol on Arc mainnet: one LP vault, ETH and BTC spot longs traded on their
///         Uniswap v4 USDC pools and priced at those pools' 10-minute TWAP. The deployer is the temporary owner;
///         ownership is then handed to governance via Ownable2Step (governance must call acceptOwnership()).
///
/// Required env: GOVERNANCE, GUARDIAN, RECORDERS (comma-separated keeper addresses that record the TWAP)
/// Optional env: MORPHO_VAULT (MetaMorpho USDC vault; default none = single-vault mode)
///
///   forge script script/Deploy.s.sol --rpc-url arc_mainnet --broadcast --account <deployer>
///
/// After deploying, the keeper must record for at least `twapWindow` (10 min) before positions can be opened.
contract Deploy is Script {
    function run() external returns (ProtocolDeployer.Deployment memory d) {
        require(block.chainid == ArcMainnet.CHAIN_ID, "not Arc mainnet");
        address governance = vm.envAddress("GOVERNANCE");
        address[] memory recorders = vm.envAddress("RECORDERS", ",");
        IERC4626 morpho = IERC4626(vm.envOr("MORPHO_VAULT", address(0)));

        vm.startBroadcast();
        address deployer = msg.sender;
        d = ProtocolDeployer.deployArc(deployer, morpho, recorders);
        d.pm.setGuardian(vm.envAddress("GUARDIAN"));
        if (governance != deployer) ProtocolDeployer.handOff(d, governance);
        vm.stopBroadcast();

        console2.log("UniV4TwapOracle ", address(d.oracle));
        console2.log("V4SwapRouter    ", address(d.router));
        console2.log("LPVault (proxy) ", address(d.vault));
        console2.log("InsuranceReserve", address(d.insurance));
        console2.log("PositionManager ", address(d.pm));
        console2.log("TraderProxy impl", d.pm.proxyImplementation());
    }
}
