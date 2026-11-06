// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {MockUSDC, MockToken, MockMetaMorpho, MockPyth, MockRouter} from "./mocks/Mocks.sol";

/// @dev Drives random LP / trader / keeper actions against the vault for the invariant suite.
contract QueueHandler is Test {
    LPVault internal vault;
    PositionManager internal pm;
    MockUSDC internal usdc;
    MockMetaMorpho internal morpho;
    MockPyth internal pyth;
    MockRouter internal router;
    address internal cirBTC;
    bytes32 internal constant BTC_ID = keccak256("BTC/USD");

    address[] internal lps;
    address internal trader = makeAddr("inv-trader");
    uint256[] internal requestIds;
    uint256[] internal ticketIds;
    uint256[] internal openPositions;

    uint256 public payoutAboveRequestValue; // ghost: must stay 0
    uint256 public sharePriceDrops; // ghost: fulfilment / cancel must never lower the stayers' share price
    uint256 public traderCloseFailures; // ghost: trader exits must never revert

    constructor(
        LPVault vault_,
        PositionManager pm_,
        MockUSDC usdc_,
        MockMetaMorpho morpho_,
        MockPyth pyth_,
        MockRouter router_,
        address cirBTC_
    ) {
        vault = vault_;
        pm = pm_;
        usdc = usdc_;
        morpho = morpho_;
        pyth = pyth_;
        router = router_;
        cirBTC = cirBTC_;
        for (uint256 i; i < 3; ++i) {
            address a = makeAddr(string(abi.encodePacked("inv-lp", i)));
            lps.push(a);
            usdc.mint(a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(vault), type(uint256).max);
        }
        usdc.mint(trader, 10_000_000e6);
        vm.prank(trader);
        usdc.approve(address(pm), type(uint256).max);
    }

    function _lp(uint256 seed) internal view returns (address) {
        return lps[seed % lps.length];
    }

    function _refreshPrice() internal {
        pyth.setPrice(BTC_ID, int64(int256(50_000e8)), uint64(50_000e8 / 10_000), -8, block.timestamp);
        router.setPrice(cirBTC, 50_000e18);
    }

    function _price() internal view returns (uint256) {
        return vault.convertToAssets(1e18);
    }

    function deposit(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1e6, 200_000e6);
        usdc.mint(_lp(seed), amount);
        vm.prank(_lp(seed));
        vault.deposit(amount, _lp(seed));
    }

    function request(uint256 seed, uint256 frac) external {
        address a = _lp(seed);
        uint256 shares = vault.balanceOf(a) * bound(frac, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(a);
        requestIds.push(vault.requestRedeem(shares, a, a));
    }

    function cancel(uint256 seed) external {
        if (requestIds.length == 0) return;
        uint256 id = requestIds[seed % requestIds.length];
        LPVault.RedeemRequestData memory r = vault.getRedeemRequest(id);
        if (r.status != LPVault.RequestStatus.PENDING) return;
        uint256 p0 = _price();
        vm.prank(r.controller);
        vault.cancelRedeemRequest(id);
        if (_price() < p0) ++sharePriceDrops;
    }

    function process(uint256 n) external {
        uint256 p0 = _price();
        vault.processRedemptions(bound(n, 1, 10));
        if (_price() < p0) ++sharePriceDrops;
    }

    function claim(uint256 seed) external {
        address a = _lp(seed);
        uint256 shares = vault.maxRedeem(a);
        if (shares == 0) return;
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    function openPosition(uint256 margin) external {
        _refreshPrice();
        margin = bound(margin, 100e6, 5_000e6);
        uint256 notional = margin * 10;
        uint256 borrowed = notional - margin;
        // Only attempt opens that fit the cap, exposure and queue-priority checks.
        if (vault.totalBorrowedPrincipal() + borrowed > vault.totalAssets() * 8_500 / 10_000) return;
        uint256 free = vault.freeLiquidity();
        if (free < vault.pendingRedeemAssets() + borrowed) return;
        if (pm.assetExposure(cirBTC) + notional > vault.totalAssets()) return;

        address proxy = pm.predictProxyAddress(pm.positionCount() + 1);
        PositionManager.OpenParams memory p = PositionManager.OpenParams({
            spotToken: cirBTC,
            tier: 10,
            margin: uint128(margin),
            autoRollover: true,
            swap: PositionManager.SwapInstruction({
                router: address(router),
                minAmountOut: 0,
                data: abi.encodeCall(MockRouter.swapExactIn, (address(usdc), cirBTC, notional, 0, proxy))
            }),
            priceUpdateData: new bytes[](0)
        });
        vm.prank(trader);
        openPositions.push(pm.openPosition(p));
    }

    function closePosition(uint256 seed) external {
        if (openPositions.length == 0) return;
        _refreshPrice();
        uint256 idx = seed % openPositions.length;
        uint256 posId = openPositions[idx];
        PositionManager.Position memory pos = pm.getPosition(posId);
        uint256 bound_ = pm.markValue(posId) * 9_900 / 10_000;
        PositionManager.SwapInstruction memory s = PositionManager.SwapInstruction({
            router: address(router),
            minAmountOut: bound_,
            data: abi.encodeCall(MockRouter.swapExactIn, (cirBTC, address(usdc), pos.spotAmount, 0, pos.proxy))
        });
        vm.prank(trader);
        try pm.closePosition(posId, s, new bytes[](0)) {}
        catch {
            ++traderCloseFailures;
        }
        openPositions[idx] = openPositions[openPositions.length - 1];
        openPositions.pop();
    }

    function bonusDeposit(uint256 seed, uint256 amount) external {
        if (!vault.isStressed()) return;
        amount = bound(amount, 1_000e6, 20_000e6);
        usdc.mint(_lp(seed), amount);
        vm.prank(_lp(seed));
        ticketIds.push(vault.depositWithBonus(amount, _lp(seed)));
    }

    function claimTicket(uint256 seed) external {
        if (ticketIds.length == 0) return;
        uint256 id = ticketIds[seed % ticketIds.length];
        LPVault.BonusTicket memory t = vault.getTicket(id);
        if (!t.active) return;
        if (block.timestamp >= t.maturesAt) {
            vault.claimTicket(id);
        } else {
            vm.prank(t.owner);
            vault.breakTicket(id);
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1e6, 5_000e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.donateToBonusPot(amount);
    }

    function morphoYield(uint256 amount) external {
        usdc.mint(address(morpho), bound(amount, 0, 5_000e6));
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1 hours, 20 days));
    }
}

