// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarketManager {
    enum MarketStatus {
        Pending,
        Active,
        Closed,
        Resolved,
        Finalized,
        Disputed,
        Invalid,
        Emergency
    }

    function proposeResolution(
        bytes32 marketId,
        uint8 outcome,
        uint256 confidenceScore,
        string calldata evidence
    ) external;

    function getMarket(bytes32 marketId) external view returns (
        bytes32 id,
        address creator,
        address platform,
        string memory title,
        MarketStatus status
    );
}