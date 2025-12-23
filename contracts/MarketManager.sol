// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IPlatformRegistry.sol";

contract MarketManager is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable busd;
    IERC20 public immutable predToken;
    IPlatformRegistry public platformRegistry;

    uint256 public constant MARKET_CREATION_BOND = 500 * 10**18;
    uint256 public constant DISPUTE_BOND = 300 * 10**18;
    uint256 public constant CHALLENGE_PERIOD = 1 hours;
    uint256 public constant DISPUTE_VOTING_PERIOD = 48 hours;
    uint256 public constant MIN_QUALITY_SCORE = 60;
    uint256 public constant HIGH_QUALITY_SCORE = 90;

    address public aiOracle;
    address public emergencyCouncil;
    uint256 public marketNonce;

    enum MarketStatus { Pending, Active, Closed, Resolved, Finalized, Disputed, Invalid, Emergency }
    enum Category { Sports, Crypto, Politics, Entertainment, Finance, Technology, Weather, Other }

    struct Market {
        bytes32 id;
        address creator;
        address platform;
        string title;
        string description;
        string[] outcomes;
        uint256 creationTime;
        uint256 endTime;
        uint256 resolutionTime;
        string resolutionSource;
        string resolutionRules;
        Category category;
        MarketStatus status;
        uint8 resolvedOutcome;
        uint8 qualityScore;
        uint256 totalVolume;
        uint256 totalLiquidity;
        uint256 creatorReward;
        bool bondReturned;
    }

    struct Resolution {
        bytes32 marketId;
        uint8 proposedOutcome;
        address proposer;
        uint256 proposalTime;
        uint256 confidenceScore;
        string evidence;
        bool finalized;
        bool disputed;
    }

    struct Dispute {
        bytes32 marketId;
        address disputer;
        uint256 disputeTime;
        uint256 disputeBond;
        string reason;
        uint8 counterOutcome;
        uint256 votesFor;
        uint256 votesAgainst;
        bool resolved;
        bool disputerWon;
    }

    struct Vote {
        address voter;
        uint256 votePower;
        bool votedFor;
        uint256 voteTime;
    }

    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Resolution) public resolutions;
    mapping(bytes32 => Dispute) public disputes;
    mapping(bytes32 => mapping(address => Vote)) public votes;
    mapping(bytes32 => uint256) public totalVotes;
    mapping(address => uint256) public platformMarketCount;
    mapping(address => bytes32[]) public creatorMarkets;
    mapping(Category => bytes32[]) public categoryMarkets;
    bytes32[] public allMarkets;

    event MarketCreated(bytes32 indexed marketId, address indexed creator, address indexed platform, string title, Category category, uint256 endTime);
    event MarketApproved(bytes32 indexed marketId, uint8 qualityScore, uint256 timestamp);
    event MarketRejected(bytes32 indexed marketId, string reason, uint256 timestamp);
    event MarketClosed(bytes32 indexed marketId, uint256 timestamp);
    event ResolutionProposed(bytes32 indexed marketId, uint8 outcome, address proposer, uint256 confidenceScore, uint256 challengeDeadline);
    event ResolutionFinalized(bytes32 indexed marketId, uint8 outcome, uint256 timestamp);
    event DisputeRaised(bytes32 indexed marketId, address indexed disputer, uint8 counterOutcome, string reason, uint256 votingDeadline);
    event VoteCast(bytes32 indexed marketId, address indexed voter, uint256 votePower, bool votedFor);
    event DisputeResolved(bytes32 indexed marketId, bool disputerWon, uint8 finalOutcome, uint256 timestamp);
    event MarketInvalidated(bytes32 indexed marketId, string reason, uint256 timestamp);
    event EmergencyShutdown(bytes32 indexed marketId, address indexed initiator, string reason);
    event CreatorRewardPaid(bytes32 indexed marketId, address indexed creator, uint256 amount);
    event AIResolutionAttempt(bytes32 indexed marketId, uint8 outcome, uint256 confidence, bool accepted);

    error InvalidPlatform();
    error PlatformNotActive();
    error InvalidTitle();
    error InvalidOutcomes();
    error InvalidEndTime();
    error MarketNotFound();
    error MarketNotActive();
    error MarketNotClosed();
    error MarketAlreadyResolved();
    error InsufficientConfidence();
    error NotInChallengeP();
    error AlreadyDisputed();
    error DisputePeriodEnded();
    error AlreadyVoted();
    error NoVotingPower();
    error NotInDisputePeriod();
    error Unauthorized();
    error InvalidQualityScore();
    error BondAlreadyReturned();

    modifier onlyAIOracle() {
        if (msg.sender != aiOracle) revert Unauthorized();
        _;
    }

    modifier onlyEmergencyCouncil() {
        if (msg.sender != emergencyCouncil) revert Unauthorized();
        _;
    }

    modifier marketExists(bytes32 marketId) {
        if (markets[marketId].creator == address(0)) revert MarketNotFound();
        _;
    }

    constructor(
        address _busd,
        address _predToken,
        address _platformRegistry,
        address _aiOracle,
        address _emergencyCouncil,
        address initialOwner
    ) Ownable(initialOwner) {
        require(_busd != address(0), "Invalid BUSD");
        require(_predToken != address(0), "Invalid PRED");
        require(_platformRegistry != address(0), "Invalid registry");
        require(_aiOracle != address(0), "Invalid oracle");
        require(_emergencyCouncil != address(0), "Invalid council");

        busd = IERC20(_busd);
        predToken = IERC20(_predToken);
        platformRegistry = IPlatformRegistry(_platformRegistry);
        aiOracle = _aiOracle;
        emergencyCouncil = _emergencyCouncil;
    }

    function createMarket(
        address platform,
        string calldata title,
        string calldata description,
        string[] calldata outcomes,
        uint256 endTime,
        string calldata resolutionSource,
        string calldata resolutionRules,
        Category category
    ) external nonReentrant whenNotPaused returns (bytes32) {
        if (!platformRegistry.isActivePlatform(platform)) revert InvalidPlatform();
        if (bytes(title).length == 0 || bytes(title).length > 200) revert InvalidTitle();
        if (outcomes.length < 2 || outcomes.length > 10) revert InvalidOutcomes();
        if (endTime <= block.timestamp + 1 hours) revert InvalidEndTime();

        busd.safeTransferFrom(msg.sender, address(this), MARKET_CREATION_BOND);

        bytes32 marketId = keccak256(abi.encodePacked(msg.sender, platform, title, marketNonce++, block.timestamp));

        markets[marketId] = Market({
            id: marketId,
            creator: msg.sender,
            platform: platform,
            title: title,
            description: description,
            outcomes: outcomes,
            creationTime: block.timestamp,
            endTime: endTime,
            resolutionTime: 0,
            resolutionSource: resolutionSource,
            resolutionRules: resolutionRules,
            category: category,
            status: MarketStatus.Pending,
            resolvedOutcome: 0,
            qualityScore: 0,
            totalVolume: 0,
            totalLiquidity: 0,
            creatorReward: 0,
            bondReturned: false
        });

        allMarkets.push(marketId);
        creatorMarkets[msg.sender].push(marketId);
        categoryMarkets[category].push(marketId);
        platformMarketCount[platform]++;

        emit MarketCreated(marketId, msg.sender, platform, title, category, endTime);

        return marketId;
    }

    function moderateMarket(
        bytes32 marketId,
        uint8 qualityScore,
        bool approved,
        string calldata reason
    ) external onlyAIOracle marketExists(marketId) {
        Market storage market = markets[marketId];

        if (market.status != MarketStatus.Pending) revert MarketNotActive();
        if (qualityScore > 100) revert InvalidQualityScore();

        if (approved && qualityScore >= MIN_QUALITY_SCORE) {
            market.status = MarketStatus.Active;
            market.qualityScore = qualityScore;
            emit MarketApproved(marketId, qualityScore, block.timestamp);
        } else {
            market.status = MarketStatus.Invalid;
            market.qualityScore = qualityScore;

            if (qualityScore < 40) {
                uint256 returnAmount = MARKET_CREATION_BOND / 2;
                busd.safeTransfer(market.creator, returnAmount);
                market.bondReturned = true;
            } else {
                busd.safeTransfer(market.creator, MARKET_CREATION_BOND);
                market.bondReturned = true;
            }

            emit MarketRejected(marketId, reason, block.timestamp);
        }
    }

    function closeMarket(bytes32 marketId) external marketExists(marketId) {
        Market storage market = markets[marketId];

        if (market.status != MarketStatus.Active) revert MarketNotActive();

        bool authorized = msg.sender == market.creator ||
                         msg.sender == market.platform ||
                         msg.sender == owner() ||
                         block.timestamp >= market.endTime;

        if (!authorized) revert Unauthorized();

        market.status = MarketStatus.Closed;

        emit MarketClosed(marketId, block.timestamp);
    }

    function proposeResolution(
        bytes32 marketId,
        uint8 outcome,
        uint256 confidenceScore,
        string calldata evidence
    ) external marketExists(marketId) {
        Market storage market = markets[marketId];

        if (market.status != MarketStatus.Closed) revert MarketNotClosed();

        bool authorized = msg.sender == aiOracle || msg.sender == market.creator;
        if (!authorized) revert Unauthorized();

        if (outcome >= market.outcomes.length) revert InvalidOutcomes();

        if (msg.sender == aiOracle && confidenceScore < 85) {
            emit AIResolutionAttempt(marketId, outcome, confidenceScore, false);
            revert InsufficientConfidence();
        }

        resolutions[marketId] = Resolution({
            marketId: marketId,
            proposedOutcome: outcome,
            proposer: msg.sender,
            proposalTime: block.timestamp,
            confidenceScore: confidenceScore,
            evidence: evidence,
            finalized: false,
            disputed: false
        });

        market.status = MarketStatus.Resolved;
        market.resolvedOutcome = outcome;
        market.resolutionTime = block.timestamp;

        emit ResolutionProposed(marketId, outcome, msg.sender, confidenceScore, block.timestamp + CHALLENGE_PERIOD);

        if (msg.sender == aiOracle) {
            emit AIResolutionAttempt(marketId, outcome, confidenceScore, true);
        }
    }

    function finalizeResolution(bytes32 marketId) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        Resolution storage resolution = resolutions[marketId];

        if (market.status != MarketStatus.Resolved) revert MarketNotClosed();
        if (resolution.disputed) revert AlreadyDisputed();
        if (block.timestamp < resolution.proposalTime + CHALLENGE_PERIOD) revert NotInChallengeP();

        resolution.finalized = true;
        market.status = MarketStatus.Finalized;

        if (!market.bondReturned) {
            _returnBondAndReward(marketId);
        }

        emit ResolutionFinalized(marketId, market.resolvedOutcome, block.timestamp);
    }

    function raiseDispute(
        bytes32 marketId,
        uint8 counterOutcome,
        string calldata reason
    ) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        Resolution storage resolution = resolutions[marketId];

        if (market.status != MarketStatus.Resolved) revert MarketNotClosed();
        if (resolution.finalized) revert MarketAlreadyResolved();
        if (resolution.disputed) revert AlreadyDisputed();
        if (block.timestamp >= resolution.proposalTime + CHALLENGE_PERIOD) revert NotInChallengeP();
        if (counterOutcome >= market.outcomes.length) revert InvalidOutcomes();

        busd.safeTransferFrom(msg.sender, address(this), DISPUTE_BOND);

        disputes[marketId] = Dispute({
            marketId: marketId,
            disputer: msg.sender,
            disputeTime: block.timestamp,
            disputeBond: DISPUTE_BOND,
            reason: reason,
            counterOutcome: counterOutcome,
            votesFor: 0,
            votesAgainst: 0,
            resolved: false,
            disputerWon: false
        });

        resolution.disputed = true;
        market.status = MarketStatus.Disputed;

        emit DisputeRaised(marketId, msg.sender, counterOutcome, reason, block.timestamp + DISPUTE_VOTING_PERIOD);
    }

    function voteOnDispute(
        bytes32 marketId,
        bool voteFor,
        uint256 votePower
    ) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        Dispute storage dispute = disputes[marketId];

        if (market.status != MarketStatus.Disputed) revert NotInDisputePeriod();
        if (dispute.resolved) revert MarketAlreadyResolved();
        if (block.timestamp >= dispute.disputeTime + DISPUTE_VOTING_PERIOD) revert DisputePeriodEnded();
        if (votes[marketId][msg.sender].voter != address(0)) revert AlreadyVoted();
        if (votePower == 0) revert NoVotingPower();

        predToken.safeTransferFrom(msg.sender, address(this), votePower);

        votes[marketId][msg.sender] = Vote({
            voter: msg.sender,
            votePower: votePower,
            votedFor: voteFor,
            voteTime: block.timestamp
        });

        if (voteFor) {
            dispute.votesFor += votePower;
        } else {
            dispute.votesAgainst += votePower;
        }

        totalVotes[marketId] += votePower;

        emit VoteCast(marketId, msg.sender, votePower, voteFor);
    }

    function resolveDispute(bytes32 marketId) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        Dispute storage dispute = disputes[marketId];
        Resolution storage resolution = resolutions[marketId];

        if (market.status != MarketStatus.Disputed) revert NotInDisputePeriod();
        if (dispute.resolved) revert MarketAlreadyResolved();
        if (block.timestamp < dispute.disputeTime + DISPUTE_VOTING_PERIOD) revert NotInDisputePeriod();

        dispute.resolved = true;

        if (dispute.votesFor > dispute.votesAgainst) {
            dispute.disputerWon = true;
            market.resolvedOutcome = dispute.counterOutcome;
            resolution.proposedOutcome = dispute.counterOutcome;

            uint256 reward = DISPUTE_BOND + (DISPUTE_BOND / 2);
            busd.safeTransfer(dispute.disputer, reward);
        } else {
            dispute.disputerWon = false;
        }

        market.status = MarketStatus.Finalized;
        resolution.finalized = true;

        if (!market.bondReturned) {
            _returnBondAndReward(marketId);
        }

        emit DisputeResolved(marketId, dispute.disputerWon, market.resolvedOutcome, block.timestamp);
    }

    function claimVotingReward(bytes32 marketId) external nonReentrant marketExists(marketId) {
        Dispute storage dispute = disputes[marketId];
        Vote storage vote = votes[marketId][msg.sender];

        if (!dispute.resolved) revert NotInDisputePeriod();
        if (vote.voter == address(0)) revert NoVotingPower();

        bool voterWon = (dispute.disputerWon && vote.votedFor) || (!dispute.disputerWon && !vote.votedFor);

        predToken.safeTransfer(msg.sender, vote.votePower);

        if (voterWon) {
            uint256 winningVotes = dispute.disputerWon ? dispute.votesFor : dispute.votesAgainst;
            uint256 rewardPool = DISPUTE_BOND / 2;
            uint256 reward = (rewardPool * vote.votePower) / winningVotes;

            busd.safeTransfer(msg.sender, reward);
        }

        delete votes[marketId][msg.sender];
    }

    function emergencyShutdown(bytes32 marketId, string calldata reason) external onlyEmergencyCouncil marketExists(marketId) {
        Market storage market = markets[marketId];
        market.status = MarketStatus.Emergency;
        emit EmergencyShutdown(marketId, msg.sender, reason);
    }

    function invalidateMarket(bytes32 marketId, string calldata reason) external marketExists(marketId) {
        Market storage market = markets[marketId];

        if (msg.sender != owner() && msg.sender != emergencyCouncil) revert Unauthorized();

        market.status = MarketStatus.Invalid;

        if (!market.bondReturned) {
            busd.safeTransfer(market.creator, MARKET_CREATION_BOND);
            market.bondReturned = true;
        }

        emit MarketInvalidated(marketId, reason, block.timestamp);
    }

    function setAIOracle(address _aiOracle) external onlyOwner {
        require(_aiOracle != address(0), "Invalid address");
        aiOracle = _aiOracle;
    }

    function setEmergencyCouncil(address _emergencyCouncil) external onlyOwner {
        require(_emergencyCouncil != address(0), "Invalid address");
        emergencyCouncil = _emergencyCouncil;
    }

    function setPlatformRegistry(address _platformRegistry) external onlyOwner {
        require(_platformRegistry != address(0), "Invalid address");
        platformRegistry = IPlatformRegistry(_platformRegistry);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyOwner whenPaused {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(recipient, amount);
    }

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getResolution(bytes32 marketId) external view returns (Resolution memory) {
        return resolutions[marketId];
    }

    function getDispute(bytes32 marketId) external view returns (Dispute memory) {
        return disputes[marketId];
    }

    function getAllMarkets() external view returns (bytes32[] memory) {
        return allMarkets;
    }

    function getCreatorMarkets(address creator) external view returns (bytes32[] memory) {
        return creatorMarkets[creator];
    }

    function getCategoryMarkets(Category category) external view returns (bytes32[] memory) {
        return categoryMarkets[category];
    }

    function getPlatformMarketCount(address platform) external view returns (uint256) {
        return platformMarketCount[platform];
    }

    function _returnBondAndReward(bytes32 marketId) internal {
        Market storage market = markets[marketId];

        uint256 reward = _calculateCreatorReward(marketId);

        uint256 totalPayout = MARKET_CREATION_BOND + reward;
        busd.safeTransfer(market.creator, totalPayout);

        market.bondReturned = true;
        market.creatorReward = reward;

        emit CreatorRewardPaid(marketId, market.creator, reward);
    }

    function _calculateCreatorReward(bytes32 marketId) internal view returns (uint256) {
        Market storage market = markets[marketId];

        uint256 liquidityReward = (market.totalLiquidity * 1) / 1000;
        uint256 volumeReward = (market.totalVolume * 5) / 10000;

        uint256 durationDays = (market.resolutionTime - market.creationTime) / 1 days;
        if (durationDays > 30) durationDays = 30;
        uint256 durationBonus = durationDays * 10 * 10**18;

        uint256 baseReward = liquidityReward + volumeReward + durationBonus;

        uint256 qualityMultiplier = market.qualityScore >= HIGH_QUALITY_SCORE ? 2 : 1;

        return baseReward * qualityMultiplier;
    }
}