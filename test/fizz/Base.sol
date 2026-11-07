// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LPVault} from "../../src/LPVault.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {InsuranceReserve} from "../../src/InsuranceReserve.sol";
import {UniV4TwapOracle} from "../../src/UniV4TwapOracle.sol";
import {V4SwapRouter} from "../../src/V4SwapRouter.sol";
import {ILPVault, IInsuranceReserve, IOracle, IV4SwapRouter} from "../../src/interfaces/IProtocol.sol";

import {MockUSDC, MockToken, MockMetaMorpho, MockOracle, MockRouter} from "../mocks/Mocks.sol";
import {MockPoolManager} from "./utils/MockPoolManager.sol";

/// @notice Base contract with state variables, mock setups, protocol wiring, and actor management
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 internal constant INITIAL_USDC_BALANCE = 1_000_000e6;
    uint256 internal constant INITIAL_VAULT_SEED = 100_000e6;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    struct Ghosts {
        uint256 ghost_totalDeposited;
        uint256 ghost_totalWithdrawn;
        uint256 ghost_totalBorrowed;
        uint256 ghost_totalMargin;
        uint256 ghost_openPositionsCount;
        uint256 ghost_insuranceFunded;
        uint256 ghost_badDebt;
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;
    address internal keeper;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    modifier asKeeper() virtual {
        vm.startPrank(keeper);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    MockUSDC public usdc;
    MockToken public cirBTC;
    MockToken public weth;
    MockMetaMorpho public morpho;
    MockOracle public mockOracle;
    MockRouter public mockRouter;
    MockPoolManager public mockPoolManager;

    LPVault public vault;
    PositionManager public pm;
    InsuranceReserve public insurance;
    UniV4TwapOracle public uniOracle;
    V4SwapRouter public v4Router;

    PoolKey public keyWeth;
    PoolKey public keyCirBtc;

    // Tracking arrays for invariants
    uint256[] internal openPositions;
    uint256[] internal requestIds;
    uint256[] internal ticketIds;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal virtual {
        vm.warp(1_750_000_000);
        admin = address(this);
        keeper = address(0xCAFE);
        vm.label(admin, "Admin");
        vm.label(keeper, "Keeper");

        // Deploy mocks
        usdc = new MockUSDC();
        cirBTC = new MockToken("Circle BTC", "cirBTC", 8);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        morpho = new MockMetaMorpho(IERC20(address(usdc)));
        mockOracle = new MockOracle(address(usdc));
        mockRouter = new MockRouter(address(usdc));
        mockPoolManager = new MockPoolManager();

        // Setup pool keys
        (address c0Weth, address c1Weth) = address(weth) < address(usdc)
            ? (address(weth), address(usdc))
            : (address(usdc), address(weth));
        keyWeth = PoolKey({
            currency0: Currency.wrap(c0Weth),
            currency1: Currency.wrap(c1Weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        (address c0Btc, address c1Btc) = address(cirBTC) < address(usdc)
            ? (address(cirBTC), address(usdc))
            : (address(usdc), address(cirBTC));
        keyCirBtc = PoolKey({
            currency0: Currency.wrap(c0Btc),
            currency1: Currency.wrap(c1Btc),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Set initial mock pool manager slot0
        mockPoolManager.setSlot0(keyWeth.toId(), uint160(1 << 96), 0);
        mockPoolManager.setSlot0(keyCirBtc.toId(), uint160(1 << 96), 0);

        // Deploy protocol contracts
        uniOracle = new UniV4TwapOracle(IPoolManager(address(mockPoolManager)), address(usdc), admin);
        uniOracle.setFeed(address(weth), keyWeth);
        uniOracle.setFeed(address(cirBTC), keyCirBtc);
        uniOracle.setRecorder(keeper, true);

        v4Router = new V4SwapRouter(IPoolManager(address(mockPoolManager)));

        LPVault vaultImpl = new LPVault();
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), IERC4626(address(morpho)), admin))
                )
            )
        );

        insurance = new InsuranceReserve(IERC20(address(usdc)), admin);

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(
                        PositionManager.initialize,
                        (
                            IERC20(address(usdc)),
                            ILPVault(address(vault)),
                            IInsuranceReserve(address(insurance)),
                            IOracle(address(mockOracle)),
                            admin
                        )
                    )
                )
            )
        );

        // Permissions and wiring
        vault.setPositionManager(address(pm));
        insurance.setPositionManager(address(pm));
        pm.setSwapRouter(address(mockRouter));
        pm.setAsset(address(cirBTC), true, 3_500, 2_000);
        pm.setAsset(address(weth), true, 3_500, 2_000);
        vault.setQueueParams(7 days, 8_000, 2_500, 10_000);

        pm.setLevel(
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

        // Seed router inventory
        usdc.mint(address(mockRouter), 20_000_000e6);
        cirBTC.mint(address(mockRouter), 10_000e8);
        weth.mint(address(mockRouter), 100_000e18);

        // Seed mock pool manager inventory
        usdc.mint(address(mockPoolManager), 10_000_000e6);
        cirBTC.mint(address(mockPoolManager), 1_000e8);
        weth.mint(address(mockPoolManager), 10_000e18);

        // Initial prices ($50,000 for cirBTC, $2,500 for weth)
        _setPrices(50_000, 2_500);

        // Seed initial vault liquidity from admin
        usdc.mint(admin, INITIAL_VAULT_SEED);
        usdc.approve(address(vault), INITIAL_VAULT_SEED);
        vault.deposit(INITIAL_VAULT_SEED, admin);
        ghosts.ghost_totalDeposited += INITIAL_VAULT_SEED;

        // Setup actors
        setupActors();
    }

    function setupActors() internal {
        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            vm.label(_actor, ACTOR_LABELS[i]);

            // Fund actor
            usdc.mint(_actor, INITIAL_USDC_BALANCE);

            // Grant approvals
            vm.startPrank(_actor);
            usdc.approve(address(vault), type(uint256).max);
            usdc.approve(address(pm), type(uint256).max);
            vault.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        actor = actors[0];
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    function _setPrices(uint256 btcUsd, uint256 ethUsd) internal {
        mockOracle.setPrice(address(cirBTC), btcUsd * 1e18);
        mockRouter.setPrice(address(cirBTC), btcUsd * 1e18);

        mockOracle.setPrice(address(weth), ethUsd * 1e18);
        mockRouter.setPrice(address(weth), ethUsd * 1e18);
    }

    function _removePosition(uint256 posId) internal {
        for (uint256 i = 0; i < openPositions.length; i++) {
            if (openPositions[i] == posId) {
                openPositions[i] = openPositions[openPositions.length - 1];
                openPositions.pop();
                break;
            }
        }
    }

    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
