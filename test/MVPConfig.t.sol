// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "./Base.t.sol";
import {ConfigureMVP} from "../script/ConfigureMVP.s.sol";
import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {InsuranceReserve} from "../src/InsuranceReserve.sol";
import {ILPVault, IInsuranceReserve, IOracle} from "../src/interfaces/IProtocol.sol";

/// @notice The MVP launch: a $100 vault where traders open $5-$10 positions, configured by script/ConfigureMVP.
contract MVPConfigTest is BaseTest {
    address internal constant SCRIPT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38; // forge default sender

    function setUp() public override {
        super.setUp();

        // Fresh $100 deployment, reusing the mocks and oracle from BaseTest.
        vm.startPrank(owner);
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(new LPVault()),
                    abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), IERC4626(address(morpho)), owner))
                )
            )
        );
        insurance = new InsuranceReserve(IERC20(address(usdc)), owner);
        pm = _deployPM(IOracle(address(oracle)));
        vault.setPositionManager(address(pm));
        insurance.setPositionManager(address(pm));
        pm.setAsset(address(cirBTC), true, 3_500, 2_000);
        pm.setAsset(address(weth), true, 3_500, 2_000);
        pm.setSwapRouter(address(router));
        pm.transferOwnership(SCRIPT_SENDER);
        vault.transferOwnership(SCRIPT_SENDER);
        vm.stopPrank();
        vm.startPrank(SCRIPT_SENDER);
        pm.acceptOwnership();
        vault.acceptOwnership();
        vm.stopPrank();

        usdc.mint(lp, 100e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, lp);
        vm.stopPrank();
        vm.prank(trader);
        usdc.approve(address(pm), type(uint256).max);
    }

    function _configure() internal {
        vm.setEnv("POSITION_MANAGER", vm.toString(address(pm)));
        vm.setEnv("LP_VAULT", vm.toString(address(vault)));
        vm.setEnv("ASSETS", string.concat(vm.toString(address(cirBTC)), ",", vm.toString(address(weth))));
        new ConfigureMVP().run();
    }

    function test_defaults_rejectMvpSizes() public {
        _expectOpenRevert(10e6, 5, abi.encodeWithSelector(PositionManager.BelowMinNotional.selector, 50e6));
    }

    function test_configure_setsParams() public {
        _configure();
        assertEq(pm.minNotional(), 25e6);
        assertEq(pm.keeperBounty(), 0.1e6);
        assertEq(pm.rolloverAprBps(), 800);
        (bool enabled, uint16 cap, uint16 shock) = pm.assetConfigs(address(cirBTC));
        assertTrue(enabled);
        assertEq(cap, 10_000);
        assertEq(shock, 2_000);
        assertEq(vault.minBonusDeposit(), 10e6);
    }

    function test_mvp_fiveDollarsAtFiveX_and_tenX() public {
        _configure();
        uint256 a = _open(5e6, 5, false); // $25 notional, $20 borrowed
        uint256 b = _openAs(trader, address(weth), 5e6, 10, false); // $50 notional, $45 borrowed
        assertEq(vault.totalBorrowedPrincipal(), 65e6);

        // Close both at a 10% gain: margin back plus 90% / 85% of the profit.
        _setPrice(address(cirBTC), 55_000);
        _setPrice(address(weth), 2_750);
        uint256 before = usdc.balanceOf(trader);
        vm.startPrank(trader);
        pm.closePosition(a, _exitSwap(a, 100));
        pm.closePosition(b, _exitSwap(b, 100));
        vm.stopPrank();
        // a: profit 2.5, keep 85% -> 7.125. b: profit 5, keep 85% -> 9.25. Total = 16.375.
        assertEq(usdc.balanceOf(trader) - before, 16.375e6);
        // LP cut: 12% of 2.5 + 12% of 5 = 0.9, released over the 12h profit-vesting window.
        vm.warp(block.timestamp + 12 hours);
        assertEq(vault.totalAssets(), 100.9e6);
    }

    function test_mvp_tenDollarsAtFiveX() public {
        _configure();
        _open(10e6, 5, false); // $40 borrowed of an $85 cap
        assertEq(vault.totalBorrowedPrincipal(), 40e6);
    }

    function test_mvp_utilisationCapStillBinds() public {
        _configure();
        _open(5e6, 10, false); // $45 borrowed
        // Another $45 would take borrowing to $90 > 85% of $100.
        _expectOpenRevert(5e6, 10, "");
    }

    function test_mvp_liquidationPaysSmallBounty() public {
        _configure();
        uint256 id = _open(5e6, 10, false); // N=50, B=45, V_liq = 46
        _setPrice(address(cirBTC), 45_900); // V = 45.9
        uint256 before = usdc.balanceOf(keeper);
        uint256 s = _exitSwap(id, 200);
        vm.prank(keeper);
        pm.liquidate(id, s);
        assertEq(usdc.balanceOf(keeper) - before, 0.1e6);
        assertEq(vault.totalBorrowedPrincipal(), 0);
    }
}
