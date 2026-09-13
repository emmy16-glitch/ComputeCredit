// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.t.sol";
import {WorkEscrow} from "../src/WorkEscrow.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";

/// @notice Stretch-module tests: escrowed receivable + automatic advance servicing on release.
contract WorkEscrowTest is Base {
    uint256 constant ESCROW_AMOUNT = 10_000_000; // 10 USDC buyer payment

    function _fundedEscrow() internal returns (uint256 id) {
        vm.startPrank(client);
        usdc.approve(address(escrow), ESCROW_AMOUNT);
        id = escrow.fund(nova, ESCROW_AMOUNT, block.timestamp + 1 days, arbiter, keccak256("job-escrow-1"));
        vm.stopPrank();
    }

    function test_FundSubmitConfirmNoDebt() public {
        uint256 id = _fundedEscrow();
        vm.prank(nova);
        escrow.submitResult(id, keccak256("result-1"));
        uint256 before = usdc.balanceOf(nova);
        vm.prank(client);
        escrow.confirm(id);
        (,,,,,,,, WorkEscrow.Status s) = (escrow.escrows(id));
        assertEq(uint8(s), uint8(WorkEscrow.Status.Released));
        // no advance, no lien -> router forwards 100%
        assertEq(usdc.balanceOf(nova) - before, ESCROW_AMOUNT);
    }

    function test_ReleaseServicesActiveAdvanceAutomatically() public {
        _depositLender(20_000_000);
        uint256 advId = _requestAdvance(keccak256("job-1"), nova);
        uint256 repayable = vault.repayableOf(advId);

        uint256 id = _fundedEscrow();
        vm.prank(nova);
        escrow.submitResult(id, keccak256("result-1"));
        uint256 novaBefore = usdc.balanceOf(nova);
        vm.prank(client);
        escrow.confirm(id);

        // 20% of 10 USDC = 2 USDC serviced; fee 0.01 remains
        assertEq(vault.remainingOf(advId), repayable - 2_000_000);
        assertEq(usdc.balanceOf(nova) - novaBefore, ESCROW_AMOUNT - 2_000_000);
        _assertOutstandingEqualsActiveSum();
    }

    function test_ReleaseClearsFullAdvanceWhenLargeEnough() public {
        _depositLender(20_000_000);
        uint256 advId = _requestAdvance(keccak256("job-1"), nova);
        uint256 id = _fundedEscrow();
        vm.prank(nova);
        escrow.submitResult(id, keccak256("result-1"));
        vm.prank(client);
        escrow.confirm(id);
        // second escrow release clears the rest
        vm.startPrank(client);
        usdc.approve(address(escrow), ESCROW_AMOUNT);
        uint256 id2 = escrow.fund(nova, ESCROW_AMOUNT, block.timestamp + 1 days, arbiter, keccak256("job-escrow-2"));
        vm.stopPrank();
        vm.prank(nova);
        escrow.submitResult(id2, keccak256("result-2"));
        vm.prank(client);
        escrow.confirm(id2);
        assertEq(uint8(_status(advId)), uint8(ComputeCreditVault.Status.Settled));
        assertEq(vault.totalOutstanding(), 0);
    }

    function test_ConfirmBeforeDeliveryReverts() public {
        uint256 id = _fundedEscrow();
        vm.prank(client);
        vm.expectRevert();
        escrow.confirm(id);
    }

    function test_NonWorkerCannotSubmit() public {
        uint256 id = _fundedEscrow();
        vm.prank(buyer);
        vm.expectRevert(WorkEscrow.OnlyWorker.selector);
        escrow.submitResult(id, keccak256("x"));
    }

    function test_RefundExpiredWhenUndelivered() public {
        uint256 id = _fundedEscrow();
        uint256 before = usdc.balanceOf(client);
        vm.warp(block.timestamp + 2 days);
        vm.prank(client);
        escrow.refundExpired(id);
        assertEq(usdc.balanceOf(client) - before, ESCROW_AMOUNT);
    }

    function test_RefundBeforeDeadlineReverts() public {
        uint256 id = _fundedEscrow();
        vm.prank(client);
        vm.expectRevert(WorkEscrow.NotOverdue.selector);
        escrow.refundExpired(id);
    }

    function test_ArbiterCanRefundDisputedDelivery() public {
        uint256 id = _fundedEscrow();
        vm.prank(nova);
        escrow.submitResult(id, keccak256("result-1"));
        uint256 before = usdc.balanceOf(client);
        vm.prank(arbiter);
        escrow.resolve(id, false);
        assertEq(usdc.balanceOf(client) - before, ESCROW_AMOUNT);
    }

    function test_ArbiterCanReleaseToWorker() public {
        uint256 id = _fundedEscrow();
        uint256 before = usdc.balanceOf(nova);
        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(usdc.balanceOf(nova) - before, ESCROW_AMOUNT);
    }

    function test_DoubleReleaseReverts() public {
        uint256 id = _fundedEscrow();
        vm.prank(nova);
        escrow.submitResult(id, keccak256("result-1"));
        vm.prank(client);
        escrow.confirm(id);
        vm.prank(client);
        vm.expectRevert();
        escrow.confirm(id);
    }
}
