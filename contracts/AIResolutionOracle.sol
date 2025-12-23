// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IMarketManager.sol";

contract AIResolutionOracle is AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    IMarketManager public marketManager;

    uint256 public constant MIN_CONFIDENCE = 85;
    uint256 public constant MIN_PROPOSAL_CONFIDENCE = 70;
    uint256 public constant MAX_CONFIDENCE = 100;
    uint256 public constant RESOLUTION_COOLDOWN = 10 minutes;
    uint256 public constant AUTONOMY_THRESHOLD = 950;

    enum ResolutionMethod { WebSearch, PriceFeeds, SportsAPIs, NewsAPIs, Custom, MultiSource }
    enum ProposalStatus { Pending, Verified, Submitted, Accepted, Rejected, Failed }

    struct AIAgent {
        address agentAddress;
        string name;
        string model;
        uint256 registrationTime;
        uint256 totalResolutions;
        uint256 successfulResolutions;
        uint256 disputedResolutions;
        uint256 reputationScore;
        bool isActive;
        bool hasAutonomy;
    }

    struct ResolutionProposal {
        bytes32 id;
        bytes32 marketId;
        address agent;
        uint8 proposedOutcome;
        uint256 confidenceScore;
        uint256 proposalTime;
        ResolutionMethod method;
        string[] dataSources;
        string evidence;
        string reasoning;
        ProposalStatus status;
        address verifiedBy;
        uint256 verificationTime;
    }

    struct DataSource {
        string name;
        string endpoint;
        bool isActive;
        uint256 reliabilityScore;
        uint256 usageCount;
    }

    struct ResolutionAttempt {
        bytes32 marketId;
        address agent;
        uint256 attemptTime;
        bool successful;
        string failureReason;
    }

    mapping(address => AIAgent) public agents;
    address[] public agentList;
    mapping(bytes32 => ResolutionProposal) public proposals;
    mapping(bytes32 => bytes32[]) public marketProposals;
    mapping(bytes32 => uint256) public lastAttemptTime;
    mapping(string => DataSource) public dataSources;
    string[] public dataSourceList;
    uint256 public proposalNonce;
    uint256 public totalResolutions;
    uint256 public successfulResolutions;

    event AIAgentRegistered(address indexed agent, string name, string model, uint256 timestamp);
    event AIAgentDeactivated(address indexed agent, string reason, uint256 timestamp);
    event ResolutionProposed(bytes32 indexed proposalId, bytes32 indexed marketId, address indexed agent, uint8 outcome, uint256 confidence, ResolutionMethod method);
    event ProposalVerified(bytes32 indexed proposalId, address indexed verifier, bool approved, uint256 timestamp);
    event ResolutionSubmitted(bytes32 indexed proposalId, bytes32 indexed marketId, bool accepted, uint256 timestamp);
    event AgentReputationUpdated(address indexed agent, uint256 oldScore, uint256 newScore, string reason);
    event DataSourceAdded(string name, string endpoint, uint256 timestamp);
    event ResolutionFailed(bytes32 indexed marketId, address indexed agent, string reason, uint256 timestamp);
    event AutonomyGranted(address indexed agent, uint256 reputationScore, uint256 timestamp);

    error AgentNotRegistered();
    error AgentAlreadyRegistered();
    error AgentNotActive();
    error InvalidConfidence();
    error ProposalNotFound();
    error ProposalAlreadySubmitted();
    error ResolutionCooldownActive();
    error InsufficientReputation();
    error InvalidMarket();
    error NoDataSources();
    error Unauthorized();

    constructor(address _marketManager, address admin) {
        require(_marketManager != address(0), "Invalid market manager");
        require(admin != address(0), "Invalid admin");

        marketManager = IMarketManager(_marketManager);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_MANAGER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
    }

    function registerAgent(address agent, string calldata name, string calldata model) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (agents[agent].agentAddress != address(0)) revert AgentAlreadyRegistered();

        agents[agent] = AIAgent({
            agentAddress: agent,
            name: name,
            model: model,
            registrationTime: block.timestamp,
            totalResolutions: 0,
            successfulResolutions: 0,
            disputedResolutions: 0,
            reputationScore: 700,
            isActive: true,
            hasAutonomy: false
        });

        agentList.push(agent);

        _grantRole(AI_AGENT_ROLE, agent);

        emit AIAgentRegistered(agent, name, model, block.timestamp);
    }

    function deactivateAgent(address agent, string calldata reason) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (agents[agent].agentAddress == address(0)) revert AgentNotRegistered();

        agents[agent].isActive = false;
        agents[agent].hasAutonomy = false;

        _revokeRole(AI_AGENT_ROLE, agent);

        emit AIAgentDeactivated(agent, reason, block.timestamp);
    }

    function grantAutonomy(address agent) external onlyRole(ORACLE_MANAGER_ROLE) {
        AIAgent storage agentData = agents[agent];

        if (!agentData.isActive) revert AgentNotActive();
        if (agentData.reputationScore < AUTONOMY_THRESHOLD) revert InsufficientReputation();

        agentData.hasAutonomy = true;

        emit AutonomyGranted(agent, agentData.reputationScore, block.timestamp);
    }

    function proposeResolution(
        bytes32 marketId,
        uint8 outcome,
        uint256 confidenceScore,
        ResolutionMethod method,
        string[] calldata dataSource,
        string calldata evidence,
        string calldata reasoning
    ) external onlyRole(AI_AGENT_ROLE) nonReentrant whenNotPaused returns (bytes32) {
        AIAgent storage agent = agents[msg.sender];

        if (!agent.isActive) revert AgentNotActive();
        if (block.timestamp < lastAttemptTime[marketId] + RESOLUTION_COOLDOWN) revert ResolutionCooldownActive();
        if (confidenceScore < MIN_PROPOSAL_CONFIDENCE || confidenceScore > MAX_CONFIDENCE) revert InvalidConfidence();
        if (dataSource.length == 0) revert NoDataSources();

        bytes32 proposalId = keccak256(abi.encodePacked(marketId, msg.sender, outcome, proposalNonce++, block.timestamp));

        proposals[proposalId] = ResolutionProposal({
            id: proposalId,
            marketId: marketId,
            agent: msg.sender,
            proposedOutcome: outcome,
            confidenceScore: confidenceScore,
            proposalTime: block.timestamp,
            method: method,
            dataSources: dataSource,
            evidence: evidence,
            reasoning: reasoning,
            status: ProposalStatus.Pending,
            verifiedBy: address(0),
            verificationTime: 0
        });

        marketProposals[marketId].push(proposalId);
        lastAttemptTime[marketId] = block.timestamp;

        emit ResolutionProposed(proposalId, marketId, msg.sender, outcome, confidenceScore, method);

        if (agent.hasAutonomy && confidenceScore >= MIN_CONFIDENCE) {
            _submitResolution(proposalId);
        }

        return proposalId;
    }

    function verifyProposal(bytes32 proposalId, bool approved) external onlyRole(ORACLE_MANAGER_ROLE) {
        ResolutionProposal storage proposal = proposals[proposalId];

        if (proposal.agent == address(0)) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending) revert ProposalAlreadySubmitted();

        proposal.verifiedBy = msg.sender;
        proposal.verificationTime = block.timestamp;

        if (approved) {
            proposal.status = ProposalStatus.Verified;
            _submitResolution(proposalId);
        } else {
            proposal.status = ProposalStatus.Rejected;
            _updateAgentReputation(proposal.agent, false, "Proposal rejected by verifier");
        }

        emit ProposalVerified(proposalId, msg.sender, approved, block.timestamp);
    }

    function submitResolution(bytes32 proposalId) external onlyRole(ORACLE_MANAGER_ROLE) {
        ResolutionProposal storage proposal = proposals[proposalId];

        if (proposal.status != ProposalStatus.Verified) revert ProposalAlreadySubmitted();

        _submitResolution(proposalId);
    }

    function addDataSource(string calldata name, string calldata endpoint, uint256 reliabilityScore) external onlyRole(ORACLE_MANAGER_ROLE) {
        require(reliabilityScore <= 1000, "Invalid reliability score");

        dataSources[name] = DataSource({
            name: name,
            endpoint: endpoint,
            isActive: true,
            reliabilityScore: reliabilityScore,
            usageCount: 0
        });

        dataSourceList.push(name);

        emit DataSourceAdded(name, endpoint, block.timestamp);
    }

    function updateDataSourceReliability(string calldata name, uint256 newScore) external onlyRole(ORACLE_MANAGER_ROLE) {
        require(newScore <= 1000, "Invalid score");
        dataSources[name].reliabilityScore = newScore;
    }

    function onResolutionAccepted(bytes32 proposalId) external {
        require(msg.sender == address(marketManager), "Only market manager");

        ResolutionProposal storage proposal = proposals[proposalId];
        proposal.status = ProposalStatus.Accepted;

        AIAgent storage agent = agents[proposal.agent];
        agent.totalResolutions++;
        agent.successfulResolutions++;

        totalResolutions++;
        successfulResolutions++;

        _updateAgentReputation(proposal.agent, true, "Resolution accepted");

        emit ResolutionSubmitted(proposalId, proposal.marketId, true, block.timestamp);
    }

    function onResolutionDisputed(bytes32 proposalId) external {
        require(msg.sender == address(marketManager), "Only market manager");

        ResolutionProposal storage proposal = proposals[proposalId];
        AIAgent storage agent = agents[proposal.agent];

        agent.disputedResolutions++;

        _updateAgentReputation(proposal.agent, false, "Resolution disputed");
    }

    function setMarketManager(address _marketManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_marketManager != address(0), "Invalid address");
        marketManager = IMarketManager(_marketManager);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function getAgent(address agent) external view returns (AIAgent memory) {
        return agents[agent];
    }

    function getProposal(bytes32 proposalId) external view returns (ResolutionProposal memory) {
        return proposals[proposalId];
    }

    function getMarketProposals(bytes32 marketId) external view returns (bytes32[] memory) {
        return marketProposals[marketId];
    }

    function getAllAgents() external view returns (address[] memory) {
        return agentList;
    }

    function getDataSource(string calldata name) external view returns (DataSource memory) {
        return dataSources[name];
    }

    function getOracleStats() external view returns (
        uint256 _totalResolutions,
        uint256 _successfulResolutions,
        uint256 _successRate,
        uint256 _activeAgents
    ) {
        _totalResolutions = totalResolutions;
        _successfulResolutions = successfulResolutions;
        _successRate = totalResolutions > 0 ? (successfulResolutions * 100) / totalResolutions : 0;

        uint256 active = 0;
        for (uint256 i = 0; i < agentList.length; i++) {
            if (agents[agentList[i]].isActive) active++;
        }
        _activeAgents = active;
    }

    function _submitResolution(bytes32 proposalId) internal {
        ResolutionProposal storage proposal = proposals[proposalId];

        proposal.status = ProposalStatus.Submitted;

        try marketManager.proposeResolution(
            proposal.marketId,
            proposal.proposedOutcome,
            proposal.confidenceScore,
            proposal.evidence
        ) {
            
        } catch Error(string memory reason) {
            proposal.status = ProposalStatus.Failed;
            emit ResolutionFailed(proposal.marketId, proposal.agent, reason, block.timestamp);
        }
    }

    function _updateAgentReputation(address agent, bool success, string memory reason) internal {
        AIAgent storage agentData = agents[agent];
        uint256 oldScore = agentData.reputationScore;

        if (success) {
            uint256 increase = 10;
            agentData.reputationScore = agentData.reputationScore + increase > 1000 ? 1000 : agentData.reputationScore + increase;
        } else {
            uint256 decrease = 20;
            agentData.reputationScore = agentData.reputationScore > decrease ? agentData.reputationScore - decrease : 0;

            if (agentData.reputationScore < AUTONOMY_THRESHOLD) {
                agentData.hasAutonomy = false;
            }
        }

        emit AgentReputationUpdated(agent, oldScore, agentData.reputationScore, reason);
    }
}