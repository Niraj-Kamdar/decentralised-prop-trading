// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IV4SwapRouter} from "./interfaces/IProtocol.sol";

/// @title V4SwapRouter
/// @notice Minimal exact-input, single-pool Uniswap v4 router for TraderProxy custody containers.
/// @dev The caller grants a plain ERC-20 approval for `amountIn` (no Permit2); the router pulls only what the pool
///      actually consumed, settles it with the PoolManager and sends the output to `recipient`. It holds no
///      balances between calls and has no owner. ERC-20 currencies only (Arc pools quote the 0x3600 USDC ERC-20).
contract V4SwapRouter is IV4SwapRouter, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    error OnlyPoolManager();
    error NativeCurrencyUnsupported();
    error AmountTooLarge();
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOut);

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @inheritdoc IV4SwapRouter
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        if (Currency.unwrap(key.currency0) == address(0)) revert NativeCurrencyUnsupported();
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        bytes memory ret = poolManager.unlock(
            abi.encode(
                CallbackData({
                    payer: msg.sender,
                    recipient: recipient,
                    key: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    minAmountOut: minAmountOut
                })
            )
        );
        amountOut = abi.decode(ret, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory d = abi.decode(data, (CallbackData));

        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency cin, Currency cout) =
            d.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);
        (int128 dIn, int128 dOut) =
            d.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = uint256(int256(-dIn)); // may be < amountIn if the pool ran out of liquidity
        if (dOut <= 0) revert InsufficientOutput(d.minAmountOut, 0);
        uint256 amountOut = uint256(int256(dOut));
        if (amountOut < d.minAmountOut) revert InsufficientOutput(d.minAmountOut, amountOut);

        poolManager.sync(cin);
        IERC20(Currency.unwrap(cin)).safeTransferFrom(d.payer, address(poolManager), paid);
        poolManager.settle();
        poolManager.take(cout, d.recipient, amountOut);
        return abi.encode(amountOut);
    }
}
