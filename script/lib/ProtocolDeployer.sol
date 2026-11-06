// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LPVault} from "../../src/LPVault.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {InsuranceReserve} from "../../src/InsuranceReserve.sol";
import {UniV4TwapOracle} from "../../src/UniV4TwapOracle.sol";
import {ChainlinkOracle, AggregatorV3Interface} from "../../src/ChainlinkOracle.sol";
import {V4SwapRouter} from "../../src/V4SwapRouter.sol";
import {ILPVault, IInsuranceReserve, IOracle} from "../../src/interfaces/IProtocol.sol";
import {ArcMainnet} from "./ArcMainnet.sol";
import {BaseMainnet} from "./BaseMainnet.sol";

/// @notice Deploys and wires the whole protocol. Internal functions run in the caller's context, so the same code
///         serves the broadcast script (caller = broadcaster), fork tests and the anvil fork script.
library ProtocolDeployer {
    struct Deployment {
        UniV4TwapOracle oracle;
        V4SwapRouter router;
        LPVault vault;
        InsuranceReserve insurance;
        PositionManager pm;
    }

    struct BaseDeployment {
        ChainlinkOracle oracle;
        V4SwapRouter router;
        LPVault vault;
        InsuranceReserve insurance;
        PositionManager pm;
    }

    /// @param owner      Temporary owner of every contract (the deployer); hand-off happens separately.
    /// @param morphoVault MetaMorpho USDC vault, or address(0) for single-vault mode (idle USDC stays local).
    /// @param recorders  Keeper addresses allowed to record TWAP observations.
    function deployArc(address owner, IERC4626 morphoVault, address[] memory recorders)
        internal
        returns (Deployment memory d)
    {
        IERC20 usdc = IERC20(ArcMainnet.USDC);

        d.oracle = new UniV4TwapOracle(IPoolManager(ArcMainnet.POOL_MANAGER), ArcMainnet.USDC, owner);
        d.oracle.setFeed(ArcMainnet.WETH, ArcMainnet.wethUsdcKey());
        d.oracle.setFeed(ArcMainnet.CIRBTC, ArcMainnet.cirBtcUsdcKey());
        for (uint256 i; i < recorders.length; ++i) {
            d.oracle.setRecorder(recorders[i], true);
        }

        d.router = new V4SwapRouter(IPoolManager(ArcMainnet.POOL_MANAGER));

        LPVault impl = new LPVault();
        d.vault = LPVault(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(LPVault.initialize, (usdc, morphoVault, owner))))
        );
        d.insurance = new InsuranceReserve(usdc, owner);
        PositionManager pmImpl = new PositionManager();
        d.pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (
                            usdc,
                            ILPVault(address(d.vault)),
                            IInsuranceReserve(address(d.insurance)),
                            IOracle(address(d.oracle)),
                            owner
                        )
                    )
                )
            )
        );

        d.vault.setPositionManager(address(d.pm));
        d.insurance.setPositionManager(address(d.pm));
        d.pm.setSwapRouter(address(d.router));
        // Spot long on ETH and BTC only.
        d.pm.setAsset(ArcMainnet.WETH, true, 3_500, 2_000);
        d.pm.setAsset(ArcMainnet.CIRBTC, true, 3_500, 2_000);
        d.pm.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 10,
                maxMargin: type(uint128).max,
                lpProfitBps: 1200,
                treasuryProfitBps: 300,
                promoteMinTrades: 0,
                promoteMinPnl: 0,
                demoteMaxLoss: 0
            })
        );
    }

    /// @notice Start the Ownable2Step hand-off of every contract to `governance` (which must accept).
    function handOff(Deployment memory d, address governance) internal {
        d.oracle.transferOwnership(governance);
        d.vault.transferOwnership(governance);
        d.insurance.transferOwnership(governance);
        d.pm.transferOwnership(governance);
    }

    /// @param owner     Temporary owner of every contract (the deployer); hand-off happens separately.
    /// @param idleVault ERC-4626 USDC vault (e.g. MetaMorpho or Aave static aUSDC), or address(0).
    function deployBase(address owner, IERC4626 idleVault)
        internal
        returns (BaseDeployment memory d)
    {
        IERC20 usdc = IERC20(BaseMainnet.USDC);

        d.oracle = new ChainlinkOracle(BaseMainnet.USDC, owner);
        d.oracle.setFeed(
            BaseMainnet.WETH,
            AggregatorV3Interface(BaseMainnet.ETH_USD_FEED),
            BaseMainnet.MAX_STALENESS,
            BaseMainnet.wethUsdcKey()
        );
        d.oracle.setFeed(
            BaseMainnet.CBBTC,
            AggregatorV3Interface(BaseMainnet.BTC_USD_FEED),
            BaseMainnet.MAX_STALENESS,
            BaseMainnet.cbBtcUsdcKey()
        );

        d.router = new V4SwapRouter(IPoolManager(BaseMainnet.POOL_MANAGER));

        LPVault impl = new LPVault();
        d.vault = LPVault(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(LPVault.initialize, (usdc, idleVault, owner))))
        );
        d.vault.setDepositCaps(10_000e6, 100e6);

        d.insurance = new InsuranceReserve(usdc, owner);

        PositionManager pmImpl = new PositionManager();
        d.pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (
                            usdc,
                            ILPVault(address(d.vault)),
                            IInsuranceReserve(address(d.insurance)),
                            IOracle(address(d.oracle)),
                            owner
                        )
                    )
                )
            )
        );

        d.vault.setPositionManager(address(d.pm));
        d.insurance.setPositionManager(address(d.pm));
        d.pm.setSwapRouter(address(d.router));

        d.pm.setRiskParams(800, 8_000, 50e6, 0.5e6, 100, 100, 200);
        d.pm.setAsset(BaseMainnet.WETH, true, 3_500, 2_000);
        d.pm.setAsset(BaseMainnet.CBBTC, true, 3_500, 2_000);

        d.pm.setLevel(
            0,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 5,
                maxMargin: 50e6,
                lpProfitBps: 1500,
                treasuryProfitBps: 500,
                promoteMinTrades: 5,
                promoteMinPnl: 25e6,
                demoteMaxLoss: 0
            })
        );
        d.pm.setLevel(
            1,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 10,
                maxMargin: 250e6,
                lpProfitBps: 1000,
                treasuryProfitBps: 300,
                promoteMinTrades: 10,
                promoteMinPnl: 100e6,
                demoteMaxLoss: 50e6
            })
        );
        d.pm.setLevel(
            2,
            PositionManager.LevelConfig({
                enabled: true,
                maxLeverage: 10,
                maxMargin: 1000e6,
                lpProfitBps: 700,
                treasuryProfitBps: 200,
                promoteMinTrades: 0,
                promoteMinPnl: 0,
                demoteMaxLoss: 200e6
            })
        );
    }

    function handOff(BaseDeployment memory d, address governance) internal {
        d.oracle.transferOwnership(governance);
        d.vault.transferOwnership(governance);
        d.insurance.transferOwnership(governance);
        d.pm.transferOwnership(governance);
    }
}
