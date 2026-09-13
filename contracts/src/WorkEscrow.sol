// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RevenueRouter} from "./RevenueRouter.sol";

/// @title WorkEscrow
/// @notice STRETCH module (not on core-demo critical path): buyer-escrowed receivable.
/// @dev A client locks USDC for a job. Release ALWAYS routes through the authorized
///      RevenueRouter, so an indebted worker automatically services their vault advance
///      and keeps the remainder — the escrow is what turns "expected future revenue"
///      into a locked receivable, the strongest underwriting story for lenders.
///      If the worker has no debt, the router forwards 100% — uniform, auditable path.
contract WorkEscrow is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Funded,
        Delivered,
        Released,
        Refunded
    }

    struct Escrow {
        uint256 id;
        address client;
        address worker;
        uint256 amount;
        uint256 deadline;
        address arbiter;
        bytes32 jobHash;
        bytes32 resultHash;
        Status status;
    }

    IERC20 public immutable usdc;
    RevenueRouter public immutable router;

    uint256 public nextEscrowId = 1;
    mapping(uint256 id => Escrow) public escrows;

    event EscrowFunded(
        uint256 indexed id, address indexed client, address indexed worker, uint256 amount, bytes32 jobHash, uint256 deadline
    );
    event ResultSubmitted(uint256 indexed id, bytes32 indexed resultHash);
    event EscrowReleased(uint256 indexed id, address indexed worker, uint256 toVault, uint256 toWorker);
    event EscrowRefunded(uint256 indexed id, address indexed client, uint256 amount);
    event EscrowResolved(uint256 indexed id, bool releasedToWorker);

    error ZeroAmount();
    error ZeroAddress();
    error BadDeadline();
    error OnlyWorker();
    error OnlyClient();
    error OnlyArbiter();
    error BadStatus(Status want, Status got);
    error NotOverdue();
    error AlreadySettled();

    constructor(IERC20 usdc_, RevenueRouter router_, address owner_) Ownable(owner_) {
        usdc = usdc_;
        router = router_;
    }

    /// @notice Client locks funds for a job. Pulls USDC from caller.
    function fund(address worker, uint256 amount, uint256 deadline, address arbiter_, bytes32 jobHash)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (worker == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert BadDeadline();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        id = nextEscrowId++;
        escrows[id] = Escrow({
            id: id,
            client: msg.sender,
            worker: worker,
            amount: amount,
            deadline: deadline,
            arbiter: arbiter_,
            jobHash: jobHash,
            resultHash: bytes32(0),
            status: Status.Funded
        });
        emit EscrowFunded(id, msg.sender, worker, amount, jobHash, deadline);
    }

    /// @notice Worker posts a result hash. Offchain payload verified by client/arbiter.
    function submitResult(uint256 id, bytes32 resultHash) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[id];
        if (msg.sender != e.worker) revert OnlyWorker();
        if (e.status != Status.Funded) revert BadStatus(Status.Funded, e.status);
        e.resultHash = resultHash;
        e.status = Status.Delivered;
        emit ResultSubmitted(id, resultHash);
    }

    /// @notice Client accepts the result → release via router (services any advance first).
    function confirm(uint256 id) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[id];
        if (msg.sender != e.client) revert OnlyClient();
        if (e.status != Status.Delivered) revert BadStatus(Status.Delivered, e.status);
        _release(e);
    }

    /// @notice Arbiter resolves Funded/Delivered escrows: true = pay worker (via router), false = refund.
    function resolve(uint256 id, bool releaseToWorker) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[id];
        if (msg.sender != e.arbiter) revert OnlyArbiter();
        if (e.status != Status.Funded && e.status != Status.Delivered) revert AlreadySettled();
        if (releaseToWorker) _release(e);
        else _refund(e);
        emit EscrowResolved(id, releaseToWorker);
    }

    /// @notice Client reclaims funds after deadline when nothing was ever delivered.
    function refundExpired(uint256 id) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[id];
        if (msg.sender != e.client) revert OnlyClient();
        if (e.status != Status.Funded) revert BadStatus(Status.Funded, e.status);
        if (block.timestamp <= e.deadline) revert NotOverdue();
        _refund(e);
    }

    function _release(Escrow storage e) internal {
        e.status = Status.Released;
        usdc.approve(address(router), e.amount);
        (uint256 toVault, uint256 toWorker) = router.routePayment(e.worker, e.amount, e.worker);
        usdc.approve(address(router), 0);
        emit EscrowReleased(e.id, e.worker, toVault, toWorker);
    }

    function _refund(Escrow storage e) internal {
        e.status = Status.Refunded;
        usdc.safeTransfer(e.client, e.amount);
        emit EscrowRefunded(e.id, e.client, e.amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
