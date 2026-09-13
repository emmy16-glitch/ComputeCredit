// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { TrustPassport } from "../src/TrustPassport.sol";

/**
 * @notice TrustPassport tests: bounded score authority, guarded seeding, tiers, liens and
 *         EIP-712 work attestations.
 *
 * Spec reference: ComputeCredit_v2.pdf §7 (TrustPassport specification), §15 (Testing checklist
 * — "Score seeding can occur only once", "Score cannot exceed 1,000", "Score cannot become
 * negative").
 */
contract TrustPassportTest is Test {
    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal agent = makeAddr("agent");
    address internal outsider = makeAddr("outsider");

    // Attester is a real key so that EIP-712 signatures can be produced and verified.
    uint256 internal attesterPk = 0xA11CE;
    address internal attester;

    TrustPassport internal passport;

    event ScoreSeeded(address indexed agent, uint256 score, string reason);

    function setUp() public {
        vm.warp(1_760_000_000);
        attester = vm.addr(attesterPk);
        passport = new TrustPassport(attester, owner);
        vm.prank(owner);
        passport.setVault(vault);
    }

    // =====================================================================
    // Seeding (spec §7.4)
    // =====================================================================

    function test_SeedScoreClampsToBootstrapCeiling() public {
        vm.expectEmit(true, false, false, true, address(passport));
        emit ScoreSeeded(agent, 200, "bootstrap: trusted attester value, not verified history");

        vm.prank(attester);
        passport.seedScore(agent, 900); // requested above the clamp

        assertEq(passport.score(agent), 200, "clamped to 200");
        assertTrue(passport.scoreSeeded(agent), "seeded before the event");
    }

    function test_SeedScoreStoresValueBelowClamp() public {
        vm.prank(attester);
        passport.seedScore(agent, 150);
        assertEq(passport.score(agent), 150);
    }

    function test_SeedScoreCanOccurOnlyOnce() public {
        vm.prank(attester);
        passport.seedScore(agent, 150);

        vm.expectRevert(abi.encodeWithSelector(TrustPassport.ScoreAlreadySeeded.selector, agent));
        vm.prank(attester);
        passport.seedScore(agent, 200);
    }

    function test_SeedScoreOnlyAttester() public {
        vm.expectRevert(TrustPassport.NotAttester.selector);
        vm.prank(outsider);
        passport.seedScore(agent, 150);

        vm.expectRevert(TrustPassport.NotAttester.selector);
        vm.prank(owner);
        passport.seedScore(agent, 150);
    }

    function test_SeedScoreRejectsZeroAddress() public {
        vm.expectRevert(TrustPassport.ZeroAddress.selector);
        vm.prank(attester);
        passport.seedScore(address(0), 150);
    }

    function test_AttesterIsRotatableByOwnerOnly() public {
        address newAttester = makeAddr("newAttester");
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        passport.setAttester(newAttester);

        vm.prank(owner);
        passport.setAttester(newAttester);
        assertEq(passport.attester(), newAttester);

        vm.expectRevert(TrustPassport.NotAttester.selector);
        vm.prank(attester); // old attester lost the right
        passport.seedScore(agent, 150);
    }

    // =====================================================================
    // Score mutation authority (spec §7.5)
    // =====================================================================

    function test_OnlyVaultCanMutateScore() public {
        vm.expectRevert(TrustPassport.NotVault.selector);
        vm.prank(outsider);
        passport.increaseScore(agent, 20);

        vm.expectRevert(TrustPassport.NotVault.selector);
        vm.prank(owner); // even the passport owner cannot rewrite a score
        passport.slashScore(agent, 20);

        vm.expectRevert(TrustPassport.NotVault.selector);
        vm.prank(attester);
        passport.slashToZero(agent, "nope");
    }

    function test_VaultBindingIsOneTime() public {
        vm.expectRevert(TrustPassport.VaultAlreadySet.selector);
        vm.prank(owner);
        passport.setVault(makeAddr("otherVault"));

        assertEq(passport.vault(), vault);
    }

    function test_SetVaultRejectsZeroAddressAndNonOwner() public {
        TrustPassport fresh = new TrustPassport(attester, owner);
        vm.expectRevert(TrustPassport.ZeroAddress.selector);
        vm.prank(owner);
        fresh.setVault(address(0));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), outsider));
        vm.prank(outsider);
        fresh.setVault(vault);
    }

    function test_ScoreCannotExceedMaximum() public {
        vm.prank(vault);
        passport.increaseScore(agent, 5_000);
        assertEq(passport.score(agent), 1_000, "capped at SCORE_MAX");
    }

    function test_ScoreCannotBecomeNegative() public {
        vm.prank(vault);
        passport.increaseScore(agent, 30);

        vm.prank(vault);
        passport.slashScore(agent, 100); // more than the current score
        assertEq(passport.score(agent), 0, "floored at zero");
    }

    function test_SlashToZeroIsDeterministic() public {
        vm.prank(vault);
        passport.increaseScore(agent, 400);

        vm.prank(vault);
        passport.slashToZero(agent, "default");
        assertEq(passport.score(agent), 0);
    }

    // =====================================================================
    // Tiers (spec §7.3)
    // =====================================================================

    function test_TierLimitsMatchSpecification() public view {
        assertEq(passport.maxAdvanceFor(0), 1e6, "0 -> 1 USDC");
        assertEq(passport.maxAdvanceFor(200), 1e6, "200 -> 1 USDC");
        assertEq(passport.maxAdvanceFor(201), 5e6, "201 -> 5 USDC");
        assertEq(passport.maxAdvanceFor(500), 5e6, "500 -> 5 USDC");
        assertEq(passport.maxAdvanceFor(501), 25e6, "501 -> 25 USDC");
        assertEq(passport.maxAdvanceFor(800), 25e6, "800 -> 25 USDC");
        assertEq(passport.maxAdvanceFor(801), 50e6, "801 -> 50 USDC");
        assertEq(passport.maxAdvanceFor(1_000), 50e6, "1000 -> 50 USDC");
    }

    function test_TierOfReportsUnderwritingTier() public {
        vm.prank(attester);
        passport.seedScore(agent, 150);
        assertEq(passport.tierOf(agent), 1);

        vm.prank(vault);
        passport.increaseScore(agent, 400);
        assertEq(passport.score(agent), 550);
        assertEq(passport.tierOf(agent), 3);
        assertEq(passport.maxAdvance(agent), 25e6);
    }

    // =====================================================================
    // Liens (spec §5.8, §5.9)
    // =====================================================================

    function test_LienLifecycle() public {
        assertFalse(passport.isLienActive(agent));

        vm.prank(vault);
        passport.setLien(agent, 30_000, 10_000);

        assertTrue(passport.isLienActive(agent));
        assertEq(passport.lienTarget(agent), 30_000);
        assertEq(passport.revenueLienBps(agent), 10_000);
        assertEq(passport.remainingLien(agent), 30_000);

        vm.prank(vault);
        (uint256 captured, bool cleared) = passport.recordLienCapture(agent, 10_000);
        assertEq(captured, 10_000);
        assertFalse(cleared);
        assertEq(passport.lienCaptured(agent), 10_000);
        assertEq(passport.remainingLien(agent), 20_000);
        assertTrue(passport.isLienActive(agent));

        // Over-payment is credited only up to the target.
        vm.prank(vault);
        (captured, cleared) = passport.recordLienCapture(agent, 50_000);
        assertEq(captured, 20_000, "capture stops at the target");
        assertTrue(cleared);
        assertEq(passport.lienCaptured(agent), 30_000);
        assertFalse(passport.isLienActive(agent));
        assertEq(passport.revenueLienBps(agent), 0, "cleared lien resets the capture rate");
    }

    function test_LienCaptureBeyondTargetReverts() public {
        vm.prank(vault);
        passport.setLien(agent, 1_000, 10_000);
        vm.prank(vault);
        passport.recordLienCapture(agent, 1_000);

        vm.expectRevert(abi.encodeWithSelector(TrustPassport.NoActiveLien.selector, agent));
        vm.prank(vault);
        passport.recordLienCapture(agent, 1);
    }

    function test_LienSettersAreVaultOnly() public {
        vm.expectRevert(TrustPassport.NotVault.selector);
        vm.prank(outsider);
        passport.setLien(agent, 1_000, 10_000);

        vm.expectRevert(TrustPassport.NotVault.selector);
        vm.prank(outsider);
        passport.recordLienCapture(agent, 1);
    }

    // =====================================================================
    // Work attestations (spec §7.6)
    // =====================================================================

    function _attestation(uint256 nonce) internal view returns (TrustPassport.WorkAttestation memory) {
        return TrustPassport.WorkAttestation({
            agent: agent,
            workHash: keccak256("job-result"),
            paymentTxHash: keccak256("buyer-payment-tx"),
            issuedAt: block.timestamp,
            nonce: nonce
        });
    }

    function test_AttestRequiresAttester() public {
        vm.expectRevert(TrustPassport.NotAttester.selector);
        vm.prank(outsider);
        passport.attest(_attestation(0));
    }

    function test_AttestStoresHashAndConsumesNonce() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        vm.prank(attester);
        bytes32 stored = passport.attest(att);

        assertEq(stored, passport.hashAttestation(att));
        assertEq(passport.attestationCount(agent), 1);
        assertEq(passport.attestationAt(agent, 0), stored);
        assertEq(passport.attestationNonce(agent), 1);
    }

    function test_AttestationNoncePreventsReplay() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        vm.prank(attester);
        passport.attest(att);

        // Same payload again: the nonce was consumed.
        vm.expectRevert(abi.encodeWithSelector(TrustPassport.InvalidNonce.selector, 0, 1));
        vm.prank(attester);
        passport.attest(att);
    }

    function test_AttestationRejectsEmptyFields() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        att.workHash = bytes32(0);
        vm.expectRevert(TrustPassport.InvalidAttestation.selector);
        vm.prank(attester);
        passport.attest(att);

        TrustPassport.WorkAttestation memory att2 = _attestation(0);
        att2.agent = address(0);
        vm.expectRevert(TrustPassport.InvalidAttestation.selector);
        vm.prank(attester);
        passport.attest(att2);

        TrustPassport.WorkAttestation memory att3 = _attestation(0);
        att3.issuedAt = 0;
        vm.expectRevert(TrustPassport.InvalidAttestation.selector);
        vm.prank(attester);
        passport.attest(att3);
    }

    function test_AttestationReadOutOfRangeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(TrustPassport.NoAttestations.selector, agent));
        passport.attestationAt(agent, 0);
    }

    function test_DomainSeparatorMatchesEip712Specification() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ComputeCreditTrustPassport")),
                keccak256(bytes("1")),
                block.chainid,
                address(passport)
            )
        );
        assertEq(passport.domainSeparatorV4(), expected, "domain = name, version, chainId, verifyingContract");
    }

    function test_AttestBySigVerifiesSignatureOnchain() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        bytes32 digest = passport.attestationDigest(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes32 stored = passport.attestBySig(att, signature);

        assertEq(passport.attestationCount(agent), 1, "stored once");
        assertEq(stored, passport.hashAttestation(att));
        assertEq(passport.attestationNonce(agent), 1, "nonce consumed");
    }

    function test_AttestBySigRejectsWrongSigner() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        bytes32 digest = passport.attestationDigest(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest); // not the attester
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(TrustPassport.InvalidSigner.selector, vm.addr(0xB0B), attester));
        passport.attestBySig(att, signature);
    }

    function test_AttestBySigRejectsTamperedPayload() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        bytes32 digest = passport.attestationDigest(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        att.workHash = keccak256("tampered");
        vm.expectRevert(); // signature no longer matches the digest
        passport.attestBySig(att, signature);
    }

    function test_AttestBySigReplayReverts() public {
        TrustPassport.WorkAttestation memory att = _attestation(0);
        bytes32 digest = passport.attestationDigest(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        passport.attestBySig(att, signature);

        vm.expectRevert(abi.encodeWithSelector(TrustPassport.InvalidNonce.selector, 0, 1));
        passport.attestBySig(att, signature);
    }

    function test_MultipleAttestationsAccumulate() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(attester);
            passport.attest(_attestation(i));
        }
        assertEq(passport.attestationCount(agent), 3);
        assertEq(passport.attestationNonce(agent), 3);
    }
}
