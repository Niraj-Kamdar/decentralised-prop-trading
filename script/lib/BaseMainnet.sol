// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Base mainnet (chain 8453) addresses the protocol trades and prices against.
library BaseMainnet {
    uint256 internal constant CHAIN_ID = 8453;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant BTC_USD_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    uint32 internal constant MAX_STALENESS = 3600;

    /// @dev WETH/USDC, 0.30% fee, tick spacing 60.
    function wethUsdcKey() internal pure returns (PoolKey memory) {
        return _key(WETH, 3000, 60);
    }

    /// @dev cbBTC/USDC, 0.05% fee, tick spacing 10.
    function cbBtcUsdcKey() internal pure returns (PoolKey memory) {
        return _key(CBBTC, 500, 10);
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
