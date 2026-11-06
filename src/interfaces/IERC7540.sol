// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice ERC-7540 operator methods (interface id 0xe3bc4e65).
interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool);
}

/// @notice ERC-7540 asynchronous redemption (interface id 0x620ee8e4).
interface IERC7540Redeem {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}
