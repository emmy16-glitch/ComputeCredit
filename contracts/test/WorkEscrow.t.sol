// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { TestBase } from "./TestBase.sol";
import { WorkEscrow } from "../src/WorkEscrow.sol";

/**
 * @notice STRETCH MODULE tests (spec §13). The escrow is deliberately separate from the core
 *         vault: these tests prove it can be shipped independently without touching the core
 *         advance lifecycle.
 */
contract WorkEscrowTest is TestBase {
    WorkEscrow internal escrow;

    address internal client = makeAddr("escrowClient");
    address internal worker = makeAddr("escrowWorker");
    address internal arbiter = makeAddr("escrowArbiter");

    uint256 internal constant JOB_AMOUNT = 10e6; // 10 USDC
    bytes32 internal constant JOB_HASH = keccak256("escrow-job-1");
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();

        escrow = new WorkEscrow(usdc, admin);
        vm.prank(admin);
        escrow.setRevenueRouter(address(router));

        deadline = block.timestamp + 1 days;

        usdc.mint(client, 100e6);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(worker);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _fundJob() internal returns (uint256 jobId) {
        return _fundJobFor(worker);
    }

    function _fundJobFor(address worker_) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = escrow.fundJob(worker_, JOB_AMOUNT, JOB_HASH, deadline, arbiter);
    }

    // =====================================================================
    // Funding
    // =====================================================================

    function test_FundJobLocksClientFundsAndStoresBinding() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 jobId = _fundJob();

        assertEq(usdc.balanceOf(client), clientBefore - JOB_AMOUNT, "client funds are locked");
        assertEq(usdc.balanceOf(address(escrow)), JOB_AMOUNT);

        WorkEscrow.Job memory job = escrow.jobView(jobId);
        assertEq(job.client, client);
        assertEq(job.worker, worker);
        assertEq(job.arbiter, arbiter);
        assertEq(job.amount, JOB_AMOUNT);
        assertEq(job.jobHash, JOB_HASH);
        assertEq(job.deadline, deadline);
        assertEq(uint256(job.state), uint256(WorkEscrow.JobState.Funded));
    }

    function test_FundJobValidation() public {
        vm.expectRevert(WorkEscrow.ZeroAmount.selector);
        vm.prank(client);
        escrow.fundJob(worker, 0, JOB_HASH, deadline, arbiter);

        vm.expectRevert(WorkEscrow.InvalidDeadline.selector);
        vm.prank(client);
        escrow.fundJob(worker, JOB_AMOUNT, JOB_HASH, block.timestamp, arbiter);

        vm.expectRevert(WorkEscrow.ZeroAddress.selector);
        vm.prank(client);
        escrow.fundJob(address(0), JOB_AMOUNT, JOB_HASH, deadline, arbiter);

        vm.expectRevert(WorkEscrow.ZeroAddress.selector);
        vm.prank(client);
        escrow.fundJob(worker, JOB_AMOUNT, JOB_HASH, deadline, address(0));
    }

    // =====================================================================
    // Delivery and release
    // =====================================================================

    function test_WorkerDeliversResultHash() public {
        uint256 jobId = _fundJob();
        bytes32 resultHash = keccak256("result");

        vm.prank(worker);
        escrow.deliverResult(jobId, resultHash);

        assertEq(escrow.jobView(jobId).resultHash, resultHash);
        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Delivered));
    }

    function test_DeliverResultIsWorkerOnlyAndInTime() public {
        uint256 jobId = _fundJob();

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NotWorker.selector, jobId));
        vm.prank(client);
        escrow.deliverResult(jobId, keccak256("result"));

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlinePassed.selector, jobId));
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));
    }

    function test_ReleaseTransfersToWorker() public {
        uint256 jobId = _fundJob();
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));

        uint256 workerBefore = usdc.balanceOf(worker);
        vm.prank(client);
        escrow.release(jobId, false);

        assertEq(usdc.balanceOf(worker) - workerBefore, JOB_AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Released));
    }

    function test_ReleaseIsClientOnlyAndRequiresDelivery() public {
        uint256 jobId = _fundJob();

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotDelivered.selector, jobId));
        vm.prank(client);
        escrow.release(jobId, false);

        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NotClient.selector, jobId));
        vm.prank(worker);
        escrow.release(jobId, false);
    }

    /// @notice The strongest underwriting narrative of the stretch module: an escrowed receivable
    ///         services the worker's compute advance before the remainder is released to the worker.
    function test_RoutedReleaseServicesWorkerComputeAdvance() public {
        // Nova (the escrow worker) has a live 0.02 USDC advance from the core vault.
        _openAdvance(nova);
        assertEq(vault.remainingPrincipal(nova), PROVIDER_PRICE);

        uint256 jobId = _fundJobFor(nova);
        vm.prank(nova);
        escrow.deliverResult(jobId, keccak256("result"));

        uint256 novaBefore = usdc.balanceOf(nova);

        // Escrow -> router -> vault (servicing) -> Nova (remainder), all atomically inside release().
        vm.prank(client);
        escrow.release(jobId, true);

        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Released));
        assertEq(vault.remainingPrincipal(nova), 0, "advance settled from the escrowed receivable");
        assertTrue(vault.advanceOf(nova).settled);
        assertEq(usdc.balanceOf(nova) - novaBefore, JOB_AMOUNT - PROVIDER_PRICE, "worker keeps the remainder");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow holds nothing after a routed release");
        assertEq(passport.score(nova), BOOTSTRAP_SCORE + 20, "on-time settlement still bumps the score once");
    }

    function test_RoutedReleaseWithoutRouterReverts() public {
        WorkEscrow fresh = new WorkEscrow(usdc, admin);
        usdc.mint(client, JOB_AMOUNT);
        vm.prank(client);
        usdc.approve(address(fresh), type(uint256).max);
        vm.prank(client);
        uint256 jobId = fresh.fundJob(worker, JOB_AMOUNT, JOB_HASH, deadline, arbiter);
        vm.prank(worker);
        fresh.deliverResult(jobId, keccak256("result"));

        vm.expectRevert(WorkEscrow.RouterNotConfigured.selector);
        vm.prank(client);
        fresh.release(jobId, true);
    }

    // =====================================================================
    // Refunds and disputes
    // =====================================================================

    function test_RefundExpiredReturnsFundsAfterDeadline() public {
        uint256 jobId = _fundJob();

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlineNotPassed.selector, jobId));
        escrow.refundExpired(jobId);

        vm.warp(deadline + 1);
        uint256 clientBefore = usdc.balanceOf(client);
        escrow.refundExpired(jobId);

        assertEq(usdc.balanceOf(client) - clientBefore, JOB_AMOUNT);
        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Refunded));
    }

    function test_RefundRejectedAfterDelivery() public {
        uint256 jobId = _fundJob();
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InvalidState.selector, jobId, WorkEscrow.JobState.Delivered));
        escrow.refundExpired(jobId);
    }

    function test_DisputeAndArbiterResolution() public {
        uint256 jobId = _fundJob();
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NotClient.selector, jobId));
        vm.prank(outsider);
        escrow.dispute(jobId);

        vm.prank(client);
        escrow.dispute(jobId);
        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Disputed));

        // Arbiter splits 6 USDC to the worker, 4 USDC back to the client.
        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(arbiter);
        escrow.resolveDispute(jobId, 6e6);

        assertEq(usdc.balanceOf(worker) - workerBefore, 6e6);
        assertEq(usdc.balanceOf(client) - clientBefore, 4e6);
        assertEq(uint256(escrow.jobView(jobId).state), uint256(WorkEscrow.JobState.Resolved));
    }

    function test_ArbiterResolutionWithDisputeFee() public {
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(admin);
        escrow.setDisputePolicy(feeRecipient, 500); // 5% of the job amount

        uint256 jobId = _fundJob();
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));
        vm.prank(worker);
        escrow.dispute(jobId);

        vm.prank(arbiter);
        escrow.resolveDispute(jobId, JOB_AMOUNT); // worker wins the full amount

        uint256 fee = (JOB_AMOUNT * 500) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), fee, "dispute fee paid to the configured recipient");
        assertEq(usdc.balanceOf(worker), JOB_AMOUNT - fee, "worker receives the amount minus the fee");
    }

    function test_ResolveDisputeIsArbiterOnlyAndValidSplit() public {
        uint256 jobId = _fundJob();
        vm.prank(worker);
        escrow.deliverResult(jobId, keccak256("result"));
        vm.prank(worker);
        escrow.dispute(jobId);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NotArbiter.selector, jobId));
        vm.prank(outsider);
        escrow.resolveDispute(jobId, 1);

        vm.expectRevert(WorkEscrow.InvalidSplit.selector);
        vm.prank(arbiter);
        escrow.resolveDispute(jobId, JOB_AMOUNT + 1);
    }

    function test_EscrowPauseBlocksTokenMovement() public {
        vm.prank(admin);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(client);
        escrow.fundJob(worker, JOB_AMOUNT, JOB_HASH, deadline, arbiter);

        vm.prank(admin);
        escrow.unpause();
        _fundJob();
    }

    function test_EscrowAdminSettersAreOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        escrow.setRevenueRouter(outsider);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        escrow.setDisputePolicy(outsider, 100);

        vm.expectRevert(WorkEscrow.InvalidSplit.selector);
        vm.prank(admin);
        escrow.setDisputePolicy(outsider, 10_001);
    }
}
