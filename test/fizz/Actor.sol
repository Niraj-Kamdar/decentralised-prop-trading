// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ForceSendETH {
    constructor(address dst) payable {
        assembly {
            selfdestruct(dst)
        }
    }
}

/// @notice Represents an actor interacting with the system (LPs, traders, keepers, random actors)
contract Actor {
    constructor() payable {}

    receive() external payable {}

    function forceSendETH(address recipient, uint256 amount) public {
        new ForceSendETH{value: amount}(recipient);
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function execute(address target, uint256 value, bytes calldata data)
        external
        returns (bool success, bytes memory returnData)
    {
        (success, returnData) = target.call{value: value}(data);
    }

    // ――――――――――――――――――― Flash loan borrower ――――――――――――――――――――

    function onFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes32) {
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // ――――――――――――――――――――― ERC-721 receiver ―――――――――――――――――――――

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ―――――――――――――――――――― ERC-1155 receiver ―――――――――――――――――――――

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
