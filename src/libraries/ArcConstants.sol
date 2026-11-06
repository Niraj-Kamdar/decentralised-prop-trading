// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Arc network constants.
/// @dev USDC on Arc is both the native gas token (18 decimals, via msg.value / address.balance) and an
///      ERC-20 precompile at 0x3600..0000 (6 decimals). Protocol contracts only ever use the ERC-20 interface.
library ArcConstants {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant MAINNET_CHAIN_ID = 5042;
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    uint8 internal constant USDC_DECIMALS = 6;

    function isArc() internal view returns (bool) {
        return block.chainid == MAINNET_CHAIN_ID || block.chainid == TESTNET_CHAIN_ID;
    }
}
