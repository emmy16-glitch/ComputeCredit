// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVaultView {
    function activeAdvanceId(address borrower) external view returns (uint256);
    function lienTarget(address borrower) external view returns (uint256);
    function lienCaptured(address borrower) external view returns (uint256);
}

/// @title RwaCollateral
/// @notice OKX Dev Day "Build a Market" RWA integration: borrowers lock
/// tokenized-stock (xStock) as soft collateral. Locked value boosts the
/// vault's effective advance limit (tier + min(value, cap)).
/// @dev Mock oracle: owner sets stockPriceUSDC (6-decimal USDC per whole 1e18 stock).
/// Locks are blocked from withdrawal while an advance is active or a lien is open.
contract RwaCollateral is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable xstock;
    address public vault; // ComputeCreditVault (view only: activeAdvanceId + lien)
    uint256 public stockPriceUSDC = 10_000_000; // 10 USDC per whole stock (6 decimals)

    mapping(address borrower => uint256) public locked; // 18-dec stock base units

    event StockLocked(address indexed borrower, uint256 amount, uint256 totalLocked);
    event StockUnlocked(address indexed borrower, uint256 amount, uint256 totalLocked);
    event VaultSet(address indexed vault);
    event StockPriceSet(uint256 priceUSDC);

    error ZeroAmount();
    error ZeroAddress();
    error PositionLocked(); // active advance or open lien
    error InsufficientLocked(uint256 have, uint256 want);

    constructor(address xstock_, address owner_) Ownable(owner_) {
        if (xstock_ == address(0)) revert ZeroAddress();
        xstock = IERC20(xstock_);
    }

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function setStockPriceUSDC(uint256 priceUSDC_) external onlyOwner {
        if (priceUSDC_ == 0) revert ZeroAmount();
        stockPriceUSDC = priceUSDC_;
        emit StockPriceSet(priceUSDC_);
    }

    function lock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        xstock.safeTransferFrom(msg.sender, address(this), amount);
        locked[msg.sender] += amount;
        emit StockLocked(msg.sender, amount, locked[msg.sender]);
    }

    function unlock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 have = locked[msg.sender];
        if (amount > have) revert InsufficientLocked(have, amount);
        if (vault != address(0)) {
            if (IVaultView(vault).activeAdvanceId(msg.sender) != 0) revert PositionLocked();
            uint256 target = IVaultView(vault).lienTarget(msg.sender);
            uint256 captured = IVaultView(vault).lienCaptured(msg.sender);
            if (target > captured) revert PositionLocked();
        }
        locked[msg.sender] = have - amount;
        xstock.safeTransfer(msg.sender, amount);
        emit StockUnlocked(msg.sender, amount, locked[msg.sender]);
    }

    /// @notice Locked value in 6-decimal USDC: locked(1e18) * price(1e6) / 1e18.
    function collateralValue(address borrower) public view returns (uint256) {
        return (locked[borrower] * stockPriceUSDC) / 1e18;
    }
}
