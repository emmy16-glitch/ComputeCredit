// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockXStock} from "../src/MockXStock.sol";
import {RwaCollateral} from "../src/RwaCollateral.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {WorkEscrow} from "../src/WorkEscrow.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {ComputeFutures} from "../src/ComputeFutures.sol";
import {FacilitatorAdapter} from "../src/FacilitatorAdapter.sol";
import {CreditAdmin} from "../src/CreditAdmin.sol";
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
        address identity;
        address futures;
        address adapter;
        address admin;
        address xstock;
        address rwaCollateral;
    }

    function run() external {
        Config memory c = _config();
        vm.startBroadcast(c.key);
        Contracts memory d = _deploy(c);
        vm.stopBroadcast();
        _print(d, c.operator);
    }

    function _config() internal view returns (Config memory c) {
        c.key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        c.deployer = vm.addr(c.key);
        c.usdcAddr = vm.envOr("USDC", address(0));
        c.operator = vm.envOr("OPERATOR", c.deployer);
        c.provider = vm.envOr("PROVIDER", address(0xCAFE));
        c.providerPayout = vm.envOr("PROVIDER_PAYOUT", address(0xF00D));
        c.providerPrice = vm.envOr("PROVIDER_PRICE", uint256(2_000_000));
        c.serviceId = vm.envOr("SERVICE_ID", keccak256("haiku-v1"));
    }

    function _deploy(Config memory c) internal returns (Contracts memory d) {
        (IERC20 usdc, ProviderRegistry registry, TrustPassport passport, ComputeCreditVault vault, RevenueRouter router) =
            _deployCore(c);
        (WorkEscrow workEscrow, AgentIdentity identity, ComputeFutures futures, FacilitatorAdapter adapter, CreditAdmin admin) =
            _deployExtra(usdc, router, c.deployer);
        // RWA leg: mock tokenized stock + collateral vault (testnet/demo only).
        MockXStock xstock = new MockXStock("AAPLx");
        RwaCollateral rwa = new RwaCollateral(address(xstock), c.deployer);
        _wire(c, usdc, registry, passport, vault, router, identity);
        vault.setRwaCollateral(address(rwa));
        rwa.setVault(address(vault));

        d = Contracts({
            usdc: address(usdc),
            registry: address(registry),
            passport: address(passport),
            vault: address(vault),
            router: address(router),
            workEscrow: address(workEscrow),
            identity: address(identity),
            futures: address(futures),
            adapter: address(adapter),
            admin: address(admin),
            xstock: address(xstock),
            rwaCollateral: address(rwa)
        });
    }

    function _deployCore(Config memory c)
        internal
        returns (IERC20 usdc, ProviderRegistry registry, TrustPassport passport, ComputeCreditVault vault, RevenueRouter router)
    {
        if (c.usdcAddr == address(0)) {
            usdc = IERC20(address(new MockUSDC()));
        } else {
            usdc = IERC20(c.usdcAddr);
        }
        registry = new ProviderRegistry(c.deployer);
        passport = new TrustPassport(c.deployer);
        vault = new ComputeCreditVault(usdc, registry, passport, c.deployer);
        router = new RevenueRouter(vault, c.deployer);
    }

    function _deployExtra(IERC20 usdc, RevenueRouter router, address deployer)
        internal
        returns (WorkEscrow workEscrow, AgentIdentity identity, ComputeFutures futures, FacilitatorAdapter adapter, CreditAdmin admin)
    {
        workEscrow = new WorkEscrow(usdc, router, deployer);
        identity = new AgentIdentity(deployer);
        futures = new ComputeFutures(usdc, router, deployer);
        adapter = new FacilitatorAdapter(router, deployer);
        // MVP admin: single-owner threshold 1, no delay (production: N owners + delay).
        address[] memory owners = new address[](1);
        owners[0] = deployer;
        admin = new CreditAdmin(owners, 1, 0);
    }

    function _wire(
        Config memory c,
        IERC20,
        ProviderRegistry registry,
        TrustPassport passport,
        ComputeCreditVault vault,
        RevenueRouter router,
        AgentIdentity identity
    ) internal {
        vault.setRouter(address(router), true);
        vault.setOperator(c.operator, true);
        passport.grantRole(passport.ATTESTER_ROLE(), c.deployer);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        passport.setIdentityRegistry(address(identity));
        registry.registerProvider(c.provider, c.providerPayout, c.providerPrice, c.serviceId);
    }

    function _print(Contracts memory d, address operator) internal view {
        console.log("USDC:               ", d.usdc);
        console.log("ProviderRegistry:   ", d.registry);
        console.log("TrustPassport:      ", d.passport);
        console.log("ComputeCreditVault: ", d.vault);
        console.log("RevenueRouter:      ", d.router);
        console.log("WorkEscrow:         ", d.workEscrow, "(stretch module)");
        console.log("AgentIdentity:      ", d.identity);
        console.log("ComputeFutures:     ", d.futures);
        console.log("FacilitatorAdapter: ", d.adapter);
        console.log("CreditAdmin:        ", d.admin, "(multisig-timelock, threshold 1 / delay 0)");
        console.log("MockXStock (RWA):   ", d.xstock);
        console.log("RwaCollateral:      ", d.rwaCollateral);
        console.log("Operator:           ", operator);
        console.log("Chain ID:           ", block.chainid);
    }
}
