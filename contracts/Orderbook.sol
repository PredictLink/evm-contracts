// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract OrderBook is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable busd;
    address public platformRegistry;
    address public tradeExecutor;
    address public matchingEngine;

    uint256 public constant MIN_PRICE = 1;
    uint256 public constant MAX_PRICE = 9900;
    uint256 public constant MIN_SHARES = 1;
    uint256 public orderNonce;

    struct Order {
        bytes32 id;
        address trader;
        address platform;
        bytes32 marketId;
        uint8 outcome;
        bool isBuy;
        uint256 shares;
        uint256 price;
        uint256 filledShares;
        uint256 timestamp;
        uint256 expirationTime;
        bool isActive;
    }

    struct PriceLevel {
        uint256 price;
        uint256 totalShares;
        bytes32[] orderIds;
        mapping(bytes32 => uint256) orderIndex;
    }

    mapping(bytes32 => mapping(uint8 => mapping(bool => mapping(uint256 => PriceLevel)))) public priceLevels;
    mapping(bytes32 => mapping(uint8 => mapping(bool => uint256[]))) public sortedPrices;
    mapping(bytes32 => Order) public orders;
    mapping(address => bytes32[]) public userOrders;
    mapping(bytes32 => mapping(uint8 => uint256)) public outcomeLiquidity;
    mapping(bytes32 => uint256) public marketOrderCount;

    event OrderPlaced(bytes32 indexed orderId, address indexed trader, bytes32 indexed marketId, uint8 outcome, bool isBuy, uint256 shares, uint256 price, uint256 timestamp);
    event OrderCancelled(bytes32 indexed orderId, address indexed trader, uint256 remainingShares);
    event OrderFilled(bytes32 indexed orderId, uint256 filledShares, uint256 remainingShares);
    event OrderExpired(bytes32 indexed orderId, uint256 timestamp);
    event TradeExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event MatchingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event PlatformRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    error InvalidPlatform();
    error SharesTooSmall();
    error InvalidPrice();
    error InvalidExpiration();
    error OrderNotActive();
    error NotOrderOwner();
    error InsufficientShares();
    error Unauthorized();
    error InvalidAddress();
    error OrderNotFound();

    modifier onlyTradeExecutor() {
        if (msg.sender != tradeExecutor) revert Unauthorized();
        _;
    }

    modifier onlyMatchingEngine() {
        if (msg.sender != matchingEngine && msg.sender != tradeExecutor) revert Unauthorized();
        _;
    }

    constructor(address _busd, address _platformRegistry, address initialOwner) Ownable(initialOwner) {
        require(_busd != address(0), "Invalid BUSD address");
        require(_platformRegistry != address(0), "Invalid registry address");
        busd = IERC20(_busd);
        platformRegistry = _platformRegistry;
    }

    function placeOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares,
        uint256 price,
        uint256 expirationTime,
        address platform
    ) external nonReentrant whenNotPaused returns (bytes32) {
        if (!_isActivePlatform(platform)) revert InvalidPlatform();
        if (shares < MIN_SHARES) revert SharesTooSmall();
        if (price < MIN_PRICE || price > MAX_PRICE) revert InvalidPrice();
        if (expirationTime != 0 && expirationTime <= block.timestamp) revert InvalidExpiration();

        bytes32 orderId = keccak256(abi.encodePacked(msg.sender, marketId, outcome, orderNonce++, block.timestamp));

        if (isBuy) {
            uint256 cost = (shares * price) / 100;
            busd.safeTransferFrom(msg.sender, address(this), cost);
        }

        orders[orderId] = Order({
            id: orderId,
            trader: msg.sender,
            platform: platform,
            marketId: marketId,
            outcome: outcome,
            isBuy: isBuy,
            shares: shares,
            price: price,
            filledShares: 0,
            timestamp: block.timestamp,
            expirationTime: expirationTime,
            isActive: true
        });

        _addOrderToPriceLevel(marketId, outcome, isBuy, price, orderId, shares);
        userOrders[msg.sender].push(orderId);
        outcomeLiquidity[marketId][outcome] += shares;
        marketOrderCount[marketId]++;

        emit OrderPlaced(orderId, msg.sender, marketId, outcome, isBuy, shares, price, block.timestamp);
        return orderId;
    }

    function cancelOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (!order.isActive) revert OrderNotActive();
        if (order.trader != msg.sender) revert NotOrderOwner();

        uint256 remainingShares = order.shares - order.filledShares;
        order.isActive = false;

        _removeOrderFromPriceLevel(order.marketId, order.outcome, order.isBuy, order.price, orderId, remainingShares);

        if (order.isBuy && remainingShares > 0) {
            uint256 refund = (remainingShares * order.price) / 100;
            busd.safeTransfer(msg.sender, refund);
        }

        outcomeLiquidity[order.marketId][order.outcome] -= remainingShares;
        emit OrderCancelled(orderId, msg.sender, remainingShares);
    }

    function fillOrder(bytes32 orderId, uint256 sharesToFill) external onlyTradeExecutor returns (uint256 actualFilled) {
        Order storage order = orders[orderId];
        if (!order.isActive) revert OrderNotActive();
        if (sharesToFill == 0) revert InsufficientShares();

        uint256 remainingShares = order.shares - order.filledShares;
        actualFilled = sharesToFill > remainingShares ? remainingShares : sharesToFill;
        order.filledShares += actualFilled;

        if (order.filledShares >= order.shares) {
            order.isActive = false;
            _removeOrderFromPriceLevel(order.marketId, order.outcome, order.isBuy, order.price, orderId, actualFilled);
        } else {
            PriceLevel storage level = priceLevels[order.marketId][order.outcome][order.isBuy][order.price];
            level.totalShares -= actualFilled;
        }

        emit OrderFilled(orderId, actualFilled, order.shares - order.filledShares);
        return actualFilled;
    }

    function cleanupExpiredOrders(bytes32[] calldata orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage order = orders[orderIds[i]];

            if (order.isActive && order.expirationTime != 0 && block.timestamp >= order.expirationTime) {
                uint256 remainingShares = order.shares - order.filledShares;
                order.isActive = false;

                _removeOrderFromPriceLevel(order.marketId, order.outcome, order.isBuy, order.price, orderIds[i], remainingShares);

                if (order.isBuy && remainingShares > 0) {
                    uint256 refund = (remainingShares * order.price) / 100;
                    busd.safeTransfer(order.trader, refund);
                }

                outcomeLiquidity[order.marketId][order.outcome] -= remainingShares;
                emit OrderExpired(orderIds[i], block.timestamp);
            }
        }
    }

    function setTradeExecutor(address _tradeExecutor) external onlyOwner {
        if (_tradeExecutor == address(0)) revert InvalidAddress();
        address oldExecutor = tradeExecutor;
        tradeExecutor = _tradeExecutor;
        emit TradeExecutorUpdated(oldExecutor, _tradeExecutor);
    }

    function setMatchingEngine(address _matchingEngine) external onlyOwner {
        if (_matchingEngine == address(0)) revert InvalidAddress();
        address oldEngine = matchingEngine;
        matchingEngine = _matchingEngine;
        emit MatchingEngineUpdated(oldEngine, _matchingEngine);
    }

    function setPlatformRegistry(address _platformRegistry) external onlyOwner {
        if (_platformRegistry == address(0)) revert InvalidAddress();
        address oldRegistry = platformRegistry;
        platformRegistry = _platformRegistry;
        emit PlatformRegistryUpdated(oldRegistry, _platformRegistry);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    function getSortedPrices(bytes32 marketId, uint8 outcome, bool isBuy) external view returns (uint256[] memory) {
        return sortedPrices[marketId][outcome][isBuy];
    }

    function getBestPrice(bytes32 marketId, uint8 outcome, bool isBuy) external view returns (uint256) {
        uint256[] memory prices = sortedPrices[marketId][outcome][isBuy];
        return prices.length > 0 ? prices[0] : 0;
    }

    function getOrdersAtPrice(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price) external view returns (bytes32[] memory) {
        return priceLevels[marketId][outcome][isBuy][price].orderIds;
    }

    function getPriceLevelInfo(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price) external view returns (uint256 totalShares, uint256 orderCount) {
        PriceLevel storage level = priceLevels[marketId][outcome][isBuy][price];
        return (level.totalShares, level.orderIds.length);
    }

    function getOutcomeLiquidity(bytes32 marketId, uint8 outcome) external view returns (uint256) {
        return outcomeLiquidity[marketId][outcome];
    }

    function _addOrderToPriceLevel(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price, bytes32 orderId, uint256 shares) internal {
        PriceLevel storage level = priceLevels[marketId][outcome][isBuy][price];

        if (level.orderIds.length == 0) {
            level.price = price;
            _insertPrice(marketId, outcome, isBuy, price);
        }

        level.orderIndex[orderId] = level.orderIds.length;
        level.orderIds.push(orderId);
        level.totalShares += shares;
    }

    function _removeOrderFromPriceLevel(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price, bytes32 orderId, uint256 shares) internal {
        PriceLevel storage level = priceLevels[marketId][outcome][isBuy][price];

        uint256 index = level.orderIndex[orderId];
        uint256 lastIndex = level.orderIds.length - 1;

        if (index != lastIndex) {
            bytes32 lastOrderId = level.orderIds[lastIndex];
            level.orderIds[index] = lastOrderId;
            level.orderIndex[lastOrderId] = index;
        }

        level.orderIds.pop();
        delete level.orderIndex[orderId];
        level.totalShares -= shares;

        if (level.orderIds.length == 0) {
            _removePrice(marketId, outcome, isBuy, price);
        }
    }

    function _insertPrice(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price) internal {
        uint256[] storage prices = sortedPrices[marketId][outcome][isBuy];

        if (prices.length == 0) {
            prices.push(price);
            return;
        }

        uint256 left = 0;
        uint256 right = prices.length;

        while (left < right) {
            uint256 mid = (left + right) / 2;
            bool shouldInsertBefore = isBuy ? price > prices[mid] : price < prices[mid];

            if (shouldInsertBefore) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }

        prices.push(prices[prices.length - 1]);
        for (uint256 i = prices.length - 1; i > left; i--) {
            prices[i] = prices[i - 1];
        }
        prices[left] = price;
    }

    function _removePrice(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price) internal {
        uint256[] storage prices = sortedPrices[marketId][outcome][isBuy];

        for (uint256 i = 0; i < prices.length; i++) {
            if (prices[i] == price) {
                prices[i] = prices[prices.length - 1];
                prices.pop();
                break;
            }
        }
    }

    function _isActivePlatform(address platform) internal view returns (bool) {
        (bool success, bytes memory data) = platformRegistry.staticcall(
            abi.encodeWithSignature("isActivePlatform(address)", platform)
        );
        if (!success || data.length == 0) return false;
        return abi.decode(data, (bool));
    }
}