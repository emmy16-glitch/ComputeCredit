// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WorkEscrow
 * @notice STRETCH MODULE (spec §13). NOT part of the core demo claim.
 *
 * It stays deliberately separate from `ComputeCreditVault`: the core vault must work, and be
 * demonstrable, without this contract. Nothing in the core advance lifecycle depends on it.
 *
 * Minimum flow (spec §13):
 *   1. the client deposits USDC (locked against one job);
 *   2. the escrow stores jobHash, worker, amount, deadline and arbiter;
 *   3. the worker delivers a result hash;
 *   4. the client confirms, or the worker disputes;
 *   5. the escrow releases funds to the worker or resolves per the arbiter rule;
 *   6. the release can optionally be routed through the revenue router, in which case a
 *      compute advance is serviced out of the escrowed receivable before the remainder
 *      reaches the worker.
 *
 * Honest framing: the escrowed receivable is the strongest *future* underwriting improvement
 * named in the specification (§3.2, §10.2). Shipping it as a separate, tested contract does not
 * upgrade the core MVP's trust claims.
 */
contract WorkEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum JobState {
        None,
        Funded,
        Delivered,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    struct Job {
        address client;
        address worker;
        address arbiter;
        uint256 amount;
        uint256 deadline;
        bytes32 jobHash;
        bytes32 resultHash;
        JobState state;
    }

    /// @notice Settlement token.
    IERC20 public immutable usdc;
    /// @notice Optional revenue router used when a release should service a compute advance.
    address public revenueRouter;
    /// @notice Protocol fee recipient for dispute fees (set to address(0) to disable).
    address public feeRecipient;
    /// @notice Dispute fee in bps of the job amount, paid to `feeRecipient` on arbiter resolution.
    uint256 public disputeFeeBps;
    uint256 public constant MAX_BPS = 10_000;

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;

    event JobFunded(uint256 indexed jobId, address indexed client, address indexed worker, uint256 amount, bytes32 jobHash, uint256 deadline, address arbiter);
    event ResultDelivered(uint256 indexed jobId, bytes32 resultHash);
    event JobReleased(uint256 indexed jobId, address indexed worker, uint256 amount, bool routedThroughRouter);
    event JobRefunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobDisputed(uint256 indexed jobId, address indexed by);
    event JobResolved(uint256 indexed jobId, address indexed arbiter, uint256 workerAmount, uint256 clientAmount, uint256 fee);
    event RevenueRouterUpdated(address indexed router);
    event DisputePolicyUpdated(address indexed feeRecipient, uint256 disputeFeeBps);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDeadline();
    error JobNotFunded(uint256 jobId);
    error JobNotDelivered(uint256 jobId);
    error NotClient(uint256 jobId);
    error NotWorker(uint256 jobId);
    error NotArbiter(uint256 jobId);
    error DeadlineNotPassed(uint256 jobId);
    error DeadlinePassed(uint256 jobId);
    error InvalidState(uint256 jobId, JobState state);
    error InvalidSplit();
    error RouterNotConfigured();

    constructor(IERC20 usdc_, address owner_) Ownable(owner_) {
        if (address(usdc_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    /// @notice Configure the router used for optional routed releases.
    function setRevenueRouter(address router) external onlyOwner {
        revenueRouter = router;
        emit RevenueRouterUpdated(router);
    }

    /// @notice Configure the dispute fee policy.
    function setDisputePolicy(address feeRecipient_, uint256 disputeFeeBps_) external onlyOwner {
        if (disputeFeeBps_ > MAX_BPS) revert InvalidSplit();
        feeRecipient = feeRecipient_;
        disputeFeeBps = disputeFeeBps_;
        emit DisputePolicyUpdated(feeRecipient_, disputeFeeBps_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Fund a job: the client locks `amount` USDC and names the worker and arbiter.
     * @dev The client must approve this contract for `amount` beforehand.
     */
    function fundJob(address worker, uint256 amount, bytes32 jobHash, uint256 deadline, address arbiter)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 jobId)
    {
        if (worker == address(0) || arbiter == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        jobId = ++jobCount;
        jobs[jobId] = Job({
            client: msg.sender,
            worker: worker,
            arbiter: arbiter,
            amount: amount,
            deadline: deadline,
            jobHash: jobHash,
            resultHash: bytes32(0),
            state: JobState.Funded
        });

        emit JobFunded(jobId, msg.sender, worker, amount, jobHash, deadline, arbiter);
    }

    /// @notice Worker publishes the delivered result hash.
    function deliverResult(uint256 jobId, bytes32 resultHash) external whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.state != JobState.Funded) revert InvalidState(jobId, job.state);
        if (msg.sender != job.worker) revert NotWorker(jobId);
        if (block.timestamp > job.deadline) revert DeadlinePassed(jobId);
        if (resultHash == bytes32(0)) revert ZeroAmount();

        job.resultHash = resultHash;
        job.state = JobState.Delivered;

        emit ResultDelivered(jobId, resultHash);
    }

    /**
     * @notice Client confirms delivery and releases funds.
     * @param jobId              Job to release.
     * @param routeThroughRouter When true, funds are pushed through the configured revenue
     *                           router, which services any compute advance of `job.worker`
     *                           before forwarding the remainder.
     */
    function release(uint256 jobId, bool routeThroughRouter) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.state != JobState.Delivered) revert JobNotDelivered(jobId);
        if (msg.sender != job.client) revert NotClient(jobId);

        job.state = JobState.Released;

        if (routeThroughRouter) {
            address router = revenueRouter;
            if (router == address(0)) revert RouterNotConfigured();
            usdc.forceApprove(router, job.amount);
            IRevenueRouter(router).routePayment(job.worker, job.amount, job.jobHash);
        } else {
            usdc.safeTransfer(job.worker, job.amount);
        }

        emit JobReleased(jobId, job.worker, job.amount, routeThroughRouter);
    }

    /// @notice Client reclaims funds after the deadline when nothing was delivered.
    function refundExpired(uint256 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.state != JobState.Funded) revert InvalidState(jobId, job.state);
        if (block.timestamp <= job.deadline) revert DeadlineNotPassed(jobId);

        job.state = JobState.Refunded;
        usdc.safeTransfer(job.client, job.amount);

        emit JobRefunded(jobId, job.client, job.amount);
    }

    /// @notice Either party escalates a delivered job to the arbiter.
    function dispute(uint256 jobId) external whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.state != JobState.Delivered) revert InvalidState(jobId, job.state);
        if (msg.sender != job.client && msg.sender != job.worker) revert NotClient(jobId);

        job.state = JobState.Disputed;

        emit JobDisputed(jobId, msg.sender);
    }

    /// @notice Arbiter resolves a disputed job by splitting the escrowed amount.
    function resolveDispute(uint256 jobId, uint256 workerAmount) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.state != JobState.Disputed) revert InvalidState(jobId, job.state);
        if (msg.sender != job.arbiter) revert NotArbiter(jobId);
        if (workerAmount > job.amount) revert InvalidSplit();

        uint256 fee = (job.amount * disputeFeeBps) / MAX_BPS;
        if (feeRecipient == address(0)) fee = 0;

        uint256 workerPayout = workerAmount > fee ? workerAmount - fee : 0;
        uint256 clientPayout = job.amount - workerAmount;

        job.state = JobState.Resolved;

        if (workerPayout > 0) usdc.safeTransfer(job.worker, workerPayout);
        if (fee > 0) usdc.safeTransfer(feeRecipient, fee);
        if (clientPayout > 0) usdc.safeTransfer(job.client, clientPayout);

        emit JobResolved(jobId, msg.sender, workerPayout, clientPayout, fee);
    }

    /// @notice Read model for tooling.
    function jobView(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}

/// @dev Minimal interface used for the optional routed release path.
interface IRevenueRouter {
    function routePayment(address borrower, uint256 amount, bytes32 paymentRef)
        external
        returns (uint256 serviced, uint256 lienCaptured, uint256 forwardedToBorrower);
}
