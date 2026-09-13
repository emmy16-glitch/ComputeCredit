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
 * @title DemoLocal
 * @notice Scripted end-to-end walkthrough of every flow in spec §9, using real transactions on a
 *         local chain with the publicly known anvil development keys.
 *
 * Spec reference: ComputeCredit_v2.pdf §9 (End-to-end flows), §14 Day 7 (testnet integration:
 * happy path, partial servicing, default and recovery, record transaction hashes), §16 (demo script).
 *
 * Two phases, because a blockchain clock cannot be rewound or fast-forwarded from inside a
 * transaction:
 *
 *   Phase 1 - `run()`              deploy + lender deposit + happy path (§9.1) + partial
 *                                  servicing (§9.2) + state snapshot.
 *   Phase 2 - `runDefaultPhase()`  opens a fresh advance, penalizes it after expiry (§9.3) and
 *                                  captures routed recovery revenue. Requires the chain clock to
 *                                  be past `dueAt`; `scripts/demo-local.sh` advances it with the
 *                                  node's `evm_increaseTime` / `evm_mine` RPCs between the phases.
 *
 * Usage:
 *   bash scripts/demo-local.sh            # from the repository root (starts anvil if needed)
 *
 * Every transaction hash is recorded by Foundry in
 * `broadcast/DemoLocal.s.sol/<chainId>/run-latest.json`, and machine-readable snapshots are written
 * to `deployments/<chainId>.json` and `deployments/<chainId>-demo.json`.
 *
 * The private keys below are the standard, publicly known Anvil development keys (accounts 0-5).
 * They must never be used on a public network and hold no value.
 */
