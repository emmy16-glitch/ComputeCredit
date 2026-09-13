// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.t.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";

/// @notice Core vault/passport/registry/router tests (24 cases).
contract ComputeCreditTest is Base {
    // ---------- lender / shares ----------

    function test_DepositBelowMinReverts() public {
        vm.startPrank(lender);
        usdc.approve(address(vault), 100);
        vm.expectRevert(ComputeCreditVault.BelowMinDeposit.selector);
        vault.deposit(100, lender);
        vm.stopPrank();
    }

    function test_DepositMintsSharesAndWithdrawBoundedByIdle() public {
        uint256 s1 = _depositLender(10_000_000);
        assertGt(s1, 0);
        // issue advance -> idle drops, lender cannot withdraw full deposit
        bytes32 job = keccak256("job-1");
        _requestAdvance(job, nova);
        uint256 idle = vault.totalAssets();
        assertEq(idle, 10_000_000 - COST);
        uint256 maxW = vault.maxWithdraw(lender);
        assertLe(maxW, idle);
        vm.prank(lender);
        vm.expectRevert(); // withdrawing more than idle share reverts (ERC4626)
        vault.withdraw(10_000_000, lender, lender);
    }

    function test_SecondDepositProportionalAfterLoss() public {
        _depositLender(10_000_000);
        _requestAdvance(keccak256("job-1"), nova);
        // force a default with no recovery -> share price falls; new deposit gets MORE shares per asset
        vm.warp(block.timestamp + 43_201);
        vault.penalize(nova);
        address lender2 = address(0xD00D);
        usdc.mint(lender2, 10_000_000);
        vm.startPrank(lender2);
        usdc.approve(address(vault), 8_000_000);
        uint256 s2 = vault.deposit(8_000_000, lender2);
        vm.stopPrank();
        assertGt(s2, 0);
    }

    // ---------- advance validation ----------

    function test_NonOperatorCannotRequest() public {
        vm.prank(buyer);
        vm.expectRevert(ComputeCreditVault.NotAuthorizedRequester.selector);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("x"), nova);
    }

    function test_BorrowerCanSelfRequest() public {
        _depositLender(10_000_000);
        vm.prank(nova);
        uint256 id = vault.requestAdvanceFor(nova, provider, COST, keccak256("self"), nova);
        assertEq(id, 1);
    }

    function test_NoTwoActiveAdvances() public {
        _depositLender(10_000_000);
        _requestAdvance(keccak256("job-1"), nova);
        vm.prank(operator);
        vm.expectRevert(ComputeCreditVault.HasActiveAdvance.selector);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("job-2"), nova);
    }

    function test_UnknownProviderReverts() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.requestAdvanceFor(nova, address(0xDEAD), COST, keccak256("j"), nova);
    }

    function test_OverProviderPriceReverts() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.requestAdvanceFor(nova, provider, PROVIDER_PRICE + 1, keccak256("j"), nova);
    }

    function test_OverTierLimitReverts() public {
        // score 300 -> 5 USDC limit; provider price is 5 USDC so raise price first
        vm.prank(owner);
        registry.updatePrice(provider, 100_000_000);
        vm.prank(operator);
        vm.expectRevert();
        vault.requestAdvanceFor(nova, provider, 6_000_000, keccak256("j"), nova);
    }

    function test_JobHashReuseRevertsAfterSettle() public {
        _depositLender(20_000_000);
        bytes32 job = keccak256("reuse");
        uint256 id = _requestAdvance(job, nova);
        // fully service via router then try same hash again
        uint256 repayable = vault.repayableOf(id);
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        // buyer payment sized so 20% split covers full repayable: payment = repayable*5
        router.routePayment(nova, repayable * 5, nova);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Settled));
        vm.prank(operator);
        vm.expectRevert(ComputeCreditVault.JobHashUsed.selector);
        vault.requestAdvanceFor(nova, provider, COST, job, nova);
    }

    function test_InsufficientLiquidityReverts() public {
        _depositLender(1_000_000); // 1 USDC < 2 USDC cost
        vm.prank(operator);
        vm.expectRevert();
        vault.requestAdvanceFor(nova, provider, COST, keccak256("j"), nova);
    }

    // ---------- EIP-712 consent ----------

    function test_RequestWithSigWorks() public {
        _depositLender(10_000_000);
        bytes32 job = keccak256("sig-job");
        uint256 nonce = vault.nonces(nova);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _intentDigest(nova, provider, COST, job, nova, nonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(novaKey, digest);
        vm.prank(buyer); // anyone can relay
        uint256 id = vault.requestAdvanceWithSig(nova, provider, COST, job, nova, nonce, expiry, abi.encodePacked(r, s, v));
        assertEq(id, 1);
    }

    function test_RequestWithBadSigReverts() public {
        _depositLender(10_000_000);
        uint256 badKey = 0xBAD;
        bytes32 job = keccak256("sig-job");
        uint256 nonce = vault.nonces(nova);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _intentDigest(nova, provider, COST, job, nova, nonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badKey, digest);
        vm.expectRevert(ComputeCreditVault.BadSignature.selector);
        vault.requestAdvanceWithSig(nova, provider, COST, job, nova, nonce, expiry, abi.encodePacked(r, s, v));
    }

    // ---------- servicing ----------

    function test_NonRouterServiceReverts() public {
        _depositLender(10_000_000);
        _requestAdvance(keccak256("job-1"), nova);
        vm.prank(buyer);
        vm.expectRevert(ComputeCreditVault.NotRouter.selector);
        vault.serviceAdvanceWithTransfer(nova, 1);
    }

    function test_PartialThenFullServiceViaRouter() public {
        _depositLender(10_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(id); // 2_010_000
        assertEq(vault.totalOutstanding(), repayable);

        // partial: buyer pays 5 USDC -> 20% = 1 USDC serviced
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        (uint256 toVault1, uint256 toNova1) = router.routePayment(nova, 5_000_000, nova);
        vm.stopPrank();
        assertEq(toVault1, 1_000_000);
        assertEq(toNova1, 4_000_000);
        assertEq(vault.totalOutstanding(), repayable - 1_000_000);
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Active));
        _assertOutstandingEqualsActiveSum();

        // remainder: buyer pays enough to cover rest
        uint256 rest = vault.remainingOf(id);
        vm.startPrank(buyer);
        (uint256 toVault2,) = router.routePayment(nova, rest * 5, nova);
        vm.stopPrank();
        assertEq(toVault2, rest);
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Settled));
        assertEq(vault.totalOutstanding(), 0);
        assertEq(uint256(passport.score(nova)), 350); // 300 + 50 bump, exactly once
        // post-settlement routed payments forward 100% to borrower (no active advance, no lien)
        vm.startPrank(buyer);
        (uint256 vAfter, uint256 nAfter) = router.routePayment(nova, 1_000_000, nova);
        vm.stopPrank();
        assertEq(vAfter, 0);
        assertEq(nAfter, 1_000_000);
    }

    function test_NoDoubleDecrementOnSettle() public {
        _depositLender(10_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(id);
        uint256 outBefore = vault.totalOutstanding();
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        router.routePayment(nova, repayable * 5, nova);
        vm.stopPrank();
        assertEq(outBefore, repayable);
        assertEq(vault.totalOutstanding(), 0); // not negative, decremented exactly repayable
    }

    function test_EarlyRepaySamePath() public {
        _depositLender(10_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        usdc.mint(nova, 5_000_000);
        uint256 repayable = vault.repayableOf(id);
        vm.startPrank(nova);
        usdc.approve(address(vault), repayable);
        vault.repayEarly(nova, repayable);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Settled));
        assertEq(vault.totalOutstanding(), 0);
    }

    // ---------- default + lien ----------

    function test_PenalizeBeforeExpiryReverts() public {
        _depositLender(10_000_000);
        _requestAdvance(keccak256("job-1"), nova);
        vm.expectRevert(ComputeCreditVault.NotOverdue.selector);
        vault.penalize(nova);
    }

    function test_DefaultRecordsShortfallAndLien() public {
        _depositLender(10_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(id);
        vm.warp(block.timestamp + 43_201);
        vault.penalize(nova);
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Defaulted));
        assertEq(vault.totalOutstanding(), 0);
        uint256 target = vault.lienTarget(nova);
        assertEq(target, (repayable * 11_000) / 10_000); // 10% surcharge
        assertEq(uint256(passport.score(nova)), 0); // 300 - 300 slash
        // repeated penalize reverts
        vm.expectRevert();
        vault.penalize(nova);
    }

    function test_LienCaptureCapsAtTargetAndForwardsExcess() public {
        _depositLender(20_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(id);
        uint256 target = (repayable * 11_000) / 10_000;
        vm.warp(block.timestamp + 43_201);
        vault.penalize(nova);

        // nova blocked from new advance while lien open
        vm.prank(operator);
        vm.expectRevert(ComputeCreditVault.RevenueSourceLocked.selector);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("job-2"), nova);

        // route a huge payment: 50% capture capped at target, rest to nova
        uint256 novaBefore = usdc.balanceOf(nova);
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        (uint256 toVault, uint256 toNova) = router.routePayment(nova, 100_000_000, nova);
        vm.stopPrank();
        assertEq(toVault, target);
        assertEq(toNova, 100_000_000 - target);
        assertEq(usdc.balanceOf(nova) - novaBefore, toNova);
        assertEq(vault.lienCaptured(nova), target);
        // further routed payments go 100% to borrower (lien cleared)
        usdc.mint(buyer, 1_000_000);
        vm.startPrank(buyer);
        (uint256 v2, uint256 n2) = router.routePayment(nova, 1_000_000, nova);
        vm.stopPrank();
        assertEq(v2, 0);
        assertEq(n2, 1_000_000);
    }

    function test_PartialDefaultWithPartialService() public {
        _depositLender(10_000_000);
        uint256 id = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(id);
        // service 1 USDC first
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        router.routePayment(nova, 5_000_000, nova);
        vm.stopPrank();
        uint256 shortfall = repayable - 1_000_000;
        vm.warp(block.timestamp + 43_201);
        vault.penalize(nova);
        assertEq(vault.lienTarget(nova), (shortfall * 11_000) / 10_000);
        assertEq(vault.totalOutstanding(), 0);
    }

    // ---------- passport ----------

    function test_SeedOnlyOnce() public {
        vm.prank(owner);
        vm.expectRevert();
        passport.seedScore(nova, 500, "again");
    }

    function test_ScoreCapsAt1000() public {
        address rich = address(0xCCC1);
        vm.startPrank(owner);
        passport.seedScore(rich, 990, "high");
        vm.stopPrank();
        // simulate 5 settlements bumping +50 each but capped
        vm.startPrank(address(vault));
        for (uint256 i; i < 5; i++) passport.notifySettled(rich);
        vm.stopPrank();
        assertEq(passport.score(rich), 1000);
    }

    // ---------- full happy path (demo script) ----------

    function test_FullHappyPath() public {
        // 1. lender deposits 10 USDC
        _depositLender(10_000_000);
        // 2. nova (0 balance) requests 2 USDC advance
        assertEq(usdc.balanceOf(nova), 0);
        uint256 id = _requestAdvance(keccak256("nova-job-1"), nova);
        assertEq(usdc.balanceOf(nova), COST); // provider cost in hand
        // 3. orchestrator pays provider (simulated: nova forwards exact cost)
        vm.prank(nova);
        usdc.transfer(providerPayout, COST);
        assertEq(usdc.balanceOf(providerPayout), COST);
        // 4. buyer pays 10 USDC through router; 20% split = 2 USDC services principal, fee remainder stays
        // repayable = 2.01 USDC; first payment services 2.0, leaving 0.01
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        router.routePayment(nova, 10_000_000, nova);
        vm.stopPrank();
        assertEq(vault.remainingOf(id), vault.repayableOf(id) - 2_000_000);
        // 5. second small payment clears fee -> settled, score bumped
        vm.startPrank(buyer);
        router.routePayment(nova, 1_000_000, nova);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Settled));
        _assertOutstandingEqualsActiveSum();
    }
}
