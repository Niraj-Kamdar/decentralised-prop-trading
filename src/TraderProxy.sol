// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterRegistry} from "./interfaces/IProtocol.sol";

/// @title TraderProxy
/// @notice Isolated per-position spot custody container, deployed as an EIP-1167 clone by PositionManager.
/// @dev `manager` is an immutable of the implementation; clones delegatecall into the implementation code, so
///      every clone shares the same immutable manager without an initializer. The trader has no entry points.
contract TraderProxy {
    using SafeERC20 for IERC20;

    address public immutable manager;

    error OnlyManager();
    error RouterNotWhitelisted(address router);
    error SwapCallFailed(bytes reason);
    error InputNotFullySpent(uint256 expected, uint256 actual);
    error InsufficientOutput(uint256 minOut, uint256 actual);

    constructor(address manager_) {
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    /// @notice Swap exactly `amountIn` of `tokenIn` held by this proxy into `tokenOut` via a whitelisted router.
    /// @dev Output is measured as this proxy's own balance delta, so router calldata that redirects proceeds to a
    ///      third-party recipient fails the `minOut` check. Approval is exact and revoked after the call.
    function executeSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata data
    ) external onlyManager returns (uint256 amountOut) {
        if (!IRouterRegistry(manager).isWhitelistedRouter(router)) revert RouterNotWhitelisted(router);

        IERC20 tin = IERC20(tokenIn);
        IERC20 tout = IERC20(tokenOut);
        uint256 inBefore = tin.balanceOf(address(this));
        uint256 outBefore = tout.balanceOf(address(this));

        tin.forceApprove(router, amountIn);
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) revert SwapCallFailed(ret);
        tin.forceApprove(router, 0);

        uint256 inAfter = tin.balanceOf(address(this));
        if (inAfter + amountIn != inBefore) revert InputNotFullySpent(amountIn, inBefore - inAfter);

        uint256 outAfter = tout.balanceOf(address(this));
        amountOut = outAfter > outBefore ? outAfter - outBefore : 0;
        if (amountOut < minOut) revert InsufficientOutput(minOut, amountOut);
    }

    /// @notice Return settled tokens to the manager during unwind.
    function sweep(address token, address to, uint256 amount) external onlyManager {
        IERC20(token).safeTransfer(to, amount);
    }
}
