// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ReentrantUSDC
 * @notice Adversarial 6-decimal token that attempts to re-enter a target call during
 *         `transferFrom`, used to prove the vault's reentrancy protection (spec §10.1, §10.2,
 *         §15 "Reentrancy attempts revert").
 *
 * The attack is deliberately *non-fatal* to the outer transaction: it records whether the
 * re-entrant call reverted, then continues. That lets a test assert both that:
 *   (a) the re-entrant call reverted, and
 *   (b) the outer accounting is still applied exactly once.
 */
contract ReentrantUSDC is ERC20 {
    address public attackTarget;
    bytes public attackData;
    bool public armed;
    bool public attackAttempted;
    bool public attackReverted;
    bytes public attackReturnData;

    constructor() ERC20("Reentrant USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Self-approve a spender (the token contract itself is the allowance owner).
    function selfApprove(address spender, uint256 amount) external {
        _approve(address(this), spender, amount);
    }

    /// @notice Arm the re-entrancy attempt for the next `transferFrom`.
    function armAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
        armed = true;
        attackAttempted = false;
        attackReverted = false;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false; // one-shot, prevents unbounded recursion in the mock itself
            attackAttempted = true;
            (bool ok, bytes memory ret) = attackTarget.call(attackData);
            attackReverted = !ok;
            attackReturnData = ret;
        }
        return super.transferFrom(from, to, value);
    }
}
