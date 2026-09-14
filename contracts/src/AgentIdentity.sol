// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AgentIdentity
/// @notice Cross-wallet identity registry: links multiple EOAs to one agentId so
///         scores/history cannot be reset by rotating wallets (sybil mitigation).
/// @dev Planned module from README ("cross-wallet identity"). Attesters link wallets
///      after offchain proof (stake / history / social). Wallets may unlink themselves.
///      TrustPassport.setIdentityRegistry() points at this contract for UI lookups.
contract AgentIdentity is AccessControl {
    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");

    uint256 public nextAgentId = 1;
    mapping(address wallet => uint256) public agentOf; // 0 = unlinked
    mapping(uint256 agentId => address[]) private _wallets;
    mapping(uint256 agentId => address) public primaryOf;

    event AgentCreated(uint256 indexed agentId, address indexed wallet);
    event WalletLinked(uint256 indexed agentId, address indexed wallet, address indexed attester);
    event WalletUnlinked(uint256 indexed agentId, address indexed wallet);

    error AlreadyLinked(address wallet, uint256 agentId);
    error NotLinked(address wallet);
    error NotWalletOwner();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Create a fresh agentId bound to `wallet` (attested linkage).
    function createAgent(address wallet) external onlyRole(ATTESTER_ROLE) returns (uint256 agentId) {
        if (agentOf[wallet] != 0) revert AlreadyLinked(wallet, agentOf[wallet]);
        agentId = nextAgentId++;
        agentOf[wallet] = agentId;
        _wallets[agentId].push(wallet);
        primaryOf[agentId] = wallet;
        emit AgentCreated(agentId, wallet);
        emit WalletLinked(agentId, wallet, msg.sender);
    }

    /// @notice Link an additional wallet to an existing agentId.
    function linkWallet(uint256 agentId, address wallet) external onlyRole(ATTESTER_ROLE) {
        if (agentOf[wallet] != 0) revert AlreadyLinked(wallet, agentOf[wallet]);
        require(agentId != 0 && agentId < nextAgentId, "unknown agent");
        agentOf[wallet] = agentId;
        _wallets[agentId].push(wallet);
        emit WalletLinked(agentId, wallet, msg.sender);
    }

    /// @notice A wallet may unlink itself (fresh start, but loses shared history pointer).
    function unlinkSelf() external {
        uint256 agentId = agentOf[msg.sender];
        if (agentId == 0) revert NotLinked(msg.sender);
        agentOf[msg.sender] = 0;
        address[] storage ws = _wallets[agentId];
        for (uint256 i = 0; i < ws.length; i++) {
            if (ws[i] == msg.sender) {
                ws[i] = ws[ws.length - 1];
                ws.pop();
                break;
            }
        }
        if (primaryOf[agentId] == msg.sender && ws.length > 0) primaryOf[agentId] = ws[0];
        emit WalletUnlinked(agentId, msg.sender);
    }

    function walletsOf(uint256 agentId) external view returns (address[] memory) {
        return _wallets[agentId];
    }

    function walletCount(uint256 agentId) external view returns (uint256) {
        return _wallets[agentId].length;
    }
}
