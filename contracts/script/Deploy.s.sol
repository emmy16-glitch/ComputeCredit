// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {WorkEscrow} from "../src/WorkEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy full ComputeCredit v3 stack (core + WorkEscrow stretch module).
/// @dev Env:
///   DEPLOYER_PRIVATE_KEY — default: anvil key 0 (local only)
///   USDC — if unset, deploys MockUSDC (testnet/demo only)
///   OPERATOR — orchestrator EOA; defaults to deployer
///   PROVIDER, PROVIDER_PAYOUT, PROVIDER_PRICE, SERVICE_ID
/// Usage:
///   forge script contracts/script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    struct Config {
        uint256 key;
        address deployer;
        address usdcAddr;
        address operator;
        address provider;
        address providerPayout;
        uint256 providerPrice;
        bytes32 serviceId;
    }

    struct Contracts {
        address usdc;
        address registry;
        address passport;
        address vault;
        address router;
        address workEscrow;
    }

    function run() external {
        Config memory c = _config();
        vm.startBroadcast(c.key);
        Contracts memory d = _deploy(c);
        vm.stopBroadcast();
        _print(d, c.operator);
    }

    function _config() internal view returns (Config memory c) {
        c.key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7b4bd3ff80));
        c.deployer = vm.addr(c.key);
        c.usdcAddr = vm.envOr("USDC", address(0));
        c.operator = vm.envOr("OPERATOR", c.deployer);
        c.provider = vm.envOr("PROVIDER", address(0xCAFE));
        c.providerPayout = vm.envOr("PROVIDER_PAYOUT", address(0xF00D));
        c.providerPrice = vm.envOr("PROVIDER_PRICE", uint256(2_000_000));
        c.serviceId = vm.envOr("SERVICE_ID", keccak256("haiku-v1"));
    }

    function _deploy(Config memory c) internal returns (Contracts memory d) {
        IERC20 usdc;
        if (c.usdcAddr == address(0)) {
            usdc = IERC20(address(new MockUSDC()));
        } else {
            usdc = IERC20(c.usdcAddr);
        }
        ProviderRegistry registry = new ProviderRegistry(c.deployer);
        TrustPassport passport = new TrustPassport(c.deployer);
        ComputeCreditVault vault = new ComputeCreditVault(usdc, registry, passport, c.deployer);
        RevenueRouter router = new RevenueRouter(vault, c.deployer);
        WorkEscrow workEscrow = new WorkEscrow(usdc, router, c.deployer);

        vault.setRouter(address(router), true);
        vault.setOperator(c.operator, true);
        passport.grantRole(passport.ATTESTER_ROLE(), c.deployer);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        registry.registerProvider(c.provider, c.providerPayout, c.providerPrice, c.serviceId);

        d = Contracts({
            usdc: address(usdc),
            registry: address(registry),
            passport: address(passport),
            vault: address(vault),
            router: address(router),
            workEscrow: address(workEscrow)
        });
    }

    function _print(Contracts memory d, address operator) internal view {
        console.log("USDC:               ", d.usdc);
        console.log("ProviderRegistry:   ", d.registry);
        console.log("TrustPassport:      ", d.passport);
        console.log("ComputeCreditVault: ", d.vault);
        console.log("RevenueRouter:      ", d.router);
        console.log("WorkEscrow:         ", d.workEscrow, "(stretch module)");
        console.log("Operator:           ", operator);
        console.log("Chain ID:           ", block.chainid);
    }
}
