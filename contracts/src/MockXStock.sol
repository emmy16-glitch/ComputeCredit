// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only tokenized-stock mock (e.g. AAPLx) for the OKX Dev Day
/// "Build a Market" RWA integration. 18 decimals like real xStocks.
/// Permissionless mint = testnet velocity only, never mainnet.
contract MockXStock is ERC20 {
    string private _sym;

    constructor(string memory symbol_) ERC20("Tokenized Stock (mock)", symbol_) {
        _sym = symbol_;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
