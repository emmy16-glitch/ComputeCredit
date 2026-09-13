// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.t.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";

/// @notice Fuzz coverage over the core accounting invariant:
///         totalOutstanding == active remaining at every step, under random payments.
contract FuzzTest is Base {
    /// @notice Random buyer payments never break the outstanding invariant and never over-service.
    function testFuzz_RouterPaymentsKeepInvariant(uint256 pay1, uint256 pay2) public {
        pay1 = bound(pay1, 100, 50_000_000);
        pay2 = bound(pay2, 100, 50_000_000);
        _depositLender(60_000_000);
        uint256 id = _requestAdvance(keccak256("fuzz-1"), nova);
        uint256 repayable = vault.repayableOf(id);

        usdc.mint(buyer, pay1 + pay2);
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        router.routePayment(nova, pay1, nova);
        _assertOutstandingEqualsActiveSum();
        // serviced can never exceed repayable
        assertLe(repayable - vault.remainingOf(id), repayable);
        router.routePayment(nova, pay2, nova);
        vm.stopPrank();
        _assertOutstandingEqualsActiveSum();
        if (vault.activeAdvanceId(nova) == 0) {
            assertEq(vault.totalOutstanding(), 0);
            assertEq(uint8(_status(id)), uint8(ComputeCreditVault.Status.Settled));
        }
    }

    /// @notice Deposits then full withdrawals (no advances) always round-trip within dust.
    function testFuzz_DepositWithdrawRoundtrip(uint96 a, uint96 b) public {
        uint256 d1 = bound(uint256(a), 1_000_000, 20_000_000);
        uint256 d2 = bound(uint256(b), 1_000_000, 20_000_000);
        vm.startPrank(lender);
        usdc.approve(address(vault), d1 + d2);
        vault.deposit(d1, lender);
        vault.deposit(d2, lender);
        uint256 maxW = vault.maxWithdraw(lender);
        // idle-only assets: full deposit value withdrawable when no advances exist
        assertApproxEqAbs(maxW, d1 + d2, 2);
        vault.withdraw(maxW, lender, lender);
        vm.stopPrank();
        assertApproxEqAbs(usdc.balanceOf(lender), 100_000_000, 2);
    }

    /// @notice Repeated settle bumps can never push score past 1000 (any start score).
    function testFuzz_ScoreCapHolds(uint256 startScore, uint8 bumps) public {
        startScore = bound(startScore, 0, 1_000);
        bumps = uint8(bound(uint256(bumps), 1, 20));
        address agent = address(uint160(0xF0F0 + bumps));
        vm.startPrank(owner);
        passport.seedScore(agent, startScore, "fuzz");
        vm.stopPrank();
        vm.startPrank(address(vault));
        for (uint256 i; i < bumps; i++) passport.notifySettled(agent);
        vm.stopPrank();
        assertLe(passport.score(agent), 1_000);
    }

    /// @notice Lien capture of random amounts never exceeds target and always clears exactly.
    function testFuzz_LienCaptureBounded(uint256 bigPayment) public {
        bigPayment = bound(bigPayment, 1_000_000, 200_000_000);
        _depositLender(20_000_000);
        _requestAdvance(keccak256("fuzz-lien"), nova);
        vm.warp(block.timestamp + 43_201);
        vault.penalize(nova);
        uint256 target = vault.lienTarget(nova);
        usdc.mint(buyer, bigPayment);
        vm.startPrank(buyer);
        usdc.approve(address(router), type(uint256).max);
        (uint256 toVault,) = router.routePayment(nova, bigPayment, nova);
        vm.stopPrank();
        assertLe(toVault, target);
        assertEq(vault.lienCaptured(nova), toVault);
        assertLe(vault.lienCaptured(nova), target);
    }
}
