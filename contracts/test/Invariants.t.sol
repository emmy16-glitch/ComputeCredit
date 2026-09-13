// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { MockUSDC } from "./mocks/MockUSDC.sol";
import { TrustPassport } from "../src/TrustPassport.sol";
import { ProviderRegistry } from "../src/ProviderRegistry.sol";
import { ComputeCreditVault } from "../src/ComputeCreditVault.sol";
import { RevenueRouter } from "../src/RevenueRouter.sol";

/**
 * @notice Stateful invariant tests over the whole advance lifecycle.
 *
 * Spec reference: ComputeCredit_v2.pdf §5.2 (Vault invariants), §10.3 (Core test invariants):
 *   serviced <= principal
 *   settled implies serviced == principal
 *   defaulted implies settled == false
 *   totalOutstanding equals the sum of remaining principal for active advances
 *   lienCaptured <= lienTarget
 *   cleared lien implies revenueLienBps == 0
 *   withdrawals cannot exceed idle liquidity
 *   one active advance per borrower
 */
contract InvariantsTest is Test {
    MockUSDC internal usdc;
    TrustPassport internal passport;
    ProviderRegistry internal providers;
    ComputeCreditVault internal vault;
    RevenueRouter internal router;
    VaultHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal attester = makeAddr("attester");
    address internal operator = makeAddr("operator");
    address internal provider = makeAddr("provider");
    address internal buyer = makeAddr("buyer");

    bytes32 internal constant SERVICE_ID = keccak256("haiku-v1");
    uint256 internal constant PROVIDER_PRICE = 20_000;
    uint256 internal constant ADVANCE_WINDOW = 43_200;

    function setUp() public {
        vm.warp(1_760_000_000);

        usdc = new MockUSDC();
        passport = new TrustPassport(attester, admin);
        providers = new ProviderRegistry(admin);
        vault = new ComputeCreditVault(usdc, passport, providers, admin);
        router = new RevenueRouter(usdc, vault, admin);

        vm.startPrank(admin);
        passport.setVault(address(vault));
        vault.setApprovedRouter(address(router), true);
        vault.setApprovedOperator(operator, true);
        vault.setApprovedRevenueSource(address(router), true);
        providers.registerProvider(provider, provider, PROVIDER_PRICE, SERVICE_ID);
        vm.stopPrank();

        handler = new VaultHandler(vault, router, usdc, passport, providers, operator, provider, buyer, attester);
        targetContract(address(handler));

        // Also exercise the vault directly with a bounded set of calls.
        excludeSender(address(handler));
    }

    // =====================================================================
    // Invariants (spec §5.2, §10.3)
    // =====================================================================

    /// @notice `serviced <= principal` for every borrower that ever received an advance.
    function invariant_servicedNeverExceedsPrincipal() public view {
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            address borrower = handler.borrowerAt(i);
            ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(borrower);
            assertLe(a.serviced, a.principal, "serviced must never exceed principal");
        }
    }

    /// @notice `totalOutstanding` equals the sum of unserviced principal of active advances.
    function invariant_totalOutstandingEqualsActiveRemainders() public view {
        uint256 expected;
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            address borrower = handler.borrowerAt(i);
            ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(borrower);
            bool active = a.principal > 0 && !a.settled && !a.defaulted;
            if (active) {
                expected += a.principal - a.serviced;
            }
        }
        assertEq(vault.totalOutstanding(), expected, "totalOutstanding must mirror active remainders");
    }

    /// @notice Settlement is only ever recorded when the principal is fully serviced.
    function invariant_settledImpliesFullyServiced() public view {
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(handler.borrowerAt(i));
            if (a.settled) {
                assertEq(a.serviced, a.principal, "settled implies serviced == principal");
                assertFalse(a.defaulted, "an advance can never be settled and defaulted");
            }
        }
    }

    /// @notice Default and settlement are mutually exclusive, and a defaulted advance never
    ///         returns to the outstanding set.
    function invariant_defaultedImpliesNotSettled() public view {
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(handler.borrowerAt(i));
            if (a.defaulted) {
                assertFalse(a.settled, "defaulted implies not settled");
            }
        }
    }

    /// @notice One active advance per borrower.
    function invariant_activeAdvanceCountMatchesBorrowers() public view {
        uint256 active;
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            if (vault.hasActiveAdvance(handler.borrowerAt(i))) active += 1;
        }
        assertEq(vault.activeAdvanceCount(), active, "active advance tally must match per-borrower state");
        assertLe(active, borrowers, "at most one active advance per borrower");
    }

    /// @notice Share accounting: individual shares always sum to `totalShares`.
    function invariant_sharesSumEqualsTotalShares() public view {
        uint256 sum;
        uint256 lenders = handler.lenderCount();
        for (uint256 i = 0; i < lenders; i++) {
            sum += vault.shares(handler.lenderAt(i));
        }
        assertEq(sum, vault.totalShares(), "sum of lender shares must equal totalShares");
    }

    /// @notice Lien capture never exceeds the lien target, and a cleared lien has a zero rate.
    function invariant_lienBoundedByTarget() public view {
        uint256 borrowers = handler.borrowerCount();
        for (uint256 i = 0; i < borrowers; i++) {
            address borrower = handler.borrowerAt(i);
            uint256 target = passport.lienTarget(borrower);
            uint256 captured = passport.lienCaptured(borrower);
            assertLe(captured, target, "lienCaptured must never exceed lienTarget");
            if (captured >= target) {
                assertEq(passport.revenueLienBps(borrower), 0, "cleared lien implies revenueLienBps == 0");
            }
        }
    }

    /// @notice The pool can never lend more principal than it has issued, and lender shares can
    ///         never be withdrawn beyond the idle balance.
    function invariant_poolAccountingStaysConsistent() public view {
        assertLe(vault.totalOutstanding(), vault.totalIssued(), "outstanding cannot exceed issued principal");
        assertLe(vault.totalServiced(), vault.totalIssued(), "serviced cannot exceed issued principal");
        assertGe(vault.idleAssets(), 0);

        uint256 lenders = handler.lenderCount();
        for (uint256 i = 0; i < lenders; i++) {
            address lender = handler.lenderAt(i);
            uint256 shares = vault.shares(lender);
            if (shares == 0) continue;
            // Proportional claim on idle assets must never exceed the idle balance itself.
            assertLe(vault.maxWithdrawable(lender), vault.idleAssets(), "idle claim cannot exceed idle assets");
        }
    }

    /// @notice The vault must never be left with fewer tokens than its idle accounting claims.
    function invariant_vaultHoldsItsIdleAssets() public view {
        assertEq(vault.idleAssets(), usdc.balanceOf(address(vault)), "idleAssets is the real token balance");
    }

    /// @notice Sanity: the handler actually exercised the lifecycle (guards against a vacuous run).
    function afterInvariant() public view {
        assertGt(handler.requestCount(), 0, "invariant run must open at least one advance");
    }
}

