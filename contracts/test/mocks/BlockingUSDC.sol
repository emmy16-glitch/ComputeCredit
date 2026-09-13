// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title BlockingUSDC
 * @notice 6-decimal token whose `transferFrom` can be switched to revert on demand.
 *
 * Used to prove the invariant that repayment can never be *recorded* without the tokens being
 * *received* (spec §10.2 "Fake repayment record" -> "Router must transfer USDC with servicing").
 * If a servicing call reverts at the token transfer, the vault accounting must be unchanged.
 */
contract BlockingUSDC is ERC20 {
    bool public blocking;

    event BlockingSet(bool blocking);

    constructor() ERC20("Blocking USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocking(bool blocking_) external {
        blocking = blocking_;
        emit BlockingSet(blocking_);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!blocking, "BlockingUSDC: transfers blocked");
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(!blocking, "BlockingUSDC: transfers blocked");
        return super.transfer(to, value);
    }
}
