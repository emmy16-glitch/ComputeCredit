// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Stateful invariant suite with a fuzzed handler interleaving every entrypoint.
/// @dev Idea credit: Arena AI draft PR (handler pattern). Rewritten for v3 semantics:
///      advance IDs, origination fee, ERC4626 shares, 50% lien capture.
contract InvariantsTest is Test {
    MockUSDC usdc;
    ProviderRegistry registry;
    TrustPassport passport;
    ComputeCreditVault vault;
    RevenueRouter router;
    VaultHandler handler;

    address owner = address(0xA11CE);
    address lender = address(0xBEEF);
    address buyer = address(0xB07E5);
    address operator = address(0xBEEF2);
    address provider = address(0xCAFE);

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        registry = new ProviderRegistry(owner);
        passport = new TrustPassport(owner);
        vault = new ComputeCreditVault(IERC20(address(usdc)), registry, passport, owner);
        router = new RevenueRouter(vault, owner);
        vault.setRouter(address(router), true);
        vault.setOperator(operator, true);
        passport.grantRole(passport.ATTESTER_ROLE(), owner);
        passport.grantRole(passport.VAULT_ROLE(), address(vault));
        registry.registerProvider(provider, provider, 5_000_000, keccak256("haiku-v1"));
        for (uint256 i; i < 5; i++) {
            passport.seedScore(address(uint160(0xB000 + i + 1)), 300, "fuzz bootstrap");
        }
        vm.stopPrank();

        handler = new VaultHandler(usdc, vault, router, passport, lender, buyer, operator, provider);
        targetContract(address(handler));
    }

    // ---- invariants ----

    /// @notice totalOutstanding always equals live active remainders (the v2 double-decrement can never recur).
    function invariant_outstandingMirrorsActive() public view {
        uint256 expected;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.idAt(i);
            (
                ,
                ,
                ,
                uint256 principal,
                uint256 fee,
                uint256 repaid,
                ,
                ,
                ,
                ,
                ,
                ComputeCreditVault.Status status
            ) = vault.advances(id);
            if (status == ComputeCreditVault.Status.Active) expected += (principal + fee - repaid);
        }
        assertEq(vault.totalOutstanding(), expected);
    }

    /// @notice No advance is ever over-serviced.
    function invariant_neverOverServiced() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            (,,,, uint256 fee, uint256 repaid,,,,,,) = _full(handler.idAt(i));
            assertLe(repaid, _principal(handler.idAt(i)) + fee);
        }
    }

    /// @notice Settled implies fully repaid; defaulted implies not settled.
    function invariant_terminalStatesConsistent() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.idAt(i);
            uint256 principal = _principal(id);
            (,,,, uint256 fee, uint256 repaid,,,,,, ComputeCreditVault.Status status) = _full(id);
            if (status == ComputeCreditVault.Status.Settled) assertEq(repaid, principal + fee);
            if (status == ComputeCreditVault.Status.Defaulted) {
                // defaulted advance never counts as settled, and is never "the" active one
                // (borrower may rehabilitate with a NEW advance after the lien clears)
                assertTrue(status != ComputeCreditVault.Status.Settled);
                assertTrue(vault.activeAdvanceId(_borrower(id)) != id);
            }
        }
    }

    /// @notice Lien capture never exceeds its target.
    function invariant_lienBounded() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; i++) {
            address b = handler.actorAt(i);
            assertLe(vault.lienCaptured(b), vault.lienTarget(b));
        }
    }

    /// @notice Idle accounting is honest: totalAssets == real balance; lender can never withdraw more.
    function invariant_idleHonest() public view {
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));
        assertLe(vault.maxWithdraw(lender), usdc.balanceOf(address(vault)));
    }

    /// @notice Scores stay in range no matter the interleaving.
    function invariant_scoresInRange() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; i++) {
            assertLe(passport.score(handler.actorAt(i)), 1_000);
        }
    }

    // ---- tuple helpers (12-field Advance) ----

    function _principal(uint256 id) internal view returns (uint256 p) {
        (,,, p,,,,,,,,) = vault.advances(id);
    }

    function _borrower(uint256 id) internal view returns (address b) {
        (, b,,,,,,,,,,) = vault.advances(id);
    }

    function _full(uint256 id)
        internal
        view
        returns (
            uint256 a,
            address b,
            address c,
            uint256 d,
            uint256 fee,
            uint256 repaid,
            uint256 g,
            uint256 h,
            uint256 k,
            bytes32 m,
            address r,
            ComputeCreditVault.Status s
        )
    {
        return vault.advances(id);
    }
}

/// @notice Fuzzed actor driving every vault/router entrypoint in random order.
contract VaultHandler is Test {
    MockUSDC usdc;
    ComputeCreditVault vault;
    RevenueRouter router;
    TrustPassport passport;
    address lender;
    address buyer;
    address operator;
    address provider;

    address[] actors;
    uint256[] ids;
    uint256 nonce;

    constructor(
        MockUSDC usdc_,
        ComputeCreditVault vault_,
        RevenueRouter router_,
        TrustPassport passport_,
        address lender_,
        address buyer_,
        address operator_,
        address provider_
    ) {
        usdc = usdc_;
        vault = vault_;
        router = router_;
        passport = passport_;
        lender = lender_;
        buyer = buyer_;
        operator = operator_;
        provider = provider_;
        for (uint256 i; i < 5; i++) {
            address a = address(uint160(0xB000 + i + 1));
            actors.push(a);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function depositLender(uint256 amount) external {
        amount = bound(amount, 1_000_000, 30_000_000);
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, lender) {} catch {}
        vm.stopPrank();
    }

    function requestAdvance(uint256 actorSeed, uint256 cost) external {
        address b = _actor(actorSeed);
        cost = bound(cost, 500_000, 4_000_000);
        bytes32 job = keccak256(abi.encode(nonce++));
        vm.prank(operator);
        try vault.requestAdvanceFor(b, provider, cost, job, b) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function serviceViaRouter(uint256 actorSeed, uint256 pay) external {
        address b = _actor(actorSeed);
        pay = bound(pay, 100_000, 20_000_000);
        usdc.mint(buyer, pay);
        vm.startPrank(buyer);
        usdc.approve(address(router), pay);
        try router.routePayment(b, pay, b) {} catch {}
        vm.stopPrank();
    }

    function repayEarly(uint256 actorSeed, uint256 amt) external {
        address b = _actor(actorSeed);
        uint256 id = vault.activeAdvanceId(b);
        if (id == 0) return;
        amt = bound(amt, 100_000, vault.remainingOf(id) + 500_000);
        usdc.mint(b, amt);
        vm.startPrank(b);
        usdc.approve(address(vault), amt);
        try vault.repayEarly(b, amt) {} catch {}
        vm.stopPrank();
    }

    function penalize(uint256 actorSeed) external {
        try vault.penalize(_actor(actorSeed)) {} catch {}
    }

    function withdrawLender(uint256 amount) external {
        uint256 max = vault.maxWithdraw(lender);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(lender);
        try vault.withdraw(amount, lender, lender) {} catch {}
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 0, 7 days);
        vm.warp(block.timestamp + secs);
    }

    // ---- ghost accessors ----
    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
