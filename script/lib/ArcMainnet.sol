// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Arc mainnet (chain 5042) addresses the protocol trades and prices against.
/// @dev Uniswap v4 addresses are from Uniswap's deployments page. Pool keys were checked against the on-chain
///      Initialize events and StateView; both pools are hookless and quote the 0x3600 USDC ERC-20 as currency1.
library ArcMainnet {
    uint256 internal constant CHAIN_ID = 5042;

    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// @dev Arc's native-coin precompile used by the USDC implementation; absent on anvil forks (see UsdcForkShim).
    address internal constant NATIVE_COIN = 0x1800000000000000000000000000000000000000;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    address internal constant WETH = 0x128cC466B61f542da60c70e3aA11c10e19B84EDB; // 18 decimals
    address internal constant CIRBTC = 0x171A4217b86A807A64eB94757Db6849fb4bDbAA0; // Circle Wrapped Bitcoin, 8 dec

    /// @dev WETH/USDC, 0.25% fee, tick spacing 25. PoolId 0x0e3778957c57c367e7ea5513122d3e300a1ee635166e22d07c284b01dcea1f95
    function wethUsdcKey() internal pure returns (PoolKey memory) {
        return _key(WETH, 2500, 25);
    }

    /// @dev cirBTC/USDC, 0.30% fee, tick spacing 30. PoolId 0xc955cbfb9d03cde6f78901a81740264f895b9c00025beb9115cf2d7b86b3ee5a
    function cirBtcUsdcKey() internal pure returns (PoolKey memory) {
        return _key(CIRBTC, 3000, 30);
    }

    function _key(address token, uint24 fee, int24 tickSpacing) private pure returns (PoolKey memory) {
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }
}
