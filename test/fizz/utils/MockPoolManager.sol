// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Minimal mock PoolManager to satisfy UniV4TwapOracle and V4SwapRouter in tests
contract MockPoolManager {
    using SafeERC20 for IERC20;

    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

    mapping(PoolId => uint160) public sqrtPrices;
    mapping(PoolId => int24) public ticks;
    mapping(bytes32 => bytes32) public slotData;

    function setSlot0(PoolId id, uint160 sqrtPriceX96, int24 tick) external {
        sqrtPrices[id] = sqrtPriceX96;
        ticks[id] = tick;
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(id), POOLS_SLOT));
        bytes32 packed = bytes32(uint256(sqrtPriceX96)) | (bytes32(uint256(uint24(tick))) << 160);
        slotData[slot] = packed;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        bytes32 val = slotData[slot];
        if (val == bytes32(0)) {
            val = bytes32(uint256(1 << 96));
        }
        return val;
    }

    function extsload(bytes32 slot, uint256 nSlots) external view returns (bytes32[] memory res) {
        res = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            res[i] = slotData[bytes32(uint256(slot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        res = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            res[i] = slotData[slots[i]];
        }
    }

    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        uint160 p = sqrtPrices[id] == 0 ? uint160(1 << 96) : sqrtPrices[id];
        return (p, ticks[id], 0, 0);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey calldata /*key*/, SwapParams calldata params, bytes calldata /*hookData*/)
        external
        pure
        returns (BalanceDelta delta)
    {
        int128 amountIn = int128(-params.amountSpecified);
        int128 amountOut = amountIn;
        if (params.zeroForOne) {
            delta = toBalanceDelta(-amountIn, amountOut);
        } else {
            delta = toBalanceDelta(amountOut, -amountIn);
        }
    }

    function sync(Currency /*currency*/) external {}

    function settle() external pure returns (uint256) {
        return 0;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
    }
}
