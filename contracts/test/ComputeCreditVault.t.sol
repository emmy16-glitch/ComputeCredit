// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { TestBase } from "./TestBase.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { ReentrantUSDC } from "./mocks/ReentrantUSDC.sol";
import { TrustPassport } from "../src/TrustPassport.sol";
import { ProviderRegistry } from "../src/ProviderRegistry.sol";
import { ComputeCreditVault } from "../src/ComputeCreditVault.sol";
import { RevenueRouter } from "../src/RevenueRouter.sol";

/**
 * @notice Vault / pool / advance-lifecycle tests.
 *
 * Spec reference: ComputeCredit_v2.pdf §4 (Economic model), §5 (Contract specifications),
 * §9 (End-to-end flows), §10 (Security model), §15 (Testing checklist — contract tests) and
 * §19 (Final release criteria).
 */
contract ComputeCreditVaultTest is TestBase {
    // =====================================================================
    // 1. Pool accounting: deposits and shares (spec §4.2, §5.3)
    // =====================================================================

    function test_InitialDepositMintsOneToOneShares() public view {
        assertEq(vault.totalShares(), LENDER_DEPOSIT, "total shares != first deposit");
        assertEq(vault.shares(lender), LENDER_DEPOSIT, "lender shares != first deposit");
        assertEq(vault.idleAssets(), LENDER_DEPOSIT, "idle assets != 50 USDC");
        assertEq(vault.totalOutstanding(), 0, "no outstanding principal yet");
    }

    function test_DepositBelowMinimumReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.DepositBelowMinimum.selector, 1e6 - 1, 1e6));
        vm.prank(lender2);
        vault.depositLiquidity(1e6 - 1);
    }

    function test_SubsequentDepositMintsProportionalShares() public {
        // S = 50e6 shares, A = 50e6 assets -> a 1 USDC deposit mints 1e6 shares.
        vm.prank(lender2);
        uint256 minted = vault.depositLiquidity(1e6);

        assertEq(minted, 1e6, "proportional shares");
        assertEq(vault.totalShares(), 51e6);
        assertEq(vault.idleAssets(), 51e6);
    }

    function test_DepositMintsProportionalSharesAfterRevenueArrives() public {
        // Service 0.02 USDC back into the pool: A = 50.02e6, S = 50e6.
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);

        uint256 sharesBefore = vault.totalShares();
        uint256 assetsBefore = vault.idleAssets();

        vm.prank(lender2);
        uint256 minted = vault.depositLiquidity(1e6);

        assertEq(minted, (1e6 * sharesBefore) / assetsBefore, "shares = amount * S / A (rounded down)");
        // Rounding down must never dilute existing holders.
        assertGe(_sharePriceE18(), (assetsBefore * 1e18) / sharesBefore, "share price must not fall");
    }

    function test_DepositsRevertWhenPoolHasNoAssetsButSharesOutstanding() public {
        // Drive the pool to S > 0, A == 0 (see the insolvency scenario test for the full path).
        _bumpScore(nova, TrustPassport(passport).SCORE_MAX());

        uint256 idle = vault.idleAssets();
        vm.prank(lender);
        vault.withdrawLiquidity(idle - PROVIDER_PRICE);
        assertEq(vault.idleAssets(), PROVIDER_PRICE);
        assertGt(vault.totalShares(), 0);

        _openAdvance(nova); // takes the entire remaining idle balance
        assertEq(vault.idleAssets(), 0, "pool fully lent out");
        assertGt(vault.totalShares(), 0, "shares still outstanding -> accounting cannot price a deposit");

        vm.expectRevert(ComputeCreditVault.PoolInsolvent.selector);
        vm.prank(lender2);
        vault.depositLiquidity(1e6);
    }

    // =====================================================================
    // 2. Pool accounting: withdrawals and rounding (spec §4.2, §5.4)
    // =====================================================================

    function test_WithdrawCannotExceedIdleShareValue() public {
        _openAdvance(nova); // 0.02 USDC leaves the vault; idle = 49.98e6

        assertEq(vault.idleAssets(), LENDER_DEPOSIT - PROVIDER_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(ComputeCreditVault.WithdrawExceedsIdleShare.selector, LENDER_DEPOSIT, LENDER_DEPOSIT - PROVIDER_PRICE)
        );
        vm.prank(lender);
        vault.withdrawLiquidity(LENDER_DEPOSIT);
    }

    function test_LenderCannotWithdrawLiquidityBackingActiveAdvance() public {
        _openAdvance(nova);

        // The lender owns 100% of shares, but the outstanding principal is not idle liquidity.
        assertEq(vault.maxWithdrawable(lender), LENDER_DEPOSIT - PROVIDER_PRICE);
        assertLt(vault.maxWithdrawable(lender), LENDER_DEPOSIT);

        // Exactly the idle claim is withdrawable.
        vm.prank(lender);
        uint256 burned = vault.withdrawLiquidity(LENDER_DEPOSIT - PROVIDER_PRICE);
        assertGt(burned, 0);
        assertEq(vault.shares(lender), 0, "full exit burns all shares");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE, "outstanding principal is untouched by the exit");
    }

    function test_WithdrawRoundsSharesUpProtectingRemainingShareholders() public {
        // Servicing returns 0.02 USDC: A = 50.02e6, S = 50e6
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);

        // Second lender enters at the new share price; rounding floors their share count.
        vm.prank(lender2);
        vault.depositLiquidity(1e6);

        uint256 priceBefore = _sharePriceE18();

        // Lender withdraws an amount that does not divide evenly by the share price.
        uint256 amount = 33_333_333;
        vm.prank(lender);
        uint256 burned = vault.withdrawLiquidity(amount);

        // sharesToBurn = ceil(amount * totalShares / idleAssets)
        uint256 supplyBefore = vault.totalShares() + burned;
        uint256 assetsBefore = vault.idleAssets() + amount;
        uint256 expectedBurn = (amount * supplyBefore + assetsBefore - 1) / assetsBefore;
        assertEq(burned, expectedBurn, "shares burned must round UP");

        assertGe(_sharePriceE18(), priceBefore, "remaining shareholders must not be diluted by an exit");
    }

    function test_WithdrawRevertsWithNoShares() public {
        vm.expectRevert(ComputeCreditVault.NoShares.selector);
        vm.prank(outsider);
        vault.withdrawLiquidity(1e6);
    }

    function test_RepaymentIncreasesPoolLiquidityAndShareValue() public {
        _openAdvance(nova);
        uint256 idleWhileLent = vault.idleAssets(); // 49.98 USDC while the advance is live

        _routePayment(nova, BUYER_PAYMENT); // 0.02 serviced, 0.08 forwarded to Nova

        assertEq(vault.idleAssets(), LENDER_DEPOSIT, "pool made whole by servicing");
        assertGt(vault.idleAssets(), idleWhileLent, "repayment restores idle liquidity");
        assertEq(_sharePriceE18(), 1e18, "shares are worth the full principal again");
        assertEq(vault.totalOutstanding(), 0);
    }

    // =====================================================================
    // 3. Advance request validation (spec §5.5 — the nine checks)
    // =====================================================================

    function test_HappyPathAdvanceRequestTransfersPrincipalAndRecordsObligation() public {
        bytes32 jobHash = _jobHash(nova);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ComputeCreditVault.AdvanceRequested(
            nova, provider, PROVIDER_PRICE, jobHash, address(router), nova, block.timestamp + ADVANCE_WINDOW, vault.NORMAL_SPLIT_BPS()
        );

        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, jobHash, address(router));

        assertEq(usdc.balanceOf(nova), PROVIDER_PRICE, "borrower received the exact provider cost");
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE, "totalOutstanding += principal");
        assertEq(vault.idleAssets(), LENDER_DEPOSIT - PROVIDER_PRICE);
        assertTrue(vault.hasActiveAdvance(nova));
        assertEq(vault.activeAdvanceCount(), 1);
        assertEq(vault.registeredRevenueSource(nova), address(router));

        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(nova);
        assertEq(a.principal, PROVIDER_PRICE);
        assertEq(a.serviced, 0);
        assertEq(a.splitBps, vault.NORMAL_SPLIT_BPS());
        assertEq(a.jobHash, jobHash);
        assertEq(a.provider, provider);
        assertEq(a.revenueSource, address(router));
        assertEq(a.dueAt, block.timestamp + ADVANCE_WINDOW);
        assertFalse(a.settled);
        assertFalse(a.defaulted);
    }

    function test_BorrowerCanSelfRequestAdvance() public {
        vm.prank(admin);
        vault.setSpendingDestination(nova, novaSpend);

        bytes32 jobHash = _jobHash(nova);
        vm.prank(nova); // borrower self-request, isolated spending wallet configured
        vault.requestComputeAdvance(provider, PROVIDER_PRICE, jobHash, address(router));

        assertEq(usdc.balanceOf(novaSpend), PROVIDER_PRICE, "advance goes to the isolated spending wallet");
        assertEq(usdc.balanceOf(nova), 0);
        assertEq(vault.payoutDestination(nova), novaSpend);
    }

    function test_NonApprovedOperatorCannotRequestAdvance() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotAuthorizedRequester.selector, outsider, nova));
        vm.prank(outsider);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_BorrowerAuthorisedRequesterCanRequest() public {
        vm.prank(nova);
        vault.authorizeRequester(outsider, true);

        vm.prank(outsider);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
        assertTrue(vault.hasActiveAdvance(nova));
    }

    function test_SecondActiveAdvanceReverts() public {
        _openAdvance(nova);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.ActiveAdvanceExists.selector, nova));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_UnknownProviderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.ProviderNotActive.selector, outsider));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, outsider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_InactiveProviderReverts() public {
        vm.prank(admin);
        providers.setProviderActive(provider, false);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.ProviderNotActive.selector, provider));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_AdvanceAboveRegisteredProviderPriceReverts() public {
        // Provider price is 0.02 USDC; a caller-supplied inflated quote must be rejected.
        vm.expectRevert(
            abi.encodeWithSelector(ComputeCreditVault.AdvanceAboveProviderPrice.selector, PROVIDER_PRICE + 1, PROVIDER_PRICE)
        );
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE + 1, _jobHash(nova), address(router));
    }

    function test_AdvanceBelowProviderPriceIsAllowed() public {
        uint256 discounted = PROVIDER_PRICE / 2;
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, discounted, _jobHash(nova), address(router));
        assertEq(usdc.balanceOf(nova), discounted, "may be lower than the registered price, never higher");
        assertEq(vault.totalOutstanding(), discounted);
    }

    function test_AdvanceAboveScoreTierReverts() public {
        // Bootstrap score 150 -> tier 1 -> 1 USDC ceiling.
        vm.prank(admin);
        providers.updateProviderPrice(provider, 2e6);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.AdvanceAboveScoreTier.selector, 1_500_000, 1e6));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, 1_500_000, _jobHash(nova), address(router));
    }

    function test_ScoreTierCeilingFollowsScoreIncrease() public {
        assertEq(passport.maxAdvance(nova), 1e6, "tier 1");

        _bumpScore(nova, 201);
        assertEq(passport.maxAdvance(nova), 5e6, "tier 2 after one on-time settlement");
        assertEq(passport.tierOf(nova), 2);
    }

    function test_ReusedJobHashReverts() public {
        bytes32 jobHash = _jobHash(nova);
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, jobHash, address(router));

        // Settle so the borrower has no active advance; the job hash is still burned.
        _routePayment(nova, BUYER_PAYMENT);
        assertFalse(vault.hasActiveAdvance(nova));

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.JobHashAlreadyUsed.selector, jobHash));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, jobHash, address(router));
    }

    function test_ZeroJobHashReverts() public {
        vm.expectRevert(ComputeCreditVault.ZeroJobHash.selector);
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, bytes32(0), address(router));
    }

    function test_ZeroCostReverts() public {
        vm.expectRevert(ComputeCreditVault.ZeroAmount.selector);
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, 0, _jobHash(nova), address(router));
    }

    function test_InsufficientIdleLiquidityReverts() public {
        // Lender takes almost everything out: idle = 0.01 USDC < 0.02 USDC requested.
        vm.prank(lender);
        vault.withdrawLiquidity(LENDER_DEPOSIT - 10_000);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.InsufficientIdleLiquidity.selector, PROVIDER_PRICE, 10_000));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_UnapprovedRevenueSourceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.RevenueSourceNotApproved.selector, outsider));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), outsider);
    }

    function test_RevenueSourceMismatchReverts() public {
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT); // settle

        address otherRouter = makeAddr("otherRouter");
        vm.startPrank(admin);
        vault.setApprovedRevenueSource(otherRouter, true);
        vault.setApprovedRouter(otherRouter, true);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.RevenueSourceMismatch.selector, address(router), otherRouter));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), otherRouter);
    }

    function test_RevenueSourceCannotChangeWhileAdvanceActive() public {
        _openAdvance(nova);

        address otherRouter = makeAddr("otherRouter");
        vm.prank(admin);
        vault.setApprovedRevenueSource(otherRouter, true);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.RevenueSourceLocked.selector, nova));
        vm.prank(operator);
        vault.registerRevenueSource(nova, otherRouter);
    }

    function test_NewAdvanceRejectedWhileLienOutstanding() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        // The lien is now an obstacle: no fresh credit until recovery or rehabilitation (spec §5.9).
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NoOutstandingLien.selector, nova));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
    }

    function test_NewAdvanceAllowedAfterLienCleared() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        _routePayment(nova, 100_000); // 0.03 USDC clears the lien (target = 1.5 * 0.02)

        assertFalse(passport.isLienActive(nova));
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));
        assertTrue(vault.hasActiveAdvance(nova));
    }

    // =====================================================================
    // 4. Servicing and settlement accounting (spec §4.3, §5.6, §5.7, §9.2)
    // =====================================================================

    function test_NonRouterServicingReverts() public {
        _openAdvance(nova);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotApprovedRouter.selector, outsider));
        vm.prank(outsider);
        vault.serviceAdvance(nova, PROVIDER_PRICE);

        // A renamed entrypoint must not become a bypass.
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotApprovedRouter.selector, outsider));
        vm.prank(outsider);
        vault.serviceAdvanceWithTransfer(nova, PROVIDER_PRICE);
    }

    function test_PartialServicingUpdatesAccountingExactlyOnce() public {
        _openAdvance(nova); // principal 0.02

        // Buyer pays 0.05; the 20% split services 0.01 (spec §9.2).
        (uint256 serviced, uint256 captured, uint256 forwarded) = _routePayment(nova, 50_000);

        assertEq(serviced, 10_000, "serviced = 20% of 0.05");
        assertEq(captured, 0);
        assertEq(forwarded, 40_000, "borrower keeps 80%");

        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(nova);
        assertEq(a.serviced, 10_000);
        assertEq(a.principal, PROVIDER_PRICE);
        assertEq(vault.totalOutstanding(), 10_000, "totalOutstanding decreased by exactly the serviced amount");
        assertFalse(a.settled, "not settled until the principal is fully serviced");
        assertEq(passport.score(nova), BOOTSTRAP_SCORE, "score is not bumped on partial servicing");

        // A later routed payment services the remaining 0.01 USDC and settles.
        (uint256 serviced2,,) = _routePayment(nova, 50_000);
        assertEq(serviced2, 10_000);
        assertEq(vault.totalOutstanding(), 0, "no residual outstanding principal");
        assertTrue(vault.advanceOf(nova).settled);
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 20, "score bumped exactly once");
    }

    function test_ExactServicingSettlesAdvanceWithoutDoubleDecrement() public {
        _openAdvance(nova);
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE);

        _routePayment(nova, BUYER_PAYMENT); // 20% of 0.10 == 0.02 == principal

        assertEq(vault.totalOutstanding(), 0, "settlement performs no second principal subtraction");
        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(nova);
        assertTrue(a.settled);
        assertEq(a.serviced, a.principal);
        assertEq(vault.activeAdvanceCount(), 0);
    }

    function test_SettlementIncreasesScoreOnceAndIncrementsTierProgress() public {
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 20);

        // A second, independent advance must not re-apply the previous settlement's score bump.
        _openAdvance(nova);
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 20, "score unchanged while the new advance is open");
        _routePayment(nova, BUYER_PAYMENT);
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 40, "one bump per settled advance");
    }

    function test_SettlementCapsScoreAtMaximum() public {
        _bumpScore(nova, 990);
        assertEq(passport.score(nova), 990);

        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);
        assertEq(passport.score(nova), 1_000, "score capped at 1,000");
    }

    function test_PostSettlementServicingReverts() public {
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);

        vm.prank(admin);
        vault.setApprovedRouter(outsider, true);
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.AdvanceClosed.selector, nova));
        vm.prank(outsider);
        vault.serviceAdvanceWithTransfer(nova, 1);
    }

    function test_ServicingExceedingRemainingReverts() public {
        _openAdvance(nova);

        vm.prank(admin);
        vault.setApprovedRouter(outsider, true);
        vm.expectRevert(
            abi.encodeWithSelector(ComputeCreditVault.ServicingExceedsRemaining.selector, PROVIDER_PRICE + 1, PROVIDER_PRICE)
        );
        vm.prank(outsider);
        vault.serviceAdvanceWithTransfer(nova, PROVIDER_PRICE + 1);
    }

    function test_OverpaymentIsNotRecordedEvenWhenSplitExceedsPrincipal() public {
        _openAdvance(nova);
        // A large payment whose 20% split (20 USDC) exceeds the 0.02 principal: service only
        // the remaining principal and forward the rest to the borrower.
        (uint256 serviced, uint256 captured, uint256 forwarded) = _routePayment(nova, 100e6);

        assertEq(serviced, PROVIDER_PRICE, "servicing is capped at the remaining principal");
        assertEq(captured, 0);
        assertEq(forwarded, 100e6 - PROVIDER_PRICE, "everything else reaches the borrower");
        assertEq(vault.totalOutstanding(), 0);
        assertTrue(vault.advanceOf(nova).settled);
    }

    function test_EarlyRepaymentUsesSameAccountingPath() public {
        // Revenue path (reference).
        _openAdvance(nova);
        _routePayment(nova, BUYER_PAYMENT);
        uint256 scoreAfterRevenue = passport.score(nova);
        assertEq(vault.totalOutstanding(), 0);

        // Early repayment path (spec §5.7) — must not diverge.
        _openAdvance(nova);
        vm.prank(nova);
        (uint256 serviced, bool settledNow) = vault.repayEarly(nova, PROVIDER_PRICE);

        assertEq(serviced, PROVIDER_PRICE);
        assertTrue(settledNow);
        assertEq(vault.totalOutstanding(), 0);
        assertTrue(vault.advanceOf(nova).settled);
        assertEq(passport.score(nova), scoreAfterRevenue + 20, "same score bump as the revenue path");
    }

    function test_EarlyRepaymentByOperatorAllowedAndCapped() public {
        _openAdvance(nova);
        usdc.mint(operator, 10_000);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NoActiveAdvance.selector, lender));
        vm.prank(operator);
        vault.repayEarly(lender, 1);

        vm.prank(operator);
        (uint256 serviced,) = vault.repayEarly(nova, 5_000);
        assertEq(serviced, 5_000);
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE - 5_000);
    }

    function test_EarlyRepaymentByOutsiderReverts() public {
        _openAdvance(nova);
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotAuthorizedRequester.selector, outsider, nova));
        vm.prank(outsider);
        vault.repayEarly(nova, 1_000);
    }

    function test_RepaymentAfterDefaultReverts() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.AdvanceClosed.selector, nova));
        vm.prank(nova);
        vault.repayEarly(nova, PROVIDER_PRICE);

        vm.prank(admin);
        vault.setApprovedRouter(outsider, true);
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.AdvanceClosed.selector, nova));
        vm.prank(outsider);
        vault.serviceAdvanceWithTransfer(nova, 1);
    }

    // =====================================================================
    // 5. Default and conditional lien (spec §5.8, §5.9, §9.3)
    // =====================================================================

    function test_PenalizeBeforeExpiryReverts() public {
        _openAdvance(nova);
        uint256 dueAt = vault.advanceOf(nova).dueAt;

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotExpired.selector, dueAt));
        vm.prank(keeper);
        vault.penalize(nova);
    }

    function test_PenalizeAfterExpiryRecordsShortfallAndLienTarget() public {
        _openAdvance(nova);
        uint256 dueAt = vault.advanceOf(nova).dueAt;
        vm.warp(dueAt + 1);
        uint256 outstandingBefore = vault.totalOutstanding();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ComputeCreditVault.AdvanceDefaulted(nova, PROVIDER_PRICE, PROVIDER_PRICE * 3 / 2, dueAt);

        vm.prank(keeper); // permissionless after expiry (spec §5.8)
        (uint256 shortfall, uint256 lienTarget) = vault.penalize(nova);

        assertEq(shortfall, PROVIDER_PRICE, "shortfall = principal - serviced");
        assertEq(lienTarget, (PROVIDER_PRICE * 15_000) / 10_000, "lien target = 1.5x shortfall");
        assertEq(vault.totalOutstanding(), outstandingBefore - shortfall, "remaining principal leaves the outstanding set");
        assertTrue(vault.advanceOf(nova).defaulted);
        assertFalse(vault.advanceOf(nova).settled, "defaulted implies not settled");
        assertEq(passport.revenueLienBps(nova), 10_000, "capture rate set to 100%");
        assertEq(passport.lienTarget(nova), lienTarget);
        assertEq(passport.lienCaptured(nova), 0);
        assertEq(passport.score(nova), 0, "deterministic demo penalty: full slash to zero");
        assertEq(usdc.balanceOf(address(vault)), LENDER_DEPOSIT - PROVIDER_PRICE, "default moves no money");
    }

    function test_RepeatedPenalizeReverts() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.AdvanceClosed.selector, nova));
        vm.prank(keeper);
        vault.penalize(nova);
    }

    function test_PenalizeWithNoAdvanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NoActiveAdvance.selector, nova));
        vm.prank(keeper);
        vault.penalize(nova);
    }

    function test_PartiallyServicedAdvanceDefaultsOnRemainderOnly() public {
        _openAdvance(nova);
        _routePayment(nova, 50_000); // service 0.01 of 0.02
        vm.warp(block.timestamp + ADVANCE_WINDOW + 1);

        (uint256 shortfall, uint256 lienTarget) = vault.penalize(nova);
        assertEq(shortfall, 10_000, "only the unserviced remainder is the shortfall");
        assertEq(lienTarget, 15_000, "1.5x the remainder");
        assertEq(vault.totalOutstanding(), 0);
    }

    function test_DirectLienCaptureByNonRouterReverts() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotApprovedRouter.selector, outsider));
        vm.prank(outsider);
        vault.captureLien(nova, 10_000);
    }

    function test_LienCaptureCannotExceedTargetAndExcessReachesBorrower() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);
        // Lien target = 0.03 USDC; Nova now has 0.02 USDC of (unrecovered) advance proceeds.
        uint256 novaBalanceBefore = usdc.balanceOf(nova);
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        // A 0.05 payment overshoots the 0.03 target by 0.02.
        (uint256 serviced, uint256 captured, uint256 forwarded) = _routePayment(nova, 50_000);

        assertEq(serviced, 0, "no advance is being serviced");
        assertEq(captured, 30_000, "capture stops at the exact target");
        assertEq(forwarded, 20_000, "excess above the target reaches the borrower");
        assertEq(passport.lienCaptured(nova), 30_000);
        assertFalse(passport.isLienActive(nova), "lien cleared at the target");
        assertEq(passport.revenueLienBps(nova), 0, "cleared lien resets the capture rate to zero");
        assertEq(usdc.balanceOf(nova), novaBalanceBefore + 20_000);
        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore + 30_000, "recovery increases idle liquidity");
    }

    function test_LienCaptureAccumulatesAcrossPaymentsUntilTarget() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        (, uint256 captured1, uint256 forwarded1) = _routePayment(nova, 10_000);
        assertEq(captured1, 10_000);
        assertEq(forwarded1, 0, "nothing forwarded while the lien is open");
        assertEq(passport.lienCaptured(nova), 10_000);
        assertTrue(passport.isLienActive(nova));

        (, uint256 captured2, uint256 forwarded2) = _routePayment(nova, 20_000);
        assertEq(captured2, 20_000);
        assertEq(forwarded2, 0);
        assertEq(passport.lienCaptured(nova), 30_000);
        assertFalse(passport.isLienActive(nova));

        // Later revenue is no longer captured by the lien (spec §9.3 step 12).
        (, uint256 captured3, uint256 forwarded3) = _routePayment(nova, 10_000);
        assertEq(captured3, 0);
        assertEq(forwarded3, 10_000);
    }

    function test_CaptureLienAfterClearanceReverts() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);
        _routePayment(nova, 30_000); // clears the lien exactly

        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NoOutstandingLien.selector, nova));
        vm.prank(address(router));
        vault.captureLien(nova, 1);
    }

    // =====================================================================
    // 6. Lender loss and pool insolvency (honest risk disclosure, spec §1.2, §4.4)
    // =====================================================================

    function test_DefaultWithoutFutureRevenueMeansLenderLossAndNoRecovery() public {
        _bumpScore(nova, 1_000); // tier 4
        vm.prank(admin);
        providers.updateProviderPrice(provider, 50e6);

        uint256 idleBefore = vault.idleAssets();
        vm.prank(lender);
        vault.withdrawLiquidity(idleBefore - 30_000); // leave 0.03 USDC idle

        _openAdvance(nova, 30_000); // lend out the entire remaining idle balance
        assertEq(vault.idleAssets(), 0);

        vm.warp(block.timestamp + ADVANCE_WINDOW + 1);
        vm.prank(keeper);
        (uint256 shortfall, uint256 lienTarget) = vault.penalize(nova);

        assertEq(shortfall, 30_000);
        assertEq(lienTarget, 45_000);
        assertEq(vault.idleAssets(), 0, "no funds exist to recover yet");

        // The lender cannot withdraw what does not exist: the pool has shares but no assets.
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.WithdrawExceedsIdleShare.selector, 1, 0));
        vm.prank(lender);
        vault.withdrawLiquidity(1);

        // Recovery is conditional on future routed revenue — 0.045 USDC clears the lien.
        _routePayment(nova, 50_000);
        assertEq(vault.idleAssets(), 45_000, "captured revenue becomes idle liquidity again");

        uint256 lenderBalanceBefore = usdc.balanceOf(lender);
        vm.prank(lender);
        vault.withdrawLiquidity(45_000);
        assertEq(usdc.balanceOf(lender) - lenderBalanceBefore, 45_000, "recovered funds are withdrawable by shareholders");
    }

    // =====================================================================
    // 7. Access control, configuration and pausing (spec §8.3, §10.1)
    // =====================================================================

    function test_OnlyOwnerCanManageRouterOperatorAndSourceAllowlists() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        vault.setApprovedRouter(outsider, true);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        vault.setApprovedOperator(outsider, true);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        vault.setApprovedRevenueSource(outsider, true);
    }

    function test_VaultApprovalChangesEmitEvents() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ComputeCreditVault.RouterApprovalUpdated(outsider, true);
        vm.prank(admin);
        vault.setApprovedRouter(outsider, true);
        assertTrue(vault.approvedRouters(outsider));
    }

    function test_PausedVaultBlocksTokenMovementButNotDefaultRecording() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(lender2);
        vault.depositLiquidity(1e6);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(lender);
        vault.withdrawLiquidity(1e6);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(operator);
        vault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, _jobHash(nova), address(router));

        // Default recording is permissionless and moves no money: it must stay available.
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        vault.unpause();
        _openAdvance(nova);
        vm.warp(block.timestamp + ADVANCE_WINDOW + 1);
        vm.prank(admin);
        vault.pause();
        vm.prank(keeper);
        vault.penalize(nova);
        assertTrue(vault.advanceOf(nova).defaulted);
    }

    function test_PauseIsOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        vault.pause();
    }

    // =====================================================================
    // 8. Token configuration and atomicity (spec §10.1, §10.2)
    // =====================================================================

    function test_VaultRejectsTokenWithWrongDecimals() public {
        ERC20 eighteen = new EighteenDecimalToken(); // 18 decimals by default
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.InvalidTokenDecimals.selector, 18, 6));
        new ComputeCreditVault(IERC20(address(eighteen)), passport, providers, admin);
    }

    function test_VaultRejectsNonContractTokenAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.InvalidToken.selector, outsider));
        new ComputeCreditVault(IERC20(outsider), passport, providers, admin);

        vm.expectRevert(ComputeCreditVault.ZeroAddress.selector);
        new ComputeCreditVault(IERC20(address(0)), passport, providers, admin);
    }

    function test_VaultRejectsZeroAddressDependencies() public {
        vm.expectRevert(ComputeCreditVault.ZeroAddress.selector);
        new ComputeCreditVault(usdc, passport, ProviderRegistry(address(0)), admin);

        vm.expectRevert(ComputeCreditVault.ZeroAddress.selector);
        new ComputeCreditVault(usdc, TrustPassport(address(0)), providers, admin);

        // Ownable validates the administrator before the vault's own dependency checks run.
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableInvalidOwner(address)")), address(0)));
        new ComputeCreditVault(usdc, passport, providers, address(0));
    }

    function test_TransfersUseConfiguredTokenOnly() public {
        assertEq(address(vault.usdc()), address(usdc), "vault bound to the configured token");

        // A different 6-decimal token is worthless here: balances of the configured token move.
        MockUSDC otherToken = new MockUSDC();
        otherToken.mint(lender, 100e6);
        vm.prank(lender);
        otherToken.approve(address(vault), type(uint256).max);

        uint256 otherBefore = otherToken.balanceOf(lender);
        vm.prank(lender);
        vault.depositLiquidity(1e6);

        assertEq(usdc.balanceOf(address(vault)), LENDER_DEPOSIT + 1e6, "configured token received the deposit");
        assertEq(otherToken.balanceOf(lender), otherBefore, "no other token moved");
    }

    function test_ServicingWithoutTokenTransferCannotRecordRepayment() public {
        // "Fake repayment record" threat (spec §10.2): with no allowance, the pull fails and no
        // accounting is written.
        address pennilessRouter = makeAddr("pennilessRouter");
        vm.prank(admin);
        vault.setApprovedRouter(pennilessRouter, true);

        _openAdvance(nova);

        vm.expectRevert();
        vm.prank(pennilessRouter);
        vault.serviceAdvanceWithTransfer(nova, PROVIDER_PRICE);

        assertEq(vault.advanceOf(nova).serviced, 0, "serviced must be unchanged");
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE, "totalOutstanding must be unchanged");
    }

    function test_ReentrancyIntoDepositReverts() public {
        ReentrantUSDC token = new ReentrantUSDC();
        (ComputeCreditVault reentrantVault,) = _deployReentrantFixture(token);

        token.mint(lender2, 10e6);
        vm.prank(lender2);
        token.approve(address(reentrantVault), type(uint256).max);

        uint256 supplyBefore = reentrantVault.totalShares();
        token.armAttack(address(reentrantVault), abi.encodeCall(ComputeCreditVault.depositLiquidity, (1e6)));

        vm.prank(lender2);
        reentrantVault.depositLiquidity(1e6);

        assertTrue(token.attackAttempted(), "attack was attempted");
        assertTrue(token.attackReverted(), "re-entrant deposit must revert (ReentrancyGuard)");
        assertEq(reentrantVault.totalShares() - supplyBefore, 1e6, "outer deposit recorded exactly once");
    }

    function test_ReentrancyIntoAdvanceServicingReverts() public {
        ReentrantUSDC token = new ReentrantUSDC();
        (ComputeCreditVault reentrantVault, RevenueRouter reentrantRouter) = _deployReentrantFixture(token);

        // Give the malicious token router rights so the only thing that can stop it is the guard.
        vm.prank(admin);
        reentrantVault.setApprovedRouter(address(token), true);

        // Open an advance for the borrower.
        bytes32 jobHash = keccak256("job");
        vm.prank(operator);
        reentrantVault.requestComputeAdvanceFor(nova, provider, PROVIDER_PRICE, jobHash, address(reentrantRouter));

        token.mint(address(token), 1e6);
        token.selfApprove(address(reentrantVault), type(uint256).max);
        token.armAttack(
            address(reentrantVault),
            abi.encodeCall(ComputeCreditVault.serviceAdvanceWithTransfer, (nova, PROVIDER_PRICE))
        );

        // The outer call services the advance (the malicious token is an allowlisted router);
        // the nested call must be rejected by the guard.
        vm.prank(address(token));
        reentrantVault.serviceAdvanceWithTransfer(nova, PROVIDER_PRICE);

        assertTrue(token.attackAttempted(), "attack was attempted");
        assertTrue(token.attackReverted(), "re-entrant servicing must revert (ReentrancyGuard)");
        assertEq(reentrantVault.advanceOf(nova).serviced, PROVIDER_PRICE, "serviced exactly once");
        assertEq(reentrantVault.totalOutstanding(), 0, "outstanding principal decremented exactly once");
        assertTrue(reentrantVault.advanceOf(nova).settled);
    }

    function _deployReentrantFixture(ReentrantUSDC token) private returns (ComputeCreditVault, RevenueRouter) {
        TrustPassport p = new TrustPassport(attester, admin);
        ProviderRegistry r = new ProviderRegistry(admin);
        ComputeCreditVault v = new ComputeCreditVault(token, p, r, admin);
        RevenueRouter rt = new RevenueRouter(token, v, admin);

        vm.startPrank(admin);
        p.setVault(address(v));
        v.setApprovedRouter(address(rt), true);
        v.setApprovedOperator(operator, true);
        v.setApprovedRevenueSource(address(rt), true);
        r.registerProvider(provider, providerWallet, PROVIDER_PRICE, SERVICE_ID);
        vm.stopPrank();

        vm.prank(attester);
        p.seedScore(nova, BOOTSTRAP_SCORE);

        // Real idle liquidity: the vault must be able to fund the advance.
        token.mint(lender2, 1e6);
        vm.prank(lender2);
        token.approve(address(v), type(uint256).max);
        vm.prank(lender2);
        v.depositLiquidity(1e6);

        token.mint(address(rt), 10e6);
        return (v, rt);
    }

    // =====================================================================
    // 9. Provider registry (spec §6)
    // =====================================================================

    function test_RegistryRejectsDuplicateProviderRegistration() public {
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderAlreadyRegistered.selector, provider));
        vm.prank(admin);
        providers.registerProvider(provider, providerWallet, PROVIDER_PRICE, keccak256("other-service"));
    }

    function test_RegistryRejectsZeroPriceAndZeroAddresses() public {
        vm.expectRevert(ProviderRegistry.InvalidPrice.selector);
        vm.prank(admin);
        providers.registerProvider(outsider, outsider, 0, keccak256("s"));

        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        vm.prank(admin);
        providers.registerProvider(address(0), outsider, 1, keccak256("s"));
    }

    function test_RegistryPriceUpdateIsAdminOnlyAndEmitsEvent() public {
        vm.expectRevert(ProviderRegistry.NotAdministrator.selector);
        vm.prank(outsider);
        providers.updateProviderPrice(provider, 1e6);

        vm.expectEmit(true, false, false, true, address(providers));
        emit ProviderRegistry.ProviderPriceUpdated(provider, PROVIDER_PRICE, 500_000);
        vm.prank(admin);
        providers.updateProviderPrice(provider, 500_000);

        assertEq(providers.pricePerJob(provider), 500_000);
        ProviderRegistry.ProviderQuote memory q = providers.quoteOf(provider);
        assertEq(q.updatedAt, block.timestamp);
    }

    function test_RegistryAdministratorCanRegisterAndUpdate() public {
        address adminBot = makeAddr("adminBot");
        vm.prank(admin);
        providers.setAdministrator(adminBot, true);

        address newProvider = makeAddr("newProvider");
        vm.prank(adminBot);
        providers.registerProvider(newProvider, newProvider, 1e6, keccak256("vision-v1"));

        assertTrue(providers.isActive(newProvider));
        assertEq(providers.pricePerJob(newProvider), 1e6);
        assertEq(providers.providerForService(keccak256("vision-v1")), newProvider);

        vm.prank(adminBot);
        providers.setProviderActive(newProvider, false);
        assertFalse(providers.isActive(newProvider));
    }

    function test_JobHashBindsBorrowerProviderServicePriceNonceAndExpiry() public {
        bytes32 base = providers.computeJobHash(nova, provider, SERVICE_ID, PROVIDER_PRICE, 1, block.timestamp + 1 hours);

        assertEq(
            base, providers.computeJobHash(nova, provider, SERVICE_ID, PROVIDER_PRICE, 1, block.timestamp + 1 hours), "deterministic"
        );
        assertTrue(base != providers.computeJobHash(lender, provider, SERVICE_ID, PROVIDER_PRICE, 1, block.timestamp + 1 hours));
        assertTrue(base != providers.computeJobHash(nova, outsider, SERVICE_ID, PROVIDER_PRICE, 1, block.timestamp + 1 hours));
        assertTrue(base != providers.computeJobHash(nova, provider, keccak256("other"), PROVIDER_PRICE, 1, block.timestamp + 1 hours));
        assertTrue(base != providers.computeJobHash(nova, provider, SERVICE_ID, PROVIDER_PRICE + 1, 1, block.timestamp + 1 hours));
        assertTrue(base != providers.computeJobHash(nova, provider, SERVICE_ID, PROVIDER_PRICE, 2, block.timestamp + 1 hours));
        assertTrue(base != providers.computeJobHash(nova, provider, SERVICE_ID, PROVIDER_PRICE, 1, block.timestamp + 2 hours));
    }

    function test_RegistryRejectsDuplicateServiceBinding() public {
        address second = makeAddr("secondProvider");
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.DuplicateServiceRegistered.selector, provider, SERVICE_ID));
        vm.prank(admin);
        providers.registerProvider(second, second, PROVIDER_PRICE, SERVICE_ID);
    }

    // =====================================================================
    // 10. End-to-end flows from the specification (§9.1 - §9.4)
    // =====================================================================

    function test_EndToEnd_HappyPathFactoringFlow_Spec_9_1() public {
        // 1-2. Lender deposits 50 USDC and owns proportional shares.
        assertEq(vault.idleAssets(), 50e6);
        assertEq(vault.shares(lender), 50e6);

        // 3-4. Bootstrap score 150 (tier limit 1 USDC) and registered price 0.02 USDC.
        assertEq(passport.score(nova), 150);
        assertEq(passport.maxAdvance(nova), 1e6);
        assertEq(providers.pricePerJob(provider), 20_000);

        // 5-7. Advance requested, verified and paid out.
        bytes32 jobHash = _openAdvance(nova);
        assertEq(usdc.balanceOf(nova), 20_000);
        assertEq(vault.totalOutstanding(), 20_000);

        // 8. The orchestrator pays the provider through the configured payment rail.
        vm.prank(nova);
        usdc.transfer(providerWallet, 20_000);
        assertEq(usdc.balanceOf(nova), 0, "Nova spends the entire advance on compute");
        assertEq(usdc.balanceOf(providerWallet), 20_000);

        // 9-11. Buyer pays 0.10 USDC; the router sends 20% (0.02) to the vault.
        (uint256 serviced,, uint256 forwarded) = _routePayment(nova, 100_000);
        assertEq(serviced, 20_000);
        assertEq(forwarded, 80_000);

        // 12-14. Exactly serviced, settled, score +20.
        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(nova);
        assertEq(a.serviced, a.principal);
        assertTrue(a.settled);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(passport.score(nova), 170);

        // 15. Nova received 0.08 USDC: 0.10 revenue minus 0.02 servicing.
        assertEq(usdc.balanceOf(nova), 80_000);
        assertEq(vault.idleAssets(), 50e6, "pool back to its original liquidity");

        // Lender can withdraw the full idle balance again.
        assertEq(vault.maxWithdrawable(lender), 50e6);
        assertEq(vault.advanceHistoryCount(nova), 1);
        assertEq(vault.advanceOf(nova).jobHash, jobHash);
    }

    function test_EndToEnd_PartialServicingThenDefaultRecovery_Spec_9_2_and_9_3() public {
        // Partial servicing: 0.05 payment -> 0.01 serviced.
        _openAdvance(nova);
        (uint256 serviced,,) = _routePayment(nova, 50_000);
        assertEq(serviced, 10_000);
        assertEq(vault.totalOutstanding(), 10_000);
        assertEq(vault.advanceOf(nova).serviced, 10_000);

        // No further revenue before the deadline: anyone may penalize after expiry.
        vm.warp(block.timestamp + ADVANCE_WINDOW + 1);
        (uint256 shortfall, uint256 lienTarget) = vault.penalize(nova);
        assertEq(shortfall, 10_000);
        assertEq(lienTarget, 15_000);

        // Later revenue through the registered route is captured toward the lien.
        (, uint256 captured, uint256 forwarded) = _routePayment(nova, 10_000);
        assertEq(captured, 10_000, "100% capture while the lien is open");
        assertEq(forwarded, 0, "no remainder while the target is unmet");
        assertEq(passport.remainingLien(nova), 5_000);

        (, captured, forwarded) = _routePayment(nova, 5_000);
        assertEq(captured, 5_000);
        assertFalse(passport.isLienActive(nova), "lien clears at the exact target");
        assertEq(passport.revenueLienBps(nova), 0);
        assertEq(forwarded, 0, "this payment is exactly the target remainder");
    }

    function test_EndToEnd_LenderFlow_Spec_9_4() public {
        // Lender monitors pool state.
        assertEq(vault.totalShares(), 50e6);
        assertEq(vault.totalOutstanding(), 0);
        assertEq(vault.utilizationBps(), 0);

        _openAdvance(nova);
        assertEq(vault.utilizationBps(), (20_000 * 10_000) / 50e6, "utilization reflects the live advance");
        assertEq(vault.idleClaimOf(lender), 50e6 - 20_000);

        _routePayment(nova, 100_000); // repayment restores liquidity
        assertEq(vault.idleClaimOf(lender), 50e6, "repayment increases lender idle claim");
        assertEq(vault.utilizationBps(), 0);

        vm.prank(lender);
        vault.withdrawLiquidity(5e6);
        assertEq(usdc.balanceOf(lender), 1_000e6 - 50e6 + 5e6, "lender withdraws idle liquidity only");
    }
}

/// @dev Concrete 18-decimal token used to prove decimal validation at construction.
contract EighteenDecimalToken is ERC20 {
    constructor() ERC20("Wrong Decimals", "WRONG") { }
}
