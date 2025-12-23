// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IOrderBook.sol";
import "./IPlatformRegistry.sol";
import "./IMatchingEngine.sol";

contract TradeExecutor is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable busd;
    IOrderBook public orderBook;
    IPlatformRegistry public platformRegistry;
    IMatchingEngine public matchingEngine;

    uint256 public constant BASIS_POINTS = 10000;

    struct Position {
        uint256 shares;
        uint256 avgEntryPrice;
        uint256 totalCost;
    }

    mapping(address => mapping(bytes32 => mapping(uint8 => Position))) public positions;
    mapping(bytes32 => uint256) public marketVolume;
    mapping(bytes32 => mapping(uint8 => uint256)) public outcomeShares;
    mapping(bytes32 => uint256) public marketTradeCount;
    mapping(address => uint256) public userTradeCount;

    event TradeExecuted(address indexed trader, address indexed platform, bytes32 indexed marketId, uint8 outcome, bool isBuy, uint256 shares, uint256 avgPrice, uint256 totalCost, uint256 platformFee, uint256 timestamp);
    event PositionUpdated(address indexed user, bytes32 indexed marketId, uint8 outcome, uint256 shares, uint256 avgEntryPrice);
    event MarketSettled(bytes32 indexed marketId, uint8 winningOutcome, uint256 totalPayout, uint256 timestamp);
    event Payout(address indexed user, bytes32 indexed marketId, uint8 outcome, uint256 shares, uint256 payout);
    event OrderBookUpdated(address indexed oldOrderBook, address indexed newOrderBook);
    event PlatformRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event MatchingEngineUpdated(address indexed oldEngine, address indexed newEngine);

    error InvalidPlatform();
    error InvalidShares();
    error InsufficientPosition();
    error MarketNotResolved();
    error MarketAlreadySettled();
    error NoPayoutAvailable();
    error Unauthorized();
    error InvalidAddress();
    error TransferFailed();

    constructor(address _busd, address _orderBook, address _platformRegistry, address initialOwner) Ownable(initialOwner) {
        require(_busd != address(0), "Invalid BUSD address");
        require(_orderBook != address(0), "Invalid orderbook address");
        require(_platformRegistry != address(0), "Invalid registry address");

        busd = IERC20(_busd);
        orderBook = IOrderBook(_orderBook);
        platformRegistry = IPlatformRegistry(_platformRegistry);
    }

    function executeMarketOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares,
        uint256 maxSlippageBps,
        address platform
    ) external nonReentrant whenNotPaused {
        if (!platformRegistry.isActivePlatform(platform)) revert InvalidPlatform();
        if (shares == 0) revert InvalidShares();

        if (!isBuy) {
            if (positions[msg.sender][marketId][outcome].shares < shares) revert InsufficientPosition();
        }

        IMatchingEngine.MatchResult memory result = matchingEngine.matchMarketOrder(
            marketId,
            outcome,
            isBuy,
            shares,
            maxSlippageBps,
            platform
        );

        uint256 platformFee = (result.totalCost * platformRegistry.getPlatformFee(platform)) / BASIS_POINTS;

        if (isBuy) {
            uint256 totalPayment = result.totalCost + platformFee;
            busd.safeTransferFrom(msg.sender, address(this), totalPayment);

            Position storage pos = positions[msg.sender][marketId][outcome];
            uint256 newTotalCost = pos.totalCost + result.totalCost;
            uint256 newTotalShares = pos.shares + shares;
            
            pos.shares = newTotalShares;
            pos.totalCost = newTotalCost;
            pos.avgEntryPrice = (newTotalCost * 100) / newTotalShares;

            outcomeShares[marketId][outcome] += shares;

        } else {
            Position storage pos = positions[msg.sender][marketId][outcome];
            
            uint256 costReduction = (pos.totalCost * shares) / pos.shares;
            pos.shares -= shares;
            pos.totalCost -= costReduction;
            
            if (pos.shares > 0) {
                pos.avgEntryPrice = (pos.totalCost * 100) / pos.shares;
            } else {
                pos.avgEntryPrice = 0;
            }

            uint256 netProceeds = result.totalCost - platformFee;
            busd.safeTransfer(msg.sender, netProceeds);

            outcomeShares[marketId][outcome] -= shares;
        }

        _settleMatchedOrders(msg.sender, marketId, outcome, isBuy, result);

        if (platformFee > 0) {
            platformRegistry.addCollectedFees(platform, platformFee);
        }

        marketVolume[marketId] += result.totalCost;
        platformRegistry.recordVolume(platform, result.totalCost);

        marketTradeCount[marketId]++;
        userTradeCount[msg.sender]++;

        emit TradeExecuted(msg.sender, platform, marketId, outcome, isBuy, shares, result.avgPrice, result.totalCost, platformFee, block.timestamp);
        emit PositionUpdated(msg.sender, marketId, outcome, positions[msg.sender][marketId][outcome].shares, positions[msg.sender][marketId][outcome].avgEntryPrice);
    }

    function executeLimitOrder(bytes32 orderId, address platform) external nonReentrant whenNotPaused {
        if (!platformRegistry.isActivePlatform(platform)) revert InvalidPlatform();

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        
        require(order.isActive, "Order not active");
        require(order.trader == msg.sender, "Not order owner");
    }

    function settleMarket(bytes32 marketId, uint8 winningOutcome) external onlyOwner nonReentrant {
        uint256 totalPayout = outcomeShares[marketId][winningOutcome] * 100;
        emit MarketSettled(marketId, winningOutcome, totalPayout, block.timestamp);
    }

    function claimPayout(bytes32 marketId, uint8 winningOutcome) external nonReentrant {
        Position storage pos = positions[msg.sender][marketId][winningOutcome];

        if (pos.shares == 0) revert NoPayoutAvailable();

        uint256 payout = pos.shares * 100;
        uint256 shares = pos.shares;

        pos.shares = 0;
        pos.totalCost = 0;
        pos.avgEntryPrice = 0;

        busd.safeTransfer(msg.sender, payout);

        emit Payout(msg.sender, marketId, winningOutcome, shares, payout);
    }

    function setOrderBook(address _orderBook) external onlyOwner {
        if (_orderBook == address(0)) revert InvalidAddress();
        address oldOrderBook = address(orderBook);
        orderBook = IOrderBook(_orderBook);
        emit OrderBookUpdated(oldOrderBook, _orderBook);
    }

    function setPlatformRegistry(address _platformRegistry) external onlyOwner {
        if (_platformRegistry == address(0)) revert InvalidAddress();
        address oldRegistry = address(platformRegistry);
        platformRegistry = IPlatformRegistry(_platformRegistry);
        emit PlatformRegistryUpdated(oldRegistry, _platformRegistry);
    }

    function setMatchingEngine(address _matchingEngine) external onlyOwner {
        if (_matchingEngine == address(0)) revert InvalidAddress();
        address oldEngine = address(matchingEngine);
        matchingEngine = IMatchingEngine(_matchingEngine);
        emit MatchingEngineUpdated(oldEngine, _matchingEngine);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner whenPaused {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function getUserPosition(address user, bytes32 marketId, uint8 outcome) external view returns (Position memory) {
        return positions[user][marketId][outcome];
    }

    function getMarketVolume(bytes32 marketId) external view returns (uint256) {
        return marketVolume[marketId];
    }

    function getOutcomeShares(bytes32 marketId, uint8 outcome) external view returns (uint256) {
        return outcomeShares[marketId][outcome];
    }

    function getUserTradeCount(address user) external view returns (uint256) {
        return userTradeCount[user];
    }

    function getMarketTradeCount(bytes32 marketId) external view returns (uint256) {
        return marketTradeCount[marketId];
    }

    function calculateUnrealizedPnL(
        address user,
        bytes32 marketId,
        uint8 outcome,
        uint256 currentPrice
    ) external view returns (int256) {
        Position memory pos = positions[user][marketId][outcome];
        
        if (pos.shares == 0) return 0;

        uint256 currentValue = (pos.shares * currentPrice) / 100;
        
        if (currentValue >= pos.totalCost) {
            return int256(currentValue - pos.totalCost);
        } else {
            return -int256(pos.totalCost - currentValue);
        }
    }

    function _settleMatchedOrders(
        address taker,
        bytes32 marketId,
        uint8 outcome,
        bool takerIsBuy,
        IMatchingEngine.MatchResult memory result
    ) internal {
        for (uint256 i = 0; i < result.matchedOrderIds.length; i++) {
            bytes32 orderId = result.matchedOrderIds[i];
            uint256 fillShares = result.matchedShares[i];
            uint256 fillPrice = result.matchedPrices[i];

            orderBook.fillOrder(orderId, fillShares);

            IOrderBook.Order memory makerOrder = orderBook.getOrder(orderId);
            address maker = makerOrder.trader;

            uint256 fillCost = (fillShares * fillPrice) / 100;

            if (takerIsBuy) {
                busd.safeTransfer(maker, fillCost);

                Position storage makerPos = positions[maker][marketId][outcome];
                if (makerPos.shares >= fillShares) {
                    uint256 costReduction = (makerPos.totalCost * fillShares) / makerPos.shares;
                    makerPos.shares -= fillShares;
                    makerPos.totalCost -= costReduction;
                    
                    if (makerPos.shares > 0) {
                        makerPos.avgEntryPrice = (makerPos.totalCost * 100) / makerPos.shares;
                    } else {
                        makerPos.avgEntryPrice = 0;
                    }

                    emit PositionUpdated(maker, marketId, outcome, makerPos.shares, makerPos.avgEntryPrice);
                }
            } else {
                Position storage makerPos = positions[maker][marketId][outcome];
                uint256 newTotalCost = makerPos.totalCost + fillCost;
                uint256 newTotalShares = makerPos.shares + fillShares;
                
                makerPos.shares = newTotalShares;
                makerPos.totalCost = newTotalCost;
                makerPos.avgEntryPrice = (newTotalCost * 100) / newTotalShares;

                emit PositionUpdated(maker, marketId, outcome, makerPos.shares, makerPos.avgEntryPrice);
            }
        }
    }
}