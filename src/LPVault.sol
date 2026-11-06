// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ArcConstants} from "./libraries/ArcConstants.sol";
import {IRiskView} from "./interfaces/IProtocol.sol";
import {IERC7540Operator, IERC7540Redeem} from "./interfaces/IERC7540.sol";

/// @title LPVault (spUSDC)
/// @notice ERC-4626 USDC vault with ERC-7540 asynchronous redemptions. Idle reserves are supplied to a MetaMorpho
///         vault; up to `maxUtilizationBps` of assets are lent synchronously to TraderProxy positions. Realised
///         trading yield vests linearly over `profitUnlockDuration` to defeat deposit -> close -> withdraw sandwiches.
///
///         Exits go through a FIFO queue (`redeemCooldown`). Queued shares stop earning, and a request made while the
///         pool is stressed also forfeits `exitPenaltyBps` of the yield earned before it (never principal). Forfeits
///         fund a bonus pot that streams to new LPs who lock a deposit for `bonusDuration` while the pool is stressed.
///         Fulfilment is gated so free liquidity always covers the PositionManager's worst-case stressed LP loss.
contract LPVault is
    Initializable,
    ERC4626Upgradeable,
    IERC7540Operator,
    IERC7540Redeem,
    ReentrancyGuardUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;
    using SafeCast for uint256;

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_UNLOCK_DURATION = 7 days;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum RequestStatus {
        NONE,
        PENDING,
        FULFILLED,
        CANCELLED
    }

    struct RedeemRequestData {
        address controller;
        uint64 requestedAt;
        uint64 maturesAt;
        bool stressedAtRequest;
        RequestStatus status;
        uint128 shares; // still pending, escrowed in this vault
        uint128 basis; // principal attributed to the pending shares
        uint128 assetsAtRequest; // value of the pending shares when requested
        uint128 filledShares; // shares already fulfilled
    }

    struct BonusTicket {
        address owner;
        uint64 maturesAt;
        bool active;
        uint128 shares; // escrowed in this vault until claim/break
        uint128 weight; // USDC deposited
        uint128 basis;
        uint256 rewardDebt;
    }

    // ---------------------------------------------------------------------
    // Storage (append-only for UUPS upgrades)
    // ---------------------------------------------------------------------

    IERC4626 public morphoVault;
    address public positionManager;

    uint256 public totalBorrowedPrincipal;

    uint256 public lockedProfit;
    uint256 public lastProfitUnlockTime;
    uint256 public profitUnlockDuration;

    uint256 public localBufferBps;
    uint256 public maxUtilizationBps;

    // --- exit queue & bonus (added on top of feat/core-contracts) ---

    uint256 public redeemCooldown;
    uint256 public stressUtilizationBps;
    uint256 public exitPenaltyBps;
    uint256 public gateCoverageBps;
    uint256 public bonusDuration;
    uint256 public bonusEmissionPeriod;
    uint256 public maxBonusAprBps;
    uint256 public minBonusDeposit;

    /// @notice USDC principal attributed to the shares each account holds.
    mapping(address account => uint256) public costBasis;
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    uint256 public nextRequestId;
    uint256 public queueHead;
    uint256[] internal _queue;
    mapping(uint256 requestId => RedeemRequestData) internal _requests;
    /// @notice Sum of `assetsAtRequest` over pending requests; reserved ahead of new trader allocations.
    uint256 public pendingRedeemAssets;
    uint256 public totalPendingShares;
    /// @notice USDC owed to fulfilled requests, always held as local USDC.
    uint256 public reservedForClaims;
    mapping(address controller => uint256) public claimableShares;
    mapping(address controller => uint256) public claimableAssets;

    /// @notice Unemitted bonus pot (liability; excluded from totalAssets).
    uint256 public bonusPot;
    /// @notice Bonus emitted to tickets but not yet claimed (liability; excluded from totalAssets).
    uint256 public bonusAccrued;
    uint256 public lastBonusUpdate;
    uint256 public accBonusPerWeight; // 1e18-scaled
    uint256 public totalTicketWeight;
    uint256 public nextTicketId;
    mapping(uint256 ticketId => BonusTicket) internal _tickets;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event PositionManagerSet(address indexed positionManager);
    event MorphoVaultMigrated(address indexed oldVault, address indexed newVault, uint256 assetsMoved);
    event Allocated(address indexed proxy, uint256 amount, uint256 totalBorrowed);
    event Repaid(uint256 principalReturned, uint256 principalBorrowed, uint256 yieldEarned, uint256 totalBorrowed);
    event BadDebtRealized(uint256 loss);
    event ProfitLocked(uint256 added, uint256 lockedProfitAfter);
    event ParamsUpdated(uint256 localBufferBps, uint256 maxUtilizationBps, uint256 profitUnlockDuration);
    event MorphoSupplyFailed(uint256 amount);
    event RedeemRequestCancelled(uint256 indexed requestId, uint256 sharesReturned, uint256 forfeit);
    event RedeemFulfilled(
        uint256 indexed requestId,
        address indexed controller,
        uint256 shares,
        uint256 payout,
        uint256 forfeit,
        uint256 penalty
    );
    event RedemptionsGated(uint256 netStressLoss, uint256 freeLiquidity);
    event BonusPotFunded(address indexed source, uint256 amount);
    event BonusTicketOpened(
        uint256 indexed ticketId, address indexed owner, uint256 assets, uint256 shares, uint64 maturesAt
    );
    event BonusTicketClaimed(uint256 indexed ticketId, uint256 bonusAssets, uint256 bonusShares);
    event BonusTicketBroken(uint256 indexed ticketId, uint256 forfeited);
    event QueueParamsUpdated(
        uint256 redeemCooldown, uint256 stressUtilizationBps, uint256 exitPenaltyBps, uint256 gateCoverageBps
    );
    event BonusParamsUpdated(
        uint256 bonusDuration, uint256 bonusEmissionPeriod, uint256 maxBonusAprBps, uint256 minBonusDeposit
    );

    error OnlyPositionManager();
    error ZeroAddress();
    error InvalidAsset();
    error InvalidParams();
    error UtilizationCapExceeded(uint256 borrowedAfter, uint256 cap);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error RepayExceedsBorrowed();
    error SyncRedeemDisabled();
    error NotAuthorized();
    error InvalidAmount();
    error RequestNotPending(uint256 requestId);
    error ExceedsClaimable(uint256 requested, uint256 claimable);
    error NotStressed();
    error BelowMinBonusDeposit(uint256 assets, uint256 minimum);
    error TicketNotActive(uint256 ticketId);
    error TicketNotMatured(uint64 maturesAt);
    error TicketMatured(uint64 maturesAt);
    error AllocationBlockedByQueue(uint256 requested, uint256 available);

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

        // Exit queue & bonus defaults: 30-day queue; stressed at >= 80% utilisation (hard cap stays 85%); a stressed
        // exit forfeits 25% of already-earned yield; free liquidity must cover 100% of the stressed loss; stressed
        // deposits can lock for 90 days and earn up to 20% APR from the pot, which streams over 90 days.
        redeemCooldown = 30 days;
        stressUtilizationBps = 8_000;
        exitPenaltyBps = 2_500;
        gateCoverageBps = 10_000;
        bonusDuration = 90 days;
        bonusEmissionPeriod = 90 days;
        maxBonusAprBps = 2_000;
        minBonusDeposit = 1_000e6;
        lastBonusUpdate = block.timestamp;
    }

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert OnlyPositionManager();
        _;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 accounting
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Excludes unvested profit and every earmarked liability: fulfilled-but-unclaimed redemptions and the
    ///      bonus pot (emitted or not). Open positions are carried at face value.
    function totalAssets() public view override returns (uint256) {
        uint256 gross = _liquidUsdc() + _morphoAssets() + totalBorrowedPrincipal;
        uint256 deductions = _calculateLockedProfit() + reservedForClaims + bonusPot + bonusAccrued;
        return gross > deductions ? gross - deductions : 0;
    }

    /// @notice USDC that can leave the vault right now (local buffer + instantly withdrawable from Morpho).
    function availableLiquidity() public view returns (uint256) {
        return _liquidUsdc() + morphoVault.maxWithdraw(address(this));
    }

    /// @notice Available liquidity that is not earmarked for claims or the bonus pot.
    function freeLiquidity() public view returns (uint256) {
        uint256 avail = availableLiquidity();
        uint256 earmarked = reservedForClaims + bonusPot + bonusAccrued;
        return avail > earmarked ? avail - earmarked : 0;
    }

    function utilizationBps() public view returns (uint256) {
        uint256 assets = totalAssets();
        if (assets == 0) return totalBorrowedPrincipal == 0 ? 0 : BPS;
        return totalBorrowedPrincipal.mulDiv(BPS, assets);
    }

    /// @notice The pool is stressed once utilisation reaches `stressUtilizationBps`.
    function isStressed() public view returns (bool) {
        return utilizationBps() >= stressUtilizationBps;
    }

    /// @notice Worst-case LP loss from open positions (net of insurance) as reported by the PositionManager.
    function netStressLoss() public view returns (uint256) {
        address pm = positionManager;
        return pm == address(0) ? 0 : IRiskView(pm).stressedNetLoss();
    }

    /// @notice USDC the queue may pay out now: free liquidity in excess of the covered stressed loss.
    function fulfilmentBudget() public view returns (uint256) {
        uint256 free = freeLiquidity();
        uint256 required = netStressLoss().mulDiv(gateCoverageBps, BPS, Math.Rounding.Ceil);
        return free > required ? free - required : 0;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (receiver != address(this)) costBasis[receiver] += assets;
        _supplyIdle();
    }

    /// @dev Moves cost basis pro rata with user-to-user share transfers. Mints, burns and escrow moves in or out of
    ///      this vault are accounted by their callers.
    function _update(address from, address to, uint256 value) internal override {
        if (value > 0 && from != address(0) && to != address(0) && from != address(this) && to != address(this)) {
            uint256 moved = _basisPortion(from, value);
            costBasis[from] -= moved;
            costBasis[to] += moved;
        }
        super._update(from, to, value);
    }

    /// @dev Virtual-share offset makes first-depositor inflation attacks unprofitable (shares have 12 decimals).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------------
    // ERC-7540 asynchronous redemption
    // ---------------------------------------------------------------------

    /// @notice Escrow `shares` from `owner` into the FIFO exit queue. They stop earning from now on.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert InvalidAmount();
        if (controller == address(0)) revert ZeroAddress();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();

        uint256 basis = _basisPortion(owner, shares);
        costBasis[owner] -= basis;
        _transfer(owner, address(this), shares);

        uint256 assetsAtRequest = _convertToAssets(shares, Math.Rounding.Floor);
        uint64 maturesAt = (block.timestamp + redeemCooldown).toUint64();
        requestId = ++nextRequestId;
        _requests[requestId] = RedeemRequestData({
            controller: controller,
            requestedAt: block.timestamp.toUint64(),
            maturesAt: maturesAt,
            stressedAtRequest: isStressed(),
            status: RequestStatus.PENDING,
            shares: shares.toUint128(),
            basis: basis.toUint128(),
            assetsAtRequest: assetsAtRequest.toUint128(),
            filledShares: 0
        });
        _queue.push(requestId);
        pendingRedeemAssets += assetsAtRequest;
        totalPendingShares += shares;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    /// @notice Cancel a pending request. Any gain accrued while queued is forfeited to the bonus pot, so a request
    ///         can never be used as a free option on queue-period upside.
    function cancelRedeemRequest(uint256 requestId) external nonReentrant {
        RedeemRequestData storage r = _requests[requestId];
        if (r.status != RequestStatus.PENDING) revert RequestNotPending(requestId);
        address controller = r.controller;
        _checkController(controller);

        uint256 shares = r.shares;
        uint256 valueNow = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 keep = shares;
        uint256 forfeit;
        if (valueNow > r.assetsAtRequest) {
            keep = shares.mulDiv(r.assetsAtRequest, valueNow);
            uint256 burnShares = shares - keep;
            forfeit = _convertToAssets(burnShares, Math.Rounding.Floor);
            _accrueBonus();
            _burn(address(this), burnShares);
            if (forfeit > 0) {
                bonusPot += forfeit;
                emit BonusPotFunded(address(this), forfeit);
            }
        }

        pendingRedeemAssets -= r.assetsAtRequest;
        totalPendingShares -= shares;
        costBasis[controller] += r.basis;
        r.status = RequestStatus.CANCELLED;
        r.shares = 0;
        r.basis = 0;
        r.assetsAtRequest = 0;
        if (keep > 0) _transfer(address(this), controller, keep);

        emit RedeemRequestCancelled(requestId, keep, forfeit);
    }

    /// @notice Permissionless: fulfil matured requests in FIFO order, up to `fulfilmentBudget()`.
    /// @return fulfilled Number of requests fully or partially fulfilled.
    function processRedemptions(uint256 maxRequests) external nonReentrant returns (uint256 fulfilled) {
        uint256 budget = fulfilmentBudget();
        uint256 head = queueHead;
        uint256 len = _queue.length;
        bool gated;

        while (head < len && fulfilled < maxRequests) {
            uint256 id = _queue[head];
            RedeemRequestData storage r = _requests[id];
            if (r.status != RequestStatus.PENDING) {
                ++head;
                continue;
            }
            if (r.maturesAt > block.timestamp) break;
            if (budget == 0) {
                gated = true;
                break;
            }
            uint256 payout = _fulfil(id, r, budget);
            if (payout == type(uint256).max) {
                gated = true; // budget too small for even one share
                break;
            }
            budget -= payout;
            ++fulfilled;
            if (r.status == RequestStatus.PENDING) break; // partially filled: budget exhausted
            ++head;
        }
        queueHead = head;

        if (fulfilled > 0) _ensureLocal(reservedForClaims);
        if (gated) emit RedemptionsGated(netStressLoss(), freeLiquidity());
    }

    /// @notice ERC-7540 claim: burn claimable request shares for their fixed payout.
    function redeem(uint256 shares, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _checkController(controller);
        uint256 cShares = claimableShares[controller];
        if (shares == 0 || shares > cShares) revert ExceedsClaimable(shares, cShares);
        uint256 cAssets = claimableAssets[controller];
        assets = shares == cShares ? cAssets : cAssets.mulDiv(shares, cShares);
        _claim(controller, receiver, assets, shares);
    }

    /// @notice ERC-7540 claim by asset amount.
    function withdraw(uint256 assets, address receiver, address controller)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _checkController(controller);
        uint256 cAssets = claimableAssets[controller];
        if (assets == 0 || assets > cAssets) revert ExceedsClaimable(assets, cAssets);
        uint256 cShares = claimableShares[controller];
        shares = assets == cAssets ? cShares : cShares.mulDiv(assets, cAssets, Math.Rounding.Ceil);
        _claim(controller, receiver, assets, shares);
    }

    function maxWithdraw(address controller) public view override returns (uint256) {
        return claimableAssets[controller];
    }

    function maxRedeem(address controller) public view override returns (uint256) {
        return claimableShares[controller];
    }

    /// @dev ERC-7540: previews MUST revert for asynchronous flows.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert SyncRedeemDisabled();
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        revert SyncRedeemDisabled();
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequestData storage r = _requests[requestId];
        return r.controller == controller && r.status == RequestStatus.PENDING ? r.shares : 0;
    }

    /// @dev Claimable balances are aggregated per controller (claims are not tied to a request id).
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequestData storage r = _requests[requestId];
        if (r.controller != controller || r.filledShares == 0) return 0;
        return Math.min(r.filledShares, claimableShares[controller]);
    }

    function getRedeemRequest(uint256 requestId) external view returns (RedeemRequestData memory) {
        return _requests[requestId];
    }

    function queueLength() external view returns (uint256) {
        return _queue.length - queueHead;
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        if (operator == msg.sender) revert NotAuthorized();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC-165
            || id == 0xe3bc4e65 // ERC-7540 operator
            || id == 0x620ee8e4; // ERC-7540 async redeem
    }

    // ---------------------------------------------------------------------
    // Bonus pot & tickets
    // ---------------------------------------------------------------------

    /// @notice While stressed, deposit and lock the shares for `bonusDuration` to earn a share of the bonus pot.
    function depositWithBonus(uint256 assets, address receiver) external nonReentrant returns (uint256 ticketId) {
        if (receiver == address(0)) revert ZeroAddress();
        if (!isStressed()) revert NotStressed();
        if (assets < minBonusDeposit) revert BelowMinBonusDeposit(assets, minBonusDeposit);
        _accrueBonus();

        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, address(this), assets, shares);

        uint64 maturesAt = (block.timestamp + bonusDuration).toUint64();
        ticketId = ++nextTicketId;
        _tickets[ticketId] = BonusTicket({
            owner: receiver,
            maturesAt: maturesAt,
            active: true,
            shares: shares.toUint128(),
            weight: assets.toUint128(),
            basis: assets.toUint128(),
            rewardDebt: assets.mulDiv(accBonusPerWeight, 1e18)
        });
        totalTicketWeight += assets;
        emit BonusTicketOpened(ticketId, receiver, assets, shares, maturesAt);
    }

    /// @notice After maturity (callable by anyone): unlock the shares to the owner and mint the bonus as shares.
    function claimTicket(uint256 ticketId) external nonReentrant returns (uint256 bonusShares) {
        BonusTicket storage t = _tickets[ticketId];
        if (!t.active) revert TicketNotActive(ticketId);
        if (block.timestamp < t.maturesAt) revert TicketNotMatured(t.maturesAt);
        uint256 reward = _closeTicket(t);

        if (reward > 0) {
            // Price the bonus while it is still a liability, then release it into totalAssets.
            bonusShares = _convertToShares(reward, Math.Rounding.Floor);
            bonusAccrued -= reward;
            _mint(t.owner, bonusShares);
            costBasis[t.owner] += reward;
        }
        emit BonusTicketClaimed(ticketId, reward, bonusShares);
    }

    /// @notice Before maturity: unlock the shares now and forfeit all accrued bonus back to the pot.
    function breakTicket(uint256 ticketId) external nonReentrant {
        BonusTicket storage t = _tickets[ticketId];
        if (!t.active) revert TicketNotActive(ticketId);
        if (msg.sender != t.owner) revert NotAuthorized();
        if (block.timestamp >= t.maturesAt) revert TicketMatured(t.maturesAt);
        uint256 reward = _closeTicket(t);
        if (reward > 0) {
            bonusAccrued -= reward;
            bonusPot += reward;
            emit BonusPotFunded(address(this), reward);
        }
        emit BonusTicketBroken(ticketId, reward);
    }

    /// @notice Anyone may seed the bonus pot.
    function donateToBonusPot(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrueBonus();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        bonusPot += amount;
        emit BonusPotFunded(msg.sender, amount);
    }

    /// @notice Pull any pending emission into the accumulator (permissionless poke).
    function accrueBonus() external nonReentrant {
        _accrueBonus();
    }

    function getTicket(uint256 ticketId) external view returns (BonusTicket memory) {
        return _tickets[ticketId];
    }

    function pendingBonus(uint256 ticketId) external view returns (uint256) {
        BonusTicket storage t = _tickets[ticketId];
        if (!t.active) return 0;
        (uint256 inc,) = _pendingEmission();
        return uint256(t.weight).mulDiv(accBonusPerWeight + inc, 1e18) - t.rewardDebt;
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
        // Liquidity promised to the exit queue has priority over new trader allocations.
        uint256 free = freeLiquidity();
        uint256 allocatable = free > pendingRedeemAssets ? free - pendingRedeemAssets : 0;
        if (amount > allocatable) revert AllocationBlockedByQueue(amount, allocatable);

        _ensureLiquidity(amount);
        totalBorrowedPrincipal = borrowedAfter;
        IERC20(asset()).safeTransfer(proxy, amount);
        emit Allocated(proxy, amount, borrowedAfter);
    }

    /// @notice Pulls `principalReturned + yieldEarned` from the PositionManager and closes out `principalBorrowed`.
    /// @dev `principalReturned < principalBorrowed` realises the uncovered bad debt into share price immediately;
    ///      `yieldEarned` (rollover fees + profit split) vests linearly. Never touches the queue or gate, so trader
    ///      settlement can never be blocked by LP exits.
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
            localBufferBps_ > BPS || maxUtilizationBps_ > 9_500 || maxUtilizationBps_ < stressUtilizationBps
                || profitUnlockDuration_ == 0 || profitUnlockDuration_ > MAX_UNLOCK_DURATION
        ) revert InvalidParams();
        // Checkpoint the vesting schedule so a duration change cannot step totalAssets().
        lockedProfit = _calculateLockedProfit();
        lastProfitUnlockTime = block.timestamp;

        localBufferBps = localBufferBps_;
        maxUtilizationBps = maxUtilizationBps_;
        profitUnlockDuration = profitUnlockDuration_;
        emit ParamsUpdated(localBufferBps_, maxUtilizationBps_, profitUnlockDuration_);
    }

    /// @notice Exit-queue parameters. Existing requests keep their snapshot (maturity and stress flag).
    function setQueueParams(
        uint256 redeemCooldown_,
        uint256 stressUtilizationBps_,
        uint256 exitPenaltyBps_,
        uint256 gateCoverageBps_
    ) external onlyOwner {
        if (
            redeemCooldown_ < 1 days || redeemCooldown_ > 60 days || stressUtilizationBps_ == 0
                || stressUtilizationBps_ > maxUtilizationBps || exitPenaltyBps_ > 5_000 || gateCoverageBps_ < 5_000
                || gateCoverageBps_ > 20_000
        ) revert InvalidParams();
        redeemCooldown = redeemCooldown_;
        stressUtilizationBps = stressUtilizationBps_;
        exitPenaltyBps = exitPenaltyBps_;
        gateCoverageBps = gateCoverageBps_;
        emit QueueParamsUpdated(redeemCooldown_, stressUtilizationBps_, exitPenaltyBps_, gateCoverageBps_);
    }

    /// @notice Bonus parameters. Existing tickets keep their maturity.
    function setBonusParams(
        uint256 bonusDuration_,
        uint256 bonusEmissionPeriod_,
        uint256 maxBonusAprBps_,
        uint256 minBonusDeposit_
    ) external onlyOwner {
        if (
            bonusDuration_ < 30 days || bonusDuration_ > 180 days || bonusEmissionPeriod_ < 7 days
                || bonusEmissionPeriod_ > 180 days || maxBonusAprBps_ > 5_000 || minBonusDeposit_ == 0
        ) revert InvalidParams();
        _accrueBonus();
        bonusDuration = bonusDuration_;
        bonusEmissionPeriod = bonusEmissionPeriod_;
        maxBonusAprBps = maxBonusAprBps_;
        minBonusDeposit = minBonusDeposit_;
        emit BonusParamsUpdated(bonusDuration_, bonusEmissionPeriod_, maxBonusAprBps_, minBonusDeposit_);
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

    /// @dev Make `amount` of local USDC available on top of what is reserved for claims.
    function _ensureLiquidity(uint256 amount) internal {
        _ensureLocal(amount + reservedForClaims);
    }

    /// @dev Make the local USDC balance at least `target`, pulling the shortfall from Morpho.
    function _ensureLocal(uint256 target) internal {
        uint256 liquid = _liquidUsdc();
        if (liquid >= target) return;
        uint256 shortfall = target - liquid;
        uint256 morphoMax = morphoVault.maxWithdraw(address(this));
        if (shortfall > morphoMax) revert InsufficientLiquidity(target, liquid + morphoMax);
        morphoVault.withdraw(shortfall, address(this), address(this));
    }

    /// @dev Never reverts: a Morpho supply cap or pause must not block deposits, repayments or settlement.
    ///      USDC reserved for claims always stays local.
    function _supplyIdle() internal {
        uint256 liquid = _liquidUsdc();
        uint256 target = totalAssets().mulDiv(localBufferBps, BPS) + reservedForClaims;
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

    function _checkController(address controller) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert NotAuthorized();
    }

    /// @dev Basis attributed to `shares` of `account`, rounded up and capped at the account's basis.
    function _basisPortion(address account, uint256 shares) internal view returns (uint256) {
        uint256 bal = balanceOf(account);
        uint256 basis = costBasis[account];
        if (bal == 0 || basis == 0) return 0;
        if (shares >= bal) return basis;
        return Math.min(basis, basis.mulDiv(shares, bal, Math.Rounding.Ceil));
    }

    /// @dev Fulfil up to `budget` USDC of request `r`. Returns the payout, or type(uint256).max if not even one
    ///      share fits in the budget.
    function _fulfil(uint256 id, RedeemRequestData storage r, uint256 budget) internal returns (uint256 payout) {
        uint256 shares = r.shares;
        (uint256 fullPayout,,) = _quote(shares, r.assetsAtRequest, r.basis, r.stressedAtRequest);

        uint256 fill = shares;
        if (fullPayout > budget) {
            fill = shares.mulDiv(budget, fullPayout);
            if (fill == 0) return type(uint256).max;
        }
        uint256 reqAssets = fill == shares ? r.assetsAtRequest : uint256(r.assetsAtRequest).mulDiv(fill, shares);
        uint256 basis = fill == shares ? r.basis : uint256(r.basis).mulDiv(fill, shares);
        uint256 gross;
        uint256 penalty;
        (payout, gross, penalty) = _quote(fill, reqAssets, basis, r.stressedAtRequest);
        if (payout > budget) payout = budget;
        uint256 forfeit = gross - payout;

        _accrueBonus();
        _burn(address(this), fill);
        if (forfeit > 0) {
            bonusPot += forfeit;
            emit BonusPotFunded(address(this), forfeit);
        }
        reservedForClaims += payout;
        address controller = r.controller;
        claimableShares[controller] += fill;
        claimableAssets[controller] += payout;

        r.shares = (shares - fill).toUint128();
        r.basis -= basis.toUint128();
        r.assetsAtRequest -= reqAssets.toUint128();
        r.filledShares += fill.toUint128();
        if (fill == shares) r.status = RequestStatus.FULFILLED;
        pendingRedeemAssets -= reqAssets;
        totalPendingShares -= fill;

        emit RedeemFulfilled(id, controller, fill, payout, forfeit, penalty);
    }

    /// @dev Exit pricing. Queued shares stop earning (capped at their value when requested); a stressed request
    ///      also forfeits `exitPenaltyBps` of the yield earned before it; the penalty never cuts into principal.
    function _quote(uint256 shares, uint256 assetsAtRequest, uint256 basis, bool stressed)
        internal
        view
        returns (uint256 payout, uint256 gross, uint256 penalty)
    {
        gross = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 capped = Math.min(gross, assetsAtRequest);
        if (stressed && assetsAtRequest > basis) penalty = (assetsAtRequest - basis).mulDiv(exitPenaltyBps, BPS);
        payout = capped > penalty ? capped - penalty : 0;
        uint256 principalFloor = Math.min(basis, capped);
        if (payout < principalFloor) payout = principalFloor;
        penalty = capped - payout;
    }

    function _claim(address controller, address receiver, uint256 assets, uint256 shares) internal {
        claimableShares[controller] -= shares;
        claimableAssets[controller] -= assets;
        reservedForClaims -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _closeTicket(BonusTicket storage t) internal returns (uint256 reward) {
        _accrueBonus();
        uint256 weight = t.weight;
        reward = weight.mulDiv(accBonusPerWeight, 1e18) - t.rewardDebt;
        // Per-ticket floor rounding can exceed the emitted total by at most 1 wei per ticket.
        if (reward > bonusAccrued) reward = bonusAccrued;
        totalTicketWeight -= weight;
        t.active = false;
        address owner = t.owner;
        costBasis[owner] += t.basis;
        _transfer(address(this), owner, t.shares);
    }

    /// @dev Emission since the last update: the pot streams at `bonusPot / bonusEmissionPeriod` per second, capped at
    ///      `maxBonusAprBps` on the ticket weight. Nothing is emitted while no ticket is active.
    function _pendingEmission() internal view returns (uint256 increment, uint256 emitted) {
        uint256 weight = totalTicketWeight;
        uint256 pot = bonusPot;
        uint256 dt = block.timestamp - lastBonusUpdate;
        if (weight == 0 || pot == 0 || dt == 0) return (0, 0);
        uint256 period = bonusEmissionPeriod;
        uint256 stream = dt >= period ? pot : pot.mulDiv(dt, period);
        uint256 cap = weight.mulDiv(maxBonusAprBps * dt, BPS * 365 days);
        increment = Math.min(stream, cap).mulDiv(1e18, weight);
        emitted = increment.mulDiv(weight, 1e18, Math.Rounding.Ceil);
        if (emitted > pot) emitted = pot;
    }

    function _accrueBonus() internal {
        (uint256 increment, uint256 emitted) = _pendingEmission();
        lastBonusUpdate = block.timestamp;
        if (increment == 0) return;
        accBonusPerWeight += increment;
        bonusPot -= emitted;
        bonusAccrued += emitted;
    }
}