contract QueueInvariantsTest is BaseTest {
    QueueHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        pm.setAsset(address(cirBTC), true, 10_000, 2_000);
        vault.setQueueParams(7 days, 8_000, 2_500, 10_000); // shorter queue so runs reach fulfilment
        vm.stopPrank();
        handler = new QueueHandler(vault, pm, usdc, morpho, pyth, router, address(cirBTC));
        targetContract(address(handler));
    }

    /// Gross holdings always cover totalAssets plus every earmarked liability.
    function invariant_conservation() public view {
        uint256 gross = usdc.balanceOf(address(vault)) + morpho.convertToAssets(morpho.balanceOf(address(vault)))
            + vault.totalBorrowedPrincipal();
        assertGe(gross + 2, vault.totalAssets() + vault.reservedForClaims() + vault.bonusPot() + vault.bonusAccrued());
    }

    function invariant_claimsAlwaysPayable() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.reservedForClaims());
    }

    function invariant_escrowMatchesQueueAndTickets() public view {
        assertGe(vault.balanceOf(address(vault)), vault.totalPendingShares());
    }

    function invariant_aggregatesMatchVault() public view {
        assertEq(pm.borrowedByAssetTier(address(cirBTC), 10), vault.totalBorrowedPrincipal());
    }

    function invariant_stayersNeverDiluted() public view {
        assertEq(handler.sharePriceDrops(), 0);
    }

    function invariant_traderExitsNeverRevert() public view {
        assertEq(handler.traderCloseFailures(), 0);
    }
}
