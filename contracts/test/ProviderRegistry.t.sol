// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ProviderRegistry } from "../src/ProviderRegistry.sol";

/**
 * @notice ProviderRegistry tests: administrator bounds, registration, price / wallet / service
 *         updates, activation and the canonical job-hash formula.
 *
 * Spec reference: ComputeCredit_v2.pdf §6 (Provider registry), §15 (Testing checklist — the
 * registry is the authoritative price source, so the vault can never be asked to advance more
 * than the registered price), §16 (demo provider configuration).
 */
contract ProviderRegistryTest is Test {
    address internal owner = makeAddr("owner");
    address internal administrator = makeAddr("administrator");
    address internal outsider = makeAddr("outsider");
    address internal provider = makeAddr("provider");
    address internal providerWallet = makeAddr("providerWallet");
    address internal replacementWallet = makeAddr("replacementWallet");
    address internal otherProvider = makeAddr("otherProvider");

    bytes32 internal constant SERVICE_ID = keccak256("haiku-v1");
    bytes32 internal constant OTHER_SERVICE_ID = keccak256("image-v1");
    uint256 internal constant PROVIDER_PRICE = 20_000; // 0.02 USDC
    uint256 internal constant RAISED_PRICE = 30_000; // 0.03 USDC

    ProviderRegistry internal registry;

    event AdministratorSet(address indexed administrator, bool approved);
    event ProviderRegistered(
        address indexed provider, address indexed providerWallet, uint256 pricePerJob, bytes32 serviceId
    );
    event ProviderPriceUpdated(address indexed provider, uint256 previousPrice, uint256 newPrice);
    event ProviderWalletUpdated(address indexed provider, address previousWallet, address newWallet);
    event ProviderStatusUpdated(address indexed provider, bool active);
    event ProviderServiceUpdated(address indexed provider, bytes32 previousServiceId, bytes32 newServiceId);

    function setUp() public {
        vm.warp(1_760_000_000);
        registry = new ProviderRegistry(owner);
        vm.prank(owner);
        registry.setAdministrator(administrator, true);
        vm.prank(administrator);
        registry.registerProvider(provider, providerWallet, PROVIDER_PRICE, SERVICE_ID);
    }

    // =====================================================================
    // Construction and administrator bounds (spec §6, §3.1 trust boundary)
    // =====================================================================

    function test_ConstructorRejectsZeroOwner() public {
        // OpenZeppelin Ownable rejects the zero owner before the registry body runs.
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ProviderRegistry(address(0));
    }

    function test_SetAdministratorIsOwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        registry.setAdministrator(outsider, true);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit AdministratorSet(outsider, true);
        registry.setAdministrator(outsider, true);

        vm.prank(outsider);
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);
        assertTrue(registry.isActive(otherProvider), "granted administrator can register providers");
    }

    function test_SetAdministratorRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.setAdministrator(address(0), true);
    }

    function test_RevokedAdministratorLosesWriteAccess() public {
        vm.prank(owner);
        registry.setAdministrator(administrator, false);

        vm.prank(administrator);
        vm.expectRevert(ProviderRegistry.NotAdministrator.selector);
        registry.updateProviderPrice(provider, RAISED_PRICE);
    }

    function test_OnlyAdministratorsCanMutateTheRegistry() public {
        bytes4 notAdmin = ProviderRegistry.NotAdministrator.selector;

        vm.startPrank(outsider);
        vm.expectRevert(notAdmin);
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);
        vm.expectRevert(notAdmin);
        registry.updateProviderPrice(provider, RAISED_PRICE);
        vm.expectRevert(notAdmin);
        registry.updateProviderWallet(provider, replacementWallet);
        vm.expectRevert(notAdmin);
        registry.updateProviderService(provider, OTHER_SERVICE_ID);
        vm.expectRevert(notAdmin);
        registry.setProviderActive(provider, false);
        vm.stopPrank();
    }

    // =====================================================================
    // Registration (spec §6)
    // =====================================================================

    function test_RegisterProviderStoresTheQuoteAndEmits() public {
        vm.prank(administrator);
        vm.expectEmit(true, true, false, true, address(registry));
        emit ProviderRegistered(otherProvider, providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);

        ProviderRegistry.ProviderQuote memory quote = registry.quoteOf(otherProvider);
        assertTrue(quote.active, "registered providers start active");
        assertEq(quote.providerWallet, providerWallet, "payout wallet");
        assertEq(quote.pricePerJob, PROVIDER_PRICE, "registered price cap");
        assertEq(quote.serviceId, OTHER_SERVICE_ID, "service id");
        assertEq(quote.updatedAt, block.timestamp, "updatedAt");
        assertEq(registry.providerCount(), 2, "monotonic provider counter");
        assertEq(registry.providerForService(OTHER_SERVICE_ID), otherProvider, "service reverse index");
    }

    function test_RegisterProviderRejectsZeroAddressesAndZeroPrice() public {
        vm.startPrank(administrator);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.registerProvider(address(0), providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.registerProvider(otherProvider, address(0), PROVIDER_PRICE, OTHER_SERVICE_ID);
        vm.expectRevert(ProviderRegistry.InvalidPrice.selector);
        registry.registerProvider(otherProvider, providerWallet, 0, OTHER_SERVICE_ID);
        vm.stopPrank();
    }

    function test_RegisterProviderRejectsDuplicates() public {
        vm.startPrank(administrator);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderAlreadyRegistered.selector, provider));
        registry.registerProvider(provider, replacementWallet, RAISED_PRICE, bytes32(0));

        // A service id already owned by another provider cannot be reused either.
        vm.expectRevert(
            abi.encodeWithSelector(ProviderRegistry.DuplicateServiceRegistered.selector, provider, SERVICE_ID)
        );
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, SERVICE_ID);
        vm.stopPrank();
    }

    function test_RegisterProviderWithoutServiceIdIsAllowed() public {
        vm.prank(administrator);
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, bytes32(0));
        assertEq(registry.serviceId(otherProvider), bytes32(0), "no service id recorded");
        assertTrue(registry.isActive(otherProvider), "still an approved provider");
    }

    // =====================================================================
    // Price updates (spec §6 — this is the vault's only trusted price source)
    // =====================================================================

    function test_UpdateProviderPriceEmitsPreviousAndNew() public {
        vm.prank(administrator);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderPriceUpdated(provider, PROVIDER_PRICE, RAISED_PRICE);
        registry.updateProviderPrice(provider, RAISED_PRICE);

        assertEq(registry.pricePerJob(provider), RAISED_PRICE, "new cap applies");
        assertEq(registry.quoteOf(provider).updatedAt, block.timestamp, "update stamped");
    }

    function test_UpdateProviderPriceGuards() public {
        vm.startPrank(administrator);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, outsider));
        registry.updateProviderPrice(outsider, RAISED_PRICE);
        vm.expectRevert(ProviderRegistry.InvalidPrice.selector);
        registry.updateProviderPrice(provider, 0);
        vm.stopPrank();
    }

    function test_UpdateProviderWallet() public {
        vm.prank(administrator);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderWalletUpdated(provider, providerWallet, replacementWallet);
        registry.updateProviderWallet(provider, replacementWallet);
        assertEq(registry.providerWallet(provider), replacementWallet, "wallet rotated");

        vm.startPrank(administrator);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.updateProviderWallet(provider, address(0));
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, outsider));
        registry.updateProviderWallet(outsider, replacementWallet);
        vm.stopPrank();
    }

    function test_UpdateProviderService() public {
        vm.prank(administrator);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderServiceUpdated(provider, SERVICE_ID, OTHER_SERVICE_ID);
        registry.updateProviderService(provider, OTHER_SERVICE_ID);

        assertEq(registry.serviceId(provider), OTHER_SERVICE_ID, "service id rotated");
        assertEq(registry.providerForService(OTHER_SERVICE_ID), provider, "reverse index follows");
    }

    function test_UpdateProviderServiceRejectsServiceOwnedByAnotherProvider() public {
        vm.prank(administrator);
        registry.registerProvider(otherProvider, providerWallet, PROVIDER_PRICE, OTHER_SERVICE_ID);

        vm.prank(administrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProviderRegistry.DuplicateServiceRegistered.selector, otherProvider, OTHER_SERVICE_ID
            )
        );
        registry.updateProviderService(provider, OTHER_SERVICE_ID);
    }

    function test_UpdateProviderServiceAllowsClearingToZero() public {
        vm.prank(administrator);
        registry.updateProviderService(provider, bytes32(0));
        assertEq(registry.serviceId(provider), bytes32(0), "cleared");
    }

    // =====================================================================
    // Activation (spec §5.5 — inactive providers cannot back advances)
    // =====================================================================

    function test_SetProviderActiveTogglesAndEmits() public {
        vm.prank(administrator);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderStatusUpdated(provider, false);
        registry.setProviderActive(provider, false);

        assertFalse(registry.isActive(provider), "deactivated");
        assertFalse(registry.quoteOf(provider).active, "struct agrees");
        assertEq(registry.pricePerJob(provider), PROVIDER_PRICE, "price retained while inactive");

        vm.prank(administrator);
        registry.setProviderActive(provider, true);
        assertTrue(registry.isActive(provider), "reactivated");
    }

    function test_SetProviderActiveGuardsUnregisteredProvider() public {
        vm.prank(administrator);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, outsider));
        registry.setProviderActive(outsider, true);
    }

    // =====================================================================
    // Views and canonical job hash (spec §6)
    // =====================================================================

    function test_UnregisteredProviderReadsAsInactiveAndUnpriced() public {
        assertFalse(registry.isActive(outsider), "unknown providers are inactive");
        assertEq(registry.pricePerJob(outsider), 0, "unknown price is zero");
        assertEq(registry.providerWallet(outsider), address(0), "unknown wallet is zero");
        assertEq(registry.serviceId(outsider), bytes32(0), "unknown service id is zero");
    }

    function test_JobHashBindsBorrowerProviderServicePriceNonceAndExpiry() public {
        address borrower = makeAddr("borrower");
        uint256 nonce = 7;
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 expected =
            keccak256(abi.encode(borrower, provider, SERVICE_ID, PROVIDER_PRICE, nonce, expiry));
        assertEq(
            registry.computeJobHash(borrower, provider, SERVICE_ID, PROVIDER_PRICE, nonce, expiry),
            expected,
            "canonical hash"
        );
        assertEq(
            registry.computeJobHashRaw(borrower, provider, SERVICE_ID, PROVIDER_PRICE, nonce, expiry),
            expected,
            "raw variant is identical"
        );

        // Every bound field changes the hash: a provider cannot be swapped for a cheaper one,
        // a price cannot be inflated, and a stale nonce/expiry cannot be replayed.
        assertTrue(
            registry.computeJobHash(borrower, otherProvider, SERVICE_ID, PROVIDER_PRICE, nonce, expiry) != expected,
            "provider is bound"
        );
        assertTrue(
            registry.computeJobHash(borrower, provider, OTHER_SERVICE_ID, PROVIDER_PRICE, nonce, expiry) != expected,
            "service is bound"
        );
        assertTrue(
            registry.computeJobHash(borrower, provider, SERVICE_ID, RAISED_PRICE, nonce, expiry) != expected,
            "price is bound"
        );
        assertTrue(
            registry.computeJobHash(borrower, provider, SERVICE_ID, PROVIDER_PRICE, nonce + 1, expiry) != expected,
            "nonce is bound"
        );
        assertTrue(
            registry.computeJobHash(borrower, provider, SERVICE_ID, PROVIDER_PRICE, nonce, expiry + 1) != expected,
            "expiry is bound"
        );
    }
}
