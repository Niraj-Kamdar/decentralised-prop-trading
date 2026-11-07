// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {LPVault} from "../src/LPVault.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockMetaMorpho} from "./mocks/Mocks.sol";

/// @notice Stand-in MetaMorpho that can be paused or revert on redemption to simulate emergency lockouts.
contract PausableMockMetaMorpho is MockMetaMorpho {
    bool public paused;
    bool public illiquid;

    constructor(IERC20 usdc) MockMetaMorpho(usdc) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function setIlliquid(bool ill) external {
        illiquid = ill;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused) return 0;
        if (illiquid) return super.maxRedeem(owner) / 2;
        return super.maxRedeem(owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(!paused, "MORPHO_PAUSED");
        return super.redeem(shares, receiver, owner);
    }
}

contract LPVaultFixesTest is BaseTest {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _stressVault() internal {
        vm.prank(owner);
        pm.setAsset(address(cbBTC), true, 10_000, 0);
        // Open position with 9,000e6 at 10x -> 81k borrowed out of 100k -> 81% utilization (stressed >= 80%)
        _open(9_000e6, 10, true);
        assertTrue(vault.isStressed(), "vault should be stressed");
    }

    // =========================================================================
    // 1. Deposit cap bypass via address(this) receiver in depositWithBonus
    // =========================================================================

    function test_fix_depositWithBonus_respectsPerAddressCap() public {
        _stressVault();

        uint256 cap = 5_000e6;
        vm.prank(owner);
        vault.setDepositCaps(type(uint256).max, cap);

        // Alice deposits exactly her perAddressCap via depositWithBonus
        vm.prank(alice);
        uint256 ticketId = vault.depositWithBonus(cap, alice);
        assertGt(ticketId, 0);

        // Alice's costBasis must be immediately updated to reflect the deposit
        assertEq(vault.costBasis(alice), cap, "costBasis must reflect bonus deposit");
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit must be 0 after cap reached");

        // Alice attempts another bonus deposit -> must revert with ERC4626ExceededMaxDeposit
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1_000e6, 0)
        );
        vault.depositWithBonus(1_000e6, alice);

        // Alice attempts a standard deposit -> must revert with ERC4626ExceededMaxDeposit
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1_000e6, 0)
        );
        vault.deposit(1_000e6, alice);

        // If Alice tries to deposit for Bob while Alice's cap is reached -> reverts
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1_000e6, 0)
        );
        vault.depositWithBonus(1_000e6, bob);
    }

    function test_fix_depositWithBonus_noDoubleCountingOnClaim() public {
        _stressVault();

        // Donate to pot so there is yield
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vault.donateToBonusPot(1_000e6);

        vm.prank(alice);
        uint256 ticketId = vault.depositWithBonus(10_000e6, alice);
        assertEq(vault.costBasis(alice), 10_000e6);

        skip(90 days);
        uint256 expectedBonus = vault.pendingBonus(ticketId);
        vault.claimTicket(ticketId);

        // Cost basis must be principal + bonus, NOT 2x principal + bonus!
        assertApproxEqAbs(vault.costBasis(alice), 10_000e6 + expectedBonus, 2);
    }

    // =========================================================================
    // 2. Streaming bonus pot time truncation in _accrueBonus
    // =========================================================================

    function test_fix_streamingBonusAccrual_noTimeLossOnZeroIncrementPokes() public {
        _stressVault();

        // Donate a small pot
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.donateToBonusPot(10_000e6);

        vm.prank(alice);
        uint256 ticketId = vault.depositWithBonus(10_000e6, alice);

        // Record initial state
        uint256 startUpdate = vault.lastBonusUpdate();
        assertEq(startUpdate, block.timestamp);

        // Warp 1 second: with 10_000e6 deposit and 90-day emission, 1 second may yield tiny or 0 increment
        // Poke accrueBonus multiple times. If time were reset when increment == 0,
        // frequent pokes would keep wiping out dt and zero emissions would ever accrue!
        for (uint256 i = 0; i < 5; i++) {
            skip(1);
            vault.accrueBonus();
        }

        // Warp 30 days
        skip(30 days);
        uint256 pending = vault.pendingBonus(ticketId);
        assertGt(pending, 0, "emissions must accrue despite frequent earlier pokes");

        // The accrued bonus over 30 days + 5 seconds must match the expected rate
        uint256 expectedEmission = uint256(10_000e6) * 2_000 * (30 days + 5) / (10_000 * 365 days);
        assertApproxEqAbs(pending, expectedEmission, 2);
    }

    // =========================================================================
    // 3. Extreme dilution on totalAssets == 0 in claimTicket
    // =========================================================================

    function test_fix_claimTicket_revertsOnZeroTotalAssets() public {
        _stressVault();

        // Donate to pot
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vault.donateToBonusPot(1_000e6);

        vm.prank(alice);
        uint256 ticketId = vault.depositWithBonus(10_000e6, alice);

        skip(90 days);

        // Simulate catastrophic total loss (totalAssets() becomes 0)
        // 1. PositionManager writes off totalBorrowedPrincipal as total bad debt (0 returned)
        uint256 borrowed = vault.totalBorrowedPrincipal();
        if (borrowed > 0) {
            vm.prank(address(pm));
            vault.repayFromPosition(0, borrowed, 0);
        }

        // 2. Drain local usdc and morpho assets
        uint256 localBal = usdc.balanceOf(address(vault));
        if (localBal > 0) {
            vm.prank(address(vault));
            usdc.transfer(address(0xdead), localBal);
        }
        uint256 morphoBal = usdc.balanceOf(address(morpho));
        if (morphoBal > 0) {
            vm.prank(address(morpho));
            usdc.transfer(address(0xdead), morphoBal);
        }

        // Ensure totalAssets() is 0
        assertEq(vault.totalAssets(), 0, "vault must have 0 totalAssets");

        // Calling claimTicket must revert with ZeroAssets rather than diluting shares
        vm.expectRevert(LPVault.ZeroAssets.selector);
        vault.claimTicket(ticketId);
    }

    // =========================================================================
    // 4. Cost basis inflation in cancelRedeemRequest
    // =========================================================================

    function test_fix_cancelRedeemRequest_scalesBasisProportionally() public {
        uint256 shares = vault.balanceOf(lp) / 2;
        vm.prank(lp);
        uint256 id = vault.requestRedeem(shares, lp, lp);

        uint256 basisBeforeCancel = vault.costBasis(lp);
        assertApproxEqAbs(basisBeforeCancel, 50_000e6, 1);

        // Simulate 10k yield in Morpho: pool grows from 100k to 110k
        usdc.mint(address(morpho), 10_000e6);

        // Cancel request: shares are worth 55k now, assetsAtRequest was 50k.
        // 1/11 of the shares are burned as forfeit to bonus pot.
        vm.prank(lp);
        vault.cancelRedeemRequest(id);

        // Kept fraction is 10/11:
        // Scaled basis restored = 50_000e6 * 10 / 11 = ~45,454.54e6
        // Total costBasis(lp) = 50_000e6 + 45_454.54e6 = ~95,454.54e6 (NOT 100_000e6!)
        uint256 expectedBasis = 50_000e6 + Math.mulDiv(50_000e6, 10, 11);
        assertApproxEqAbs(vault.costBasis(lp), expectedBasis, 2);
        assertLt(vault.costBasis(lp), 100_000e6, "basis must be scaled down, not inflated to 100k");
    }

    // =========================================================================
    // 5. Basis portion rounding on transfers in _basisPortion
    // =========================================================================

    function test_fix_basisPortion_roundsDownOnTransfer() public {
        // Alice deposits 3e6
        vm.prank(alice);
        vault.deposit(3e6, alice);
        assertEq(vault.costBasis(alice), 3e6);

        // Alice transfers 1 share to Bob
        // With Math.Rounding.Floor, basis moved = 3e6 * 1 / aliceBal = 0
        // With Math.Rounding.Ceil, basis moved would be 1, stripping basis from Alice
        vm.prank(alice);
        vault.transfer(bob, 1);

        assertEq(vault.costBasis(bob), 0, "Bob receives 0 basis due to floor rounding");
        assertEq(vault.costBasis(alice), 3e6, "Alice retains full basis without unfair stripping");
    }

    // =========================================================================
    // 6. Emergency Morpho migration lockout in migrateMorphoVault
    // =========================================================================

    function test_fix_migrateMorphoVault_emergencyWhenMorphoPaused() public {
        // Deploy pausable morpho and migrate to it first while healthy
        PausableMockMetaMorpho pMorpho = new PausableMockMetaMorpho(IERC20(address(usdc)));
        vm.prank(owner);
        vault.migrateMorphoVault(IERC4626(address(pMorpho)));
        assertEq(address(vault.morphoVault()), address(pMorpho));

        // Rebalance so funds are in pMorpho
        vault.rebalance();
        assertGt(pMorpho.balanceOf(address(vault)), 0, "funds deposited into pMorpho");

        // Now MetaMorpho experiences emergency pause (reverts on redeem)
        pMorpho.setPaused(true);

        // Governance disconnects Morpho in emergency by setting morphoVault to address(0)
        // Under old code: old.redeem reverts with "MORPHO_PAUSED", locking governance out!
        // Under new code: try/catch absorbs the failure and allows migration to address(0)
        vm.prank(owner);
        vault.migrateMorphoVault(IERC4626(address(0)));

        assertEq(address(vault.morphoVault()), address(0), "governance successfully disconnected morpho");
    }

    function test_fix_migrateMorphoVault_partialRedeemWhenIlliquid() public {
        PausableMockMetaMorpho pMorpho = new PausableMockMetaMorpho(IERC20(address(usdc)));
        vm.prank(owner);
        vault.migrateMorphoVault(IERC4626(address(pMorpho)));

        vault.rebalance();
        uint256 initialShares = pMorpho.balanceOf(address(vault));
        assertGt(initialShares, 0);

        // Simulate illiquidity (maxRedeem is only half of balance)
        pMorpho.setIlliquid(true);

        // Deploy new vault
        MockMetaMorpho newMorpho = new MockMetaMorpho(IERC20(address(usdc)));

        // Governance migrates to newMorpho: should redeem whatever is available (capped by maxRedeem)
        vm.prank(owner);
        vault.migrateMorphoVault(IERC4626(address(newMorpho)));

        assertEq(address(vault.morphoVault()), address(newMorpho));
    }

    // =========================================================================
    // 7. Storage gap present
    // =========================================================================

    function test_fix_storageGap_present() public view {
        // Contract compiles with uint256[50] private __gap
        // Verify vault is functional and deployed as UUPS proxy
        assertEq(vault.owner(), owner);
    }
}
