// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { TestBase } from "./TestBase.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { ComputeCreditVault } from "../src/ComputeCreditVault.sol";
import { RevenueRouter } from "../src/RevenueRouter.sol";

/**
 * @notice RevenueRouter tests: the split rule, the conditional lien, router authorisation and
 *         the exact boundaries of what a router can and cannot do.
 *
 * Spec reference: ComputeCredit_v2.pdf §8 (Revenue router), §5.9 (Lien capture),
 * §10 (Security model), §15 (Testing checklist).
 */
contract RevenueRouterTest is TestBase {
    // =====================================================================
    // Normal servicing (spec §8.1)
    // =====================================================================

    function test_RoutePaymentSplitsRevenueTwentyEighty() public {
        _openAdvance(nova); // principal 0.02

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 novaBefore = usdc.balanceOf(nova);
        bytes32 paymentRef = keccak256("buyer-payment-1");

        vm.expectEmit(true, true, true, true, address(router));
        emit RevenueRouter.PaymentRouted(buyer, nova, 100_000, 20_000, 0, 80_000, paymentRef);

        vm.prank(buyer);
        (uint256 serviced, uint256 captured, uint256 forwarded) = router.routePayment(nova, 100_000, paymentRef);

        assertEq(serviced, 20_000, "20% split services the advance");
        assertEq(captured, 0);
        assertEq(forwarded, 80_000, "80% forwarded to the borrower");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 20_000);
        assertEq(usdc.balanceOf(nova) - novaBefore, 80_000);
        assertEq(vault.totalOutstanding(), 0, "advance settled");
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 20);
        assertEq(router.totalRoutedVolume(), 100_000);
        assertEq(router.totalServicedVolume(), 20_000);
    }

    function test_RoutePaymentForBorrowerWithNoObligationForwardsEverything() public {
        _registerRevenueSource(nova); // the route must exist before payments flow through it
        uint256 novaBefore = usdc.balanceOf(nova);

        vm.prank(buyer);
        (uint256 serviced, uint256 captured, uint256 forwarded) = router.routePayment(nova, 100_000, bytes32("ref"));

        assertEq(serviced, 0);
        assertEq(captured, 0);
        assertEq(forwarded, 100_000, "no advance, no lien -> the borrower keeps everything");
        assertEq(usdc.balanceOf(nova) - novaBefore, 100_000);
    }

    function test_PartialServicingThroughRouterLeavesAdvanceOpen() public {
        _openAdvance(nova);

        vm.prank(buyer);
        (uint256 serviced,, uint256 forwarded) = router.routePayment(nova, 50_000, bytes32("ref"));

        assertEq(serviced, 10_000);
        assertEq(forwarded, 40_000);
        assertEq(vault.totalOutstanding(), 10_000);
        assertFalse(vault.advanceOf(nova).settled);
        assertEq(passport.score(nova), BOOTSTRAP_SCORE, "no score bump before full servicing");
    }

    function test_RouterCapsServicingAtRemainingPrincipal() public {
        _openAdvance(nova);

        // 20% of 1e8 would be 2e7, far above the 2e4 remaining principal.
        vm.prank(buyer);
        (uint256 serviced,, uint256 forwarded) = router.routePayment(nova, 100e6, bytes32("ref"));

        assertEq(serviced, 20_000, "servicing stops at the remaining principal");
        assertEq(forwarded, 100e6 - 20_000);
        assertEq(vault.totalOutstanding(), 0);
    }

    function test_RouterForwardsToIsolatedSpendingDestination() public {
        vm.prank(nova);
        vault.setSpendingDestination(nova, novaSpend);
        _openAdvance(nova);

        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));

        assertEq(usdc.balanceOf(novaSpend), 20_000 + 80_000, "advance and remainder both reach the isolated wallet");
        assertEq(usdc.balanceOf(nova), 0);
    }

    // =====================================================================
    // Registered revenue source enforcement (spec §8.1, §8.2)
    // =====================================================================

    function test_RouterNotRegisteredAsRevenueSourceReverts() public {
        // Nova's registered revenue source is a *different* router.
        address otherRouter = makeAddr("otherRouter");
        vm.startPrank(admin);
        vault.setApprovedRouter(otherRouter, true);
        vault.setApprovedRevenueSource(otherRouter, true);
        vault.registerRevenueSource(nova, otherRouter);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(RevenueRouter.NotRegisteredRevenueSource.selector, nova, buyer));
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));
    }

    function test_PaymentOutsideRegisteredRouteIsNotCaptured() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);

        // A payment sent directly to Nova's wallet bypasses the router entirely.
        uint256 novaBefore = usdc.balanceOf(nova);
        vm.prank(buyer);
        usdc.transfer(nova, 50_000);

        assertEq(usdc.balanceOf(nova), novaBefore + 50_000, "off-route payments are not captured");
        assertEq(passport.lienCaptured(nova), 0, "no lien recovery happens outside the registered route");
        // This is the documented MVP limitation (spec §17: "payments outside the registered route
        // are not automatically captured").
    }

    // =====================================================================
    // Defaulted servicing (spec §8.2, §9.3)
    // =====================================================================

    function test_LienCapturesFullRoutedRevenueUntilTargetMet() public {
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova); // lien target = 0.03

        uint256 novaBefore = usdc.balanceOf(nova);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(buyer);
        (uint256 serviced, uint256 captured, uint256 forwarded) = router.routePayment(nova, 10_000, bytes32("ref-1"));

        assertEq(serviced, 0);
        assertEq(captured, 10_000, "100% of routed revenue while the lien is open");
        assertEq(forwarded, 0, "nothing forwarded while the target is unmet");
        assertEq(usdc.balanceOf(nova), novaBefore, "borrower receives nothing");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 10_000, "captured funds land in the vault");
        assertEq(passport.remainingLien(nova), 20_000);
        assertEq(router.totalLienCapturedVolume(), 10_000);

        // Second payment clears the lien and forwards the excess.
        vm.prank(buyer);
        (serviced, captured, forwarded) = router.routePayment(nova, 25_000, bytes32("ref-2"));

        assertEq(captured, 20_000, "capture stops exactly at the target");
        assertEq(forwarded, 5_000, "excess above the target reaches the borrower");
        assertFalse(passport.isLienActive(nova));
        assertEq(passport.revenueLienBps(nova), 0);

        // Post-clearance revenue is no longer captured, even for a defaulted borrower.
        vm.prank(buyer);
        (serviced, captured, forwarded) = router.routePayment(nova, 10_000, bytes32("ref-3"));
        assertEq(captured, 0);
        assertEq(forwarded, 10_000);
    }

    // =====================================================================
    // Router authorisation and bounded authority (spec §8.3, §10)
    // =====================================================================

    function test_UnapprovedRouterCannotBeConstructedAgainstVaultToken() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(abi.encodeWithSelector(RevenueRouter.TokenMismatch.selector, address(other), address(usdc)));
        new RevenueRouter(other, vault, admin);
    }

    function test_OnlyOwnerCanManagePayerAllowlist() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        router.setAuthorizedPayer(buyer, true);
    }

    function test_PayerAllowlistBlocksUnknownPayers() public {
        vm.prank(admin);
        router.setAuthorizedPayer(buyer, true);
        assertEq(router.authorizedPayerCount(), 1);

        _openAdvance(nova);

        vm.expectRevert(abi.encodeWithSelector(RevenueRouter.PayerNotAllowed.selector, outsider));
        vm.prank(outsider);
        router.routePayment(nova, 100_000, bytes32("ref"));

        // The allowlisted payer still works.
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));
        assertEq(vault.totalOutstanding(), 0);

        // Revoking restores the empty-allowlist behaviour (any payer).
        vm.prank(admin);
        router.setAuthorizedPayer(buyer, false);
        assertEq(router.authorizedPayerCount(), 0);
        vm.prank(outsider);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(outsider);
        router.routePayment(nova, 1, bytes32("ref"));
    }

    function test_PauseStopsRouting() public {
        _openAdvance(nova);
        vm.prank(admin);
        router.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));

        vm.prank(admin);
        router.unpause();
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));
        assertEq(vault.totalOutstanding(), 0);
    }

    function test_RouterRejectsInvalidArguments() public {
        vm.expectRevert(RevenueRouter.ZeroAmount.selector);
        vm.prank(buyer);
        router.routePayment(nova, 0, bytes32("ref"));

        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        vm.prank(buyer);
        router.routePayment(address(0), 1, bytes32("ref"));
    }

    function test_RouterCannotPerformAdministrativeVaultActions() public {
        // The router is not an operator: it can never open a credit line.
        assertFalse(vault.approvedOperators(address(router)));

        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), address(router)));
        vault.setApprovedRouter(address(router), true);

        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), address(router)));
        vault.setApprovedOperator(address(router), true);

        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), address(router)));
        vault.setApprovedRevenueSource(address(router), true);

        // And it cannot withdraw lender liquidity (it has no shares).
        vm.prank(address(router));
        vm.expectRevert(ComputeCreditVault.NoShares.selector);
        vault.withdrawLiquidity(1);

        // Nor can it rewrite another borrower's revenue source.
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.NotApprovedOperator.selector, address(router)));
        vault.registerRevenueSource(nova, address(router));
    }

    function test_RouterCannotRecordRepaymentWithoutTokens() public {
        _openAdvance(nova);

        // Drain the router's balance and allowance so the pull cannot succeed.
        uint256 routerBalance = usdc.balanceOf(address(router));
        vm.prank(admin);
        router.sweepStrayTokens(address(usdc), admin, routerBalance);

        vm.prank(buyer);
        usdc.approve(address(router), 0);

        vm.expectRevert();
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));

        assertEq(vault.advanceOf(nova).serviced, 0, "no repayment recorded without a transfer");
        assertEq(vault.totalOutstanding(), PROVIDER_PRICE);
    }

    function test_StrayTokenSweepIsOwnerOnlyAndDoesNotTouchVaultFunds() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        router.sweepStrayTokens(address(usdc), outsider, 1);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        router.sweepStrayTokens(address(usdc), admin, 0);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "vault funds are unreachable from the router");
    }

    // =====================================================================
    // Preview helper (used by the orchestrator / bot / dashboard)
    // =====================================================================

    function test_PreviewRoutingMatchesExecutionForAllThreeStates() public {
        // (a) no obligation
        RevenueRouter.RoutingPreview memory p = router.previewRouting(nova, 100_000);
        assertFalse(p.lienActive);
        assertFalse(p.advanceActive);
        assertEq(p.serviceAmount, 0);
        assertEq(p.borrowerAmount, 100_000);

        // (b) active advance
        _openAdvance(nova);
        p = router.previewRouting(nova, 100_000);
        assertTrue(p.advanceActive);
        assertEq(p.serviceAmount, 20_000);
        assertEq(p.borrowerAmount, 80_000);
        assertEq(p.destination, nova);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(buyer);
        (uint256 serviced,, uint256 forwarded) = router.routePayment(nova, 100_000, bytes32("ref"));
        assertEq(serviced, p.serviceAmount, "preview matches execution");
        assertEq(forwarded, p.borrowerAmount);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, p.serviceAmount);

        // (c) defaulted with an active lien
        _expireAdvance(nova);
        vm.prank(keeper);
        vault.penalize(nova);
        p = router.previewRouting(nova, 100_000);
        assertTrue(p.lienActive);
        assertEq(p.lienCaptureAmount, 30_000, "preview caps at the remaining lien target");
        assertEq(p.borrowerAmount, 70_000);
    }

    function test_RouterKeepsNoBalanceBetweenCalls() public {
        _openAdvance(nova);
        vm.prank(buyer);
        router.routePayment(nova, 100_000, bytes32("ref"));
        assertEq(usdc.balanceOf(address(router)), 0, "payments are split atomically; nothing idles in the router");
    }
}
