// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.t.sol";
import {MockXStock} from "../src/MockXStock.sol";
import {RwaCollateral} from "../src/RwaCollateral.sol";

/// @notice RWA integration tests: lock xStock -> boosted effective limit.
contract RwaTest is Base {
    MockXStock xstock;
    RwaCollateral collateral;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        xstock = new MockXStock("AAPLx");
        collateral = new RwaCollateral(address(xstock), owner);
        collateral.setVault(address(vault));
        vault.setRwaCollateral(address(collateral));
        vm.stopPrank();
        // nova holds 2 whole stocks @ 10 USDC each = 20 USDC value, capped to 10 boost
        xstock.mint(nova, 2e18);
    }

    function test_EffectiveLimitWithoutLockIsTier() public view {
        // score 300 -> tier 5 USDC
        assertEq(vault.effectiveLimit(nova), 5_000_000);
    }

    function test_LockBoostsLimitCapped() public {
        vm.startPrank(nova);
        xstock.approve(address(collateral), 2e18);
        collateral.lock(2e18);
        vm.stopPrank();
        assertEq(collateral.collateralValue(nova), 20_000_000);
        assertEq(vault.effectiveLimit(nova), 5_000_000 + 10_000_000); // capped
    }

    function test_BoostedAdvanceSucceeds() public {
        _depositLender(50_000_000);
        vm.startPrank(nova);
        xstock.approve(address(collateral), 1e18);
        collateral.lock(1e18); // 10 USDC value -> +10 boost = 15 limit
        vm.stopPrank();
        // provider ceiling is 5 USDC in Base; raise for this test via owner
        vm.prank(owner);
        registry.updatePrice(provider, 15_000_000);
        vm.prank(operator);
        uint256 id = vault.requestAdvanceFor(nova, provider, 12_000_000, keccak256("rwa-job"), nova);
        assertEq(vault.activeAdvanceId(nova), id);
    }

    function test_UnlockBlockedWithActiveAdvance() public {
        _depositLender(50_000_000);
        vm.startPrank(nova);
        xstock.approve(address(collateral), 1e18);
        collateral.lock(1e18);
        vm.stopPrank();
        vm.prank(operator);
        vault.requestAdvanceFor(nova, provider, COST, keccak256("rwa-lock-job"), nova);
        vm.prank(nova);
        vm.expectRevert(RwaCollateral.PositionLocked.selector);
        collateral.unlock(1e18);
    }

    function test_UnlockWorksWhenClear() public {
        vm.startPrank(nova);
        xstock.approve(address(collateral), 1e18);
        collateral.lock(1e18);
        collateral.unlock(1e18);
        vm.stopPrank();
        assertEq(collateral.locked(nova), 0);
        assertEq(xstock.balanceOf(nova), 2e18);
    }
}
