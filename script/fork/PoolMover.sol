// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title PoolMover
/// @notice FORK TESTING ONLY. Pushes a real Uniswap v4 pool to a target tick by trading against it, to simulate
///         rallies and crashes. It pays from its own token balances, so fund it first (shim mint / deal).
contract PoolMover is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    /// @notice Swap until the pool's tick reaches `targetTick` (or the pool runs dry). Returns the tick reached.
    function moveTo(PoolKey calldata key, int24 targetTick) external returns (int24 tick) {
        (, int24 current,,) = poolManager.getSlot0(key.toId());
        if (current == targetTick) return current;
        bool zeroForOne = targetTick < current; // selling currency0 lowers the price
        poolManager.unlock(abi.encode(key, zeroForOne, TickMath.getSqrtPriceAtTick(targetTick)));
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        (PoolKey memory key, bool zeroForOne, uint160 limit) = abi.decode(data, (PoolKey, bool, uint160));
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        Currency cout = zeroForOne ? key.currency1 : key.currency0;
        uint256 budget = IERC20(Currency.unwrap(cin)).balanceOf(address(this));

        BalanceDelta d = poolManager.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: limit}), ""
        );
        int128 dIn = zeroForOne ? d.amount0() : d.amount1();
        int128 dOut = zeroForOne ? d.amount1() : d.amount0();

        poolManager.sync(cin);
        IERC20(Currency.unwrap(cin)).transfer(address(poolManager), uint256(int256(-dIn)));
        poolManager.settle();
        if (dOut > 0) poolManager.take(cout, address(this), uint256(int256(dOut)));
        return "";
    }
}
