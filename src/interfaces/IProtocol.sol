// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IDenylist {
    function isDenied(address account) external view returns (bool);
}

interface ILPVault {
    function totalAssets() external view returns (uint256);
    function totalBorrowedPrincipal() external view returns (uint256);
    function allocateToPosition(address proxy, uint256 amount) external;
    function repayFromPosition(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned) external;
}

interface IInsuranceReserve {
    function insurancePoolBalance() external view returns (uint256);
    function fund(uint256 toInsurance, uint256 treasuryCut) external;
    function coverShortfall(uint256 deficit) external returns (uint256 covered);
}

/// @notice Manipulation-resistant USD price source (Uniswap v4 TWAP); prices are USD per whole token, 1e18.
interface IOracle {
    function getPrice(address asset) external view returns (uint256 price18);
    function valueInUsdc(address asset, uint256 amount) external view returns (uint256 usdcValue);
    /// @notice The v4 pool the asset is priced on, which is also the pool the protocol trades through.
    function poolKey(address asset) external view returns (PoolKey memory);
}

interface IV4SwapRouter {
    /// @notice Swap exactly `amountIn` (pulled from msg.sender via ERC-20 allowance) on a single v4 pool.
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}

interface ITraderProxy {
    function executeSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata data
    ) external returns (uint256 amountOut);
    function sweep(address token, address to, uint256 amount) external;
}

interface IRouterRegistry {
    function isWhitelistedRouter(address router) external view returns (bool);
}

interface IRiskView {
    /// @notice Worst-case LP principal loss from open positions under the configured stress shock, net of insurance.
    function stressedNetLoss() external view returns (uint256);
}
