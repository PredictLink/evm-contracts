// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMatchingEngine {
    struct MatchResult {
        uint256 filledShares;
        uint256 avgPrice;
        uint256 totalCost;
        bytes32[] matchedOrderIds;
        uint256[] matchedShares;
        uint256[] matchedPrices;
    }

    function matchMarketOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares,
        uint256 maxSlippageBps,
        address platform
    ) external returns (MatchResult memory);

    function matchLimitOrder(bytes32 orderId) external returns (uint256);

    function estimateMarketOrder(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares
    ) external view returns (uint256 avgPrice, uint256 totalCost, uint256 availableLiquidity);

    function calculatePriceImpact(
        bytes32 marketId,
        uint8 outcome,
        bool isBuy,
        uint256 shares
    ) external view returns (uint256);
}