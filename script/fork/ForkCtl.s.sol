// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ArcMainnet} from "../lib/ArcMainnet.sol";
import {ProtocolDeployer} from "../lib/ProtocolDeployer.sol";
import {UsdcForkShim} from "./UsdcForkShim.sol";
import {PoolMover} from "./PoolMover.sol";

/// @notice FORK TESTING ONLY. Helpers driven by script/fork/fork.sh against a local anvil fork of Arc mainnet.
///
///   deploy()                 Deploy + configure the protocol (MVP settings), seed the vault, fund test wallets,
///                            deploy a PoolMover and write deployments/fork.json. Needs the USDC shim installed.
///   balanceSlot(token, who)  Print the storage slot holding `who`'s balance of `token` (for anvil_setStorageAt).
contract ForkCtl is Script {
    using stdStorage for StdStorage;

    string internal constant OUT = "deployments/fork.json";

    /// Env: KEEPER (recorder address), TEST_WALLETS (comma-separated, optional), VAULT_SEED (6-dec, default $100),
    ///      WALLET_USDC (6-dec, default $1,000 per test wallet).
    function deploy() external {
        require(block.chainid == ArcMainnet.CHAIN_ID, "not an Arc mainnet fork");
        require(UsdcForkShim(ArcMainnet.USDC).decimals() == 6, "USDC");
        address keeper = vm.envAddress("KEEPER");
        address[] memory wallets = vm.envOr("TEST_WALLETS", ",", new address[](0));
        uint256 vaultSeed = vm.envOr("VAULT_SEED", uint256(100e6));
        uint256 walletUsdc = vm.envOr("WALLET_USDC", uint256(1_000e6));

        vm.startBroadcast();
        address deployer = msg.sender;
        // The deployer records too, so script/fork/warp.sh can fast-forward time without racing the keeper's nonces.
        address[] memory recorders = new address[](2);
        recorders[0] = keeper;
        recorders[1] = deployer;
        ProtocolDeployer.Deployment memory d = ProtocolDeployer.deployArc(deployer, IERC4626(address(0)), recorders);

        // script/ConfigureMVP.s.sol settings: $25 minimum notional, $0.10 keeper bounty, 100% per-asset cap,
        // $10 minimum bonus deposit.
        d.pm
            .setRiskParams(
                d.pm.rolloverAprBps(),
                d.pm.lpRolloverShareBps(),
                25e6,
                0.1e6,
                d.pm.maxEntrySlippageBps(),
                d.pm.maxExitSlippageBps(),
                d.pm.maxLiqSlippageBps()
            );
        d.pm.setAsset(ArcMainnet.WETH, true, 10_000, 2_000);
        d.pm.setAsset(ArcMainnet.CIRBTC, true, 10_000, 2_000);
        d.vault.setBonusParams(d.vault.bonusDuration(), d.vault.bonusEmissionPeriod(), d.vault.maxBonusAprBps(), 10e6);

        UsdcForkShim usdc = UsdcForkShim(ArcMainnet.USDC);
        usdc.mint(deployer, vaultSeed);
        IERC20(ArcMainnet.USDC).approve(address(d.vault), vaultSeed);
        d.vault.deposit(vaultSeed, deployer);
        for (uint256 i; i < wallets.length; ++i) {
            usdc.mint(wallets[i], walletUsdc);
        }

        PoolMover mover = new PoolMover(IPoolManager(ArcMainnet.POOL_MANAGER));
        vm.stopBroadcast();

        string memory j = "fork";
        vm.serializeAddress(j, "positionManager", address(d.pm));
        vm.serializeAddress(j, "lpVault", address(d.vault));
        vm.serializeAddress(j, "oracle", address(d.oracle));
        vm.serializeAddress(j, "insurance", address(d.insurance));
        vm.serializeAddress(j, "router", address(d.router));
        vm.serializeAddress(j, "poolMover", address(mover));
        string memory json = vm.serializeAddress(j, "keeper", keeper);
        vm.writeJson(json, OUT);

        console2.log("PositionManager ", address(d.pm));
        console2.log("LPVault         ", address(d.vault));
        console2.log("UniV4TwapOracle ", address(d.oracle));
        console2.log("InsuranceReserve", address(d.insurance));
        console2.log("V4SwapRouter    ", address(d.router));
        console2.log("PoolMover       ", address(mover));
    }

    function balanceSlot(address token, address who) external {
        uint256 slot = stdstore.target(token).sig(IERC20.balanceOf.selector).with_key(who).find();
        console2.log("SLOT", vm.toString(bytes32(slot)));
    }
}
