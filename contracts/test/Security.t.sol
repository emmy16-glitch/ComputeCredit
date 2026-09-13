// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ReentrantUSDC} from "./mocks/ReentrantUSDC.sol";

/// @notice Adversarial + access-control coverage.
/// @dev Reentrancy mock pattern ported from the Arena AI draft PR (idea credit);
///      all assertions rewritten against the v3 pull-pattern + ERC4626 design.
contract SecurityTest is Test {
    ReentrantUSDC evil;
    ProviderRegistry registry;
    TrustPassport passport;
    ComputeCreditVault vault;
    RevenueRouter router;

    address owner = address(0xA11CE);
    address lender = address(0xBEEF);
    address nova = address(0xA04A);
    address buyer = address(0xB07E5);
    address operator = address(0xBEEF2);
    address provider = address(0xCAFE);
    address payout = address(0xF00D);

    uint256 COST = 2_000_000;

    function setUp() public {
        vm.startPrank(owner);
        evil = new ReentrantUSDC();
        registry = new ProviderRegistry(owner);
        passport = new TrustPassport(owner);
        vault = new ComputeCreditVault(IERC20(address(evil)), registry, passport, owner);
        router = new RevenueRouter(vault, owner);
        vault.setRouter(address(router), true);
        vault.setOperator(operator, true);
        passport.grantRole(passport.ATTESTER_ROLE(), owner);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        registry.registerProvider(provider, payout, 5_000_000, keccak256("haiku-v1"));
        passport.seedScore(nova, 300, "bootstrap");
        vm.stopPrank();
        evil.mint(lender, 100_000_000);
        evil.mint(buyer, 100_000_000);
    }

    // ---------- reentrancy: vault guard ----------

    function test_ReentrantDepositRevertsInwardAndMintsOnce() public {
        uint256 assets = 10_000_000;
        uint256 expected = vault.previewDeposit(assets);
        // inner call (issued BY the token) is fully funded+approved: only the guard can stop it
        evil.mint(address(evil), assets);
        evil.selfApprove(address(vault), assets);
        evil.armAttack(address(vault), abi.encodeCall(vault.deposit, (assets, lender)));

        vm.startPrank(lender);
        evil.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, lender);
        vm.stopPrank();

        assertTrue(evil.attackAttempted(), "attack should have fired");
        assertTrue(evil.attackReverted(), "re-entrant deposit must revert");
        assertEq(shares, expected, "outer deposit mints exactly once");
        assertEq(vault.totalOutstanding(), 0);
    }

    // ---------- reentrancy: router guard ----------

    function test_ReentrantRoutePaymentRevertsInwardAndSplitsOnce() public {
        // arrange an active advance first (plain, unarmed flows)
        vm.startPrank(lender);
        evil.approve(address(vault), 10_000_000);
        vault.deposit(10_000_000, lender);
        vm.stopPrank();
        vm.prank(operator);
        uint256 id = vault.requestAdvanceFor(nova, provider, COST, keccak256("sec-1"), nova);

        uint256 payment = 5_000_000;
        uint256 wantVault = (payment * 2_000) / 10_000; // 20% split
        // inner call (issued BY the token) is fully funded+approved: only the guard can stop it
        evil.mint(address(evil), payment);
        evil.selfApprove(address(router), payment);
        evil.armAttack(address(router), abi.encodeCall(router.routePayment, (nova, payment, nova)));

        vm.startPrank(buyer);
        evil.approve(address(router), payment);
        (uint256 toVault, uint256 toNova) = router.routePayment(nova, payment, nova);
        vm.stopPrank();

        assertTrue(evil.attackAttempted(), "attack should have fired");
        assertTrue(evil.attackReverted(), "re-entrant routePayment must revert");
        assertEq(toVault, wantVault, "outer split applied exactly once");
        assertEq(toNova, payment - wantVault);
        assertEq(vault.remainingOf(id), vault.repayableOf(id) - wantVault);
    }

    // ---------- pause ----------

    function test_PauseBlocksFlowsAndUnpauseRestores() public {
        vm.startPrank(lender);
        evil.approve(address(vault), 10_000_000);
        vm.stopPrank();

        vm.prank(owner);
        vault.pause();

        vm.prank(lender);
        vm.expectRevert();
        vault.deposit(10_000_000, lender);

        vm.prank(operator);
        vm.expectRevert();
        vault.requestAdvanceFor(nova, provider, COST, keccak256("sec-2"), nova);

        vm.prank(owner);
        vault.unpause();

        vm.prank(lender);
        uint256 shares = vault.deposit(10_000_000, lender);
        assertGt(shares, 0, "deposits work again after unpause");
    }

    function test_RouterPauseBlocksRouting() public {
        vm.prank(owner);
        router.pause();
        vm.startPrank(buyer);
        evil.approve(address(router), 1_000_000);
        vm.expectRevert();
        router.routePayment(nova, 1_000_000, nova);
        vm.stopPrank();
    }

    // ---------- roles ----------

    function test_NonOwnerCannotRewire() public {
        vm.prank(buyer);
        vm.expectRevert();
        vault.setRouter(address(router), true);
        vm.prank(buyer);
        vm.expectRevert();
        vault.setOperator(operator, true);
        vm.prank(buyer);
        vm.expectRevert();
        vault.setRisk(
            ComputeCreditVault.RiskParams({
                minDeposit: 1_000_000,
                feeBps: 50,
                splitBps: 2_000,
                penaltyBps: 1_000,
                lienCaptureBps: 5_000,
                advanceWindow: 43_200
            })
        );
        vm.prank(buyer);
        vm.expectRevert();
        vault.pause();
    }

    function test_NonVaultCannotMutateScore() public {
        vm.prank(buyer);
        vm.expectRevert();
        passport.notifySettled(nova);
        vm.prank(buyer);
        vm.expectRevert();
        passport.notifyDefaulted(nova);
    }

    function test_NonAttesterCannotSeed() public {
        vm.prank(buyer);
        vm.expectRevert();
        passport.seedScore(buyer, 300, "self-seed");
    }

    // ---------- assumptions pinned ----------

    function test_DemoTokenHasUsdcDecimals() public {
        MockUSDC real = new MockUSDC();
        assertEq(real.decimals(), 6, "all USDC math assumes 6 decimals");
        assertEq(evil.decimals(), 6, "adversarial mock matches too");
    }
}