/**
 * @notice Bounded stateful fuzzing handler driving deposits, withdrawals, advance issuance,
 *         routed revenue, defaults and time.
 */
contract VaultHandler is Test {
    ComputeCreditVault public vault;
    RevenueRouter public router;
    MockUSDC public usdc;
    TrustPassport public passport;
    ProviderRegistry public providers;

    address public operator;
    address public provider;
    address public buyer;

    address[] private _borrowers;
    address[] private _lenders;

    uint256 public requestCount;
    uint256 public revenueCount;
    uint256 public withdrawCount;
    uint256 public penalizeCount;

    constructor(
        ComputeCreditVault vault_,
        RevenueRouter router_,
        MockUSDC usdc_,
        TrustPassport passport_,
        ProviderRegistry providers_,
        address operator_,
        address provider_,
        address buyer_,
        address attester_
    ) {
        vault = vault_;
        router = router_;
        usdc = usdc_;
        passport = passport_;
        providers = providers_;
        operator = operator_;
        provider = provider_;
        buyer = buyer_;

        _borrowers.push(makeAddr("borrowerA"));
        _borrowers.push(makeAddr("borrowerB"));
        _borrowers.push(makeAddr("borrowerC"));
        _lenders.push(makeAddr("lenderA"));
        _lenders.push(makeAddr("lenderB"));

        for (uint256 i = 0; i < _borrowers.length; i++) {
            address borrower = _borrowers[i];
            vm.prank(attester_);
            passport.seedScore(borrower, 150);
            // Register the router as the borrower's revenue source so routed payments are valid.
            vm.prank(operator_);
            vault.registerRevenueSource(borrower, address(router));
        }

        for (uint256 i = 0; i < _lenders.length; i++) {
            address lender = _lenders[i];
            usdc.mint(lender, 1_000e6);
            vm.prank(lender);
            usdc.approve(address(vault), type(uint256).max);
            // Seed the pool so advances have liquidity to draw on.
            vm.prank(lender);
            vault.depositLiquidity(50e6);
        }

        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Handler actions
    // ---------------------------------------------------------------------

    function deposit(uint256 lenderSeed, uint256 amountSeed) external {
        address lender = _lenders[lenderSeed % _lenders.length];
        uint256 amount = bound(amountSeed, vault.MIN_DEPOSIT(), 100e6);
        usdc.mint(lender, amount);

        vm.prank(lender);
        vault.depositLiquidity(amount);
    }

    function withdraw(uint256 lenderSeed, uint256 amountSeed) external {
        address lender = _lenders[lenderSeed % _lenders.length];
        uint256 max = vault.maxWithdrawable(lender);
        if (max == 0) return;

        uint256 amount = bound(amountSeed, 1, max);
        vm.prank(lender);
        vault.withdrawLiquidity(amount);
        withdrawCount += 1;
    }

    function requestAdvance(uint256 borrowerSeed, uint256 costSeed) external {
        address borrower = _borrowers[borrowerSeed % _borrowers.length];
        if (vault.hasActiveAdvance(borrower)) return;
        if (passport.isLienActive(borrower)) return;

        uint256 cap = providers.pricePerJob(provider);
        uint256 tierLimit = passport.maxAdvance(borrower);
        if (tierLimit < cap) cap = tierLimit;
        uint256 idle = vault.idleAssets();
        if (idle < cap) cap = idle;
        if (cap == 0) return;

        uint256 cost = bound(costSeed, 1, cap);
        bytes32 jobHash = keccak256(abi.encode("job", borrower, requestCount));
        requestCount += 1;

        vm.prank(operator);
        vault.requestComputeAdvanceFor(borrower, provider, cost, jobHash, address(router));
    }

    function payRevenue(uint256 borrowerSeed, uint256 amountSeed) external {
        address borrower = _borrowers[borrowerSeed % _borrowers.length];
        uint256 amount = bound(amountSeed, 1, 1_000_000);
        bytes32 paymentRef = keccak256(abi.encode("payment", revenueCount));
        revenueCount += 1;

        vm.prank(buyer);
        router.routePayment(borrower, amount, paymentRef);
    }

    function penalize(uint256 borrowerSeed) external {
        address borrower = _borrowers[borrowerSeed % _borrowers.length];
        if (!vault.hasActiveAdvance(borrower)) return;
        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(borrower);
        if (block.timestamp <= a.dueAt) return;

        vault.penalize(borrower);
        penalizeCount += 1;
    }

    function repayEarly(uint256 borrowerSeed, uint256 amountSeed) external {
        address borrower = _borrowers[borrowerSeed % _borrowers.length];
        if (!vault.hasActiveAdvance(borrower)) return;

        uint256 remaining = vault.remainingPrincipal(borrower);
        if (remaining == 0) return;
        uint256 amount = bound(amountSeed, 1, remaining);

        usdc.mint(borrower, amount);
        vm.prank(borrower);
        usdc.approve(address(vault), amount);
        vm.prank(borrower);
        vault.repayEarly(borrower, amount);
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 12 hours));
    }

    // ---------------------------------------------------------------------
    // Read helpers for invariants
    // ---------------------------------------------------------------------

    function borrowerCount() external view returns (uint256) {
        return _borrowers.length;
    }

    function borrowerAt(uint256 index) external view returns (address) {
        return _borrowers[index];
    }

    function lenderCount() external view returns (uint256) {
        return _lenders.length;
    }

    function lenderAt(uint256 index) external view returns (address) {
        return _lenders[index];
    }
}
