// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Adversarial 6-decimal token that attempts a one-shot re-entry into a
///         target call during `transferFrom`.
/// @dev Ported from the Arena AI draft PR (idea credit) into the v3 suite: proves the
///      vault's ReentrancyGuard holds on every token-pulling path. The attack is
///      non-fatal to the outer tx by design — it records whether the inner call
///      reverted, then lets the outer flow continue so tests can assert BOTH that
///      the re-entry reverted AND that outer accounting applied exactly once.
contract ReentrantUSDC is ERC20 {
    address public attackTarget;
    bytes public attackData;
    bool public armed;
    bool public attackAttempted;
    bool public attackReverted;

    constructor() ERC20("Reentrant USD Coin", "rUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Approve a spender on behalf of the token contract itself, so a
    ///         re-entrant call issued BY the token passes allowance checks and only
    ///         the target's ReentrancyGuard can stop it (rigorous guard test).
    function selfApprove(address spender, uint256 amount) external {
        _approve(address(this), spender, amount);
    }

    function armAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
        armed = true;
        attackAttempted = false;
        attackReverted = false;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false; // one-shot: no unbounded recursion inside the mock itself
            attackAttempted = true;
            (bool ok,) = attackTarget.call(attackData);
            attackReverted = !ok;
        }
        return super.transferFrom(from, to, value);
    }
}
