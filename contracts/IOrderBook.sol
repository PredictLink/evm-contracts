// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOrderBook {
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

    function placeOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares,
        uint256 price,
        uint256 expirationTime,
        address platform
    ) external returns (bytes32);

    function cancelOrder(bytes32 orderId) external;

    function fillOrder(bytes32 orderId, uint256 sharesToFill) external returns (uint256);

    function getOrder(bytes32 orderId) external view returns (Order memory);

    function getSortedPrices(bytes32 marketId, uint8 outcome, bool isBuy) 
        external view returns (uint256[] memory);

    function getOrdersAtPrice(bytes32 marketId, uint8 outcome, bool isBuy, uint256 price) 
        external view returns (bytes32[] memory);

    function getBestPrice(bytes32 marketId, uint8 outcome, bool isBuy) 
        external view returns (uint256);

    function getOutcomeLiquidity(bytes32 marketId, uint8 outcome) 
        external view returns (uint256);
}