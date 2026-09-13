// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockUSDC } from "../test/mocks/MockUSDC.sol";
import { TrustPassport } from "../src/TrustPassport.sol";
import { ProviderRegistry } from "../src/ProviderRegistry.sol";
import { ComputeCreditVault } from "../src/ComputeCreditVault.sol";
import { RevenueRouter } from "../src/RevenueRouter.sol";

/**
 * @title Deploy
 * @notice Deploys and wires the ComputeCredit core: TrustPassport, ProviderRegistry,
 *         ComputeCreditVault and RevenueRouter, then registers the demo provider and the
 *         borrower's bootstrap score.
 *
 * Spec reference: ComputeCredit_v2.pdf §14 (Deployment plan, Day 7 - "Deploy the contracts"),
 * §18 (Repository structure), §19 (Final release criteria).
 *
 * Usage (testnet):
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast
 *
 * All configuration is environment-driven (spec §11.2: "The actual endpoint and addresses must
 * be stored in environment variables or deployment configuration, not hardcoded in source code").
 * See .env.example for the full list.
 */
contract Deploy is Script {
    struct Config {
        address deployer;
        address admin;
        address attester;
        address operator;
        address provider;
        address providerWallet;
        uint256 providerPrice;
        address bootstrapAgent;
        uint256 bootstrapScore;
        address usdc;
        bool deployMockToken;
        bytes32 serviceId;
    }

    struct Deployment {
        address usdc;
        address passport;
        address registry;
        address vault;
        address router;
        address admin;
        address attester;
        address operator;
        address provider;
        address providerWallet;
        address bootstrapAgent;
    }

    function run() external returns (Deployment memory deployment) {
        Config memory cfg = _readConfig();
        deployment = _deployAll(cfg);
        _writeDeployment(deployment);
        _log(deployment);
    }

    // ---------------------------------------------------------------------
    // Configuration (environment driven)
    // ---------------------------------------------------------------------

    function _readConfig() private view returns (Config memory cfg) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        cfg.deployer = deployer;
        cfg.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        cfg.attester = vm.envOr("ATTESTER_ADDRESS", cfg.admin);
        cfg.operator = vm.envOr("OPERATOR_ADDRESS", cfg.admin);
        cfg.provider = vm.envOr("PROVIDER_ADDRESS", address(0));
        cfg.providerWallet = vm.envOr("PROVIDER_WALLET", cfg.provider);
        cfg.providerPrice = vm.envOr("PROVIDER_PRICE_PER_JOB", uint256(20_000)); // 0.02 USDC
        cfg.bootstrapAgent = vm.envOr("BOOTSTRAP_AGENT_ADDRESS", address(0));
        cfg.bootstrapScore = vm.envOr("BOOTSTRAP_SCORE", uint256(150));
        cfg.usdc = vm.envOr("USDC_ADDRESS", address(0));
        cfg.deployMockToken = cfg.usdc == address(0);
        cfg.serviceId = keccak256(bytes(vm.envOr("PROVIDER_SERVICE_ID", string("haiku-v1"))));
    }

    // ---------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------

    function _deployAll(Config memory cfg) private returns (Deployment memory deployment) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        if (cfg.deployMockToken) {
            // A local mock token is only acceptable on a development chain. For any public
            // network the real USDC address must be configured (see the References note in the
            // specification: confirm token addresses against official documentation first).
            require(
                block.chainid == 31337 || block.chainid == 1337,
                "USDC_ADDRESS must be set for non-local deployments"
            );
        }

        vm.startBroadcast(deployerPk);

        address usdc = cfg.usdc;
        if (cfg.deployMockToken) {
            usdc = address(new MockUSDC());
        }

        TrustPassport passport = new TrustPassport(cfg.attester, cfg.admin);
        ProviderRegistry registry = new ProviderRegistry(cfg.admin);
        ComputeCreditVault vault = new ComputeCreditVault(IERC20(usdc), passport, registry, cfg.admin);
        RevenueRouter router = new RevenueRouter(IERC20(usdc), vault, cfg.admin);

        passport.setVault(address(vault));
        vault.setApprovedRouter(address(router), true);
        vault.setApprovedOperator(cfg.operator, true);
        vault.setApprovedRevenueSource(address(router), true);

        if (cfg.provider != address(0)) {
            registry.registerProvider(
                cfg.provider,
                cfg.providerWallet == address(0) ? cfg.provider : cfg.providerWallet,
                cfg.providerPrice,
                cfg.serviceId
            );
        }

        // Bootstrap score seeding is attester-only (spec §7.4). When the deployer is also the
        // attester it can be seeded inside this broadcast; otherwise the attester must call
        // `seedScore` separately (documented in README - exact demo steps).
        bool canSeed = cfg.bootstrapAgent != address(0) && cfg.attester == cfg.deployer;
        if (canSeed) {
            passport.seedScore(cfg.bootstrapAgent, cfg.bootstrapScore);
        }

        vm.stopBroadcast();

        if (cfg.bootstrapAgent != address(0) && !canSeed) {
            console2.log("NOTE: attester != deployer. Seed the bootstrap score from the attester key:");
            console2.log("      TrustPassport.seedScore(bootstrapAgent, bootstrapScore)");
        }

        deployment = Deployment({
            usdc: usdc,
            passport: address(passport),
            registry: address(registry),
            vault: address(vault),
            router: address(router),
            admin: cfg.admin,
            attester: cfg.attester,
            operator: cfg.operator,
            provider: cfg.provider,
            providerWallet: cfg.providerWallet,
            bootstrapAgent: cfg.bootstrapAgent
        });
    }

    // ---------------------------------------------------------------------
    // Reporting
    // ---------------------------------------------------------------------

    function _writeDeployment(Deployment memory deployment) private {
        string memory obj = "computecredit";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "usdc", deployment.usdc);
        vm.serializeAddress(obj, "trustPassport", deployment.passport);
        vm.serializeAddress(obj, "providerRegistry", deployment.registry);
        vm.serializeAddress(obj, "vault", deployment.vault);
        vm.serializeAddress(obj, "revenueRouter", deployment.router);
        vm.serializeAddress(obj, "admin", deployment.admin);
        vm.serializeAddress(obj, "attester", deployment.attester);
        vm.serializeAddress(obj, "operator", deployment.operator);
        vm.serializeAddress(obj, "provider", deployment.provider);
        vm.serializeAddress(obj, "providerWallet", deployment.providerWallet);
        string memory json = vm.serializeAddress(obj, "bootstrapAgent", deployment.bootstrapAgent);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment record written to", path);
    }

    function _log(Deployment memory deployment) private view {
        console2.log("");
        console2.log("=====================================================");
        console2.log("ComputeCredit deployment (chain id %s)", block.chainid);
        console2.log("=====================================================");
        console2.log("USDC token         :", deployment.usdc);
        console2.log("TrustPassport      :", deployment.passport);
        console2.log("ProviderRegistry   :", deployment.registry);
        console2.log("ComputeCreditVault :", deployment.vault);
        console2.log("RevenueRouter      :", deployment.router);
        console2.log("Admin              :", deployment.admin);
        console2.log("Attester           :", deployment.attester);
        console2.log("Operator           :", deployment.operator);
        console2.log("Provider           :", deployment.provider);
        console2.log("Bootstrap agent    :", deployment.bootstrapAgent);
        console2.log("-----------------------------------------------------");
        console2.log("MVP trust assumptions (spec 3.1):");
        console2.log("  1. the orchestrator may request advances for an authorised borrower");
        console2.log("  2. the orchestrator may issue work attestations");
        console2.log("  3. the revenue router controls the registered demo receiving path");
    }
}
