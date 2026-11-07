// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Handlers as MainHandlers} from "../Handlers.sol";

/// @notice Re-exports the unified Handlers contract for fuzz runners
abstract contract Handlers is MainHandlers {}
