// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.t.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {ComputeFutures} from "../src/ComputeFutures.sol";
import {FacilitatorAdapter} from "../src/FacilitatorAdapter.sol";
import {CreditAdmin} from "../src/CreditAdmin.sol";
import {ComputeCreditVault} from "../src/ComputeCreditVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {TrustPassport} from "../src/TrustPassport.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Production-hardening + planned-module tests (additive; MVP behavior unchanged).
contract ProductionTest is Base {
    AgentIdentity identity;
    ComputeFutures futures;
    FacilitatorAdapter adapter;
    CreditAdmin admin;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        identity = new AgentIdentity(owner);
        futures = new ComputeFutures(usdc, router, owner);
        adapter = new FacilitatorAdapter(router, owner);
        address[] memory owners = new address[](1);
        owners[0] = owner;
        admin = new CreditAdmin(owners, 1, 0);
        identity.grantRole(identity.ATTESTER_ROLE(), owner);
        futures.setProviderAllowed(provider, true);
        passport.setIdentityRegistry(address(identity));
        vm.stopPrank();
    }

    function test_SigOnlyModeBlocksOperatorButAllowsBorrowerSelf() public {
        _depositLender(10_000_000);
        vm.prank(owner);
        vault.setSigOnlyMode(true);
        vm.expectRevert(ComputeCreditVault.NotAuthorizedRequester.selector);
        vm.prank(operator);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("sigonly-1"), nova);
        // borrower-self still works in sigOnly mode
        vm.prank(nova);
        uint256 id = vault.requestAdvanceFor(nova, provider, COST, keccak256("sigonly-1"), nova);
        assertEq(vault.activeAdvanceId(nova), id);
    }

    function test_GlobalOutstandingCapEnforced() public {
        _depositLender(100_000_000);
        vm.prank(owner);
        vault.setGlobalOutstandingCap(1_000_000); // below one repayable
        vm.expectRevert(
            abi.encodeWithSelector(
                ComputeCreditVault.OutstandingCapExceeded.selector, 2_010_000, 1_000_000
            )
        );
        vm.prank(operator);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("cap-1"), nova);
    }

    function test_WrongDecimalsReverts() public {
        BadDecimalsToken bad = new BadDecimalsToken();
        ProviderRegistry reg = new ProviderRegistry(owner);
        TrustPassport pass = new TrustPassport(owner);
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.BadDecimals.selector, 18, 6));
        new ComputeCreditVault(IERC20(address(bad)), reg, pass, owner);
    }

    function test_RiskTimelockProposeApply() public {
        vm.startPrank(owner);
        vault.setRiskChangeDelay(1 days);
        (uint256 minDeposit, , uint256 splitBps, uint256 penaltyBps, uint256 lienCaptureBps, uint256 window) = vault.risk();
        ComputeCreditVault.RiskParams memory r = ComputeCreditVault.RiskParams({
            minDeposit: minDeposit,
            feeBps: 100,
            splitBps: splitBps,
            penaltyBps: penaltyBps,
            lienCaptureBps: lienCaptureBps,
            advanceWindow: window
        });
        vault.proposeRisk(r);
        // immediate setRisk must now revert (timelocked)
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.RiskTimelocked.selector, vault.pendingRiskEta()));
        vault.setRisk(r);
        // cannot apply before eta
        vm.expectRevert(abi.encodeWithSelector(ComputeCreditVault.RiskTimelocked.selector, vault.pendingRiskEta()));
        vault.applyRisk();
        vm.warp(block.timestamp + 1 days + 1);
        vault.applyRisk();
        (, uint256 feeAfter,,,,) = vault.risk();
        assertEq(feeAfter, 100);
        vm.stopPrank();
    }

    function test_SeedQuorumTwoAttesters() public {
        address attester2 = address(0xA77E57);
        address fresh = address(0xF5E54);
        vm.startPrank(owner);
        passport.grantRole(passport.ATTESTER_ROLE(), attester2);
        passport.setSeedQuorum(2);
        passport.seedScore(fresh, 400, "first approval");
        // not yet seeded after 1 approval
        assertEq(passport.score(fresh), 0);
        vm.stopPrank();
        vm.prank(attester2);
        passport.approveSeed(fresh);
        assertEq(passport.score(fresh), 400);
    }

    function test_AgentIdentityLinkUnlink() public {
        address w1 = address(0x1111);
        address w2 = address(0x2222);
        vm.prank(owner);
        uint256 agentId = identity.createAgent(w1);
        assertEq(identity.agentOf(w1), agentId);
        vm.prank(owner);
        identity.linkWallet(agentId, w2);
        assertEq(identity.walletCount(agentId), 2);
        vm.prank(w2);
        identity.unlinkSelf();
        assertEq(identity.agentOf(w2), 0);
        assertEq(identity.walletCount(agentId), 1);
    }

    function test_ComputeFuturesReserveSettleViaRouter() public {
        _depositLender(50_000_000);
        // borrower takes an advance so router has something to service
        vm.prank(operator);
        uint256 advId = vault.requestAdvanceFor(nova, provider, COST, keccak256("fut-adv"), nova);
        // provider offers futures, buyer reserves for nova (worker)
        vm.prank(provider);
        uint256 offerId = futures.offer(1_000_000, 10, block.timestamp + 7 days, SERVICE);
        vm.startPrank(buyer);
        usdc.approve(address(futures), 2_000_000);
        uint256 resId = futures.reserve(offerId, nova, 2);
        vm.stopPrank();
        // settle: 2 USDC routed -> 20% (0.4) to vault, rest to nova
        (uint256 toVault, uint256 toWorker) = futures.settleViaRouter(resId, nova);
        assertEq(toVault, 400_000);
        assertEq(toWorker, 1_600_000);
        assertGt(vault.remainingOf(advId), 0); // partial (repayable 2.01M, serviced 0.4M)
    }

    function test_FacilitatorAdapterRecordsAndRoutes() public {
        _depositLender(10_000_000);
        vm.prank(operator);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("adapt-1"), nova);
        vm.prank(owner);
        adapter.setFacilitatorSupported(8453, true); // Base: facilitator path flagged
        bytes32 intent = keccak256("x402-intent-1");
        vm.startPrank(buyer);
        usdc.approve(address(adapter), 10_000_000);
        (uint256 toVault,, bool facilitatorPath) = adapter.recordAndRoute(nova, 10_000_000, nova, intent, 8453);
        vm.stopPrank();
        assertTrue(facilitatorPath);
        assertTrue(adapter.intentRecorded(intent));
        assertEq(toVault, 2_000_000); // 20% split
        // X Layer chain (1952) stays router fallback, never claims facilitator settlement
        bytes32 intent2 = keccak256("x402-intent-2");
        vm.startPrank(buyer);
        usdc.approve(address(adapter), 1_000_000);
        (,, bool path2) = adapter.recordAndRoute(nova, 1_000_000, nova, intent2, 1952);
        vm.stopPrank();
        assertFalse(path2);
    }

    function test_CreditAdminMultisigExecutes() public {
        // admin (threshold 1) executes setSigOnlyMode(true) on the vault via proposal
        vm.prank(owner);
        vault.transferOwnership(address(admin));
        bytes memory data = abi.encodeWithSelector(ComputeCreditVault.setSigOnlyMode.selector, true);
        vm.prank(owner);
        uint256 id = admin.propose(address(vault), data);
        vm.prank(owner);
        admin.execute(id);
        assertTrue(vault.sigOnlyMode());
    }
}

contract BadDecimalsToken is ERC20 {
    constructor() ERC20("Bad", "BAD") {}
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
