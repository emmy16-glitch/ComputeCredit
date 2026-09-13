// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProviderRegistry
 * @notice Approved compute providers and their maximum quoted price per job.
 *
 * Spec reference: ComputeCredit_v2.pdf §6 (Provider registry).
 *
 * Why this exists: the vault must never trust a caller-supplied quote. A free-form
 * `providerQuote` calldata parameter would let an orchestrator (or anyone) request an
 * inflated advance. Instead the registry is the single source of truth for the price,
 * and the vault caps every advance at the registered price at request time.
 *
 * Trust boundary (spec §3.1): the registry owner / approved administrators are trusted in
 * the MVP. Every mutation emits an event so the price history stays auditable.
 */
contract ProviderRegistry is Ownable {
    /// @notice Per-provider quote record (spec §6 — field-for-field).
    struct ProviderQuote {
        bool active;
        address providerWallet;
        uint256 pricePerJob;
        uint256 updatedAt;
        bytes32 serviceId;
    }

    /// @notice Provider address => quote.
    mapping(address => ProviderQuote) public providerQuotes;

    /// @notice Approved administrators allowed to register providers and update prices.
    mapping(address => bool) public administrators;

    /// @notice Number of providers ever registered (monotonic, for reporting).
    uint256 public providerCount;

    event AdministratorSet(address indexed administrator, bool approved);
    event ProviderRegistered(
        address indexed provider, address indexed providerWallet, uint256 pricePerJob, bytes32 serviceId
    );
    event ProviderPriceUpdated(address indexed provider, uint256 previousPrice, uint256 newPrice);
    event ProviderWalletUpdated(address indexed provider, address previousWallet, address newWallet);
    event ProviderStatusUpdated(address indexed provider, bool active);
    event ProviderServiceUpdated(address indexed provider, bytes32 previousServiceId, bytes32 newServiceId);

    error ZeroAddress();
    error NotAdministrator();
    error ProviderAlreadyRegistered(address provider);
    error ProviderNotRegistered(address provider);
    error InvalidPrice();
    error DuplicateServiceRegistered(address provider, bytes32 serviceId);

    /// @notice Optional reverse index: serviceId => provider, to make demos self-describing.
    mapping(bytes32 => address) public providerForService;

    constructor(address owner_) Ownable(owner_) { }

    modifier onlyAdministrator() {
        if (msg.sender != owner() && !administrators[msg.sender]) revert NotAdministrator();
        _;
    }

    /// @notice Grant or revoke administrator rights (owner only).
    function setAdministrator(address administrator, bool approved) external onlyOwner {
        if (administrator == address(0)) revert ZeroAddress();
        administrators[administrator] = approved;
        emit AdministratorSet(administrator, approved);
    }

    /**
     * @notice Register an approved provider with its maximum price per job.
     * @param provider         Address the vault binds advances to (the registry key).
     * @param wallet_          Wallet that actually receives provider payments.
     * @param price_           Maximum quoted price for one job, in token units (6 decimals).
     * @param serviceId_       Service identifier hashed into the job binding.
     */
    function registerProvider(address provider, address wallet_, uint256 price_, bytes32 serviceId_)
        external
        onlyAdministrator
    {
        if (provider == address(0) || wallet_ == address(0)) revert ZeroAddress();
        if (price_ == 0) revert InvalidPrice();
        if (providerQuotes[provider].updatedAt != 0) revert ProviderAlreadyRegistered(provider);
        if (serviceId_ != bytes32(0)) {
            address existing = providerForService[serviceId_];
            if (existing != address(0)) revert DuplicateServiceRegistered(existing, serviceId_);
            providerForService[serviceId_] = provider;
        }

        providerQuotes[provider] = ProviderQuote({
            active: true,
            providerWallet: wallet_,
            pricePerJob: price_,
            updatedAt: block.timestamp,
            serviceId: serviceId_
        });
        providerCount += 1;

        emit ProviderRegistered(provider, wallet_, price_, serviceId_);
    }

    /// @notice Update the maximum price per job for a registered provider.
    function updateProviderPrice(address provider, uint256 newPrice) external onlyAdministrator {
        ProviderQuote storage quote = providerQuotes[provider];
        if (quote.updatedAt == 0) revert ProviderNotRegistered(provider);
        if (newPrice == 0) revert InvalidPrice();

        uint256 previous = quote.pricePerJob;
        quote.pricePerJob = newPrice;
        quote.updatedAt = block.timestamp;

        emit ProviderPriceUpdated(provider, previous, newPrice);
    }

    /// @notice Update the wallet that receives provider payments.
    function updateProviderWallet(address provider, address newWallet) external onlyAdministrator {
        if (newWallet == address(0)) revert ZeroAddress();
        ProviderQuote storage quote = providerQuotes[provider];
        if (quote.updatedAt == 0) revert ProviderNotRegistered(provider);

        address previous = quote.providerWallet;
        quote.providerWallet = newWallet;
        quote.updatedAt = block.timestamp;

        emit ProviderWalletUpdated(provider, previous, newWallet);
    }

    /// @notice Update the service identifier bound into job hashes.
    function updateProviderService(address provider, bytes32 newServiceId) external onlyAdministrator {
        ProviderQuote storage quote = providerQuotes[provider];
        if (quote.updatedAt == 0) revert ProviderNotRegistered(provider);
        if (newServiceId != bytes32(0) && providerForService[newServiceId] != address(0) && providerForService[newServiceId] != provider) {
            revert DuplicateServiceRegistered(providerForService[newServiceId], newServiceId);
        }

        bytes32 previous = quote.serviceId;
        quote.serviceId = newServiceId;
        quote.updatedAt = block.timestamp;
        if (newServiceId != bytes32(0)) providerForService[newServiceId] = provider;

        emit ProviderServiceUpdated(provider, previous, newServiceId);
    }

    /// @notice Activate or deactivate a provider. Inactive providers cannot back advances.
    function setProviderActive(address provider, bool isActive_) external onlyAdministrator {
        ProviderQuote storage quote = providerQuotes[provider];
        if (quote.updatedAt == 0) revert ProviderNotRegistered(provider);
        quote.active = isActive_;
        quote.updatedAt = block.timestamp;
        emit ProviderStatusUpdated(provider, isActive_);
    }

    // ---------------------------------------------------------------------
    // Views used by the vault, orchestrator and dashboard
    // ---------------------------------------------------------------------

    /// @notice Full quote struct for a provider (named accessor for external tooling).
    function quoteOf(address provider) external view returns (ProviderQuote memory) {
        return providerQuotes[provider];
    }

    /// @notice True when the provider is registered and active.
    function isActive(address provider) external view returns (bool) {
        return providerQuotes[provider].active;
    }

    /// @notice Registered maximum price per job (0 when unknown).
    function pricePerJob(address provider) external view returns (uint256) {
        return providerQuotes[provider].pricePerJob;
    }

    /// @notice Registered payout wallet for a provider.
    function providerWallet(address provider) external view returns (address) {
        return providerQuotes[provider].providerWallet;
    }

    /// @notice Registered service identifier for a provider.
    function serviceId(address provider) external view returns (bytes32) {
        return providerQuotes[provider].serviceId;
    }

    /**
     * @notice Canonical job hash for stronger job binding (spec §6).
     * @dev jobHash = keccak256(borrower, provider, serviceId, quotedPrice, nonce, expiry)
     *      The provider or borrower should sign this offchain; the MVP may use the
     *      orchestrator as trusted job coordinator, but the hash is always stored onchain.
     */
    function computeJobHash(
        address borrower,
        address provider,
        bytes32 serviceId_,
        uint256 quotedPrice,
        uint256 nonce,
        uint256 expiry
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(borrower, provider, serviceId_, quotedPrice, nonce, expiry));
    }

    /// @notice Pure variant for offchain tooling that already holds the service id.
    function computeJobHashRaw(
        address borrower,
        address provider,
        bytes32 serviceId_,
        uint256 quotedPrice,
        uint256 nonce,
        uint256 expiry
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(borrower, provider, serviceId_, quotedPrice, nonce, expiry));
    }
}
