// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title InsuranceReserve
/// @notice First-loss bad-debt backstop plus an operations treasury, tracked as two buckets over one USDC balance.
contract InsuranceReserve is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public positionManager;

    /// @notice Liquidation penalties, 20% of rollover fees, 50% of the treasury profit cut, donations.
    uint256 public insurancePoolBalance;
    /// @notice Other 50% of the treasury profit cut; withdrawable by governance.
    uint256 public opsTreasuryBalance;

    event PositionManagerSet(address indexed positionManager);
    event Funded(uint256 toInsurance, uint256 toOps);
    event Donated(address indexed from, uint256 amount);
    event ShortfallCovered(uint256 deficit, uint256 covered);
    event OpsWithdrawn(address indexed to, uint256 amount);

    error OnlyPositionManager();
    error AlreadySet();
    error ZeroAddress();
    error InsufficientOpsBalance();

    constructor(IERC20 usdc_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert OnlyPositionManager();
        _;
    }

    /// @notice One-time wiring. Immutable afterwards so the backstop cannot be redirected.
    function setPositionManager(address pm) external onlyOwner {
        if (positionManager != address(0)) revert AlreadySet();
        if (pm == address(0)) revert ZeroAddress();
        positionManager = pm;
        emit PositionManagerSet(pm);
    }

    /// @notice Pulls `toInsurance + treasuryCut` from the PositionManager. Treasury cut is split 50/50.
    function fund(uint256 toInsurance, uint256 treasuryCut) external onlyPositionManager {
        uint256 total = toInsurance + treasuryCut;
        if (total == 0) return;
        usdc.safeTransferFrom(msg.sender, address(this), total);
        uint256 opsCut = treasuryCut / 2;
        insurancePoolBalance += total - opsCut;
        opsTreasuryBalance += opsCut;
        emit Funded(total - opsCut, opsCut);
    }

    /// @notice Anyone may seed the first-loss pool.
    function donate(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        insurancePoolBalance += amount;
        emit Donated(msg.sender, amount);
    }

    /// @notice Covers up to `deficit` from the insurance bucket, sending USDC to the PositionManager.
    function coverShortfall(uint256 deficit) external onlyPositionManager returns (uint256 covered) {
        uint256 bal = insurancePoolBalance;
        covered = deficit < bal ? deficit : bal;
        if (covered == 0) return 0;
        insurancePoolBalance = bal - covered;
        usdc.safeTransfer(msg.sender, covered);
        emit ShortfallCovered(deficit, covered);
    }

    function withdrawOps(address to, uint256 amount) external onlyOwner {
        if (amount > opsTreasuryBalance) revert InsufficientOpsBalance();
        opsTreasuryBalance -= amount;
        usdc.safeTransfer(to, amount);
        emit OpsWithdrawn(to, amount);
    }
}
