// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice 6-decimal settlement token used for local tests, the anvil demo and any local
 *         deployment where a testnet USDC address is not configured.
 *
 * Spec reference: ComputeCredit_v2.pdf §10.2 ("Incorrect decimals") — the vault validates the
 * configured token's decimals at construction, so local mocks must be 6-decimal like USDC.
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Test helper: mint freely.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Test helper: mint with a starting balance for a list of accounts.
    function mintMany(address[] calldata accounts, uint256 amount) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            _mint(accounts[i], amount);
        }
    }
}
