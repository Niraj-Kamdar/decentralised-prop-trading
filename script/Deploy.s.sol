// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ArcConstants} from "../src/libraries/ArcConstants.sol";
import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {InsuranceReserve} from "../src/InsuranceReserve.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ILPVault, IInsuranceReserve, IOracleVerifier} from "../src/interfaces/IProtocol.sol";

/// @notice Deploys and wires the protocol on Arc. The deployer is the temporary owner; ownership is then
///         handed to the governance multisig via Ownable2Step (the multisig must call acceptOwnership()).
///
/// Required env: MORPHO_VAULT, PYTH, GOVERNANCE, GUARDIAN, ROUTER,
///               CIRBTC, CIRBTC_FEED_ID, WETH, WETH_FEED_ID
contract Deploy is Script {
    function run() external {
        require(ArcConstants.isArc(), "not Arc");
        IERC20 usdc = IERC20(ArcConstants.USDC);
        address governance = vm.envAddress("GOVERNANCE");
        address cirBTC = vm.envAddress("CIRBTC");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast();
        address deployer = msg.sender;

        OracleVerifier oracle = new OracleVerifier(IPyth(vm.envAddress("PYTH")), deployer);
        oracle.setFeed(cirBTC, vm.envBytes32("CIRBTC_FEED_ID"), 5, 50);
        oracle.setFeed(weth, vm.envBytes32("WETH_FEED_ID"), 5, 50);

        LPVault vaultImpl = new LPVault();
        LPVault vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(LPVault.initialize, (usdc, IERC4626(vm.envAddress("MORPHO_VAULT")), deployer))
                )
            )
        );
        InsuranceReserve insurance = new InsuranceReserve(usdc, deployer);
        PositionManager pm = new PositionManager(
            usdc,
            ILPVault(address(vault)),
            IInsuranceReserve(address(insurance)),
            IOracleVerifier(address(oracle)),
            deployer
        );

        vault.setPositionManager(address(pm));
        insurance.setPositionManager(address(pm));
        oracle.setConsumer(address(pm), true);
        pm.setAsset(cirBTC, true, 3_500, 2_000);
        pm.setAsset(weth, true, 3_500, 2_000);
        pm.setRouter(vm.envAddress("ROUTER"), true);
        pm.setGuardian(vm.envAddress("GUARDIAN"));

        oracle.transferOwnership(governance);
        vault.transferOwnership(governance);
        insurance.transferOwnership(governance);
        pm.transferOwnership(governance);
        vm.stopBroadcast();

        console2.log("OracleVerifier  ", address(oracle));
        console2.log("LPVault (proxy) ", address(vault));
        console2.log("InsuranceReserve", address(insurance));
        console2.log("PositionManager ", address(pm));
        console2.log("TraderProxy impl", pm.proxyImplementation());
    }
}
