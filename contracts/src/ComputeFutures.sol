// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RevenueRouter} from "./RevenueRouter.sol";

/// @title ComputeFutures
/// @notice Planned module from README ("compute futures"): providers pre-sell future
///         compute tranches; buyers reserve with locked USDC; settlement always routes
///         via RevenueRouter so indebted workers auto-service advances first.
/// @dev Minimal v1: offer -> reserve -> settleViaRouter | cancelExpired | providerWithdraw.
///      Prices are owner-registered per offer (provider allowlist enforced offchain + onchain
///      via provider allowlist mapping). Like WorkEscrow, this turns expected revenue
///      into a locked receivable for underwriting.
contract ComputeFutures is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Reserved,
        Settled,
        Cancelled
    }

    struct Offer {
        uint256 id;
        address provider;
        uint256 pricePerJob;
        uint256 capacity; // jobs available
        uint256 reserved;
        uint256 expiry;
        bytes32 serviceId;
        Status status;
    }

    struct Reservation {
        uint256 offerId;
        address buyer;
        address worker; // agent performing the future job (advance borrower)
        uint256 jobs;
        uint256 locked; // USDC locked = jobs * pricePerJob
        Status status;
    }

    IERC20 public immutable usdc;
    RevenueRouter public immutable router;

    uint256 public nextOfferId = 1;
    uint256 public nextReservationId = 1;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Reservation) public reservations;
    mapping(address provider => bool) public allowedProviders;

    event ProviderAllowed(address indexed provider, bool allowed);
    event OfferCreated(uint256 indexed id, address indexed provider, uint256 pricePerJob, uint256 capacity, uint256 expiry);
    event Reserved(uint256 indexed reservationId, uint256 indexed offerId, address indexed buyer, address worker, uint256 jobs, uint256 locked);
    event FutureSettled(uint256 indexed reservationId, uint256 toVault, uint256 toWorker);
    event FutureCancelled(uint256 indexed reservationId, address indexed buyer, uint256 refunded);

    error ZeroAmount();
    error ZeroAddress();
    error NotAllowedProvider();
    error BadExpiry();
    error BadCapacity();
    error OverCapacity(uint256 want, uint256 free);
    error BadStatus();
    error NotBuyer();
    error NotExpired();

    constructor(IERC20 usdc_, RevenueRouter router_, address owner_) Ownable(owner_) {
        usdc = usdc_;
        router = router_;
    }

    function setProviderAllowed(address provider, bool allowed) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        allowedProviders[provider] = allowed;
        emit ProviderAllowed(provider, allowed);
    }

    /// @notice Provider pre-sells `capacity` jobs at `pricePerJob` until `expiry`.
    function offer(uint256 pricePerJob, uint256 capacity, uint256 expiry, bytes32 serviceId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (!allowedProviders[msg.sender]) revert NotAllowedProvider();
        if (pricePerJob == 0 || capacity == 0) revert BadCapacity();
        if (expiry <= block.timestamp) revert BadExpiry();
        id = nextOfferId++;
        offers[id] = Offer({
            id: id,
            provider: msg.sender,
            pricePerJob: pricePerJob,
            capacity: capacity,
            reserved: 0,
            expiry: expiry,
            serviceId: serviceId,
            status: Status.Open
        });
        emit OfferCreated(id, msg.sender, pricePerJob, capacity, expiry);
    }

    /// @notice Buyer locks USDC for `jobs` of future compute performed by `worker`.
    function reserve(uint256 offerId, address worker, uint256 jobs)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 reservationId)
    {
        Offer storage o = offers[offerId];
        if (o.status != Status.Open) revert BadStatus();
        if (block.timestamp > o.expiry) revert BadExpiry();
        if (worker == address(0)) revert ZeroAddress();
        if (jobs == 0) revert ZeroAmount();
        if (o.reserved + jobs > o.capacity) revert OverCapacity(jobs, o.capacity - o.reserved);
        uint256 locked = jobs * o.pricePerJob;
        usdc.safeTransferFrom(msg.sender, address(this), locked);
        o.reserved += jobs;
        reservationId = nextReservationId++;
        reservations[reservationId] = Reservation({
            offerId: offerId,
            buyer: msg.sender,
            worker: worker,
            jobs: jobs,
            locked: locked,
            status: Status.Reserved
        });
        emit Reserved(reservationId, offerId, msg.sender, worker, jobs, locked);
    }

    /// @notice Settle a reservation: funds flow through the RevenueRouter (services worker debt first).
    function settleViaRouter(uint256 reservationId, address workerDestination)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 toVault, uint256 toWorker)
    {
        Reservation storage r = reservations[reservationId];
        if (r.status != Status.Reserved) revert BadStatus();
        r.status = Status.Settled;
        usdc.approve(address(router), r.locked);
        (toVault, toWorker) = router.routePayment(r.worker, r.locked, workerDestination);
        usdc.approve(address(router), 0);
        emit FutureSettled(reservationId, toVault, toWorker);
    }

    /// @notice Buyer reclaims locked funds after offer expiry when never settled.
    function cancelExpired(uint256 reservationId) external nonReentrant whenNotPaused {
        Reservation storage r = reservations[reservationId];
        if (msg.sender != r.buyer) revert NotBuyer();
        if (r.status != Status.Reserved) revert BadStatus();
        if (block.timestamp <= offers[r.offerId].expiry) revert NotExpired();
        r.status = Status.Cancelled;
        usdc.safeTransfer(r.buyer, r.locked);
        emit FutureCancelled(reservationId, r.buyer, r.locked);
    }

    function freeCapacity(uint256 offerId) external view returns (uint256) {
        Offer memory o = offers[offerId];
        return o.capacity - o.reserved;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
