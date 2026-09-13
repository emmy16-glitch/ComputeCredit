// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ComputeCreditVault} from "./ComputeCreditVault.sol";

/// @title RevenueRouter
/// @notice Authorized split router: pulls buyer payment, services vault, forwards remainder.
/// @dev v3 notes:
///  - ONLY routePayment pulls payer funds; vault pulls from router (two-step atomic).
///  - Normal advances: servicingAmount = payment * splitBps / 10_000.
///  - Defaulted borrowers (lien active): capture = payment * lienCaptureBps / 10_000,
///    capped by vault at remaining target; excess auto-forwarded to borrower.
///  - Router can NEVER mint scores, advances, or move lender funds — allowlisted only.
contract RevenueRouter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    ComputeCreditVault public immutable vault;
    IERC20 public immutable usdc;

    event PaymentRouted(
        address indexed payer,
        address indexed borrower,
        uint256 payment,
        uint256 toVault,
        uint256 toBorrower,
        bool lienPath
    );

    error ZeroAmount();
    error ZeroAddress();

    constructor(ComputeCreditVault vault_, address owner_) Ownable(owner_) {
        vault = vault_;
        usdc = IERC20(vault_.asset());
    }

    /// @notice Route a buyer payment for `borrower`. Caller (payer) must approve router first.
    /// @param borrower agent whose advance/lien is serviced
    /// @param amount full buyer payment (base units)
    /// @param borrowerDestination where the remainder goes (borrower wallet)
    function routePayment(address borrower, uint256 amount, address borrowerDestination)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 toVault, uint256 toBorrower)
    {
        if (amount == 0) revert ZeroAmount();
        if (borrower == address(0) || borrowerDestination == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Lien path takes precedence over normal servicing.
        uint256 lienRem = vault.lienRemaining(borrower);
        if (lienRem > 0) {
            uint256 lienBps = vault.lienCaptureBps();
            uint256 want = (amount * lienBps) / 10_000;
            if (want > amount) want = amount;
            toVault = 0;
            if (want > 0) {
                usdc.approve(address(vault), want);
                toVault = vault.captureLienWithTransfer(borrower, want);
                // capture may be capped below `want` if target nearly cleared:
                // refund uncaptured portion to remainder math via balance diff.
                uint256 routerBal = usdc.balanceOf(address(this));
                // routerBal = amount - toVault at this point
                toBorrower = routerBal;
                usdc.approve(address(vault), 0);
            } else {
                toBorrower = amount;
            }
            if (toBorrower > 0) usdc.safeTransfer(borrowerDestination, toBorrower);
            emit PaymentRouted(msg.sender, borrower, amount, toVault, toBorrower, true);
            return (toVault, toBorrower);
        }

        // Normal path: service active advance pro-rata, forward rest.
        uint256 activeId = vault.activeAdvanceId(borrower);
        if (activeId != 0) {
            uint256 splitBps = vault.splitBpsOf(activeId);
            uint256 remaining = vault.remainingOf(activeId);
            uint256 want = (amount * splitBps) / 10_000;
            if (want > remaining) want = remaining;
            toVault = want;
            if (want > 0) {
                usdc.approve(address(vault), want);
                vault.serviceAdvanceWithTransfer(borrower, want);
                usdc.approve(address(vault), 0);
            }
        }
        toBorrower = amount - toVault;
        if (toBorrower > 0) usdc.safeTransfer(borrowerDestination, toBorrower);
        emit PaymentRouted(msg.sender, borrower, amount, toVault, toBorrower, false);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
