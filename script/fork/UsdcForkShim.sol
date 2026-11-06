// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title UsdcForkShim
/// @notice FORK TESTING ONLY. Replacement implementation for Arc's USDC proxy at 0x3600..00 on a local fork.
/// @dev Arc's USDC implementation moves value through a native-coin precompile at 0x1800..00 that anvil and forge
///      do not have, so every `transfer` reverts on a fork. Installing this contract as the proxy's implementation
///      turns USDC into an ordinary ERC-20 for the fork:
///        - an account's first ERC-20 balance is its native balance at that moment (18 -> 6 decimals), so the
///          Uniswap PoolManager and every other existing holder keep their real USDC;
///        - after that, ERC-20 balances live in this contract's namespaced storage and no longer track native
///          balances (gas is still paid in native USDC as usual);
///        - `mint` is open to anyone, to fund test wallets;
///        - `isBlacklisted` always returns false (the real one reads a second precompile, 0x1800..01).
///      Storage is namespaced (ERC-7201 style) so it cannot collide with the real implementation's layout.
contract UsdcForkShim {
    /// @dev keccak256("org.zeppelinos.proxy.implementation"): where Arc's USDC proxy stores its implementation.
    bytes32 public constant IMPLEMENTATION_SLOT = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    /// @dev keccak256(abi.encode(uint256(keccak256("spotprop.fork.usdc")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE = 0xbe07c265f3f67b304f8e46fb7fdc7647a6199b9e578108b769cef0679a051200;

    struct Layout {
        mapping(address => bool) initialised;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 minted;
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function _l() private pure returns (Layout storage l) {
        bytes32 slot = STORAGE;
        assembly {
            l.slot := slot
        }
    }

    function name() external pure returns (string memory) {
        return "USDC";
    }

    function symbol() external pure returns (string memory) {
        return "USDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    /// @dev Approximate: the real supply at fork time is not tracked. Nothing in the protocol reads it.
    function totalSupply() external view returns (uint256) {
        return 1e15 + _l().minted;
    }

    function balanceOf(address a) public view returns (uint256) {
        Layout storage l = _l();
        return l.initialised[a] ? l.balances[a] : a.balance / 1e12;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _l().allowances[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _l().allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        Layout storage l = _l();
        uint256 a = l.allowances[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= value, "ERC20: insufficient allowance");
            l.allowances[from][msg.sender] = a - value;
        }
        _move(from, to, value);
        return true;
    }

    /// @notice Arc's USDC exposes the Circle blocklist, and other Arc tokens (e.g. WETH) consult it on every
    ///         transfer. The real check reads a native precompile at 0x1800..01; on the fork nobody is blocklisted.
    function isBlacklisted(address) external pure returns (bool) {
        return false;
    }

    /// @notice Fork-only faucet.
    function mint(address to, uint256 value) external {
        Layout storage l = _l();
        _touch(l, to);
        l.balances[to] += value;
        l.minted += value;
        emit Transfer(address(0), to, value);
    }

    function _move(address from, address to, uint256 value) private {
        require(to != address(0), "ERC20: transfer to the zero address");
        Layout storage l = _l();
        _touch(l, from);
        _touch(l, to);
        uint256 b = l.balances[from];
        require(b >= value, "ERC20: transfer amount exceeds balance");
        unchecked {
            l.balances[from] = b - value;
        }
        l.balances[to] += value;
        emit Transfer(from, to, value);
    }

    function _touch(Layout storage l, address a) private {
        if (l.initialised[a]) return;
        l.initialised[a] = true;
        l.balances[a] = a.balance / 1e12;
    }
}
