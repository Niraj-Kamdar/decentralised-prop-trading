// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILPVault, IInsuranceReserve, IOracle} from "../src/interfaces/IProtocol.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PositionManagerUpgradeTest is BaseTest {
    function test_upgrade_preservesPositions() public {
        uint256 id = _open(1_000e6, 5, false);
        address newImpl = address(new PositionManager());
        vm.prank(owner);
        pm.upgradeToAndCall(newImpl, "");
        assertEq(pm.getPosition(id).trader, trader);
        assertEq(pm.minNotional(), 500e6); // field defaults survived (set in initialize)
        vm.prank(trader);
        pm.closePosition(id, 0); // still operable through the old proxy clone
    }

    function test_upgrade_onlyOwner() public {
        address impl = address(new PositionManager());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        pm.upgradeToAndCall(impl, "");
    }

    function test_impl_cannotInitialize() public {
        PositionManager impl = new PositionManager();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            IERC20(address(usdc)),
            ILPVault(address(vault)),
            IInsuranceReserve(address(insurance)),
            IOracle(address(oracle)),
            owner
        );
    }

    function test_setOracle_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        pm.setOracle(IOracle(address(1)));
    }
}
