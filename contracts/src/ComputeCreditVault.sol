// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { TrustPassport } from "./TrustPassport.sol";
import { ProviderRegistry } from "./ProviderRegistry.sol";

/**
 * @title ComputeCreditVault
 * @notice Lender-funded pool that issues one-job compute advances and services them from
 *         routed agent revenue.
 *
 * Spec reference: ComputeCredit_v2.pdf §4 (Economic model), §5 (Contract specifications),
 *                 §10 (Security model).
 *
 * The vault is the single source of truth for principal accounting:
 *   - `totalShares` / `shares[lender]`      proportional ownership of idle pool assets;
 *   - `totalOutstanding`                    sum of unserviced principal across active,
 *                                           non-defaulted advances;
 *   - `advances[borrower].serviced`         non-decreasing, always `<= principal`.
 *
 * Accounting rules implemented exactly (spec §4.3):
 *   create    : totalOutstanding += principal
 *   service   : totalOutstanding -= amount                       (once, never twice)
 *   default   : shortfall = principal - serviced; totalOutstanding -= shortfall
 *   settlement: no second principal subtraction
 *
 * Deliberate MVP trust assumptions (spec §3.1) are documented in README.md and docs/THREAT_MODEL.md.
 */
contract ComputeCreditVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice One-job advance record (spec §5.1 — field-for-field).
    struct ComputeAdvance {
        uint256 principal;
        uint256 serviced;
        uint256 issuedAt;
        uint256 dueAt;
        uint256 splitBps;
        bytes32 jobHash;
        address borrower;
        address provider;
        address revenueSource;
        bool settled;
        bool defaulted;
    }

    /// @notice Aggregate read model for routers, the orchestrator, the bot and the dashboard.
    struct AdvanceView {
        uint256 principal;
        uint256 serviced;
        uint256 remaining;
        uint256 issuedAt;
        uint256 dueAt;
        uint256 splitBps;
        bytes32 jobHash;
        address borrower;
        address provider;
        address revenueSource;
        bool settled;
        bool defaulted;
        bool active;
        bool expired;
        uint256 lienTarget;
        uint256 lienCaptured;
        uint256 revenueLienBps;
    }

    // ---------------------------------------------------------------------
    // Immutables and constants (spec §5.1)
    // ---------------------------------------------------------------------

    /// @notice Settlement token. Validated at construction (address, code, 6 decimals).
    IERC20 public immutable usdc;
    /// @notice Reputation registry; the only contract allowed to mutate scores/liens.
    TrustPassport public immutable passport;
    /// @notice Provider price + identity registry; prevents caller-supplied inflated quotes.
    ProviderRegistry public immutable providers;

    /// @notice Minimum lender deposit (1 USDC at 6 decimals).
    uint256 public constant MIN_DEPOSIT = 1e6;
    /// @notice Basis-point denominator.
    uint256 public constant MAX_BPS = 10_000;
    /// @notice Lien objective multiplier on default: shortfall * 1.5 (spec §4.4, §5.8).
    uint256 public constant DEFAULT_MULTIPLIER_BPS = 15_000;
    /// @notice Default revenue split servicing an active advance (spec §5.1: 20%).
    uint256 public constant NORMAL_SPLIT_BPS = 2_000;
    /// @notice Advance window: a request is due 12 hours after issuance (spec §5.1).
    uint256 public constant ADVANCE_WINDOW = 43_200;
    /// @notice Score scale denominator: the score is defined on a 0..1000 scale.
    uint256 public constant SCORE_GRANULARITY = 1_000;
    /// @notice Expected USDC decimals; misconfigured decimals are a named threat (spec §10.2).
    uint8 public constant EXPECTED_TOKEN_DECIMALS = 6;

    // ---------------------------------------------------------------------
    // Pool state
    // ---------------------------------------------------------------------

    /// @notice Total pool shares outstanding (spec §4.1).
    uint256 public totalShares;
    /// @notice Sum of unserviced principal across active, non-defaulted advances.
    uint256 public totalOutstanding;
    /// @notice Lender address => pool shares.
    mapping(address => uint256) public shares;

    /// @notice Borrower => active/latest advance (spec §5.1). History lives in events and in
    ///         `advanceHistory` so a settled or defaulted record is never lost by overwrite.
    mapping(address => ComputeAdvance) public advances;

    /// @notice Approved revenue routers (explicit administrator-controlled allowlist, spec §8.3).
    mapping(address => bool) public approvedRouters;
    /// @notice Approved operators (orchestrators) allowed to request advances for borrowers.
    mapping(address => bool) public approvedOperators;
    /// @notice Approved revenue sources; a payment path is only usable once allowlisted.
    mapping(address => bool) public approvedRevenueSources;
    /// @notice Borrower => registered revenue source (the only path that services the advance).
    mapping(address => address) public registeredRevenueSource;
    /// @notice Borrower => isolated spending destination for advanced funds.
    mapping(address => address) public spendingDestination;
    /// @notice Borrower => requester => authorisation to request an advance on the borrower's behalf.
    mapping(address => mapping(address => bool)) public requestAuthorizations;
    /// @notice jobHash => used (duplicate job binding protection, spec §5.5 check 9).
    mapping(bytes32 => bool) public usedJobHash;
    /// @notice Append-only advance history per borrower (for `/history` and the dashboard).
    mapping(address => ComputeAdvance[]) private _advanceHistory;
    /// @notice Number of currently active (issued, not settled, not defaulted) advances.
    uint256 public activeAdvanceCount;

    // Reporting counters (monotonic; used by the dashboard, never by accounting logic)
    uint256 public totalIssued;
    uint256 public totalServiced;
    uint256 public totalShortfall;
    uint256 public totalLienCaptured;

    // ---------------------------------------------------------------------
    // Events (every state transition, spec §10.1)
    // ---------------------------------------------------------------------

    event LiquidityDeposited(address indexed lender, uint256 amount, uint256 sharesMinted);
    event LiquidityWithdrawn(address indexed lender, uint256 amount, uint256 sharesBurned);
    event AdvanceRequested(
        address indexed borrower,
        address indexed provider,
        uint256 principal,
        bytes32 indexed jobHash,
        address revenueSource,
        address payoutDestination,
        uint256 dueAt,
        uint256 splitBps
    );
    event RevenueSourceRegistered(address indexed borrower, address indexed revenueSource);
    event SpendingDestinationUpdated(address indexed borrower, address indexed destination);
    event RequesterAuthorized(address indexed borrower, address indexed requester, bool authorized);
    event AdvanceServiced(address indexed borrower, uint256 amount, uint256 serviced, uint256 remaining, bool settled);
    event AdvanceSettled(address indexed borrower, uint256 principal, uint256 scoreAfterwards);
    event AdvanceRepaidEarly(address indexed borrower, uint256 amount, uint256 remaining, bool settled);
    event AdvanceDefaulted(address indexed borrower, uint256 shortfall, uint256 lienTarget, uint256 dueAt);
    event LienCaptured(address indexed borrower, uint256 captured, uint256 remainder, uint256 lienCaptured, uint256 lienTarget, bool cleared);
    event RouterApprovalUpdated(address indexed router, bool approved);
    event OperatorApprovalUpdated(address indexed operator, bool approved);
    event RevenueSourceApprovalUpdated(address indexed revenueSource, bool approved);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidToken(address token);
    error InvalidTokenDecimals(uint8 actual, uint8 expected);
    error DepositBelowMinimum(uint256 amount, uint256 minimum);
    error PoolInsolvent();
    error ZeroShares();
    error NoShares();
    error ZeroAmount();
    error NotAuthorizedRequester(address caller, address borrower);
    error ActiveAdvanceExists(address borrower);
    error NoActiveAdvance(address borrower);
    error AdvanceClosed(address borrower);
    error ProviderNotActive(address provider);
    error AdvanceAboveProviderPrice(uint256 requested, uint256 registeredPrice);
    error AdvanceAboveScoreTier(uint256 requested, uint256 tierLimit);
    error RevenueSourceNotApproved(address revenueSource);
    error RevenueSourceMismatch(address registered, address provided);
    error RevenueSourceLocked(address borrower);
    error InsufficientIdleLiquidity(uint256 requested, uint256 available);
    error JobHashAlreadyUsed(bytes32 jobHash);
    error ZeroJobHash();
    error NotApprovedRouter(address caller);
    error NotApprovedOperator(address caller);
    error ServicingExceedsRemaining(uint256 amount, uint256 remaining);
    error NotExpired(uint256 dueAt);
    error AlreadyDefaulted(address borrower);
    error NoOutstandingLien(address borrower);
    error PayoutDestinationIsContract(address destination);
    error WithdrawExceedsIdleShare(uint256 requested, uint256 maxWithdrawable);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /**
     * @param usdc_      USDC (or the configured demo settlement token).
     * @param passport_  TrustPassport instance (vault binding is completed by `passport.setVault`).
     * @param providers_ ProviderRegistry instance.
     * @param owner_     Vault administrator (roles, router allowlist, pause).
     */
    constructor(IERC20 usdc_, TrustPassport passport_, ProviderRegistry providers_, address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (address(passport_) == address(0) || address(providers_) == address(0)) revert ZeroAddress();
        _validateToken(address(usdc_));
        usdc = usdc_;
        passport = passport_;
        providers = providers_;
    }

    /// @dev Explicit token validation: non-zero, deployed code, and the expected decimals.
    function _validateToken(address token) private view {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert InvalidToken(token);
        try IERC20Metadata(token).decimals() returns (uint8 actual) {
            if (actual != EXPECTED_TOKEN_DECIMALS) revert InvalidTokenDecimals(actual, EXPECTED_TOKEN_DECIMALS);
        } catch {
            revert InvalidToken(token);
        }
    }

    // ---------------------------------------------------------------------
    // Administration (spec §8.3, §10.1)
    // ---------------------------------------------------------------------

    /// @notice Allowlist a revenue router (the only caller able to service or capture liens).
    function setApprovedRouter(address router, bool approved) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        approvedRouters[router] = approved;
        emit RouterApprovalUpdated(router, approved);
    }

    /// @notice Allowlist an operator (orchestrator) allowed to request advances for borrowers.
    function setApprovedOperator(address operator, bool approved) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        approvedOperators[operator] = approved;
        emit OperatorApprovalUpdated(operator, approved);
    }

    /// @notice Allowlist a revenue source shared by router-controlled flows.
    function setApprovedRevenueSource(address source, bool approved) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        approvedRevenueSources[source] = approved;
        emit RevenueSourceApprovalUpdated(source, approved);
    }

    /// @notice Pause token-moving entrypoints. `penalize` stays permissionless on purpose.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause token-moving entrypoints.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Lender side: deposits, shares, withdrawals (spec §4.1, §4.2, §5.3, §5.4)
    // ---------------------------------------------------------------------

    /// @notice Idle (immediately withdrawable) USDC held by the vault.
    /// @dev Spec §4.1: `withdrawableAssets = vault USDC balance`. Outstanding advances are
    ///      reported as receivables but are NOT assumed to be liquid.
    function idleAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Deposit USDC and receive proportional pool shares.
     * @dev Share issuance (spec §4.2):
     *        - S == 0            -> shares = amount (1:1 bootstrap)
     *        - S > 0, A > 0      -> shares = amount * S / A   (rounded DOWN: protects existing holders)
     *        - S > 0, A == 0     -> revert PoolInsolvent (pool has no assets to price against)
     */
    function depositLiquidity(uint256 amount) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        if (amount < MIN_DEPOSIT) revert DepositBelowMinimum(amount, MIN_DEPOSIT);

        uint256 supply = totalShares;
        uint256 assets = idleAssets(); // pre-transfer idle balance prices the deposit

        if (supply == 0) {
            sharesMinted = amount;
        } else {
            if (assets == 0) revert PoolInsolvent();
            sharesMinted = Math.mulDiv(amount, supply, assets);
            if (sharesMinted == 0) revert ZeroShares();
        }

        shares[msg.sender] += sharesMinted;
        totalShares = supply + sharesMinted;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit LiquidityDeposited(msg.sender, amount, sharesMinted);
    }

    /**
     * @notice Withdraw idle USDC by burning shares.
     * @dev Spec §5.4: the cap is the caller's proportional claim on *idle* assets —
     *      `amount <= idleAssets * callerShares / totalShares`. `totalDeposits - totalOutstanding`
     *      is deliberately NOT used: it does not model share ownership or repayments.
     *
     *      Rounding rule (spec §4.2: "must round in the direction that protects remaining
     *      shareholders"): shares burned are rounded UP, while the caller's cap is rounded DOWN.
     *      Deposits mint shares rounded DOWN. Both directions favour the pool.
     */
    function withdrawLiquidity(uint256 amount) external nonReentrant whenNotPaused returns (uint256 sharesBurned) {
        if (amount == 0) revert ZeroAmount();

        uint256 supply = totalShares;
        uint256 callerShares = shares[msg.sender];
        if (supply == 0 || callerShares == 0) revert NoShares();

        uint256 assets = idleAssets();
        uint256 callerMax = Math.mulDiv(assets, callerShares, supply);
        if (amount > callerMax) revert WithdrawExceedsIdleShare(amount, callerMax);

        // Round up so that the remaining shareholders are not diluted by the exit.
        sharesBurned = Math.mulDiv(amount, supply, assets, Math.Rounding.Ceil);
        if (sharesBurned > callerShares) sharesBurned = callerShares;

        shares[msg.sender] = callerShares - sharesBurned;
        totalShares = supply - sharesBurned;

        usdc.safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, amount, sharesBurned);
    }

    /// @notice Maximum amount the given lender can withdraw right now.
    function maxWithdrawable(address lender) external view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return 0;
        return Math.mulDiv(idleAssets(), shares[lender], supply);
    }

    // ---------------------------------------------------------------------
    // Borrower side: registration of the revenue route (spec §5.5, §10.1)
    // ---------------------------------------------------------------------

    /**
     * @notice Register the revenue source that services this borrower's advance.
     * @dev Callable by the borrower or an approved operator. Changing the source while an
     *      advance is active is rejected (spec §10.1: "protection against changing the revenue
     *      source while an advance is active").
     */
    function registerRevenueSource(address borrower, address revenueSource) external whenNotPaused {
        if (msg.sender != borrower && !approvedOperators[msg.sender] && msg.sender != owner()) {
            revert NotApprovedOperator(msg.sender);
        }
        if (revenueSource == address(0)) revert ZeroAddress();
        if (!approvedRevenueSources[revenueSource]) revert RevenueSourceNotApproved(revenueSource);

        address current = registeredRevenueSource[borrower];
        if (current != address(0) && current != revenueSource && _isActive(borrower)) {
            revert RevenueSourceLocked(borrower);
        }

        registeredRevenueSource[borrower] = revenueSource;
        emit RevenueSourceRegistered(borrower, revenueSource);
    }

    /// @notice Set the isolated spending destination that receives advanced funds.
    function setSpendingDestination(address borrower, address destination) external whenNotPaused {
        if (msg.sender != borrower && !approvedOperators[msg.sender] && msg.sender != owner()) {
            revert NotApprovedOperator(msg.sender);
        }
        if (destination == address(0)) revert ZeroAddress();
        spendingDestination[borrower] = destination;
        emit SpendingDestinationUpdated(borrower, destination);
    }

    /// @notice Authorise (or revoke) a requester to open advances for the caller.
    function authorizeRequester(address requester, bool authorized) external whenNotPaused {
        if (requester == address(0)) revert ZeroAddress();
        requestAuthorizations[msg.sender][requester] = authorized;
        emit RequesterAuthorized(msg.sender, requester, authorized);
    }

    /// @notice Is `caller` allowed to request an advance for `borrower`?
    function isAuthorizedRequester(address borrower, address caller) public view returns (bool) {
        return caller == borrower || approvedOperators[caller] || requestAuthorizations[borrower][caller];
    }

    /// @notice Address that receives advanced funds and borrower revenue.
    function payoutDestination(address borrower) public view returns (address) {
        address destination = spendingDestination[borrower];
        return destination == address(0) ? borrower : destination;
    }

    // ---------------------------------------------------------------------
    // Advance lifecycle (spec §5.5)
    // ---------------------------------------------------------------------

    /**
     * @notice Borrower self-service advance request.
     */
    function requestComputeAdvance(address provider, uint256 computeCost, bytes32 jobHash, address revenueSource)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 dueAt)
    {
        return _requestComputeAdvance(msg.sender, provider, computeCost, jobHash, revenueSource);
    }

    /**
     * @notice Operator-assisted, borrower-specific advance request (recommended MVP interface, §5.5).
     * @dev The nine checks of spec §5.5 are enforced in `_requestComputeAdvance`. Offchain
     *      orchestrator checks are for user experience only; these onchain checks are the authority.
     */
    function requestComputeAdvanceFor(
        address borrower,
        address provider,
        uint256 computeCost,
        bytes32 jobHash,
        address revenueSource
    ) external whenNotPaused nonReentrant returns (uint256 dueAt) {
        return _requestComputeAdvance(borrower, provider, computeCost, jobHash, revenueSource);
    }

    function _requestComputeAdvance(
        address borrower,
        address provider,
        uint256 computeCost,
        bytes32 jobHash,
        address revenueSource
    ) private returns (uint256 dueAt) {
        // (1) caller is an approved operator, an authorised requester, or the borrower.
        if (!isAuthorizedRequester(borrower, msg.sender)) revert NotAuthorizedRequester(msg.sender, borrower);
        if (borrower == address(0) || provider == address(0)) revert ZeroAddress();
        if (jobHash == bytes32(0)) revert ZeroJobHash();

        // (2) one active advance per borrower.
        if (_isActive(borrower)) revert ActiveAdvanceExists(borrower);
        // (2b) an unpaid lien must be cleared (or rehabilitated) before new credit (spec §5.9).
        if (passport.isLienActive(borrower)) revert NoOutstandingLien(borrower);

        // (3) provider is active in the registry.
        if (!providers.isActive(provider)) revert ProviderNotActive(provider);

        // (4) computeCost is non-zero and no greater than the provider's registered price.
        if (computeCost == 0) revert ZeroAmount();
        uint256 registeredPrice = providers.pricePerJob(provider);
        if (computeCost > registeredPrice) revert AdvanceAboveProviderPrice(computeCost, registeredPrice);

        // (5) computeCost is no greater than the borrower's score tier limit.
        uint256 tierLimit = passport.maxAdvance(borrower);
        if (computeCost > tierLimit) revert AdvanceAboveScoreTier(computeCost, tierLimit);

        // (6) revenueSource is registered for the borrower or is an approved router-controlled source.
        _resolveRevenueSource(borrower, revenueSource);

        // (7) the pool has sufficient idle liquidity.
        uint256 idle = idleAssets();
        if (computeCost > idle) revert InsufficientIdleLiquidity(computeCost, idle);

        // (9) jobHash has not already been used for an advance.
        if (usedJobHash[jobHash]) revert JobHashAlreadyUsed(jobHash);

        // ---- effects ----
        usedJobHash[jobHash] = true;
        dueAt = block.timestamp + ADVANCE_WINDOW;
        address destination = payoutDestination(borrower);

        ComputeAdvance memory record = ComputeAdvance({
            principal: computeCost,
            serviced: 0,
            issuedAt: block.timestamp,
            dueAt: dueAt,
            splitBps: NORMAL_SPLIT_BPS,
            jobHash: jobHash,
            borrower: borrower,
            provider: provider,
            revenueSource: revenueSource,
            settled: false,
            defaulted: false
        });

        advances[borrower] = record;
        _advanceHistory[borrower].push(record);
        activeAdvanceCount += 1;
        totalIssued += computeCost;

        // Exact accounting: outstanding principal increases by exactly the principal.
        totalOutstanding += computeCost;

        // ---- interaction ----
        usdc.safeTransfer(destination, computeCost);

        emit AdvanceRequested(
            borrower, provider, computeCost, jobHash, revenueSource, destination, dueAt, NORMAL_SPLIT_BPS
        );
    }

    /// @dev Check 6 of §5.5. The first registration is recorded; later requests must match it.
    function _resolveRevenueSource(address borrower, address revenueSource) private {
        if (revenueSource == address(0)) revert ZeroAddress();
        if (!approvedRevenueSources[revenueSource]) revert RevenueSourceNotApproved(revenueSource);

        address current = registeredRevenueSource[borrower];
        if (current == address(0)) {
            registeredRevenueSource[borrower] = revenueSource;
            emit RevenueSourceRegistered(borrower, revenueSource);
        } else if (current != revenueSource) {
            revert RevenueSourceMismatch(current, revenueSource);
        }
    }

    // ---------------------------------------------------------------------
    // Servicing and settlement (spec §5.6, §5.7)
    // ---------------------------------------------------------------------

    /**
     * @notice Service an active advance. Only an approved revenue router may call.
     * @dev Tokens are pulled from the router inside this call, so repayment can never be
     *      *recorded* without being *received* (spec §10.2: "Fake repayment record").
     *      After the pull the shared servicing path runs exactly once.
     */
    function serviceAdvance(address borrower, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyApprovedRouter
        returns (uint256 servicedAmount, bool settledNow)
    {
        return _serviceWithTransfer(borrower, amount);
    }

    /**
     * @notice Same as `serviceAdvance`, under the name recommended by spec §5.6
     *         ("A safer production interface is serviceAdvanceWithTransfer(...)").
     */
    function serviceAdvanceWithTransfer(address borrower, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyApprovedRouter
        returns (uint256 servicedAmount, bool settledNow)
    {
        return _serviceWithTransfer(borrower, amount);
    }

    function _serviceWithTransfer(address borrower, uint256 amount) private returns (uint256 servicedAmount, bool settledNow) {
        (uint256 remaining,) = _validateServicing(borrower, amount);

        // Interaction first on the money-in leg: the vault must actually receive the tokens
        // before it records the repayment. Accounting updates happen after the transfer, and
        // the whole call is protected by the reentrancy guard.
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        if (amount > remaining) revert ServicingExceedsRemaining(amount, remaining);

        return _applyServicing(borrower, amount);
    }

    /**
     * @notice Borrower (or approved operator) early repayment.
     * @dev Reuses the exact same servicing/settlement path as revenue repayment so score
     *      updates and outstanding accounting cannot diverge (spec §5.7).
     */
    function repayEarly(address borrower, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 servicedAmount, bool settledNow)
    {
        if (!isAuthorizedRequester(borrower, msg.sender)) revert NotAuthorizedRequester(msg.sender, borrower);
        _validateServicing(borrower, amount);

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        (servicedAmount, settledNow) = _applyServicing(borrower, amount);
        uint256 remaining = advances[borrower].principal - advances[borrower].serviced;
        emit AdvanceRepaidEarly(borrower, amount, remaining, settledNow);
    }

    /// @dev Shared validation for servicing / early repayment.
    function _validateServicing(address borrower, uint256 amount) private view returns (uint256 remaining, ComputeAdvance storage advance) {
        advance = advances[borrower];
        if (advance.principal == 0) revert NoActiveAdvance(borrower);
        // Post-closure state changes are rejected: no servicing after settlement or default.
        if (advance.settled || advance.defaulted) revert AdvanceClosed(borrower);
        if (amount == 0) revert ZeroAmount();
        remaining = advance.principal - advance.serviced;
        if (amount > remaining) revert ServicingExceedsRemaining(amount, remaining);
    }

    /**
     * @dev The single scoring/settlement path.
     *
     * Invariant protected here (spec §4.3): `totalOutstanding` is decremented by exactly the
     * serviced amount and NOTHING ELSE — settlement performs no second principal subtraction.
     */
    function _applyServicing(address borrower, uint256 amount) private returns (uint256 servicedAmount, bool settledNow) {
        ComputeAdvance storage advance = advances[borrower];
        if (advance.settled || advance.defaulted) revert AdvanceClosed(borrower);

        servicedAmount = amount;
        advance.serviced += amount;

        // Exact, single decrement of outstanding principal.
        totalOutstanding -= amount;
        totalServiced += amount;

        uint256 remaining = advance.principal - advance.serviced;
        if (remaining == 0) {
            advance.settled = true;
            settledNow = true;
            activeAdvanceCount -= 1;

            // Settlement bumps the score exactly once, capped at 1000 inside the passport.
            passport.increaseScore(borrower, passport.SETTLEMENT_SCORE_BUMP());

            emit AdvanceSettled(borrower, advance.principal, passport.score(borrower));
        }

        emit AdvanceServiced(borrower, amount, advance.serviced, remaining, settledNow);
    }

    // ---------------------------------------------------------------------
    // Default and conditional lien (spec §5.8, §5.9)
    // ---------------------------------------------------------------------

    /**
     * @notice Record a default after expiry. Permissionless: any keeper may call.
     * @dev No money moves here (spec §5.8: "The default function must not transfer additional
     *      money to the borrower or lender"). Recovery only happens when future revenue is
     *      captured through the registered route.
     */
    function penalize(address borrower) external returns (uint256 shortfall, uint256 lienTarget_) {
        ComputeAdvance storage advance = advances[borrower];
        if (advance.principal == 0) revert NoActiveAdvance(borrower);
        if (advance.settled || advance.defaulted) revert AdvanceClosed(borrower);
        if (block.timestamp <= advance.dueAt) revert NotExpired(advance.dueAt);

        shortfall = advance.principal - advance.serviced;
        if (shortfall == 0) revert AdvanceClosed(borrower);

        // The remaining unserviced principal leaves the outstanding-principal set exactly once.
        totalOutstanding -= shortfall;
        totalShortfall += shortfall;

        advance.defaulted = true;
        activeAdvanceCount -= 1;

        // Lien objective: shortfall * 15,000 / 10,000 (spec §5.8).
        lienTarget_ = Math.mulDiv(shortfall, DEFAULT_MULTIPLIER_BPS, MAX_BPS);
        passport.setLien(borrower, lienTarget_, MAX_BPS); // 100% capture rate on routed revenue

        // Deterministic demo penalty: full slash to zero (spec §7.5).
        passport.slashToZero(borrower, "default: advance expired without full servicing");

        emit AdvanceDefaulted(borrower, shortfall, lienTarget_, advance.dueAt);
    }

    /**
     * @notice Capture routed revenue against a defaulted borrower's lien.
     * @dev Only an approved router may call. The router transfers the routed payment to the
     *      vault inside this call; the vault credits `min(amount, remainingTarget)` and returns
     *      the excess to the router, which forwards it to the borrower's destination.
     *
     *      Lien capture can never exceed the target (spec §5.9), and clearing the lien resets
     *      `revenueLienBps` to zero.
     *
     * @return captured  Amount credited toward the lien objective.
     * @return remainder Amount returned to the caller for forwarding to the borrower.
     */
    function captureLien(address borrower, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyApprovedRouter
        returns (uint256 captured, uint256 remainder)
    {
        if (amount == 0) revert ZeroAmount();
        if (!passport.isLienActive(borrower)) revert NoOutstandingLien(borrower);

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        bool cleared;
        (captured, cleared) = passport.recordLienCapture(borrower, amount);
        remainder = amount - captured;
        totalLienCaptured += captured;

        if (remainder > 0) {
            // Excess above the target never stays in the vault: it is returned to the router
            // for forwarding to the borrower.
            usdc.safeTransfer(msg.sender, remainder);
        }

        emit LienCaptured(borrower, captured, remainder, passport.lienCaptured(borrower), passport.lienTarget(borrower), cleared);
    }

    // ---------------------------------------------------------------------
    // Views for routers, orchestrator, bot and dashboard
    // ---------------------------------------------------------------------

    function _isActive(address borrower) private view returns (bool) {
        ComputeAdvance storage advance = advances[borrower];
        return advance.principal > 0 && !advance.settled && !advance.defaulted;
    }

    /// @notice True while the borrower has an issued, unsettled, non-defaulted advance.
    function hasActiveAdvance(address borrower) external view returns (bool) {
        return _isActive(borrower);
    }

    /// @notice Unserviced principal of the active advance (0 when none).
    function remainingPrincipal(address borrower) external view returns (uint256) {
        ComputeAdvance storage advance = advances[borrower];
        if (advance.settled || advance.defaulted) return 0;
        return advance.principal - advance.serviced;
    }

    /// @notice Full read model for one borrower.
    function advanceView(address borrower) public view returns (AdvanceView memory view_) {
        ComputeAdvance storage advance = advances[borrower];
        bool active = _isActive(borrower);
        return AdvanceView({
            principal: advance.principal,
            serviced: advance.serviced,
            remaining: advance.settled || advance.defaulted ? 0 : advance.principal - advance.serviced,
            issuedAt: advance.issuedAt,
            dueAt: advance.dueAt,
            splitBps: advance.splitBps,
            jobHash: advance.jobHash,
            borrower: advance.borrower,
            provider: advance.provider,
            revenueSource: advance.revenueSource,
            settled: advance.settled,
            defaulted: advance.defaulted,
            active: active,
            expired: active && block.timestamp > advance.dueAt,
            lienTarget: passport.lienTarget(borrower),
            lienCaptured: passport.lienCaptured(borrower),
            revenueLienBps: passport.revenueLienBps(borrower)
        });
    }

    /// @notice Struct accessor for the latest/active advance of `borrower`.
    /// @dev `advances` is intentionally public to match the specification's state model, but a
    ///      public mapping of structs returns a tuple to external callers. This accessor returns
    ///      the named struct so routers, the orchestrator and the dashboard can read fields.
    function advanceOf(address borrower) external view returns (ComputeAdvance memory) {
        return advances[borrower];
    }

    /// @notice Number of advances ever opened for `borrower` (append-only history).
    function advanceHistoryCount(address borrower) external view returns (uint256) {
        return _advanceHistory[borrower].length;
    }

    /// @notice Historical advance record `index` for `borrower`.
    function advanceHistoryAt(address borrower, uint256 index) external view returns (ComputeAdvance memory) {
        return _advanceHistory[borrower][index];
    }

    /// @notice Outstanding principal as a fraction of pool assets (bps), for dashboards.
    /// @dev Utilization = totalOutstanding / (idleAssets + totalOutstanding). Reported only;
    ///      never used in accounting decisions.
    function utilizationBps() external view returns (uint256) {
        uint256 total = idleAssets() + totalOutstanding;
        if (total == 0) return 0;
        return Math.mulDiv(totalOutstanding, MAX_BPS, total);
    }

    /// @notice Score expressed on the 0..10000 reporting scale (dashboard progress bar).
    function creditQualityBps(address borrower) external view returns (uint256) {
        return Math.mulDiv(passport.score(borrower), MAX_BPS, SCORE_GRANULARITY);
    }

    /// @notice Idle USDC attributed to one lender's shares (excludes outstanding receivables).
    function idleClaimOf(address lender) external view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return 0;
        return Math.mulDiv(idleAssets(), shares[lender], supply);
    }

    modifier onlyApprovedRouter() {
        if (!approvedRouters[msg.sender]) revert NotApprovedRouter(msg.sender);
        _;
    }
}
