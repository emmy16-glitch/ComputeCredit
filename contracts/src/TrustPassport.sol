// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TrustPassport
/// @notice Minimal wallet-linked reputation registry: score 0..1000 + attestation hashes.
/// @dev v3 improvements over v2.1:
///  - score mutation restricted to VAULT_ROLE (no arbitrary attester writes post-seed)
///  - seeding is one-time, clamped, labelled bootstrap (no silent re-seed)
///  - default penalty is a calibrated slash (-300, floor 0), NOT full wipe to 0,
///    so honest-but-illiquid agents can rehabilitate; repeated defaults still sink.
///  - lien accounting moved OUT to the vault (passport stores no money logic).
///  - NOT sybil resistant — documented limitation.
contract TrustPassport is AccessControl {
    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    uint256 public constant MAX_SCORE = 1_000;
    uint256 public constant SETTLE_BUMP = 50;
    uint256 public constant DEFAULT_SLASH = 300;
    uint256 public constant BOOTSTRAP_SCORE = 300;

    mapping(address agent => uint256) public score;
    mapping(address agent => bool) public seeded;
    mapping(address agent => bytes32[]) private _attestations;
    mapping(address agent => uint256) public settledCount;
    mapping(address agent => uint256) public defaultCount;

    event ScoreSeeded(address indexed agent, uint256 score, string reason);
    event ScoreUpdated(address indexed agent, uint256 oldScore, uint256 newScore, string reason);
    event AttestationRecorded(address indexed agent, bytes32 indexed workHash, address indexed attester);

    error AlreadySeeded(address agent);
    error ScoreOutOfRange(uint256 score);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---- admin wiring ----

    function grantVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(VAULT_ROLE, vault);
    }

    // ---- seeding (hackathon bootstrap) ----

    /// @notice One-time bootstrap score. Must be labelled as trusted bootstrap in UI.
    function seedScore(address agent, uint256 initialScore, string calldata reason) external onlyRole(ATTESTER_ROLE) {
        if (seeded[agent]) revert AlreadySeeded(agent);
        if (initialScore > MAX_SCORE) revert ScoreOutOfRange(initialScore);
        seeded[agent] = true;
        score[agent] = initialScore;
        emit ScoreSeeded(agent, initialScore, reason);
    }

    /// @notice Convenience default bootstrap (300) when no history exists.
    function seedDefault(address agent) external onlyRole(ATTESTER_ROLE) {
        if (seeded[agent]) revert AlreadySeeded(agent);
        seeded[agent] = true;
        score[agent] = BOOTSTRAP_SCORE;
        emit ScoreSeeded(agent, BOOTSTRAP_SCORE, "bootstrap: no history");
    }

    // ---- vault-only mutations ----

    function notifySettled(address agent) external onlyRole(VAULT_ROLE) {
        uint256 old = score[agent];
        uint256 updated = old + SETTLE_BUMP > MAX_SCORE ? MAX_SCORE : old + SETTLE_BUMP;
        score[agent] = updated;
        settledCount[agent] += 1;
        emit ScoreUpdated(agent, old, updated, "on-time settlement");
    }

    function notifyDefaulted(address agent) external onlyRole(VAULT_ROLE) {
        uint256 old = score[agent];
        uint256 updated = old > DEFAULT_SLASH ? old - DEFAULT_SLASH : 0;
        score[agent] = updated;
        defaultCount[agent] += 1;
        emit ScoreUpdated(agent, old, updated, "default slash -300");
    }

    // ---- attestations (hash onchain, signature verified offchain for MVP) ----

    function recordAttestation(address agent, bytes32 workHash) external onlyRole(ATTESTER_ROLE) {
        _attestations[agent].push(workHash);
        emit AttestationRecorded(agent, workHash, msg.sender);
    }

    function attestations(address agent) external view returns (bytes32[] memory) {
        return _attestations[agent];
    }

    function attestationCount(address agent) external view returns (uint256) {
        return _attestations[agent].length;
    }

    // ---- underwriting tiers (pure, shared by vault + UI) ----

    /// @notice Max advance (USDC base units, 6 decimals) for a score.
    /// @dev Tier caps are deliberately small: one job only, never a credit line.
    function maxAdvanceForScore(uint256 s) public pure returns (uint256) {
        if (s <= 200) return 1_000_000; // 1 USDC
        if (s <= 500) return 5_000_000; // 5 USDC
        if (s <= 800) return 10_000_000; // 10 USDC
        return 20_000_000; // 20 USDC
    }

    function tierOf(uint256 s) public pure returns (string memory) {
        if (s <= 200) return "new";
        if (s <= 500) return "emerging";
        if (s <= 800) return "established";
        return "strong";
    }
}
