// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Phase 1/2 — deploy + lender deposit + happy path + partial servicing.
/// @dev Run via scripts/demo-local.sh against local anvil. Single broadcaster plays
///      deployer/lender/buyer/operator (all roles granted to it); borrowers are plain
///      addresses. Idea credit: Arena AI draft PR (two-phase pattern); rewritten for v3.
contract DemoLocalPhase1 is Script {
    uint256 constant ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant NOVA = address(0xA0AA);
    address constant B2 = address(0xB222);
    address constant B3 = address(0xB333);

    function run() external {
        uint256 key = vm.envOr("DEMO_PRIVATE_KEY", ANVIL_KEY);
        address me = vm.addr(key);
        vm.startBroadcast(key);

        MockUSDC usdc = new MockUSDC();
        ProviderRegistry registry = new ProviderRegistry(me);
        TrustPassport passport = new TrustPassport(me);
        ComputeCreditVault vault = new ComputeCreditVault(IERC20(address(usdc)), registry, passport, me);
        RevenueRouter router = new RevenueRouter(vault, me);
        vault.setRouter(address(router), true);
        vault.setOperator(me, true);
        passport.grantRole(passport.ATTESTER_ROLE(), me);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        registry.registerProvider(address(0xCAFE), address(0xF00D), 20_000, keccak256("haiku-v1"));
        passport.seedScore(NOVA, 150, "demo");
        passport.seedScore(B2, 150, "demo");
        passport.seedScore(B3, 150, "demo");

        // lender deposits 50 USDC
        usdc.mint(me, 200_000_000);
        usdc.approve(address(vault), 50_000_000);
        vault.deposit(50_000_000, me);

        // happy path: 0.02 advance, buyer pays 0.10 -> 0.02 serviced, 0.08 forwarded
        uint256 id1 = vault.requestAdvanceFor(NOVA, address(0xCAFE), 20_000, keccak256("demo-1"), NOVA);
        usdc.approve(address(router), type(uint256).max);
        router.routePayment(NOVA, 100_000, NOVA);
        // second payment clears the 0.0001 fee -> settled, score 150 -> 200
        router.routePayment(NOVA, 1_000, NOVA);
        require(vault.remainingOf(id1) == 0, "happy path must settle");

        // partial servicing: 0.02 advance, buyer pays 0.05 -> 0.01 serviced
        vault.requestAdvanceFor(B2, address(0xCAFE), 20_000, keccak256("demo-2"), B2);
        router.routePayment(B2, 50_000, B2);

        // default candidate: 0.02 advance, left untouched (phase 2 penalizes it)
        vault.requestAdvanceFor(B3, address(0xCAFE), 20_000, keccak256("demo-3"), B3);

        vm.stopBroadcast();

        string memory json = "demo";
        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "registry", address(registry));
        vm.serializeAddress(json, "passport", address(passport));
        vm.serializeAddress(json, "vault", address(vault));
        vm.serializeAddress(json, "router", address(router));
        vm.serializeAddress(json, "broadcaster", me);
        string memory out = vm.serializeAddress(json, "provider", address(0xCAFE));
        vm.writeJson(out, "./contracts/deployments/31337-demo.json");

        console.log("phase1 done. idle=", vault.totalAssets(), " outstanding=", vault.totalOutstanding());
    }
}

/// @notice Phase 2/2 — default, lien target, conditional recovery, final assertions.
/// @dev Run AFTER advancing chain time past the 12h window (see scripts/demo-local.sh).
contract DemoLocalPhase2 is Script {
    address constant B2 = address(0xB222);
    address constant B3 = address(0xB333);

    function run() external {
        uint256 key = vm.envOr(
            "DEMO_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        string memory raw = vm.readFile("./contracts/deployments/31337-demo.json");
        ComputeCreditVault vault =
            ComputeCreditVault(vm.parseJsonAddress(raw, ".vault"));
        RevenueRouter router = RevenueRouter(vm.parseJsonAddress(raw, ".router"));
        TrustPassport passport =
            TrustPassport(vm.parseJsonAddress(raw, ".passport"));

        vm.startBroadcast(key);

        // default: shortfall 20_100 (0.02 + 0.0001 fee), lien target 22_110, score 150 -> 0
        vault.penalize(B3);
        require(vault.lienTarget(B3) == 22_110, "lien target must be 1.1x shortfall");

        // recovery: buyer pays 0.10 through the lien path (50% capture, capped at target)
        router.routePayment(B3, 100_000, B3);
        require(vault.lienCaptured(B3) == 22_110, "lien must clear exactly at target");

        vm.stopBroadcast();

        // final state: only the partial advance (B2) remains: 20_100 - 10_000 = 10_100
        require(vault.totalOutstanding() == 10_100, "only partial advance remains");
        require(
            vault.totalAssets() == 50_000_000 - 60_000 + 30_100 + 22_110, "idle math must balance exactly"
        );
        require(passport.score(address(0xA0AA)) == 200, "nova settled: 150 + 50");
        require(passport.score(B3) == 0, "defaulter slashed to 0");

        console.log("phase2 done. idle=", vault.totalAssets(), " outstanding=", vault.totalOutstanding());
        console.log("nova score=", passport.score(address(0xA0AA)), " b3 score=", passport.score(B3));
        console.log("ALL LOCAL DEMO ASSERTIONS PASSED");
    }
}
