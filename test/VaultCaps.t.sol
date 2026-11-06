// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {LPVault} from "../src/LPVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract VaultCapsTest is BaseTest {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.setDepositCaps(LP_DEPOSIT + 10_000e6, 100e6);

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_caps_firstDepositAndExactBoundary() public {
        LPVault freshImpl = new LPVault();
        LPVault freshVault = LPVault(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), IERC4626(address(morpho)), owner))
                )
            )
        );
        vm.prank(owner);
        freshVault.setDepositCaps(10_000e6, 100e6);

        vm.prank(alice);
        usdc.approve(address(freshVault), type(uint256).max);

        // Alice deposits exactly 100e6 -> succeeds
        vm.prank(alice);
        freshVault.deposit(100e6, alice);
        assertEq(freshVault.costBasis(alice), 100e6);
        assertEq(freshVault.maxDeposit(alice), 0);

        // Alice tries to deposit 1 wei -> reverts with ERC4626ExceededMaxDeposit
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1, 0)
        );
        freshVault.deposit(1, alice);
    }

    function test_totalCap_blocksWhenFull() public {
        LPVault freshImpl = new LPVault();
        LPVault freshVault = LPVault(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), IERC4626(address(morpho)), owner))
                )
            )
        );
        vm.prank(owner);
        freshVault.setDepositCaps(200e6, 100e6);

        vm.prank(alice);
        usdc.approve(address(freshVault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(freshVault), type(uint256).max);

        vm.prank(alice);
        freshVault.deposit(100e6, alice);
        vm.prank(bob);
        freshVault.deposit(100e6, bob);

        assertEq(freshVault.totalAssets(), 200e6);
        address charlie = makeAddr("charlie");
        assertEq(freshVault.maxDeposit(charlie), 0);

        usdc.mint(charlie, 10e6);
        vm.startPrank(charlie);
        usdc.approve(address(freshVault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, charlie, 1e6, 0)
        );
        freshVault.deposit(1e6, charlie);
        vm.stopPrank();
    }

    function test_perAddressCap_tracksCostBasis() public {
        // perAddressCap is 100e6
        vm.prank(alice);
        vault.deposit(60e6, alice);
        assertEq(vault.costBasis(alice), 60e6);
        assertEq(vault.maxDeposit(alice), 40e6);

        vm.prank(alice);
        vault.deposit(40e6, alice);
        assertEq(vault.costBasis(alice), 100e6);
        assertEq(vault.maxDeposit(alice), 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1, 0)
        );
        vault.deposit(1, alice);

        // After transferring all shares to bob, alice's costBasis drops to 0
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, aliceShares);
        assertEq(vault.costBasis(alice), 0);
        assertEq(vault.maxDeposit(alice), 100e6);

        // Alice can deposit again
        vm.prank(alice);
        vault.deposit(50e6, alice);
        assertEq(vault.costBasis(alice), 50e6);
    }

    function test_mint_respectsCaps() public {
        uint256 maxShares = vault.maxMint(alice);
        assertEq(maxShares, vault.convertToShares(100e6));

        uint256 overShares = vault.convertToShares(101e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, alice, overShares, maxShares)
        );
        vault.mint(overShares, alice);
    }

    function test_raiseCaps_unblocks() public {
        vm.prank(alice);
        vault.deposit(100e6, alice);
        assertEq(vault.maxDeposit(alice), 0);

        // Owner raises caps
        vm.prank(owner);
        vault.setDepositCaps(LP_DEPOSIT + 20_000e6, 200e6);
        assertEq(vault.maxDeposit(alice), 100e6);

        vm.prank(alice);
        vault.deposit(100e6, alice);
        assertEq(vault.costBasis(alice), 200e6);
    }

    function test_denied_cannotDeposit() public {
        vm.prank(owner);
        pm.setDenied(alice, true);

        // Alice depositing for herself reverts Denied(alice)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LPVault.Denied.selector, alice));
        vault.deposit(50e6, alice);

        // Alice minting for herself reverts Denied(alice)
        uint256 mintShares = vault.convertToShares(50e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LPVault.Denied.selector, alice));
        vault.mint(mintShares, alice);

        // Bob depositing for alice reverts Denied(alice)
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LPVault.Denied.selector, alice));
        vault.deposit(50e6, alice);

        // Alice depositing for bob reverts Denied(alice)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LPVault.Denied.selector, alice));
        vault.deposit(50e6, bob);
    }

    function test_denied_lpCanStillRequestRedeem() public {
        vm.prank(owner);
        pm.setDenied(lp, true);

        // LP can still request redeem
        uint256 lpShares = vault.balanceOf(lp);
        vm.prank(lp);
        uint256 reqId = vault.requestRedeem(lpShares, lp, lp);
        assertGt(reqId, 0);
    }

    function test_setDepositCaps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositCaps(1_000e6, 50e6);
    }
}
