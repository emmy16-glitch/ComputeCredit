// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RevenueRouter} from "./RevenueRouter.sol";

/// @title FacilitatorAdapter
/// @notice Planned module ("facilitator auto-settlement"): abstracts the x402
///         facilitator transport. The CDP facilitator does NOT support X Layer, so on
///         X Layer this contract records the x402 intent hash and settles via the
///         onchain RevenueRouter (auditable fallback). On facilitator-supported chains
///         the owner marks them supported and offchain relayers complete facilitator
///         settlement referencing the recorded intent.
/// @dev Never claims facilitator settlement on X Layer — see README honesty note.
contract FacilitatorAdapter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    RevenueRouter public immutable router;
    IERC20 public immutable usdc;

    mapping(uint256 chainId => bool) public facilitatorSupported;
    mapping(bytes32 intentHash => bool) public intentRecorded;
    uint256 public intentCount;

    event IntentRecorded(bytes32 indexed intentHash, address indexed payer, address indexed borrower, uint256 amount, uint256 chainId, bool facilitatorPath);
    event FacilitatorChainSet(uint256 indexed chainId, bool supported);
    event AdaptedPayment(bytes32 indexed intentHash, uint256 toVault, uint256 toBorrower, bool facilitatorPath);

    error ZeroAmount();
    error ZeroAddress();

    constructor(RevenueRouter router_, address owner_) Ownable(owner_) {
        router = router_;
        usdc = IERC20(router_.vault().asset());
    }

    function setFacilitatorSupported(uint256 chainId, bool supported) external onlyOwner {
        facilitatorSupported[chainId] = supported;
        emit FacilitatorChainSet(chainId, supported);
    }

    /// @notice Pull buyer funds, record the x402 intent, settle via router fallback
    ///         (or flag facilitator path for supported chains; onchain leg stays router).
    function recordAndRoute(
        address borrower,
        uint256 amount,
        address borrowerDestination,
        bytes32 intentHash,
        uint256 settlementChainId
    ) external nonReentrant whenNotPaused returns (uint256 toVault, uint256 toBorrower, bool facilitatorPath) {
        if (amount == 0) revert ZeroAmount();
        if (borrower == address(0) || borrowerDestination == address(0)) revert ZeroAddress();
        facilitatorPath = facilitatorSupported[settlementChainId];
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        if (!intentRecorded[intentHash]) {
            intentRecorded[intentHash] = true;
            intentCount += 1;
        }
        emit IntentRecorded(intentHash, msg.sender, borrower, amount, settlementChainId, facilitatorPath);
        usdc.approve(address(router), amount);
        (toVault, toBorrower) = router.routePayment(borrower, amount, borrowerDestination);
        usdc.approve(address(router), 0);
        emit AdaptedPayment(intentHash, toVault, toBorrower, facilitatorPath);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