contract DemoLocal is Script {
    // Anvil development accounts (public test keys).
    uint256 internal constant PK_ADMIN = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_LENDER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PK_OPERATOR = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_NOVA = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_BUYER = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant PK_PROVIDER = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    uint256 internal constant LENDER_DEPOSIT = 50e6; // 50 USDC
    uint256 internal constant PROVIDER_PRICE = 20_000; // 0.02 USDC
    uint256 internal constant BUYER_PAYMENT = 100_000; // 0.10 USDC
    uint256 internal constant BOOTSTRAP_SCORE = 150;
    uint256 internal constant ADVANCE_WINDOW = 43_200; // 12h

    MockUSDC internal usdc;
    TrustPassport internal passport;
    ProviderRegistry internal registry;
    ComputeCreditVault internal vault;
    RevenueRouter internal router;

    address internal admin;
    address internal lender;
    address internal operator;
    address internal nova;
    address internal buyer;
    address internal providerWallet;

    bytes32 internal serviceId = keccak256("haiku-v1");
    uint256 internal nonce;

    // =====================================================================
    // Phase 1: deploy, fund, happy path, partial servicing
    // =====================================================================

    function run() external {
        _resolveActors();
        _deploy();
        _setup();
        _phaseA_happyPath();
        _phaseB_partialServicing();
        _openAdvanceForDefaultPhase();
        _writeSnapshot();
    }

    function _resolveActors() private {
        admin = vm.addr(PK_ADMIN);
        lender = vm.addr(PK_LENDER);
        operator = vm.addr(PK_OPERATOR);
        nova = vm.addr(PK_NOVA);
        buyer = vm.addr(PK_BUYER);
        providerWallet = vm.addr(PK_PROVIDER);
    }

    function _deploy() private {
        vm.startBroadcast(PK_ADMIN);

        usdc = new MockUSDC();
        passport = new TrustPassport(admin, admin); // the demo admin is also the trusted attester
        registry = new ProviderRegistry(admin);
        vault = new ComputeCreditVault(IERC20(address(usdc)), passport, registry, admin);
        router = new RevenueRouter(IERC20(address(usdc)), vault, admin);

        passport.setVault(address(vault));
        vault.setApprovedRouter(address(router), true);
        vault.setApprovedOperator(operator, true);
        vault.setApprovedRevenueSource(address(router), true);

        registry.registerProvider(admin, providerWallet, PROVIDER_PRICE, serviceId);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=================================================================");
        console2.log("PHASE 1 - deployment, funding, happy path, partial servicing");
        console2.log("=================================================================");
        console2.log("chain id           :", block.chainid);
        console2.log("USDC (mock)        :", address(usdc));
        console2.log("TrustPassport      :", address(passport));
        console2.log("ProviderRegistry   :", address(registry));
        console2.log("ComputeCreditVault :", address(vault));
        console2.log("RevenueRouter      :", address(router));

        _writeDeployment();
    }

    function _setup() private {
        vm.startBroadcast(PK_ADMIN);
        usdc.mint(lender, 1_000e6);
        usdc.mint(buyer, 1_000e6);
        usdc.mint(operator, 10e6);
        passport.seedScore(nova, BOOTSTRAP_SCORE); // trusted bootstrap value (spec §7.4)
        vm.stopBroadcast();

        vm.startBroadcast(PK_LENDER);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(PK_BUYER);
        usdc.approve(address(router), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(PK_NOVA);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(PK_LENDER);
        uint256 minted = vault.depositLiquidity(LENDER_DEPOSIT);
        vm.stopBroadcast();

        console2.log("");
        console2.log("SETUP (spec 9.1 steps 1-4)");
        console2.log("  lender deposited   : 50.000000 USDC");
        console2.log("  pool shares minted :", minted);
        console2.log("  idle assets        :", vault.idleAssets());
        console2.log("  nova score         :", passport.score(nova), "(bootstrap, tier limit 1.000000 USDC)");
        console2.log("  provider price     :", registry.pricePerJob(admin), "per job");
    }

    function _phaseA_happyPath() private {
        console2.log("");
        console2.log("--- PHASE A: happy path (spec 9.1) ---");

        console2.log("5-7. operator requests a 0.020000 USDC advance bound to the job hash");
        vm.startBroadcast(PK_OPERATOR);
        vault.requestComputeAdvanceFor(nova, admin, PROVIDER_PRICE, _jobHash(nova, PROVIDER_PRICE), address(router));
        vm.stopBroadcast();
        _logAdvance("after request", nova);

        console2.log("8. nova pays the provider 0.020000 USDC of compute");
        vm.startBroadcast(PK_NOVA);
        usdc.transfer(providerWallet, PROVIDER_PRICE);
        vm.stopBroadcast();
        console2.log("   nova balance     :", usdc.balanceOf(nova));
        console2.log("   provider balance :", usdc.balanceOf(providerWallet));

        console2.log("9-11. buyer pays 0.100000 USDC through the registered revenue route");
        vm.startBroadcast(PK_BUYER);
        (uint256 serviced,, uint256 forwarded) =
            router.routePayment(nova, BUYER_PAYMENT, keccak256(abi.encode("buyer-payment", ++nonce)));
        vm.stopBroadcast();

        console2.log("   serviced         :", serviced);
        console2.log("   forwarded to nova:", forwarded);
        _logAdvance("after buyer payment", nova);
        console2.log("   nova score       :", passport.score(nova), "(+20 on settlement)");
        console2.log("   pool idle assets :", vault.idleAssets());
    }

    function _phaseB_partialServicing() private {
        console2.log("");
        console2.log("--- PHASE B: partial servicing (spec 9.2) ---");

        vm.startBroadcast(PK_OPERATOR);
        vault.requestComputeAdvanceFor(nova, admin, PROVIDER_PRICE, _jobHash(nova, PROVIDER_PRICE), address(router));
        vm.stopBroadcast();
        console2.log("fresh 0.020000 USDC advance issued");

        console2.log("buyer pays only 0.050000 USDC -> the 20% split services 0.010000");
        vm.startBroadcast(PK_BUYER);
        (uint256 serviced,, uint256 forwarded) =
            router.routePayment(nova, 50_000, keccak256(abi.encode("buyer-payment", ++nonce)));
        vm.stopBroadcast();
        console2.log("   serviced         :", serviced);
        console2.log("   forwarded to nova:", forwarded);
        _logAdvance("after partial payment", nova);
        console2.log("   score unchanged  :", passport.score(nova));

        console2.log("a later routed payment of 0.050000 completes the servicing");
        vm.startBroadcast(PK_BUYER);
        (serviced,, forwarded) = router.routePayment(nova, 50_000, keccak256(abi.encode("buyer-payment", ++nonce)));
        vm.stopBroadcast();
        console2.log("   serviced         :", serviced);
        _logAdvance("after final payment", nova);
        console2.log("   nova score       :", passport.score(nova));
    }

    /// @notice Opens a third advance that deliberately receives no revenue. Phase 2 penalizes it
    ///         once the chain clock is past `dueAt` (spec §9.3 steps 1-2).
    function _openAdvanceForDefaultPhase() private {
        console2.log("");
        console2.log("--- PHASE B2: an advance that will receive no revenue before dueAt ---");
        vm.startBroadcast(PK_OPERATOR);
        vault.requestComputeAdvanceFor(nova, admin, PROVIDER_PRICE, _jobHash(nova, PROVIDER_PRICE), address(router));
        vm.stopBroadcast();

        uint256 dueAt = vault.advanceOf(nova).dueAt;
        console2.log("open advance issued; dueAt =", dueAt);
        console2.log("no routed revenue is sent, so the advance will expire unserviced");
        console2.log("next step: scripts/demo-local.sh advances the chain clock past dueAt");
        _logAdvance("open advance (about to expire)", nova);
    }

    // =====================================================================
    // Phase 2: default, lien and conditional recovery (spec §9.3)
    // =====================================================================

    /**
     * @notice Runs the default path against the deployment created by `run()`.
     * @dev The chain clock must already be past `dueAt` (the advance window is 12 hours);
     *      `scripts/demo-local.sh` advances it with `evm_increaseTime` between the phases.
     */
    function runDefaultPhase() external {
        _resolveActors();
        _loadDeployment();
        _phaseC_defaultAndRecovery();
        _writeSnapshot();
    }

    function _loadDeployment() private {
        string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        usdc = MockUSDC(vm.parseJsonAddress(json, ".usdc"));
        passport = TrustPassport(vm.parseJsonAddress(json, ".trustPassport"));
        registry = ProviderRegistry(vm.parseJsonAddress(json, ".providerRegistry"));
        vault = ComputeCreditVault(vm.parseJsonAddress(json, ".vault"));
        router = RevenueRouter(vm.parseJsonAddress(json, ".revenueRouter"));
    }

    function _phaseC_defaultAndRecovery() private {
        console2.log("");
        console2.log("=================================================================");
        console2.log("PHASE 2 - default, lien and conditional recovery (spec 9.3)");
        console2.log("=================================================================");

        vm.startBroadcast(PK_NOVA);
        usdc.approve(address(vault), type(uint256).max); // idempotent: keeps the borrower funded for direct repayment
        vm.stopBroadcast();

        uint256 dueAt = vault.advanceOf(nova).dueAt;
        console2.log("1. advance issued by phase 1; dueAt:", dueAt);
        console2.log("   chain clock now  :", block.timestamp);
        require(
            block.timestamp > dueAt,
            "chain clock is not past dueAt - run scripts/demo-local.sh, which advances it between phases"
        );

        console2.log("2. no revenue was routed before the deadline");
        console2.log("3. permissionless keeper calls penalize()");
        vm.startBroadcast(PK_BUYER); // any external caller, not the borrower or the operator
        (uint256 shortfall, uint256 lienTarget) = vault.penalize(nova);
        vm.stopBroadcast();
        console2.log("   shortfall        :", shortfall);
        console2.log("   lien target      :", lienTarget, "(1.5x shortfall)");
        console2.log("   nova score       :", passport.score(nova), "(slashed to zero)");
        _logAdvance("after default", nova);

        console2.log("4. nova earns 0.010000 USDC through the registered route -> captured");
        vm.startBroadcast(PK_BUYER);
        (uint256 serviced, uint256 captured, uint256 forwarded) =
            router.routePayment(nova, 10_000, keccak256(abi.encode("buyer-payment", ++nonce)));
        vm.stopBroadcast();
        console2.log("   serviced         :", serviced);
        console2.log("   lien captured    :", captured);
        console2.log("   forwarded to nova:", forwarded);
        console2.log("   lien remaining   :", passport.remainingLien(nova));

        console2.log("5. nova earns 0.050000 USDC -> lien clears, the excess reaches nova");
        vm.startBroadcast(PK_BUYER);
        (serviced, captured, forwarded) =
            router.routePayment(nova, 50_000, keccak256(abi.encode("buyer-payment", ++nonce)));
        vm.stopBroadcast();
        console2.log("   lien captured    :", captured, "(stops at the exact target)");
        console2.log("   forwarded to nova:", forwarded);
        console2.log("   lien active      :", passport.isLienActive(nova));
        console2.log("   capture rate bps :", passport.revenueLienBps(nova), "(cleared)");
        console2.log("   vault idle assets:", vault.idleAssets(), "(recovered liquidity - not a guarantee)");
    }

    // =====================================================================
    // Snapshots and utilities
    // =====================================================================

    function _writeDeployment() private {
        string memory obj = "computecredit";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "usdc", address(usdc));
        vm.serializeAddress(obj, "trustPassport", address(passport));
        vm.serializeAddress(obj, "providerRegistry", address(registry));
        vm.serializeAddress(obj, "vault", address(vault));
        vm.serializeAddress(obj, "revenueRouter", address(router));
        vm.serializeAddress(obj, "admin", admin);
        vm.serializeAddress(obj, "lender", lender);
        vm.serializeAddress(obj, "operator", operator);
        vm.serializeAddress(obj, "borrower", nova);
        vm.serializeAddress(obj, "buyer", buyer);
        vm.serializeAddress(obj, "providerWallet", providerWallet);
        vm.serializeAddress(obj, "provider", admin); // the demo registers the provider as the admin address
        vm.serializeString(obj, "serviceId", "haiku-v1");
        string memory json = vm.serializeUint(obj, "advanceWindow", ADVANCE_WINDOW);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }

    function _writeSnapshot() private {
        string memory obj = "demo";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "vault", address(vault));
        vm.serializeAddress(obj, "revenueRouter", address(router));
        vm.serializeUint(obj, "idleAssets", vault.idleAssets());
        vm.serializeUint(obj, "totalShares", vault.totalShares());
        vm.serializeUint(obj, "totalOutstanding", vault.totalOutstanding());
        vm.serializeUint(obj, "totalIssued", vault.totalIssued());
        vm.serializeUint(obj, "totalServiced", vault.totalServiced());
        vm.serializeUint(obj, "totalShortfall", vault.totalShortfall());
        vm.serializeUint(obj, "totalLienCaptured", vault.totalLienCaptured());
        vm.serializeUint(obj, "borrowerScore", passport.score(nova));
        vm.serializeUint(obj, "borrowerLienTarget", passport.lienTarget(nova));
        string memory json = vm.serializeUint(obj, "borrowerLienCaptured", passport.lienCaptured(nova));

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), "-demo.json");
        vm.writeJson(json, path);

        console2.log("");
        console2.log("=================================================================");
        console2.log("ONCHAIN SUMMARY (read back from contract state)");
        console2.log("=================================================================");
        console2.log("pool idle assets          :", vault.idleAssets());
        console2.log("total pool shares         :", vault.totalShares());
        console2.log("total outstanding         :", vault.totalOutstanding());
        console2.log("total principal issued    :", vault.totalIssued());
        console2.log("total principal serviced  :", vault.totalServiced());
        console2.log("total shortfall (defaults):", vault.totalShortfall());
        console2.log("total lien recovered      :", vault.totalLienCaptured());
        console2.log("borrower score            :", passport.score(nova));
        console2.log("snapshot                  :", path);
    }

    function _jobHash(address borrower, uint256 price) private returns (bytes32) {
        nonce += 1;
        return keccak256(abi.encode(borrower, admin, serviceId, price, nonce, block.timestamp + 1 hours));
    }

    function _logAdvance(string memory label, address borrower) private view {
        ComputeCreditVault.ComputeAdvance memory a = vault.advanceOf(borrower);
        console2.log("   [", label, "]");
        console2.log(
            string.concat(
                "     principal=",
                _u(a.principal),
                " serviced=",
                _u(a.serviced),
                " remaining=",
                _u(a.principal - a.serviced),
                " settled=",
                _b(a.settled),
                " defaulted=",
                _b(a.defaulted)
            )
        );
        console2.log("   totalOutstanding :", vault.totalOutstanding());
    }

    function _u(uint256 value) private pure returns (string memory) {
        return vm.toString(value);
    }

    function _b(bool value) private pure returns (string memory) {
        return value ? "true" : "false";
    }
}
