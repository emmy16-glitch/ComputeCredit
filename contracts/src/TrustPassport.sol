// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title TrustPassport
 * @notice Wallet-linked reputation registry for ComputeCredit.
 *
 * Spec reference: ComputeCredit_v2.pdf §7 (TrustPassport specification), §10 (Security model).
 *
 * Scope honesty (spec §7.1):
 *   - The passport stores a score in [0, 1000] plus hashes of work / repayment attestations.
 *   - It does NOT prove that two wallets belong to the same human or agent.
 *   - It does NOT eliminate sybil attacks. A fresh wallet restarts at the bootstrap tier.
 *   - It makes score and recorded history readable by other contracts (the vault).
 *
 * Authority model (spec §7.5):
 *   - `attester` may seed a score exactly once per wallet, clamped to 0..200 (bootstrap).
 *   - After `vault` is set, ONLY the vault may mutate scores and liens. This keeps score
 *     authority bounded and reviewable: one contract, one code path.
 */
contract TrustPassport is Ownable, EIP712 {
    // ---------------------------------------------------------------------
    // Score / tier constants (spec §5.1, §7.3)
    // ---------------------------------------------------------------------

    /// @notice Maximum representable score.
    uint256 public constant SCORE_MAX = 1_000;
    /// @notice A seeded (bootstrap) score is clamped to this ceiling (spec §7.4).
    uint256 public constant SEED_SCORE_CLAMP = 200;
    /// @notice Points added on exact on-time settlement (spec §7.5, "for example 20").
    uint256 public constant SETTLEMENT_SCORE_BUMP = 20;

    /// @notice Tier 1 upper bound: 0..200   -> 1 USDC max advance.
    uint256 public constant TIER_1_MAX_SCORE = 200;
    /// @notice Tier 2 upper bound: 201..500 -> 5 USDC max advance.
    uint256 public constant TIER_2_MAX_SCORE = 500;
    /// @notice Tier 3 upper bound: 501..800 -> 25 USDC max advance.
    uint256 public constant TIER_3_MAX_SCORE = 800;
    /// @notice Tier 1 limit (1 USDC, 6-decimal token units).
    uint256 public constant TIER_1_ADVANCE_LIMIT = 1e6;
    /// @notice Tier 2 limit (5 USDC).
    uint256 public constant TIER_2_ADVANCE_LIMIT = 5e6;
    /// @notice Tier 3 limit (25 USDC).
    uint256 public constant TIER_3_ADVANCE_LIMIT = 25e6;
    /// @notice Tier 4 limit (50 USDC) for scores 801..1000.
    uint256 public constant TIER_4_ADVANCE_LIMIT = 50e6;

    uint256 public constant MAX_BPS = 10_000;

    // ---------------------------------------------------------------------
    // EIP-712 work attestations (spec §7.6)
    // ---------------------------------------------------------------------

    /// @notice Attestation payload signed by the configured attester.
    struct WorkAttestation {
        address agent;
        bytes32 workHash;
        bytes32 paymentTxHash;
        uint256 issuedAt;
        uint256 nonce;
    }

    /// @dev keccak256("WorkAttestation(address agent,bytes32 workHash,bytes32 paymentTxHash,uint256 issuedAt,uint256 nonce)")
    bytes32 public constant WORK_ATTESTATION_TYPEHASH = keccak256(
        "WorkAttestation(address agent,bytes32 workHash,bytes32 paymentTxHash,uint256 issuedAt,uint256 nonce)"
    );

    // ---------------------------------------------------------------------
    // State (spec §7.2 — field-for-field)
    // ---------------------------------------------------------------------

    /// @notice Score per wallet identity, 0..SCORE_MAX.
    mapping(address => uint256) public score;

    /// @notice True once a wallet has received its one-time bootstrap seed.
    mapping(address => bool) public scoreSeeded;

    /// @notice Stored attestation hashes per agent.
    mapping(address => bytes32[]) private _attestations;

    /// @notice Share of routed revenue captured against an active lien, in bps.
    mapping(address => uint256) public revenueLienBps;

    /// @notice Recovery objective created on default: shortfall * 1.5 (spec §4.4, §5.8).
    mapping(address => uint256) public lienTarget;

    /// @notice Amount already captured toward `lienTarget`.
    mapping(address => uint256) public lienCaptured;

    /// @notice Next expected attestation nonce per agent (replay protection).
    mapping(address => uint256) public attestationNonce;

    /// @notice The only contract allowed to mutate score and lien state after deployment.
    address public vault;

    /// @notice Address allowed to seed bootstrap scores and submit work attestations.
    address public attester;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event VaultSet(address indexed vault);
    event AttesterSet(address indexed attester);
    event ScoreSeeded(address indexed agent, uint256 score, string reason);
    event ScoreIncreased(address indexed agent, uint256 amount, uint256 newScore);
    event ScoreSlashed(address indexed agent, uint256 amount, uint256 newScore);
    event ScoreZeroed(address indexed agent, string reason);
    event WorkAttested(address indexed agent, bytes32 indexed workHash, bytes32 attestationHash, uint256 nonce, bool verifiedOnchain);
    event LienSet(address indexed borrower, uint256 target, uint256 revenueLienBps);
    event LienCaptured(address indexed borrower, uint256 amount, uint256 totalCaptured, uint256 target);
    event LienCleared(address indexed borrower, uint256 totalCaptured);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error NotVault();
    error NotAttester();
    error VaultAlreadySet();
    error ScoreAlreadySeeded(address agent);
    error ScoreExceedsMax(uint256 requested, uint256 max);
    error NoAttestations(address agent);
    error InvalidNonce(uint256 provided, uint256 expected);
    error InvalidSigner(address recovered, address expected);
    error InvalidAttestation();
    error NoActiveLien(address borrower);

    // ---------------------------------------------------------------------
    // Construction / administration
    // ---------------------------------------------------------------------

    /**
     * @param attester_ Trusted bootstrap attester (spec §3.1 — a deliberate MVP trust assumption).
     * @param owner_ Administrator able to rotate the attester and set the vault once.
     */
    constructor(address attester_, address owner_) Ownable(owner_) EIP712("ComputeCreditTrustPassport", "1") {
        if (attester_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    /// @notice Rotate the trusted attester. Only the passport owner may call.
    function setAttester(address attester_) external onlyOwner {
        if (attester_ == address(0)) revert ZeroAddress();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    /**
     * @notice Bind the vault once. After this call the vault is the only address able to
     *         mutate score and lien state (spec §7.5: "Only the vault may call score
     *         mutation functions after deployment.").
     */
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        emit VaultSet(vault_);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyAttester() {
        if (msg.sender != attester) revert NotAttester();
        _;
    }

    // ---------------------------------------------------------------------
    // Score: seeding (spec §7.4)
    // ---------------------------------------------------------------------

    /**
     * @notice Seed a one-time bootstrap score for a wallet.
     * @dev Requirements (spec §7.4):
     *      - callable only by the configured attester;
     *      - callable only once per wallet;
     *      - initialScore is clamped to 0..200;
     *      - scoreSeeded[agent] is set before the event is emitted;
     *      - the event reason identifies the value as a trusted bootstrap value.
     */
    function seedScore(address agent, uint256 initialScore) external onlyAttester {
        if (agent == address(0)) revert ZeroAddress();
        if (scoreSeeded[agent]) revert ScoreAlreadySeeded(agent);

        uint256 clamped = initialScore > SEED_SCORE_CLAMP ? SEED_SCORE_CLAMP : initialScore;

        // Effects before event, and events before any external interaction.
        scoreSeeded[agent] = true;
        score[agent] = clamped;

        emit ScoreSeeded(agent, clamped, "bootstrap: trusted attester value, not verified history");
        // Keep the audit trail readable as a score change as well.
        emit ScoreIncreased(agent, clamped, clamped);
    }

    // ---------------------------------------------------------------------
    // Score: mutation (vault-only, spec §7.5)
    // ---------------------------------------------------------------------

    /// @notice Add `amount` points on on-time settlement, capped at SCORE_MAX.
    function increaseScore(address agent, uint256 amount) external onlyVault {
        uint256 updated = score[agent] + amount;
        if (updated > SCORE_MAX) updated = SCORE_MAX;
        score[agent] = updated;
        emit ScoreIncreased(agent, amount, updated);
    }

    /// @notice Remove `amount` points, floored at zero (score can never become negative).
    function slashScore(address agent, uint256 amount) external onlyVault {
        uint256 current = score[agent];
        uint256 updated = amount >= current ? 0 : current - amount;
        score[agent] = updated;
        emit ScoreSlashed(agent, amount, updated);
    }

    /**
     * @notice Deterministic default penalty used by the MVP: full slash to zero.
     * @dev Spec §7.5: "For the demo, a full slash to zero is simple to explain." A production
     *      system should calibrate the penalty and distinguish fraud, expiry and illiquidity.
     */
    function slashToZero(address agent, string calldata reason) external onlyVault {
        score[agent] = 0;
        emit ScoreZeroed(agent, reason);
        emit ScoreSlashed(agent, type(uint256).max, 0);
    }

    // ---------------------------------------------------------------------
    // Score: derived underwriting limits (spec §7.3)
    // ---------------------------------------------------------------------

    /**
     * @notice Maximum advance for a wallet's current score tier.
     * @dev The tier limit is never a general credit line: the vault additionally caps every
     *      advance by the registered one-job provider price (spec §7.3).
     */
    function maxAdvanceFor(uint256 score_) public pure returns (uint256) {
        if (score_ <= TIER_1_MAX_SCORE) return TIER_1_ADVANCE_LIMIT;
        if (score_ <= TIER_2_MAX_SCORE) return TIER_2_ADVANCE_LIMIT;
        if (score_ <= TIER_3_MAX_SCORE) return TIER_3_ADVANCE_LIMIT;
        return TIER_4_ADVANCE_LIMIT;
    }

    /// @notice Convenience view: advance ceiling for `agent`.
    function maxAdvance(address agent) external view returns (uint256) {
        return maxAdvanceFor(score[agent]);
    }

    /// @notice Human-readable tier index (1..4) for `agent`.
    function tierOf(address agent) external view returns (uint256) {
        uint256 s = score[agent];
        if (s <= TIER_1_MAX_SCORE) return 1;
        if (s <= TIER_2_MAX_SCORE) return 2;
        if (s <= TIER_3_MAX_SCORE) return 3;
        return 4;
    }

    // ---------------------------------------------------------------------
    // Liens (spec §5.8, §5.9, §7.2)
    // ---------------------------------------------------------------------

    /// @notice True while a defaulted borrower still has an uncaptured lien target.
    function isLienActive(address borrower) external view returns (bool) {
        return lienCaptured[borrower] < lienTarget[borrower];
    }

    /// @notice Remaining capture objective for a defaulted borrower.
    function remainingLien(address borrower) external view returns (uint256) {
        uint256 target = lienTarget[borrower];
        uint256 captured = lienCaptured[borrower];
        return captured >= target ? 0 : target - captured;
    }

    /// @notice Create (or replace) the lien for a defaulted borrower. Vault-only.
    function setLien(address borrower, uint256 target, uint256 revenueLienBps_) external onlyVault {
        lienTarget[borrower] = target;
        lienCaptured[borrower] = 0;
        revenueLienBps[borrower] = revenueLienBps_ > MAX_BPS ? MAX_BPS : revenueLienBps_;
        emit LienSet(borrower, target, revenueLienBps[borrower]);
    }

    /// @notice Credit captured revenue toward the lien. Vault-only.
    /// @return capturedActual Amount credited (never beyond the target).
    /// @return cleared True when the lien objective has been reached.
    function recordLienCapture(address borrower, uint256 amount) external onlyVault returns (uint256 capturedActual, bool cleared) {
        uint256 target = lienTarget[borrower];
        uint256 already = lienCaptured[borrower];
        if (already >= target) revert NoActiveLien(borrower);

        uint256 remaining = target - already;
        capturedActual = amount > remaining ? remaining : amount;
        uint256 newCaptured = already + capturedActual;
        lienCaptured[borrower] = newCaptured;

        emit LienCaptured(borrower, capturedActual, newCaptured, target);

        if (newCaptured >= target) {
            // Spec §5.9: clearing the lien resets the capture rate to zero.
            revenueLienBps[borrower] = 0;
            cleared = true;
            emit LienCleared(borrower, newCaptured);
        }
    }

    // ---------------------------------------------------------------------
    // Work attestations (spec §7.6)
    // ---------------------------------------------------------------------

    /// @notice Number of attestations stored for `agent`.
    function attestationCount(address agent) external view returns (uint256) {
        return _attestations[agent].length;
    }

    /// @notice Attestation hash at index `index` for `agent`.
    function attestationAt(address agent, uint256 index) external view returns (bytes32) {
        bytes32[] storage list = _attestations[agent];
        if (index >= list.length) revert NoAttestations(agent);
        return list[index];
    }

    /// @notice Hash of the attestation payload (stored onchain; see `attest`/`attestBySig`).
    function hashAttestation(WorkAttestation calldata attestation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                WORK_ATTESTATION_TYPEHASH,
                attestation.agent,
                attestation.workHash,
                attestation.paymentTxHash,
                attestation.issuedAt,
                attestation.nonce
            )
        );
    }

    /// @notice EIP-712 digest the attester signs.
    function attestationDigest(WorkAttestation calldata attestation) external view returns (bytes32) {
        return _hashTypedDataV4(hashAttestation(attestation));
    }

    /// @notice Current EIP-712 domain separator (name, version, chainId, verifyingContract).
    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Store an attester-signed work attestation without onchain signature recovery.
     * @dev Spec §7.6 permits this for the MVP ("it is acceptable to store the attestation hash
     *      onchain and verify the signature offchain"). Use `attestBySig` when onchain
     *      verification is wanted; the README must not claim verification that is not shipped.
     */
    function attest(WorkAttestation calldata attestation) external onlyAttester returns (bytes32 attestationHash) {
        attestationHash = _storeAttestation(attestation);
        emit WorkAttested(attestation.agent, attestation.workHash, attestationHash, attestation.nonce, false);
    }

    /**
     * @notice Store a work attestation after verifying an EIP-712 signature from the attester.
     * @dev Nonce per agent prevents replay; the signature must recover to the configured attester.
     */
    function attestBySig(WorkAttestation calldata attestation, bytes calldata signature) external returns (bytes32 attestationHash) {
        bytes32 digest = _hashTypedDataV4(hashAttestation(attestation));
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidSigner(address(0), attester);
        if (recovered != attester) revert InvalidSigner(recovered, attester);

        attestationHash = _storeAttestation(attestation);
        emit WorkAttested(attestation.agent, attestation.workHash, attestationHash, attestation.nonce, true);
    }

    function _storeAttestation(WorkAttestation calldata attestation) private returns (bytes32 attestationHash) {
        if (attestation.agent == address(0) || attestation.workHash == bytes32(0) || attestation.issuedAt == 0) {
            revert InvalidAttestation();
        }
        uint256 expected = attestationNonce[attestation.agent];
        if (attestation.nonce != expected) revert InvalidNonce(attestation.nonce, expected);

        attestationNonce[attestation.agent] = expected + 1;
        attestationHash = hashAttestation(attestation);
        _attestations[attestation.agent].push(attestationHash);
    }
}
