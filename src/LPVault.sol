// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ArcConstants} from "./libraries/ArcConstants.sol";

/// @title LPVault (spUSDC)
/// @notice ERC-4626 USDC vault. Idle reserves are supplied to a MetaMorpho vault; up to `maxUtilizationBps` of
///         assets are lent synchronously to TraderProxy positions. Realised trading yield vests linearly over
///         `profitUnlockDuration` to defeat deposit -> close -> withdraw sandwiches.
contract LPVault is
    Initializable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_UNLOCK_DURATION = 7 days;

    IERC4626 public morphoVault;
    address public positionManager;

    uint256 public totalBorrowedPrincipal;

    uint256 public lockedProfit;
    uint256 public lastProfitUnlockTime;
    uint256 public profitUnlockDuration;

    uint256 public localBufferBps;
    uint256 public maxUtilizationBps;

    event PositionManagerSet(address indexed positionManager);
    event MorphoVaultMigrated(address indexed oldVault, address indexed newVault, uint256 assetsMoved);
    event Allocated(address indexed proxy, uint256 amount, uint256 totalBorrowed);
    event Repaid(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned, uint256 totalBorrowed);
    event BadDebtRealized(uint256 loss);
    event ProfitLocked(uint256 added, uint256 lockedProfitAfter);
    event ParamsUpdated(uint256 localBufferBps, uint256 maxUtilizationBps, uint256 profitUnlockDuration);
    event MorphoSupplyFailed(uint256 amount);

    error OnlyPositionManager();
    error ZeroAddress();
    error InvalidAsset();
    error InvalidParams();
    error UtilizationCapExceeded(uint256 borrowedAfter, uint256 cap);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error RepayExceedsBorrowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 usdc_, IERC4626 morphoVault_, address owner_) external initializer {
        if (address(usdc_) == address(0) || address(morphoVault_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        // On Arc the asset MUST be the 6-decimal ERC-20 precompile; never the 18-decimal native view.
        if (ArcConstants.isArc() && address(usdc_) != ArcConstants.USDC) revert InvalidAsset();
        if (IERC20Metadata(address(usdc_)).decimals() != ArcConstants.USDC_DECIMALS) revert InvalidAsset();
        if (morphoVault_.asset() != address(usdc_)) revert InvalidAsset();

        __ERC20_init("Spot Prop USDC", "spUSDC");
        __ERC4626_init(usdc_);
        __ReentrancyGuard_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        morphoVault = morphoVault_;
        profitUnlockDuration = 12 hours;
        localBufferBps = 500;
        maxUtilizationBps = 8_500;
        lastProfitUnlockTime = block.timestamp;
    }

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert OnlyPositionManager();
        _;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 accounting
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        uint256 gross = _liquidUsdc() + _morphoAssets() + totalBorrowedPrincipal;
        uint256 unvested = _calculateLockedProfit();
        return gross > unvested ? gross - unvested : 0;
    }

    /// @notice USDC that can leave the vault right now (local buffer + instantly withdrawable from Morpho).
    function availableLiquidity() public view returns (uint256) {
        return _liquidUsdc() + morphoVault.maxWithdraw(address(this));
    }

    function utilizationBps() external view returns (uint256) {
        uint256 assets = totalAssets();
        return assets == 0 ? 0 : totalBorrowedPrincipal.mulDiv(BPS, assets);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), availableLiquidity());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(availableLiquidity(), Math.Rounding.Floor));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _supplyIdle();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureLiquidity(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Virtual-share offset makes first-depositor inflation attacks unprofitable (shares have 12 decimals).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------------
    // PositionManager hooks
    // ---------------------------------------------------------------------

    /// @notice Lend `amount` USDC to a freshly cloned TraderProxy.
    function allocateToPosition(address proxy, uint256 amount) external onlyPositionManager nonReentrant {
        if (proxy == address(0)) revert ZeroAddress();
        uint256 borrowedAfter = totalBorrowedPrincipal + amount;
        uint256 cap = totalAssets().mulDiv(maxUtilizationBps, BPS);
        if (borrowedAfter > cap) revert UtilizationCapExceeded(borrowedAfter, cap);

        _ensureLiquidity(amount);
        totalBorrowedPrincipal = borrowedAfter;
        IERC20(asset()).safeTransfer(proxy, amount);
        emit Allocated(proxy, amount, borrowedAfter);
    }

    /// @notice Pulls `principalReturned + yieldEarned` from the PositionManager and closes out `principalBorrowed`.
    /// @dev `principalReturned < principalBorrowed` realises the uncovered bad debt into share price immediately;
    ///      `yieldEarned` (rollover fees + profit split) vests linearly.
    function repayFromPosition(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned)
        external
        onlyPositionManager
        nonReentrant
    {
        if (principalReturned > principalBorrowed || principalBorrowed > totalBorrowedPrincipal) {
            revert RepayExceedsBorrowed();
        }
        uint256 inflow = principalReturned + yieldEarned;
        if (inflow > 0) IERC20(asset()).safeTransferFrom(msg.sender, address(this), inflow);

        totalBorrowedPrincipal -= principalBorrowed;
        if (yieldEarned > 0) _lockProfit(yieldEarned);
        if (principalReturned < principalBorrowed) emit BadDebtRealized(principalBorrowed - principalReturned);

        emit Repaid(principalReturned, principalBorrowed, yieldEarned, totalBorrowedPrincipal);
        _supplyIdle();
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function setPositionManager(address pm) external onlyOwner {
        if (pm == address(0)) revert ZeroAddress();
        // Swapping the manager while loans are outstanding would orphan them.
        if (totalBorrowedPrincipal != 0) revert InvalidParams();
        positionManager = pm;
        emit PositionManagerSet(pm);
    }

    function setParams(uint256 localBufferBps_, uint256 maxUtilizationBps_, uint256 profitUnlockDuration_)
        external
        onlyOwner
    {
        if (
            localBufferBps_ > BPS || maxUtilizationBps_ > 9_500 || profitUnlockDuration_ == 0
                || profitUnlockDuration_ > MAX_UNLOCK_DURATION
        ) revert InvalidParams();
        // Checkpoint the vesting schedule so a duration change cannot step totalAssets().
        lockedProfit = _calculateLockedProfit();
        lastProfitUnlockTime = block.timestamp;

        localBufferBps = localBufferBps_;
        maxUtilizationBps = maxUtilizationBps_;
        profitUnlockDuration = profitUnlockDuration_;
        emit ParamsUpdated(localBufferBps_, maxUtilizationBps_, profitUnlockDuration_);
    }

    /// @notice Move all Morpho-supplied liquidity to a new MetaMorpho vault.
    function migrateMorphoVault(IERC4626 newVault) external onlyOwner nonReentrant {
        if (address(newVault) == address(0) || newVault.asset() != asset()) revert InvalidAsset();
        IERC4626 old = morphoVault;
        uint256 shares = old.balanceOf(address(this));
        uint256 moved = shares == 0 ? 0 : old.redeem(shares, address(this), address(this));
        morphoVault = newVault;
        emit MorphoVaultMigrated(address(old), address(newVault), moved);
        _supplyIdle();
    }

    /// @notice Push idle USDC above the local buffer target into Morpho (permissionless poke).
    function rebalance() external nonReentrant {
        _supplyIdle();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _liquidUsdc() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _morphoAssets() internal view returns (uint256) {
        return morphoVault.convertToAssets(morphoVault.balanceOf(address(this)));
    }

    function _calculateLockedProfit() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastProfitUnlockTime;
        uint256 duration = profitUnlockDuration;
        if (elapsed >= duration) return 0;
        return lockedProfit.mulDiv(duration - elapsed, duration);
    }

    function _lockProfit(uint256 amount) internal {
        lockedProfit = _calculateLockedProfit() + amount;
        lastProfitUnlockTime = block.timestamp;
        emit ProfitLocked(amount, lockedProfit);
    }

    function _ensureLiquidity(uint256 amount) internal {
        uint256 liquid = _liquidUsdc();
        if (liquid >= amount) return;
        uint256 shortfall = amount - liquid;
        uint256 morphoMax = morphoVault.maxWithdraw(address(this));
        if (shortfall > morphoMax) revert InsufficientLiquidity(amount, liquid + morphoMax);
        morphoVault.withdraw(shortfall, address(this), address(this));
    }

    /// @dev Never reverts: a Morpho supply cap or pause must not block deposits, repayments or settlement.
    function _supplyIdle() internal {
        uint256 liquid = _liquidUsdc();
        uint256 target = totalAssets().mulDiv(localBufferBps, BPS);
        if (liquid <= target) return;
        uint256 excess = Math.min(liquid - target, morphoVault.maxDeposit(address(this)));
        if (excess == 0) return;

        IERC20 usdc = IERC20(asset());
        usdc.forceApprove(address(morphoVault), excess);
        try morphoVault.deposit(excess, address(this)) {}
        catch {
            emit MorphoSupplyFailed(excess);
        }
        usdc.forceApprove(address(morphoVault), 0);
    }
}
