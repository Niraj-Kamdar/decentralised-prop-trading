// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PositionManager} from "../../src/PositionManager.sol";
import {ArcMainnet} from "../../script/lib/ArcMainnet.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {UsdcForkShim} from "../../script/fork/UsdcForkShim.sol";
import {PoolMover} from "../../script/fork/PoolMover.sol";

/// @notice Arc mainnet fork: the real Uniswap v4 PoolManager, the real WETH/USDC and cirBTC/USDC pools and their
///         live liquidity, with the protocol deployed on top exactly as script/Deploy.s.sol does.
/// @dev Skipped unless ARC_MAINNET_RPC_URL is set. FORK_BLOCK pins a block (default: latest).
abstract contract ForkBase is Test {
    address internal constant USDC = ArcMainnet.USDC;
    address internal constant WETH = ArcMainnet.WETH;
    address internal constant CIRBTC = ArcMainnet.CIRBTC;

    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    ProtocolDeployer.Deployment internal d;
    PoolMover internal mover;
    bool internal forked;

    uint256 internal constant VAULT_SIZE = 1_000e6;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ARC_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        forked = true;
        assertEq(block.chainid, ArcMainnet.CHAIN_ID);

        _installUsdcShim();

        address[] memory recorders = new address[](1);
        recorders[0] = keeper;
        d = ProtocolDeployer.deployArc(address(this), IERC4626(address(0)), recorders);
        // The ConfigureMVP settings for a small vault: $25 minimum notional, $0.10 bounty, full per-asset cap.
        d.pm.setRiskParams(800, 8_000, 25e6, 0.1e6, 100, 100, 200);
        d.pm.setAsset(WETH, true, 10_000, 2_000);
        d.pm.setAsset(CIRBTC, true, 10_000, 2_000);

        mover = new PoolMover(IPoolManager(ArcMainnet.POOL_MANAGER));

        _mintUsdc(lp, VAULT_SIZE);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(d.vault), type(uint256).max);
        d.vault.deposit(VAULT_SIZE, lp);
        vm.stopPrank();

        _mintUsdc(trader, 1_000e6);
        vm.prank(trader);
        IERC20(USDC).approve(address(d.pm), type(uint256).max);

        _warmUp();
    }

    // ------------------------------------------------------------------ helpers

    function _installUsdcShim() internal {
        UsdcForkShim shim = new UsdcForkShim();
        vm.store(USDC, shim.IMPLEMENTATION_SLOT(), bytes32(uint256(uint160(address(shim)))));
    }

    function _mintUsdc(address to, uint256 amount) internal {
        UsdcForkShim(USDC).mint(to, amount);
    }

    function _assets() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = WETH;
        a[1] = CIRBTC;
    }

    /// @dev The keeper's record call: expected ticks are what it saw at the end of the previous block.
    function _record() internal {
        address[] memory a = _assets();
        int24[] memory ticks = new int24[](a.length);
        for (uint256 i; i < a.length; ++i) {
            ticks[i] = d.oracle.spotTick(a[i]);
        }
        vm.prank(keeper);
        d.oracle.record(a, ticks);
    }

    /// @dev Let `secs` pass with the keeper recording every `step` seconds (Arc blocks are sub-second).
    function _advance(uint256 secs, uint256 step) internal {
        for (uint256 t; t < secs; t += step) {
            // via-IR caches block.timestamp / block.number across a loop; the cheatcode getters read the live values.
            vm.warp(vm.getBlockTimestamp() + step);
            vm.roll(vm.getBlockNumber() + step * 2);
            _record();
        }
    }

    function _warmUp() internal {
        _record();
        _advance(d.oracle.twapWindow() + 10, 10);
    }

    function _key(address asset) internal view returns (PoolKey memory) {
        return d.oracle.poolKey(asset);
    }

    /// @dev Move a real pool to `targetTick` by trading against its live liquidity.
    function _movePool(address asset, int24 targetTick) internal returns (int24) {
        _mintUsdc(address(mover), 5_000_000e6);
        deal(asset, address(mover), asset == WETH ? 5_000e18 : 100e8);
        return mover.moveTo(_key(asset), targetTick);
    }

    /// @dev Pool tick for a move of `bps` basis points in the asset's USD price (asset is currency0 on Arc).
    function _tickFor(address asset, int256 bps) internal view returns (int24) {
        // ln(1.0001) ~ 1e-4, so a price ratio r moves the tick by ~ln(r) * 10_000; precise enough for test moves.
        int256 t = int256(d.oracle.spotTick(asset));
        int256 dt = (bps * 10_000) / (10_000 + bps / 2);
        return int24(t + dt);
    }

    function _open(address asset, uint128 margin, uint8 tier) internal returns (uint256 posId) {
        vm.prank(trader);
        posId = d.pm
            .openPosition(
                PositionManager.OpenParams({
                    spotToken: asset, tier: tier, margin: margin, autoRollover: true, minAmountOut: 0
                })
            );
    }
}
