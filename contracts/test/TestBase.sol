// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { MockUSDC } from "./mocks/MockUSDC.sol";
import { TrustPassport } from "../src/TrustPassport.sol";
import { ProviderRegistry } from "../src/ProviderRegistry.sol";
import { ComputeCreditVault } from "../src/ComputeCreditVault.sol";
import { RevenueRouter } from "../src/RevenueRouter.sol";

/**
 * @notice Shared fixture for the ComputeCredit test suites.
 *
 * Reflects the demo configuration used throughout the specification (§9 end-to-end flows,
 * §11.2 provider configuration, §16 demo script):
 *   - lender deposits 50 USDC;
 *   - Nova (borrower agent) has a bootstrap score of 150 -> tier limit 1 USDC;
 *   - the registered provider price for `haiku-v1` is 0.02 USDC;
 *   - a buyer payment of 0.10 USDC services 20% (0.02 USDC) and forwards 0.08 USDC.
 */
abstract contract TestBase is Test {
    // ---------------------------------------------------------------------
    // Actors (spec §3.1 roles)
    // ---------------------------------------------------------------------

    address internal admin = makeAddr("admin"); // vault / passport / registry owner
    address internal attester = makeAddr("attester"); // trusted bootstrap attester
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");
    address internal nova = makeAddr("nova"); // borrower agent
    address internal novaSpend = makeAddr("novaSpendingWallet"); // isolated spending wallet
    address internal buyer = makeAddr("buyer");
    address internal operator = makeAddr("orchestrator"); // approved operator
    address internal keeper = makeAddr("keeper"); // permissionless caller
    address internal provider = makeAddr("provider"); // registry key
    address internal providerWallet = makeAddr("providerWallet"); // payment receiver
    address internal outsider = makeAddr("outsider");

    // ---------------------------------------------------------------------
    // Demo parameters
    // ---------------------------------------------------------------------

    bytes32 internal constant SERVICE_ID = keccak256("haiku-v1");
    uint256 internal constant PROVIDER_PRICE = 20_000; // 0.02 USDC
    uint256 internal constant LENDER_DEPOSIT = 50e6; // 50 USDC
    uint256 internal constant BOOTSTRAP_SCORE = 150; // tier 1 -> 1 USDC limit
    uint256 internal constant BUYER_PAYMENT = 100_000; // 0.10 USDC
    uint256 internal constant ADVANCE_WINDOW = 43_200; // 12h (spec §5.1)

    // ---------------------------------------------------------------------
    // System under test
    // ---------------------------------------------------------------------

    MockUSDC internal usdc;
    TrustPassport internal passport;
    ProviderRegistry internal providers;
    ComputeCreditVault internal vault;
    RevenueRouter internal router;

    uint256 internal jobNonce;

    function setUp() public virtual {
        vm.warp(1_760_000_000); // deterministic clock
        vm.roll(20_000_000);

        usdc = new MockUSDC();
        passport = new TrustPassport(attester, admin);
        providers = new ProviderRegistry(admin);
        vault = new ComputeCreditVault(usdc, passport, providers, admin);
        router = new RevenueRouter(usdc, vault, admin);

        // ---- wiring (spec §2.1 components / §8.3 router authorisation) ----
        vm.startPrank(admin);
        passport.setVault(address(vault));
        vault.setApprovedRouter(address(router), true);
        vault.setApprovedOperator(operator, true);
        vault.setApprovedRevenueSource(address(router), true);
        providers.registerProvider(provider, providerWallet, PROVIDER_PRICE, SERVICE_ID);
        vm.stopPrank();

        // ---- bootstrap score for the borrower agent (spec §7.4 fallback 150) ----
        vm.prank(attester);
        passport.seedScore(nova, BOOTSTRAP_SCORE);

        // ---- funding ----
        usdc.mint(lender, 1_000e6);
        usdc.mint(lender2, 1_000e6);
        usdc.mint(buyer, 1_000e6);
        usdc.mint(outsider, 1_000e6);

        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lender2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(nova);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(operator);
        usdc.approve(address(vault), type(uint256).max);

        // ---- first lender deposit: 50 USDC ----
        vm.prank(lender);
        vault.depositLiquidity(LENDER_DEPOSIT);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Unique job hash bound to borrower/provider/service/price/nonce/expiry (spec §6).
    /// @dev Computed locally (no external call) so that it can be passed as an argument without
    ///      consuming a pending `vm.prank` / `vm.expectRevert`. The registry formula itself is
    ///      asserted in `test_JobHashBindsBorrowerProviderServicePriceNonceAndExpiry`.
    function _jobHash(address borrower) internal returns (bytes32) {
        jobNonce += 1;
        return keccak256(abi.encode(borrower, provider, SERVICE_ID, PROVIDER_PRICE, jobNonce, block.timestamp + 1 hours));
    }

    /// @notice Operator-assisted advance request for the standard 0.02 USDC demo job (spec §5.5).
    function _openAdvance(address borrower, uint256 cost) internal returns (bytes32 jobHash_) {
        jobHash_ = _jobHash(borrower);
        vm.prank(operator);
        vault.requestComputeAdvanceFor(borrower, provider, cost, jobHash_, address(router));
    }

    function _openAdvance(address borrower) internal returns (bytes32 jobHash_) {
        return _openAdvance(borrower, PROVIDER_PRICE);
    }

    /// @notice Register the router as a borrower's revenue source (operator-assisted, spec §5.5).
    function _registerRevenueSource(address borrower) internal {
        vm.prank(operator);
        vault.registerRevenueSource(borrower, address(router));
    }

    /// @notice Buyer pays through the registered revenue source (spec §9.1 steps 10-15).
    function _routePayment(address borrower, uint256 amount)
        internal
        returns (uint256 serviced, uint256 captured, uint256 forwarded)
    {
        bytes32 paymentRef = keccak256(abi.encode(borrower, amount, block.timestamp, block.number));
        vm.prank(buyer); // the buyer pays through the registered revenue source
        return router.routePayment(borrower, amount, paymentRef);
    }

    /// @notice Raise a borrower's score by repeatedly settling small advances (+20 each, spec §7.5).
    function _bumpScore(address borrower, uint256 targetScore) internal {
        while (passport.score(borrower) < targetScore) {
            _openAdvance(borrower);
            _routePayment(borrower, BUYER_PAYMENT);
        }
    }

    /// @notice Idle assets per share, scaled to 1e18, used for rounding-direction assertions.
    function _sharePriceE18() internal view returns (uint256) {
        if (vault.totalShares() == 0) return 0;
        return (vault.idleAssets() * 1e18) / vault.totalShares();
    }

    /// @notice Advance `borrower` 0.02 USDC and let it expire without revenue (spec §9.3).
    function _expireAdvance(address borrower) internal {
        _openAdvance(borrower);
        vm.warp(block.timestamp + ADVANCE_WINDOW + 1);
    }
}
