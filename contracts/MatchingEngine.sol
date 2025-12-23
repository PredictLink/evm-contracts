// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IOrderBook.sol";
import "./IPlatformRegistry.sol";

contract MatchingEngine is Ownable, ReentrancyGuard {
    
    IOrderBook public orderBook;
    IPlatformRegistry public platformRegistry;
    address public tradeExecutor;

    uint256 public constant MAX_ORDERS_PER_MATCH = 100;
    uint256 public constant BASIS_POINTS = 10000;

    struct MatchResult {
        uint256 filledShares;
        uint256 avgPrice;
        uint256 totalCost;
        bytes32[] matchedOrderIds;
        uint256[] matchedShares;
        uint256[] matchedPrices;
    }

    event OrderMatched(bytes32 indexed takerOrderId, bytes32 indexed makerOrderId, uint256 shares, uint256 price, uint256 timestamp);
    event MarketOrderExecuted(address indexed trader, bytes32 indexed marketId, uint8 outcome, bool isBuy, uint256 shares, uint256 avgPrice, uint256 totalCost);
    event OrderBookUpdated(address indexed oldOrderBook, address indexed newOrderBook);
    event PlatformRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event TradeExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

    error InvalidPlatform();
    error InvalidShares();
    error NoLiquidity();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error Unauthorized();
    error InvalidAddress();
    error InvalidOrderBook();

    modifier onlyTradeExecutor() {
        if (msg.sender != tradeExecutor) revert Unauthorized();
        _;
    }

    constructor(address _orderBook, address _platformRegistry, address initialOwner) Ownable(initialOwner) {
        require(_orderBook != address(0), "Invalid orderbook address");
        require(_platformRegistry != address(0), "Invalid registry address");
        orderBook = IOrderBook(_orderBook);
        platformRegistry = IPlatformRegistry(_platformRegistry);
    }

    function matchMarketOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares,
        uint256 maxSlippageBps,
        address platform
    ) external nonReentrant returns (MatchResult memory result) {
        if (!platformRegistry.isActivePlatform(platform)) revert InvalidPlatform();
        if (shares == 0) revert InvalidShares();

        uint256[] memory prices = orderBook.getSortedPrices(marketId, outcome, !isBuy);
        if (prices.length == 0) revert NoLiquidity();

        result.matchedOrderIds = new bytes32[](MAX_ORDERS_PER_MATCH);
        result.matchedShares = new uint256[](MAX_ORDERS_PER_MATCH);
        result.matchedPrices = new uint256[](MAX_ORDERS_PER_MATCH);

        uint256 remainingShares = shares;
        uint256 totalCost = 0;
        uint256 matchCount = 0;
        uint256 bestPrice = prices[0];

        for (uint256 i = 0; i < prices.length && remainingShares > 0 && matchCount < MAX_ORDERS_PER_MATCH; i++) {
            uint256 price = prices[i];
            bytes32[] memory orderIds = orderBook.getOrdersAtPrice(marketId, outcome, !isBuy, price);

            for (uint256 j = 0; j < orderIds.length && remainingShares > 0; j++) {
                IOrderBook.Order memory order = orderBook.getOrder(orderIds[j]);
                if (!order.isActive) continue;

                uint256 availableShares = order.shares - order.filledShares;
                uint256 fillShares = remainingShares > availableShares ? availableShares : remainingShares;
                uint256 fillCost = (fillShares * price) / 100;

                result.matchedOrderIds[matchCount] = orderIds[j];
                result.matchedShares[matchCount] = fillShares;
                result.matchedPrices[matchCount] = price;

                totalCost += fillCost;
                remainingShares -= fillShares;
                matchCount++;

                emit OrderMatched(bytes32(0), orderIds[j], fillShares, price, block.timestamp);
            }
        }

        if (remainingShares > 0) revert InsufficientLiquidity();

        result.avgPrice = (totalCost * 100) / shares;
        result.totalCost = totalCost;
        result.filledShares = shares;

        uint256 slippage;
        if (result.avgPrice > bestPrice) {
            slippage = ((result.avgPrice - bestPrice) * BASIS_POINTS) / bestPrice;
        } else {
            slippage = ((bestPrice - result.avgPrice) * BASIS_POINTS) / bestPrice;
        }

        if (slippage > maxSlippageBps) revert SlippageExceeded();

        bytes32[] memory finalOrderIds = new bytes32[](matchCount);
        uint256[] memory finalShares = new uint256[](matchCount);
        uint256[] memory finalPrices = new uint256[](matchCount);

        for (uint256 i = 0; i < matchCount; i++) {
            finalOrderIds[i] = result.matchedOrderIds[i];
            finalShares[i] = result.matchedShares[i];
            finalPrices[i] = result.matchedPrices[i];
        }

        result.matchedOrderIds = finalOrderIds;
        result.matchedShares = finalShares;
        result.matchedPrices = finalPrices;

        emit MarketOrderExecuted(msg.sender, marketId, outcome, isBuy, shares, result.avgPrice, result.totalCost);
        return result;
    }

    function matchLimitOrder(bytes32 orderId) external nonReentrant returns (uint256 totalFilled) {
        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        if (!order.isActive) revert InvalidOrderBook();

        uint256[] memory prices = orderBook.getSortedPrices(order.marketId, order.outcome, !order.isBuy);
        if (prices.length == 0) return 0;

        uint256 remainingShares = order.shares - order.filledShares;
        totalFilled = 0;

        for (uint256 i = 0; i < prices.length && remainingShares > 0; i++) {
            uint256 price = prices[i];

            bool priceAcceptable = order.isBuy ? price <= order.price : price >= order.price;
            if (!priceAcceptable) break;

            bytes32[] memory orderIds = orderBook.getOrdersAtPrice(order.marketId, order.outcome, !order.isBuy, price);

            for (uint256 j = 0; j < orderIds.length && remainingShares > 0; j++) {
                IOrderBook.Order memory matchOrder = orderBook.getOrder(orderIds[j]);
                if (!matchOrder.isActive) continue;

                uint256 availableShares = matchOrder.shares - matchOrder.filledShares;
                uint256 fillShares = remainingShares > availableShares ? availableShares : remainingShares;

                remainingShares -= fillShares;
                totalFilled += fillShares;

                emit OrderMatched(orderId, orderIds[j], fillShares, price, block.timestamp);
            }
        }

        return totalFilled;
    }

    function estimateMarketOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares
    ) external view returns (uint256 avgPrice, uint256 totalCost, uint256 availableLiquidity) {
        uint256[] memory prices = orderBook.getSortedPrices(marketId, outcome, !isBuy);
        if (prices.length == 0) return (0, 0, 0);

        uint256 remainingShares = shares;
        uint256 cost = 0;
        uint256 liquidity = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint256 price = prices[i];
            bytes32[] memory orderIds = orderBook.getOrdersAtPrice(marketId, outcome, !isBuy, price);

            for (uint256 j = 0; j < orderIds.length; j++) {
                IOrderBook.Order memory order = orderBook.getOrder(orderIds[j]);
                if (!order.isActive) continue;

                uint256 availableShares = order.shares - order.filledShares;
                liquidity += availableShares;

                if (remainingShares > 0) {
                    uint256 fillShares = remainingShares > availableShares ? availableShares : remainingShares;
                    cost += (fillShares * price) / 100;
                    remainingShares -= fillShares;
                }
            }
        }

        if (remainingShares > 0) return (0, 0, liquidity);

        avgPrice = (cost * 100) / shares;
        totalCost = cost;
        availableLiquidity = liquidity;

        return (avgPrice, totalCost, availableLiquidity);
    }

    function getMarketDepth(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 maxLevels
    ) external view returns (uint256[] memory prices, uint256[] memory volumes) {
        uint256[] memory allPrices = orderBook.getSortedPrices(marketId, outcome, isBuy);
        uint256 levels = allPrices.length > maxLevels ? maxLevels : allPrices.length;
        
        prices = new uint256[](levels);
        volumes = new uint256[](levels);

        uint256 cumulativeVolume = 0;

        for (uint256 i = 0; i < levels; i++) {
            prices[i] = allPrices[i];
            bytes32[] memory orderIds = orderBook.getOrdersAtPrice(marketId, outcome, isBuy, allPrices[i]);

            uint256 levelVolume = 0;
            for (uint256 j = 0; j < orderIds.length; j++) {
                IOrderBook.Order memory order = orderBook.getOrder(orderIds[j]);
                if (order.isActive) {
                    levelVolume += (order.shares - order.filledShares);
                }
            }

            cumulativeVolume += levelVolume;
            volumes[i] = cumulativeVolume;
        }

        return (prices, volumes);
    }

    function calculatePriceImpact(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares
    ) external view returns (uint256 priceImpactBps) {
        (uint256 avgPrice, , uint256 liquidity) = this.estimateMarketOrder(marketId, outcome, isBuy, shares);

        if (avgPrice == 0 || liquidity < shares) return BASIS_POINTS;

        uint256[] memory prices = orderBook.getSortedPrices(marketId, outcome, !isBuy);
        if (prices.length == 0) return BASIS_POINTS;

        uint256 bestPrice = prices[0];

        if (avgPrice > bestPrice) {
            priceImpactBps = ((avgPrice - bestPrice) * BASIS_POINTS) / bestPrice;
        } else {
            priceImpactBps = ((bestPrice - avgPrice) * BASIS_POINTS) / bestPrice;
        }

        return priceImpactBps;
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

    function setTradeExecutor(address _tradeExecutor) external onlyOwner {
        if (_tradeExecutor == address(0)) revert InvalidAddress();
        address oldExecutor = tradeExecutor;
        tradeExecutor = _tradeExecutor;
        emit TradeExecutorUpdated(oldExecutor, _tradeExecutor);
    }
}