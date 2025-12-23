// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract EmergencyManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EMERGENCY_COUNCIL = keccak256("EMERGENCY_COUNCIL");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    uint256 public constant TIMELOCK_DURATION = 48 hours;
    uint256 public constant MIN_GUARDIANS = 3;
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours;
    uint256 public constant MAX_WITHDRAWAL_PERCENTAGE = 10;

    address public treasury;
    bool public globalEmergency;
    uint256 public emergencyTriggeredAt;

    enum EmergencyType { ContractVulnerability, OracleFailure, MarketManipulation, ExploitDetected, SystemOverload, DataCorruption, GovernanceAttack, Other }
    enum ActionStatus { Proposed, Approved, Timelocked, Executed, Cancelled, Expired }

    struct EmergencyAction {
        bytes32 id;
        EmergencyType emergencyType;
        address proposer;
        uint256 proposalTime;
        uint256 executionTime;
        address targetContract;
        bytes4 functionSelector;
        bytes callData;
        string description;
        ActionStatus status;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }

    struct CircuitBreaker {
        address contractAddress;
        bool isTripped;
        uint256 tripTime;
        uint256 tripCount;
        string reason;
        address trippedBy;
    }

    struct FundRecovery {
        bytes32 id;
        address token;
        address fromContract;
        uint256 amount;
        address recipient;
        string reason;
        uint256 requestTime;
        ActionStatus status;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }

    struct Guardian {
        address guardianAddress;
        string name;
        uint256 addedTime;
        bool isActive;
        uint256 actionsApproved;
        uint256 actionsProposed;
    }

    mapping(bytes32 => EmergencyAction) public emergencyActions;
    bytes32[] public actionList;
    mapping(address => CircuitBreaker) public circuitBreakers;
    mapping(bytes32 => FundRecovery) public fundRecoveries;
    bytes32[] public recoveryList;
    mapping(address => Guardian) public guardians;
    address[] public guardianList;
    uint256 public actionNonce;
    uint256 public recoveryNonce;

    event GlobalEmergencyTriggered(address indexed triggeredBy, string reason, uint256 timestamp);
    event GlobalEmergencyResolved(address indexed resolvedBy, uint256 timestamp);
    event CircuitBreakerTripped(address indexed contractAddress, address indexed trippedBy, string reason, uint256 timestamp);
    event CircuitBreakerReset(address indexed contractAddress, address indexed resetBy, uint256 timestamp);
    event EmergencyActionProposed(bytes32 indexed actionId, EmergencyType emergencyType, address indexed proposer, address targetContract, uint256 timestamp);
    event EmergencyActionApproved(bytes32 indexed actionId, address indexed guardian, uint256 approvalCount, uint256 requiredApprovals);
    event EmergencyActionExecuted(bytes32 indexed actionId, bool success, bytes returnData, uint256 timestamp);
    event EmergencyActionCancelled(bytes32 indexed actionId, address indexed cancelledBy, string reason);
    event FundRecoveryRequested(bytes32 indexed recoveryId, address indexed token, address indexed fromContract, uint256 amount, string reason);
    event FundRecoveryExecuted(bytes32 indexed recoveryId, address token, uint256 amount, address recipient);
    event GuardianAdded(address indexed guardian, string name, uint256 timestamp);
    event GuardianRemoved(address indexed guardian, uint256 timestamp);

    error GlobalEmergencyActive();
    error NotInEmergency();
    error InsufficientGuardians();
    error AlreadyApproved();
    error ActionNotApproved();
    error TimelockNotExpired();
    error ActionAlreadyExecuted();
    error CircuitBreakerActive();
    error InvalidWithdrawalAmount();
    error Unauthorized();
    error InvalidGuardian();

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyCouncil() {
        if (!hasRole(EMERGENCY_COUNCIL, msg.sender)) revert Unauthorized();
        _;
    }

    modifier whenNotEmergency() {
        if (globalEmergency) revert GlobalEmergencyActive();
        _;
    }

    modifier whenEmergency() {
        if (!globalEmergency) revert NotInEmergency();
        _;
    }

    constructor(address _treasury, address[] memory initialGuardians, address admin) {
        require(_treasury != address(0), "Invalid treasury");
        require(initialGuardians.length >= MIN_GUARDIANS, "Insufficient guardians");

        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_COUNCIL, admin);

        for (uint256 i = 0; i < initialGuardians.length; i++) {
            _addGuardian(initialGuardians[i], "Initial Guardian");
        }
    }

    function triggerGlobalEmergency(string calldata reason) external onlyGuardian whenNotEmergency {
        globalEmergency = true;
        emergencyTriggeredAt = block.timestamp;
        emit GlobalEmergencyTriggered(msg.sender, reason, block.timestamp);
    }

    function resolveGlobalEmergency(bytes32 actionId) external onlyGuardian whenEmergency {
        EmergencyAction storage action = emergencyActions[actionId];
        
        if (action.proposer == address(0)) {
            emergencyActions[actionId].id = actionId;
            emergencyActions[actionId].proposer = msg.sender;
            emergencyActions[actionId].proposalTime = block.timestamp;
            emergencyActions[actionId].status = ActionStatus.Proposed;
        }

        if (!action.approvals[msg.sender]) {
            action.approvals[msg.sender] = true;
            action.approvalCount++;

            if (action.approvalCount >= MIN_GUARDIANS) {
                globalEmergency = false;
                action.status = ActionStatus.Executed;
                emit GlobalEmergencyResolved(msg.sender, block.timestamp);
            }
        }
    }

    function tripCircuitBreaker(address contractAddress, string calldata reason) external onlyGuardian {
        CircuitBreaker storage cb = circuitBreakers[contractAddress];

        cb.isTripped = true;
        cb.tripTime = block.timestamp;
        cb.tripCount++;
        cb.reason = reason;
        cb.trippedBy = msg.sender;
        cb.contractAddress = contractAddress;

        emit CircuitBreakerTripped(contractAddress, msg.sender, reason, block.timestamp);
    }

    function resetCircuitBreaker(address contractAddress, bytes32 actionId) external onlyGuardian {
        CircuitBreaker storage cb = circuitBreakers[contractAddress];

        if (!cb.isTripped) return;

        if (block.timestamp < cb.tripTime + CIRCUIT_BREAKER_COOLDOWN) revert CircuitBreakerActive();

        EmergencyAction storage action = emergencyActions[actionId];

        if (action.proposer == address(0)) {
            action.id = actionId;
            action.proposer = msg.sender;
            action.proposalTime = block.timestamp;
            action.targetContract = contractAddress;
            action.status = ActionStatus.Proposed;
        }

        if (!action.approvals[msg.sender]) {
            action.approvals[msg.sender] = true;
            action.approvalCount++;

            if (action.approvalCount >= MIN_GUARDIANS) {
                cb.isTripped = false;
                action.status = ActionStatus.Executed;
                emit CircuitBreakerReset(contractAddress, msg.sender, block.timestamp);
            }
        }
    }

    function proposeEmergencyAction(
        EmergencyType emergencyType,
        address targetContract,
        bytes4 functionSelector,
        bytes calldata callData,
        string calldata description
    ) external onlyGuardian returns (bytes32) {
        bytes32 actionId = keccak256(abi.encodePacked(targetContract, functionSelector, callData, actionNonce++, block.timestamp));

        EmergencyAction storage action = emergencyActions[actionId];
        action.id = actionId;
        action.emergencyType = emergencyType;
        action.proposer = msg.sender;
        action.proposalTime = block.timestamp;
        action.targetContract = targetContract;
        action.functionSelector = functionSelector;
        action.callData = callData;
        action.description = description;
        action.status = ActionStatus.Proposed;
        action.approvalCount = 1;
        action.approvals[msg.sender] = true;

        actionList.push(actionId);

        guardians[msg.sender].actionsProposed++;

        emit EmergencyActionProposed(actionId, emergencyType, msg.sender, targetContract, block.timestamp);

        return actionId;
    }

    function approveEmergencyAction(bytes32 actionId) external onlyGuardian {
        EmergencyAction storage action = emergencyActions[actionId];

        if (action.status != ActionStatus.Proposed) revert ActionAlreadyExecuted();
        if (action.approvals[msg.sender]) revert AlreadyApproved();

        action.approvals[msg.sender] = true;
        action.approvalCount++;

        guardians[msg.sender].actionsApproved++;

        if (action.approvalCount >= MIN_GUARDIANS) {
            action.status = ActionStatus.Timelocked;
            action.executionTime = block.timestamp + TIMELOCK_DURATION;
        }

        emit EmergencyActionApproved(actionId, msg.sender, action.approvalCount, MIN_GUARDIANS);
    }

    function executeEmergencyAction(bytes32 actionId) external onlyGuardian nonReentrant {
        EmergencyAction storage action = emergencyActions[actionId];

        if (action.status != ActionStatus.Timelocked) revert ActionNotApproved();
        if (block.timestamp < action.executionTime) revert TimelockNotExpired();

        action.status = ActionStatus.Executed;

        bytes memory callData = abi.encodePacked(action.functionSelector, action.callData);
        (bool success, bytes memory returnData) = action.targetContract.call(callData);

        emit EmergencyActionExecuted(actionId, success, returnData, block.timestamp);
    }

    function cancelEmergencyAction(bytes32 actionId, string calldata reason) external onlyCouncil {
        EmergencyAction storage action = emergencyActions[actionId];

        if (action.status == ActionStatus.Executed) revert ActionAlreadyExecuted();

        action.status = ActionStatus.Cancelled;

        emit EmergencyActionCancelled(actionId, msg.sender, reason);
    }

    function requestFundRecovery(
        address token,
        address fromContract,
        uint256 amount,
        address recipient,
        string calldata reason
    ) external onlyGuardian returns (bytes32) {
        bytes32 recoveryId = keccak256(abi.encodePacked(token, fromContract, amount, recoveryNonce++, block.timestamp));

        FundRecovery storage recovery = fundRecoveries[recoveryId];
        recovery.id = recoveryId;
        recovery.token = token;
        recovery.fromContract = fromContract;
        recovery.amount = amount;
        recovery.recipient = recipient;
        recovery.reason = reason;
        recovery.requestTime = block.timestamp;
        recovery.status = ActionStatus.Proposed;
        recovery.approvalCount = 1;
        recovery.approvals[msg.sender] = true;

        recoveryList.push(recoveryId);

        emit FundRecoveryRequested(recoveryId, token, fromContract, amount, reason);

        return recoveryId;
    }

    function approveFundRecovery(bytes32 recoveryId) external onlyGuardian {
        FundRecovery storage recovery = fundRecoveries[recoveryId];

        if (recovery.approvals[msg.sender]) revert AlreadyApproved();

        recovery.approvals[msg.sender] = true;
        recovery.approvalCount++;

        if (recovery.approvalCount >= MIN_GUARDIANS) {
            recovery.status = ActionStatus.Approved;
        }
    }

    function executeFundRecovery(bytes32 recoveryId) external onlyGuardian nonReentrant {
        FundRecovery storage recovery = fundRecoveries[recoveryId];

        if (recovery.status != ActionStatus.Approved) revert ActionNotApproved();

        recovery.status = ActionStatus.Executed;

        if (recovery.token == address(0)) {
            (bool success, ) = recovery.recipient.call{value: recovery.amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(recovery.token).safeTransferFrom(recovery.fromContract, recovery.recipient, recovery.amount);
        }

        emit FundRecoveryExecuted(recoveryId, recovery.token, recovery.amount, recovery.recipient);
    }

    function addGuardian(address guardian, string calldata name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addGuardian(guardian, name);
    }

    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!guardians[guardian].isActive) revert InvalidGuardian();
        if (guardianList.length <= MIN_GUARDIANS) revert InsufficientGuardians();

        guardians[guardian].isActive = false;
        _revokeRole(GUARDIAN_ROLE, guardian);

        emit GuardianRemoved(guardian, block.timestamp);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    function isCircuitBreakerTripped(address contractAddress) external view returns (bool) {
        return circuitBreakers[contractAddress].isTripped;
    }

    function getEmergencyAction(bytes32 actionId) external view returns (
        EmergencyType emergencyType,
        address proposer,
        uint256 proposalTime,
        address targetContract,
        string memory description,
        ActionStatus status,
        uint256 approvalCount
    ) {
        EmergencyAction storage action = emergencyActions[actionId];
        return (action.emergencyType, action.proposer, action.proposalTime, action.targetContract, action.description, action.status, action.approvalCount);
    }

    function getFundRecovery(bytes32 recoveryId) external view returns (
        address token,
        address fromContract,
        uint256 amount,
        address recipient,
        string memory reason,
        ActionStatus status,
        uint256 approvalCount
    ) {
        FundRecovery storage recovery = fundRecoveries[recoveryId];
        return (recovery.token, recovery.fromContract, recovery.amount, recovery.recipient, recovery.reason, recovery.status, recovery.approvalCount);
    }

    function getAllGuardians() external view returns (address[] memory) {
        return guardianList;
    }

    function getGuardianCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < guardianList.length; i++) {
            if (guardians[guardianList[i]].isActive) count++;
        }
        return count;
    }

    function _addGuardian(address guardian, string memory name) internal {
        require(guardian != address(0), "Invalid guardian");
        require(!guardians[guardian].isActive, "Already guardian");

        guardians[guardian] = Guardian({
            guardianAddress: guardian,
            name: name,
            addedTime: block.timestamp,
            isActive: true,
            actionsApproved: 0,
            actionsProposed: 0
        });

        guardianList.push(guardian);

        _grantRole(GUARDIAN_ROLE, guardian);

        emit GuardianAdded(guardian, name, block.timestamp);
    }

    receive() external payable {}
}