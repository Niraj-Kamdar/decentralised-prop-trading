// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOracle, IV4SwapRouter} from "../../src/interfaces/IProtocol.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {AggregatorV3Interface, AggregatorV2V3Interface} from "../../src/ChainlinkOracle.sol";

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

/// @notice IOracle stand-in: a settable TWAP price per asset and a synthetic USDC pool key.
contract MockOracle is IOracle {
    address public immutable usdc;
    mapping(address => uint256) public price18;
    mapping(address => uint8) public decimalsOf;

    error FeedNotEnabled(address asset);

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setPrice(address token, uint256 p) external {
        if (decimalsOf[token] == 0) decimalsOf[token] = IERC20Metadata(token).decimals();
        price18[token] = p;
    }

    function getPrice(address asset) public view returns (uint256) {
        uint256 p = price18[asset];
        if (p == 0) revert FeedNotEnabled(asset);
        return p;
    }

    function valueInUsdc(address asset, uint256 amount) external view returns (uint256) {
        return amount * getPrice(asset) / 10 ** (uint256(decimalsOf[asset]) + 12);
    }

    function poolKey(address asset) external view returns (PoolKey memory key) {
        getPrice(asset);
        (address c0, address c1) = asset < usdc ? (asset, usdc) : (usdc, asset);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

/// @notice Constant-price stand-in for V4SwapRouter. Prices are 1e18 USD per whole token; USDC is assumed $1.
/// @dev `redirectTo` simulates a router that sends proceeds somewhere other than `recipient`.
contract MockRouter is IV4SwapRouter {
    mapping(address => uint256) public price18;
    address public immutable usdc;
    uint256 public feeBps;
    address public redirectTo;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setPrice(address token, uint256 p) external {
        price18[token] = p;
    }

    function setFeeBps(uint256 f) external {
        feeBps = f;
    }

    function setRedirect(address to) external {
        redirectTo = to;
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

    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 out) {
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        address tokenIn = Currency.unwrap(cin);
        address tokenOut = Currency.unwrap(cout);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = quote(tokenIn, tokenOut, amountIn);
        require(out >= minAmountOut, "router: slippage");
        IERC20(tokenOut).transfer(redirectTo == address(0) ? recipient : redirectTo, out);
    }
}

contract MockAggregator is AggregatorV2V3Interface {
    uint8 private immutable _decimals;
    string private _description;
    int256 private _answer;
    uint256 private _updatedAt;
    uint256 private _startedAt;
    uint80 private _roundId = 1;
    uint80 private _answeredInRound = 1;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function setDescription(string memory desc) external {
        _description = desc;
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
        _startedAt = updatedAt;
    }

    function setRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        _roundId = roundId;
        _answer = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt == 0 ? _updatedAt : _startedAt, _updatedAt, _answeredInRound);
    }
}
