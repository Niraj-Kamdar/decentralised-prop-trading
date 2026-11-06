// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseMainnet} from "../../script/lib/BaseMainnet.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {AggregatorV3Interface} from "../../src/ChainlinkOracle.sol";
import {PositionManager} from "../../src/PositionManager.sol";

contract BaseForkTest is Test {
    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    ProtocolDeployer.BaseDeployment internal d;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        assertEq(block.chainid, BaseMainnet.CHAIN_ID);

        d = ProtocolDeployer.deployBase(address(this), IERC4626(address(0)));
    }

    function test_feeds_matchDescriptions() public view {
        assertEq(AggregatorV3Interface(BaseMainnet.ETH_USD_FEED).description(), "ETH / USD");
        assertEq(AggregatorV3Interface(BaseMainnet.BTC_USD_FEED).description(), "BTC / USD");
    }

    function test_oracle_pricesSane() public view {
        uint256 ethPrice = d.oracle.getPrice(BaseMainnet.WETH);
        uint256 btcPrice = d.oracle.getPrice(BaseMainnet.CBBTC);

        // ETH in [$500, $20,000], BTC in [$10,000, $500,000]
        assertGe(ethPrice, 500e18);
        assertLe(ethPrice, 20_000e18);

        assertGe(btcPrice, 10_000e18);
        assertLe(btcPrice, 500_000e18);
    }

    function test_caps_live() public view {
        assertEq(d.vault.depositCap(), 10_000e6);
        assertEq(d.vault.perAddressCap(), 100e6);
    }

    function test_idleVault_assetIsUsdc() public {
        address idle = vm.envOr("IDLE_VAULT", address(0));
        if (idle == address(0)) return;
        assertEq(IERC4626(idle).asset(), BaseMainnet.USDC);
    }

    function test_endToEnd_depositOpenClose() public {
        // Deal USDC to LP depositors. To allow borrowing 200e6 with 35% asset exposure cap (250e6 <= 35% * totalAssets),
        // we fund lp (100e6) and 9 additional LPs (100e6 each, 1,000e6 total, respecting perAddressCap).
        deal(BaseMainnet.USDC, lp, 100e6);
        vm.startPrank(lp);
        IERC20(BaseMainnet.USDC).approve(address(d.vault), type(uint256).max);
        d.vault.deposit(100e6, lp);
        vm.stopPrank();

        for (uint160 i = 1; i <= 9; i++) {
            address depositor = address(uint160(0x2000 + i));
            deal(BaseMainnet.USDC, depositor, 100e6);
            vm.startPrank(depositor);
            IERC20(BaseMainnet.USDC).approve(address(d.vault), type(uint256).max);
            d.vault.deposit(100e6, depositor);
            vm.stopPrank();
        }

        uint256 initialVaultAssets = d.vault.totalAssets();
        assertEq(initialVaultAssets, 1_000e6);

        deal(BaseMainnet.USDC, trader, 1_000e6);
        vm.prank(trader);
        IERC20(BaseMainnet.USDC).approve(address(d.pm), type(uint256).max);

        // Open and close WETH position: 50e6 margin @ 5x (250e6 notional)
        uint256 traderBeforeWeth = IERC20(BaseMainnet.USDC).balanceOf(trader);
        vm.prank(trader);
        uint256 posWeth = d.pm.openPosition(
            PositionManager.OpenParams({
                spotToken: BaseMainnet.WETH,
                tier: 5,
                margin: 50e6,
                autoRollover: false,
                minAmountOut: 0
            })
        );
        vm.prank(trader);
        d.pm.closePosition(posWeth, 0);
        uint256 traderAfterWeth = IERC20(BaseMainnet.USDC).balanceOf(trader);
        uint256 lossWeth = traderBeforeWeth - traderAfterWeth;
        // Lost < 2% of notional (250e6 * 2% = 5e6)
        assertLt(lossWeth, 5e6);

        // Open and close cbBTC position: 50e6 margin @ 5x (250e6 notional)
        uint256 traderBeforeBtc = IERC20(BaseMainnet.USDC).balanceOf(trader);
        vm.prank(trader);
        uint256 posBtc = d.pm.openPosition(
            PositionManager.OpenParams({
                spotToken: BaseMainnet.CBBTC,
                tier: 5,
                margin: 50e6,
                autoRollover: false,
                minAmountOut: 0
            })
        );
        vm.prank(trader);
        d.pm.closePosition(posBtc, 0);
        uint256 traderAfterBtc = IERC20(BaseMainnet.USDC).balanceOf(trader);
        uint256 lossBtc = traderBeforeBtc - traderAfterBtc;
        // Lost < 2% of notional (250e6 * 2% = 5e6)
        assertLt(lossBtc, 5e6);

        // Vault totalAssets >= deposit
        assertGe(d.vault.totalAssets(), initialVaultAssets);
    }
}
