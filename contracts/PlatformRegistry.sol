// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract PlatformRegistry is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable predToken;
    IERC20 public immutable busdToken;

    uint256 public constant REQUIRED_STAKE = 1_000_000 * 10**18;
    uint256 public constant POST_HALT_LOCK = 30 days;
    uint256 public constant REDEMPTION_QUEUE = 7 days;
    uint256 public constant MAX_FEE_BPS = 200;
    uint256 public constant BASIS_POINTS = 10000;

    address public slashingAuthority;
    address public treasury;

    enum PlatformState { Inactive, Active, MarketHalted, UnstakeRequested, Slashed, Withdrawn }

    struct Platform {
        address platformAddress;
        string name;
        uint256 stakedAmount;
        uint256 feePercentage;
        uint256 stakingTime;
        uint256 totalVolume;
        uint256 collectedFees;
        PlatformState state;
        uint256 haltTime;
        uint256 unstakeRequestTime;
        uint256 activeMarketCount;
        bool hasSlashableOffense;
    }

    struct SlashingRecord {
        bytes32 id;
        address platform;
        uint256 slashAmount;
        string reason;
        uint256 slashTime;
        address slashedBy;
        bool executed;
    }

    mapping(address => Platform) public platforms;
    address[] public platformList;
    mapping(address => uint256) private platformListIndex;
    mapping(bytes32 => SlashingRecord) public slashingRecords;
    mapping(address => bytes32[]) public platformSlashings;
    uint256 public slashingNonce;

    event PlatformRegistered(address indexed platform, string name, uint256 feePercentage, uint256 stakedAmount, uint256 timestamp);
    event PlatformStateChanged(address indexed platform, PlatformState oldState, PlatformState newState, uint256 timestamp);
    event MarketsHalted(address indexed platform, uint256 activeMarketCount, uint256 haltTime, uint256 unlockTime);
    event UnstakeRequested(address indexed platform, uint256 requestTime, uint256 withdrawalTime);
    event StakeWithdrawn(address indexed platform, uint256 amount, uint256 timestamp);
    event PlatformSlashed(bytes32 indexed slashingId, address indexed platform, uint256 slashAmount, string reason, uint256 timestamp);
    event SlashingProposed(bytes32 indexed slashingId, address indexed platform, uint256 proposedAmount, string reason);
    event FeeUpdated(address indexed platform, uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed platform, uint256 amount, uint256 timestamp);
    event VolumeRecorded(address indexed platform, uint256 volume, uint256 totalVolume);
    event FeesAdded(address indexed platform, uint256 amount, uint256 totalFees);
    event MarketCountUpdated(address indexed platform, uint256 newCount);

    error PlatformAlreadyRegistered();
    error PlatformNotActive();
    error PlatformNotOperational();
    error InvalidName();
    error FeeTooHigh();
    error MarketsStillActive();
    error PostHaltLockNotFinished();
    error RedemptionQueueNotFinished();
    error NoUnstakeRequest();
    error InvalidPlatform();
    error NoFeesToWithdraw();
    error Unauthorized();
    error InvalidSlashAmount();
    error AlreadySlashed();
    error StakeInsufficient();

    modifier onlySlashingAuthority() {
        if (msg.sender != slashingAuthority && msg.sender != owner()) revert Unauthorized();
        _;
    }

    modifier onlyActivePlatform() {
        if (platforms[msg.sender].state != PlatformState.Active) revert PlatformNotActive();
        _;
    }

    constructor(address _predToken, address _busdToken, address _slashingAuthority, address _treasury, address initialOwner) Ownable(initialOwner) {
        require(_predToken != address(0), "Invalid PRED token");
        require(_busdToken != address(0), "Invalid BUSD token");
        require(_slashingAuthority != address(0), "Invalid slashing authority");
        require(_treasury != address(0), "Invalid treasury");

        predToken = IERC20(_predToken);
        busdToken = IERC20(_busdToken);
        slashingAuthority = _slashingAuthority;
        treasury = _treasury;
    }

    function registerPlatform(string calldata name, uint256 feePercentage) external nonReentrant whenNotPaused {
        if (platforms[msg.sender].state != PlatformState.Inactive) revert PlatformAlreadyRegistered();
        if (feePercentage > MAX_FEE_BPS) revert FeeTooHigh();
        if (bytes(name).length == 0 || bytes(name).length > 100) revert InvalidName();

        predToken.safeTransferFrom(msg.sender, address(this), REQUIRED_STAKE);

        platforms[msg.sender] = Platform({
            platformAddress: msg.sender,
            name: name,
            stakedAmount: REQUIRED_STAKE,
            feePercentage: feePercentage,
            stakingTime: block.timestamp,
            totalVolume: 0,
            collectedFees: 0,
            state: PlatformState.Active,
            haltTime: 0,
            unstakeRequestTime: 0,
            activeMarketCount: 0,
            hasSlashableOffense: false
        });

        platformListIndex[msg.sender] = platformList.length;
        platformList.push(msg.sender);

        emit PlatformRegistered(msg.sender, name, feePercentage, REQUIRED_STAKE, block.timestamp);
    }

    function haltMarkets() external nonReentrant {
        Platform storage platform = platforms[msg.sender];
        if (platform.state != PlatformState.Active) revert PlatformNotActive();
        if (platform.activeMarketCount > 0) revert MarketsStillActive();

        PlatformState oldState = platform.state;
        platform.state = PlatformState.MarketHalted;
        platform.haltTime = block.timestamp;

        emit PlatformStateChanged(msg.sender, oldState, PlatformState.MarketHalted, block.timestamp);
        emit MarketsHalted(msg.sender, platform.activeMarketCount, block.timestamp, block.timestamp + POST_HALT_LOCK);
    }

    function requestUnstake() external nonReentrant {
        Platform storage platform = platforms[msg.sender];
        if (platform.state != PlatformState.MarketHalted) revert PlatformNotOperational();
        if (block.timestamp < platform.haltTime + POST_HALT_LOCK) revert PostHaltLockNotFinished();

        PlatformState oldState = platform.state;
        platform.state = PlatformState.UnstakeRequested;
        platform.unstakeRequestTime = block.timestamp;

        emit PlatformStateChanged(msg.sender, oldState, PlatformState.UnstakeRequested, block.timestamp);
        emit UnstakeRequested(msg.sender, block.timestamp, block.timestamp + REDEMPTION_QUEUE);
    }

    function executeWithdrawal() external nonReentrant {
        Platform storage platform = platforms[msg.sender];
        if (platform.state != PlatformState.UnstakeRequested) revert NoUnstakeRequest();
        if (block.timestamp < platform.unstakeRequestTime + REDEMPTION_QUEUE) revert RedemptionQueueNotFinished();
        if (platform.hasSlashableOffense) revert AlreadySlashed();

        uint256 withdrawAmount = platform.stakedAmount;

        PlatformState oldState = platform.state;
        platform.state = PlatformState.Withdrawn;
        platform.stakedAmount = 0;

        predToken.safeTransfer(msg.sender, withdrawAmount);
        _removePlatformFromList(msg.sender);

        emit PlatformStateChanged(msg.sender, oldState, PlatformState.Withdrawn, block.timestamp);
        emit StakeWithdrawn(msg.sender, withdrawAmount, block.timestamp);
    }

    function cancelUnstakeRequest() external {
        Platform storage platform = platforms[msg.sender];
        if (platform.state != PlatformState.UnstakeRequested) revert NoUnstakeRequest();

        if (platform.activeMarketCount == 0) {
            PlatformState oldState = platform.state;
            platform.state = PlatformState.MarketHalted;
            platform.unstakeRequestTime = 0;

            emit PlatformStateChanged(msg.sender, oldState, PlatformState.MarketHalted, block.timestamp);
        }
    }

    function proposeSlashing(address platform, uint256 slashAmount, string calldata reason) external onlySlashingAuthority returns (bytes32) {
        Platform storage plat = platforms[platform];
        if (plat.state == PlatformState.Inactive || plat.state == PlatformState.Withdrawn) revert InvalidPlatform();
        if (slashAmount == 0 || slashAmount > plat.stakedAmount) revert InvalidSlashAmount();

        bytes32 slashingId = keccak256(abi.encodePacked(platform, slashAmount, reason, slashingNonce++, block.timestamp));

        slashingRecords[slashingId] = SlashingRecord({
            id: slashingId,
            platform: platform,
            slashAmount: slashAmount,
            reason: reason,
            slashTime: block.timestamp,
            slashedBy: msg.sender,
            executed: false
        });

        platformSlashings[platform].push(slashingId);
        plat.hasSlashableOffense = true;

        emit SlashingProposed(slashingId, platform, slashAmount, reason);
        return slashingId;
    }

    function executeSlashing(bytes32 slashingId) external onlySlashingAuthority nonReentrant {
        SlashingRecord storage record = slashingRecords[slashingId];
        if (record.executed) revert AlreadySlashed();

        Platform storage platform = platforms[record.platform];
        if (record.slashAmount > platform.stakedAmount) revert StakeInsufficient();

        record.executed = true;
        platform.stakedAmount -= record.slashAmount;

        predToken.safeTransfer(treasury, record.slashAmount);

        if (platform.stakedAmount == 0) {
            PlatformState oldState = platform.state;
            platform.state = PlatformState.Slashed;
            emit PlatformStateChanged(record.platform, oldState, PlatformState.Slashed, block.timestamp);
        }

        emit PlatformSlashed(slashingId, record.platform, record.slashAmount, record.reason, block.timestamp);
    }

    function updateFee(uint256 newFeePercentage) external onlyActivePlatform {
        if (newFeePercentage > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 oldFee = platforms[msg.sender].feePercentage;
        platforms[msg.sender].feePercentage = newFeePercentage;
        emit FeeUpdated(msg.sender, oldFee, newFeePercentage);
    }

    function withdrawFees() external nonReentrant {
        Platform storage platform = platforms[msg.sender];
        if (platform.state == PlatformState.Inactive) revert InvalidPlatform();

        uint256 fees = platform.collectedFees;
        if (fees == 0) revert NoFeesToWithdraw();

        platform.collectedFees = 0;
        busdToken.safeTransfer(msg.sender, fees);

        emit FeesWithdrawn(msg.sender, fees, block.timestamp);
    }

    function recordVolume(address platform, uint256 volume) external {
        Platform storage plat = platforms[platform];
        if (plat.state != PlatformState.Active) revert InvalidPlatform();
        plat.totalVolume += volume;
        emit VolumeRecorded(platform, volume, plat.totalVolume);
    }

    function addCollectedFees(address platform, uint256 fees) external {
        Platform storage plat = platforms[platform];
        if (plat.state != PlatformState.Active) revert InvalidPlatform();
        plat.collectedFees += fees;
        emit FeesAdded(platform, fees, plat.collectedFees);
    }

    function updateMarketCount(address platform, bool increment) external {
        Platform storage plat = platforms[platform];
        if (increment) {
            plat.activeMarketCount++;
        } else {
            if (plat.activeMarketCount > 0) plat.activeMarketCount--;
        }
        emit MarketCountUpdated(platform, plat.activeMarketCount);
    }

    function setSlashingAuthority(address _slashingAuthority) external onlyOwner {
        require(_slashingAuthority != address(0), "Invalid address");
        slashingAuthority = _slashingAuthority;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
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

    function isActivePlatform(address platform) external view returns (bool) {
        return platforms[platform].state == PlatformState.Active;
    }

    function getPlatformFee(address platform) external view returns (uint256) {
        return platforms[platform].feePercentage;
    }

    function getPlatform(address platform) external view returns (Platform memory) {
        return platforms[platform];
    }

    function getAllPlatforms() external view returns (address[] memory) {
        return platformList;
    }

    function getPlatformCount() external view returns (uint256) {
        return platformList.length;
    }

    function getPlatformSlashings(address platform) external view returns (bytes32[] memory) {
        return platformSlashings[platform];
    }

    function getPostHaltLockRemaining(address platform) external view returns (uint256) {
        Platform storage plat = platforms[platform];
        if (plat.state != PlatformState.MarketHalted) return 0;

        uint256 unlockTime = plat.haltTime + POST_HALT_LOCK;
        if (block.timestamp >= unlockTime) return 0;

        return unlockTime - block.timestamp;
    }

    function getRedemptionQueueRemaining(address platform) external view returns (uint256) {
        Platform storage plat = platforms[platform];
        if (plat.state != PlatformState.UnstakeRequested) return 0;

        uint256 withdrawalTime = plat.unstakeRequestTime + REDEMPTION_QUEUE;
        if (block.timestamp >= withdrawalTime) return 0;

        return withdrawalTime - block.timestamp;
    }

    function canWithdraw(address platform) external view returns (bool) {
        Platform storage plat = platforms[platform];
        return plat.state == PlatformState.UnstakeRequested &&
               block.timestamp >= plat.unstakeRequestTime + REDEMPTION_QUEUE &&
               !plat.hasSlashableOffense;
    }

    function _removePlatformFromList(address platform) internal {
        uint256 index = platformListIndex[platform];
        uint256 lastIndex = platformList.length - 1;

        if (index != lastIndex) {
            address lastPlatform = platformList[lastIndex];
            platformList[index] = lastPlatform;
            platformListIndex[lastPlatform] = index;
        }

        platformList.pop();
        delete platformListIndex[platform];
    }
}