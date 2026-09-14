// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CreditAdmin
/// @notice Production admin upgrade from single-EOA Ownable: M-of-N multisig with
///         timelock delay for sensitive vault calls (setRouter/setOperator/setRisk/pause).
/// @dev Holds no funds. Transfer vault/registry/passport/router ownership to this
///      contract, then execute admin actions via propose -> approve (threshold) -> execute
///      after delay. Threshold 1 + delay 0 reproduces MVP single-owner behavior for tests.
contract CreditAdmin {
    struct Action {
        address target;
        bytes data;
        uint64 eta;
        uint256 approvals;
        bool executed;
    }

    address[] public owners;
    uint256 public threshold;
    uint256 public delay; // timelock seconds
    uint256 public nextActionId = 1;
    mapping(uint256 => Action) public actions;
    mapping(uint256 => mapping(address => bool)) public approvedBy;

    event ActionProposed(uint256 indexed id, address indexed target, uint64 eta);
    event ActionApproved(uint256 indexed id, address indexed owner, uint256 approvals);
    event ActionExecuted(uint256 indexed id, address indexed target, bytes result);
    event ConfigSet(uint256 threshold, uint256 delay);

    error NotOwner();
    error AlreadyApproved();
    error NotEnoughApprovals(uint256 have, uint256 need);
    error Timelocked(uint64 eta);
    error AlreadyExecuted();
    error BadConfig();
    error CallFailed(bytes reason);

    modifier onlyOwner() {
        bool ok;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == msg.sender) {
                ok = true;
                break;
            }
        }
        if (!ok) revert NotOwner();
        _;
    }

    constructor(address[] memory owners_, uint256 threshold_, uint256 delay_) {
        if (owners_.length == 0 || threshold_ == 0 || threshold_ > owners_.length) revert BadConfig();
        owners = owners_;
        threshold = threshold_;
        delay = delay_;
    }

    function setConfig(uint256 threshold_, uint256 delay_) external onlyOwner {
        if (threshold_ == 0 || threshold_ > owners.length) revert BadConfig();
        threshold = threshold_;
        delay = delay_;
        emit ConfigSet(threshold_, delay_);
    }

    function propose(address target, bytes calldata data) external onlyOwner returns (uint256 id) {
        id = nextActionId++;
        uint64 eta = uint64(block.timestamp + delay);
        actions[id] = Action({target: target, data: data, eta: eta, approvals: 0, executed: false});
        emit ActionProposed(id, target, eta);
        _approve(id); // proposer auto-approves
    }

    function approve(uint256 id) external onlyOwner {
        _approve(id);
    }

    function _approve(uint256 id) internal {
        Action storage a = actions[id];
        if (a.executed) revert AlreadyExecuted();
        if (approvedBy[id][msg.sender]) revert AlreadyApproved();
        approvedBy[id][msg.sender] = true;
        a.approvals += 1;
        emit ActionApproved(id, msg.sender, a.approvals);
    }

    function execute(uint256 id) external onlyOwner returns (bytes memory result) {
        Action storage a = actions[id];
        if (a.executed) revert AlreadyExecuted();
        if (a.approvals < threshold) revert NotEnoughApprovals(a.approvals, threshold);
        if (block.timestamp < a.eta) revert Timelocked(a.eta);
        a.executed = true;
        (bool ok, bytes memory ret) = a.target.call(a.data);
        if (!ok) revert CallFailed(ret);
        emit ActionExecuted(id, a.target, ret);
        return ret;
    }
}
