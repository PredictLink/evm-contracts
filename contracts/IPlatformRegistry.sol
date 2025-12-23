// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPlatformRegistry {
    enum PlatformState {
        Inactive,
        Active,
        MarketHalted,
        UnstakeRequested,
        Slashed,
        Withdrawn
    }

    function isActivePlatform(address platform) external view returns (bool);
    
    function getPlatformFee(address platform) external view returns (uint256);
    
    function recordVolume(address platform, uint256 volume) external;
    
    function addCollectedFees(address platform, uint256 fees) external;
    
    function updateMarketCount(address platform, bool increment) external;
}