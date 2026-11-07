// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LPVault} from "../src/LPVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {TraderProxy} from "../src/TraderProxy.sol";
import {InsuranceReserve} from "../src/InsuranceReserve.sol";
import {ILPVault, IInsuranceReserve, IOracle} from "../src/interfaces/IProtocol.sol";
import {MockUSDC, MockToken, MockMetaMorpho, MockOracle, MockRouter} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    MockUSDC internal usdc;
    MockToken internal cbBTC;
    MockToken internal weth;
    MockMetaMorpho internal morpho;
    MockRouter internal router;

    LPVault internal vault;
    InsuranceReserve internal insurance;
    MockOracle internal oracle;
    PositionManager internal pm;

    uint256 internal constant LP_DEPOSIT = 100_000e6;

    function setUp() public virtual {
        vm.warp(1_750_000_000);

        usdc = new MockUSDC();
        cbBTC = new MockToken("Coinbase Wrapped BTC", "cbBTC", 8);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        morpho = new MockMetaMorpho(IERC20(address(usdc)));
        router = new MockRouter(address(usdc));
        oracle = new MockOracle(address(usdc));

        vm.startPrank(owner);

        LPVault impl = new LPVault();
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), IERC4626(address(morpho)), owner))
                )
            )
        );
        insurance = new InsuranceReserve(IERC20(address(usdc)), owner);
        pm = _deployPM(IOracle(address(oracle)));
        vault.setPositionManager(address(pm));
        insurance.setPositionManager(address(pm));
        pm.setAsset(address(cbBTC), true, 3_500, 2_000);
        pm.setAsset(address(weth), true, 3_500, 2_000);
        pm.setSwapRouter(address(router));
        vm.stopPrank();

        // Router inventory.
        usdc.mint(address(router), 10_000_000e6);
        cbBTC.mint(address(router), 1_000e8);
        weth.mint(address(router), 100_000e18);

        _setPrice(address(cbBTC), 50_000);
        _setPrice(address(weth), 2_500);

        // LP liquidity.
        usdc.mint(lp, LP_DEPOSIT);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(LP_DEPOSIT, lp);
        vm.stopPrank();

        usdc.mint(trader, 100_000e6);
        vm.prank(trader);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _deployPM(IOracle o) internal returns (PositionManager) {
        PositionManager impl = new PositionManager();
        PositionManager deployed = PositionManager(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (
                            IERC20(address(usdc)),
                            ILPVault(address(vault)),
                            IInsuranceReserve(address(insurance)),
                            o,
                            owner
                        )
                    )
                )
            )
        );
        TraderProxy proxyImpl = new TraderProxy(address(deployed));
        deployed.setProxyImplementation(address(proxyImpl));
        deployed.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 10,
                maxMargin: type(uint128).max,
                lpProfitBps: 1_200,
                treasuryProfitBps: 300,
                promoteMinTrades: 0,
                promoteMinPnl: 0,
                demoteMaxLoss: 0
            })
        );
        return deployed;
    }

    function _setPrice(address token, uint256 usd) internal {
        oracle.setPrice(token, usd * 1e18);
        router.setPrice(token, usd * 1e18);
    }

    function _open(uint128 margin, uint8 tier, bool autoRollover) internal returns (uint256 posId) {
        return _openAs(trader, address(cbBTC), margin, tier, autoRollover);
    }

    function _openAs(address who, address token, uint128 margin, uint8 tier, bool autoRollover)
        internal
        returns (uint256 posId)
    {
        PositionManager.OpenParams memory p = _params(token, margin, tier, autoRollover);
        vm.prank(who);
        posId = pm.openPosition(p);
    }

    /// @dev Build open params up-front so `vm.expectRevert` can target `openPosition` itself.
    function _params(address token, uint128 margin, uint8 tier, bool autoRollover)
        internal
        pure
        returns (PositionManager.OpenParams memory p)
    {
        p = PositionManager.OpenParams({
            spotToken: token, tier: tier, margin: margin, autoRollover: autoRollover, minAmountOut: 0
        });
    }

    function _expectOpenRevert(uint128 margin, uint8 tier, bytes memory err) internal {
        PositionManager.OpenParams memory p = _params(address(cbBTC), margin, tier, true);
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        vm.prank(trader);
        pm.openPosition(p);
    }

    /// @dev Exit `minAmountOut` pinned exactly to the oracle bound for `slippageBps`.
    function _exitSwap(uint256 posId, uint256 slippageBps) internal view returns (uint256) {
        return pm.markValue(posId) * (10_000 - slippageBps) / 10_000;
    }
}
