// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

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

interface IOracleVerifier {
    function getPrice(address asset) external view returns (uint256 price18);
    function valueInUsdc(address asset, uint256 amount) external view returns (uint256 usdcValue);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 nativeFee);
    function updatePrices(bytes[] calldata updateData) external;
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
