// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice 6-decimal USDC stand-in with a Circle-style blocklist (reverts on send/receive).
contract MockUSDC is ERC20 {
    mapping(address => bool) public blocklisted;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocklisted(address a, bool b) external {
        blocklisted[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocklisted[from] && !blocklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal MetaMorpho stand-in: plain ERC-4626 whose yield is simulated by minting USDC into it.
contract MockMetaMorpho is ERC4626 {
    constructor(IERC20 usdc) ERC4626(usdc) ERC20("MetaMorpho USDC", "mmUSDC") {}
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _prices;
    uint256 public feePerUpdate;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) public {
        _prices[id] = Price(price, conf, expo, publishTime);
    }

    function setFee(uint256 fee) external {
        feePerUpdate = fee;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return feePerUpdate * updateData.length;
    }

    /// @dev Each update = abi.encode(bytes32 id, int64 price, uint64 conf, int32 expo); stamped with block.timestamp.
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        require(msg.value >= feePerUpdate * updateData.length, "fee");
        for (uint256 i; i < updateData.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo) =
                abi.decode(updateData[i], (bytes32, int64, uint64, int32));
            setPrice(id, price, conf, expo, block.timestamp);
        }
    }
}

/// @notice Constant-price router. Prices are 1e18 USD per whole token; USDC is assumed $1.
/// @dev `recipient` lets tests simulate calldata that redirects proceeds away from the proxy.
contract MockRouter {
    mapping(address => uint256) public price18;
    address public immutable usdc;
    uint256 public feeBps;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setPrice(address token, uint256 p) external {
        price18[token] = p;
    }

    function setFeeBps(uint256 f) external {
        feeBps = f;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 out) {
        if (tokenIn == usdc) {
            uint8 d = IERC20Metadata(tokenOut).decimals();
            out = amountIn * 1e12 * (10 ** d) / price18[tokenOut];
        } else {
            uint8 d = IERC20Metadata(tokenIn).decimals();
            out = amountIn * price18[tokenIn] / (10 ** d) / 1e12;
        }
        out = out * (10_000 - feeBps) / 10_000;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = quote(tokenIn, tokenOut, amountIn);
        require(out >= minOut, "router: slippage");
        IERC20(tokenOut).transfer(recipient, out);
    }
}
