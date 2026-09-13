// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {WorkEscrow} from "../src/WorkEscrow.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Shared fixture + helpers for all ComputeCredit test suites.
contract Base is Test {
    MockUSDC usdc;
    ProviderRegistry registry;
    TrustPassport passport;
    ComputeCreditVault vault;
    RevenueRouter router;
    WorkEscrow escrow;

    address owner = address(0xA11CE);
    address lender = address(0xBEEF);
    address nova; // borrower (key-owned for sig tests)
    uint256 novaKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address provider = address(0xCAFE);
    address providerPayout = address(0xF00D);
    address buyer = address(0xB07E5);
    address operator = address(0xBEEF2);
    address client = address(0xC11E47);
    address arbiter = address(0xA8817E5);

    bytes32 SERVICE = keccak256("haiku-v1");
    uint256 PROVIDER_PRICE = 5_000_000; // 5 USDC
    uint256 COST = 2_000_000; // 2 USDC

    function setUp() public virtual {
        nova = vm.addr(novaKey);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        registry = new ProviderRegistry(owner);
        passport = new TrustPassport(owner);
        vault = new ComputeCreditVault(usdc, registry, passport, owner);
        router = new RevenueRouter(vault, owner);
        escrow = new WorkEscrow(usdc, router, owner);
        vault.setRouter(address(router), true);
        vault.setOperator(operator, true);
        passport.grantRole(passport.ATTESTER_ROLE(), owner);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        registry.registerProvider(provider, providerPayout, PROVIDER_PRICE, SERVICE);
        passport.seedScore(nova, 300, "bootstrap");
        vm.stopPrank();

        usdc.mint(lender, 100_000_000);
        usdc.mint(buyer, 100_000_000);
        usdc.mint(client, 100_000_000);
    }

    // ---------- helpers ----------

    function _depositLender(uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(lender);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, lender);
        vm.stopPrank();
    }

    function _requestAdvance(bytes32 jobHash, address revenueSource) internal returns (uint256 id) {
        vm.prank(operator);
        return vault.requestAdvanceFor(nova, provider, COST, jobHash, revenueSource);
    }

    function _assertOutstandingEqualsActiveSum() internal view {
        uint256 activeId = vault.activeAdvanceId(nova);
        if (activeId == 0) {
            assertEq(vault.totalOutstanding(), 0, "outstanding should be 0 with no active advance");
        } else {
            assertEq(vault.totalOutstanding(), vault.remainingOf(activeId), "outstanding != active remaining");
        }
    }

    function _intentDigest(
        address borrower,
        address prov,
        uint256 cost,
        bytes32 job,
        address rev,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (bytes32) {
        bytes32 typehash = keccak256(
            "AdvanceIntent(address borrower,address provider,uint256 cost,bytes32 jobHash,address revenueSource,uint256 nonce,uint256 expiry)"
        );
        bytes32 structHash = keccak256(abi.encode(typehash, borrower, prov, cost, job, rev, nonce, expiry));
        return keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
    }

    function _status(uint256 id) internal view returns (ComputeCreditVault.Status) {
        (,,,,,,,,,,, ComputeCreditVault.Status s) = vault.advances(id);
        return s;
    }
}
