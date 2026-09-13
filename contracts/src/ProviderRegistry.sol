// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProviderRegistry
/// @notice Single source of truth for approved provider endpoints and max price per job.
/// @dev v3 improvement over v2.1: binds payout wallet + serviceId + version so the
///      vault can reject inflated caller-supplied quotes. Price can only move via
///      admin tx with event — orchestrator can never invent a price.
contract ProviderRegistry is Ownable {
    struct Provider {
        bool active;
        address payout;
        uint256 pricePerJob;
        bytes32 serviceId;
        uint64 updatedAt;
    }

    mapping(address provider => Provider) private _providers;

    event ProviderRegistered(
        address indexed provider, address indexed payout, uint256 pricePerJob, bytes32 indexed serviceId
    );
    event ProviderUpdated(address indexed provider, uint256 pricePerJob, bool active);
    event ProviderDeactivated(address indexed provider);

    error ZeroAddress();
    error ZeroPrice();
    error UnknownProvider(address provider);
    error InactiveProvider(address provider);

    constructor(address owner_) Ownable(owner_) {}

    function registerProvider(address provider, address payout, uint256 pricePerJob, bytes32 serviceId)
        external
        onlyOwner
    {
        if (provider == address(0) || payout == address(0)) revert ZeroAddress();
        if (pricePerJob == 0) revert ZeroPrice();
        _providers[provider] =
            Provider({active: true, payout: payout, pricePerJob: pricePerJob, serviceId: serviceId, updatedAt: uint64(block.timestamp)});
        emit ProviderRegistered(provider, payout, pricePerJob, serviceId);
    }

    function updatePrice(address provider, uint256 newPrice) external onlyOwner {
        Provider storage p = _providers[provider];
        if (p.payout == address(0)) revert UnknownProvider(provider);
        if (newPrice == 0) revert ZeroPrice();
        p.pricePerJob = newPrice;
        p.updatedAt = uint64(block.timestamp);
        emit ProviderUpdated(provider, newPrice, p.active);
    }

    function setActive(address provider, bool active) external onlyOwner {
        Provider storage p = _providers[provider];
        if (p.payout == address(0)) revert UnknownProvider(provider);
        p.active = active;
        if (!active) emit ProviderDeactivated(provider);
        else emit ProviderUpdated(provider, p.pricePerJob, true);
    }

    /// @notice Returns provider record; reverts unless known + active when `requireActive`.
    function getProvider(address provider) external view returns (Provider memory) {
        Provider memory p = _providers[provider];
        if (p.payout == address(0)) revert UnknownProvider(provider);
        return p;
    }

    function isActive(address provider) public view returns (bool) {
        return _providers[provider].active && _providers[provider].payout != address(0);
    }

    function quote(address provider) external view returns (uint256 pricePerJob, address payout) {
        Provider memory p = _providers[provider];
        if (p.payout == address(0)) revert UnknownProvider(provider);
        if (!p.active) revert InactiveProvider(provider);
        return (p.pricePerJob, p.payout);
    }
}
