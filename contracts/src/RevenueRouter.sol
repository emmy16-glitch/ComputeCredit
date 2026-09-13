// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ComputeCreditVault } from "./ComputeCreditVault.sol";

/**
 * @title RevenueRouter
 * @notice Splits routed buyer revenue: services the borrower's advance (or captures an active
 *         lien) and forwards the remainder to the borrower.
 *
 * Spec reference: ComputeCredit_v2.pdf §8 (Revenue router), §5.9 (Lien capture), §10 (Security).
 *
 * Enforcement scope (stated honestly, spec §1.2 and §8.2):
 *   - The router is the enforcement point ONLY for payments that pass through the registered
 *     revenue source. It is not a universal lien-enforcement mechanism. Payments sent to
 *     unrelated wallets or marketplaces are not captured.
 *   - The router cannot alter scores, create advances, change provider quotes, withdraw lender
 *     funds, or change another borrower's revenue source. It can only call the vault's two
 *     router-gated accounting functions: `serviceAdvanceWithTransfer` and `captureLien`.
 *
 * Money flow is atomic inside a single call: the payment moves router -> vault (servicing or
 * lien capture) and router -> borrower in the same transaction. The router holds no balance
 * between calls.
 */
contract RevenueRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Settlement token; must match the vault's token.
    IERC20 public immutable usdc;
    /// @notice The vault whose advances this router is allowed to service.
    ComputeCreditVault public immutable vault;

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Running totals for auditability (reporting only; never used in accounting).
    uint256 public totalRoutedVolume;
    uint256 public totalServicedVolume;
    uint256 public totalLienCapturedVolume;

    /// @notice Read model describing how a payment would be split right now.
    struct RoutingPreview {
        uint256 serviceAmount;
        uint256 lienCaptureAmount;
        uint256 borrowerAmount;
        bool lienActive;
        bool advanceActive;
        address destination;
    }

    event PaymentRouted(
        address indexed payer,
        address indexed borrower,
        uint256 amount,
        uint256 serviced,
        uint256 lienCaptured,
        uint256 forwardedToBorrower,
        bytes32 indexed paymentRef
    );
    event AdvanceServicedViaRouter(address indexed borrower, uint256 amount, bool settled);
    event LienPaymentCapturedViaRouter(address indexed borrower, uint256 captured, uint256 remainder, bool cleared);
    event UnroutedPaymentForwarded(address indexed payer, address indexed borrower, uint256 amount, bytes32 indexed paymentRef);
    event PayerAllowlistUpdated(address indexed payer, bool allowed);
    event StrayTokensSwept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotRegisteredRevenueSource(address borrower, address caller);
    error PayerNotAllowed(address payer);
    error TokenMismatch(address provided, address expected);

    /**
     * @param usdc_  Settlement token (must equal `vault.usdc()`).
     * @param vault_ The vault allowlisted to this router.
     * @param owner_ Administrator able to pause and manage the demo payer allowlist.
     */
    constructor(IERC20 usdc_, ComputeCreditVault vault_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0) || address(vault_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (address(vault_.usdc()) != address(usdc_)) revert TokenMismatch(address(usdc_), address(vault_.usdc()));
        usdc = usdc_;
        vault = vault_;
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /// @notice Demo payer allowlist (buyers / facilitators allowed to push payments in).
    mapping(address => bool) public authorizedPayers;
    /// @notice Number of allowlisted payers; when 0 the router accepts any payer.
    uint256 public authorizedPayerCount;

    /// @notice Pause routing (emergency switch for a token-moving entrypoint).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume routing.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allowlist a demo payer / facilitator. Empty allowlist means "any payer".
    function setAuthorizedPayer(address payer, bool allowed) external onlyOwner {
        if (payer == address(0)) revert ZeroAddress();
        bool wasAllowed = authorizedPayers[payer];
        if (wasAllowed != allowed) {
            authorizedPayers[payer] = allowed;
            authorizedPayerCount = allowed ? authorizedPayerCount + 1 : authorizedPayerCount - 1;
        }
        emit PayerAllowlistUpdated(payer, allowed);
    }

    /// @notice Rescue tokens that were sent to the router outside `routePayment`.
    /// @dev The router never holds routed funds between calls, so this only ever touches stray
    ///      transfers. Vault funds are unreachable from here.
    function sweepStrayTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit StrayTokensSwept(token, to, amount);
    }

    // ---------------------------------------------------------------------
    // Routing
    // ---------------------------------------------------------------------

    /**
     * @notice Route a buyer payment for `borrower` through the registered revenue source.
     * @dev The payer must have approved this router for `amount`. The full payment is pulled in
     *      first, then split atomically:
     *        - active lien      -> up to 100% toward the lien target, excess to the borrower;
     *        - active advance   -> `splitBps` of the payment services the advance (capped at the
     *                              remaining principal), remainder to the borrower;
     *        - neither          -> 100% forwarded to the borrower (nothing is owed).
     *
     * @param borrower   The agent whose advance / lien this payment belongs to.
     * @param amount     Payment amount in token units (6 decimals for USDC).
     * @param paymentRef Offchain reference (buyer payment id / x402 receipt hash) for audit.
     * @return serviced          Amount applied to the active advance's principal.
     * @return lienCaptured      Amount credited toward an active lien.
     * @return forwardedToBorrower Amount forwarded to the borrower's payout destination.
     */
    function routePayment(address borrower, uint256 amount, bytes32 paymentRef)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 serviced, uint256 lienCaptured, uint256 forwardedToBorrower)
    {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (authorizedPayerCount > 0 && !authorizedPayers[msg.sender]) revert PayerNotAllowed(msg.sender);

        // The payment must arrive through the borrower's REGISTERED revenue source.
        if (vault.registeredRevenueSource(borrower) != address(this)) {
            revert NotRegisteredRevenueSource(borrower, msg.sender);
        }

        // Pull the whole payment in before any accounting happens.
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        ComputeCreditVault.AdvanceView memory view_ = vault.advanceView(borrower);
        uint256 toBorrower;
        bool cleared;

        if (view_.lienCaptured < view_.lienTarget) {
            // ---- defaulted servicing: 100% of routed revenue toward the lien target (spec §8.2)
            uint256 remainder;
            usdc.forceApprove(address(vault), amount);
            (lienCaptured, remainder) = vault.captureLien(borrower, amount);
            usdc.forceApprove(address(vault), 0);
            toBorrower = remainder;
            cleared = vault.passport().lienCaptured(borrower) >= view_.lienTarget;
            totalLienCapturedVolume += lienCaptured;
            emit LienPaymentCapturedViaRouter(borrower, lienCaptured, remainder, cleared);
        } else if (view_.active) {
            // ---- normal servicing: servicingAmount = payment * splitBps / 10,000 (spec §8.1)
            uint256 computed = Math.mulDiv(amount, view_.splitBps, MAX_BPS);
            serviced = computed > view_.remaining ? view_.remaining : computed;

            if (serviced > 0) {
                usdc.forceApprove(address(vault), serviced);
                (, bool settled) = vault.serviceAdvanceWithTransfer(borrower, serviced);
                usdc.forceApprove(address(vault), 0);
                totalServicedVolume += serviced;
                emit AdvanceServicedViaRouter(borrower, serviced, settled);
            }
            toBorrower = amount - serviced;
        } else {
            // ---- no obligation: forward the full payment
            toBorrower = amount;
            emit UnroutedPaymentForwarded(msg.sender, borrower, amount, paymentRef);
        }

        // Forward the borrower's remainder to the registered payout destination.
        forwardedToBorrower = toBorrower;
        if (toBorrower > 0) {
            usdc.safeTransfer(vault.payoutDestination(borrower), toBorrower);
        }

        totalRoutedVolume += amount;

        emit PaymentRouted(msg.sender, borrower, amount, serviced, lienCaptured, toBorrower, paymentRef);
    }

    /**
     * @notice Preview how `routePayment` would split `amount` for `borrower` right now.
     * @dev Read-only helper for the orchestrator, the Telegram bot and the dashboard. The
     *      onchain split inside `routePayment` remains the authority.
     */
    function previewRouting(address borrower, uint256 amount) external view returns (RoutingPreview memory preview) {
        ComputeCreditVault.AdvanceView memory view_ = vault.advanceView(borrower);
        preview.lienActive = view_.lienCaptured < view_.lienTarget;
        preview.advanceActive = view_.active;
        preview.destination = vault.payoutDestination(borrower);

        if (preview.lienActive) {
            uint256 remainingTarget = view_.lienTarget - view_.lienCaptured;
            preview.lienCaptureAmount = amount > remainingTarget ? remainingTarget : amount;
            preview.borrowerAmount = amount - preview.lienCaptureAmount;
        } else if (preview.advanceActive) {
            uint256 computed = Math.mulDiv(amount, view_.splitBps, MAX_BPS);
            preview.serviceAmount = computed > view_.remaining ? view_.remaining : computed;
            preview.borrowerAmount = amount - preview.serviceAmount;
        } else {
            preview.borrowerAmount = amount;
        }
    }
}
