# PredictLink EVM Contracts

> Decentralized prediction markets engine with AI-powered resolution and advanced order matching

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-yellow)](https://hardhat.org/)

Pitch: https://docs.google.com/presentation/d/1nBYPZTmSfYFxuM6t1U4onIMLPGDKBSlEYDawlAFZCcM/edit?usp=sharing

## Overview

PredictLink is a decentralized and trustless prediction markets engine featuring:

- **Central Limit Order Book (CLOB)** - Price-time priority matching with deep liquidity
- **AI-Powered Resolution** - Automated market settlement using AI agents with confidence scoring
- **Platform Staking** - 1M PRED token stake with multi-phase unstaking and slashing protection
- **Emergency Management** - Multi-sig guardian system with circuit breakers and fund recovery
- **Advanced Trading** - Market and limit orders with slippage protection
- **Zero Protocol Fees** - Platforms pay through staking, not per-transaction fees
- **Unified Liquidity** - All platforms share a single orderbook and liquidity
- **Permissionless Markets** - Anyone can create markets with quality-based moderation

## Architecture

### Core Contracts

| Contract | Description | Key Features |
|----------|-------------|--------------|
| **OrderBook.sol** | Central limit order book | Price levels, order management, time-priority |
| **MatchingEngine.sol** | Order matching logic | Market depth, slippage protection, price impact |
| **TradeExecutor.sol** | Trade settlement | Position tracking, P&L calculation, payouts |
| **MarketManager.sol** | Market lifecycle | Creation, resolution, disputes, voting |
| **PlatformRegistry.sol** | Platform staking | Multi-phase unstaking, slashing, fee collection |
| **AIResolutionOracle.sol** | AI-powered resolution | Agent reputation, confidence scoring, autonomy |
| **EmergencyManager.sol** | Emergency response | Multi-sig, circuit breakers, fund recovery |

### Token Contracts

| Contract | Symbol | Supply | Purpose |
|----------|--------|--------|---------|
| **PREDToken.sol** | PRED | 1B (100M initial) | Governance, staking, disputes |

### BSC Testnet Deployments

- PRED Token:          https://testnet.bscscan.com/address/0xcbc65ab04350B67cdA25117c04A6393dc8AFFe61
- OrderBook:           https://testnet.bscscan.com/address/0x199d93896DC8DAAEB695450f648211D0E4dcE6Ce
- MatchingEngine:      https://testnet.bscscan.com/address/0xd011E4f7D42C1FeaeEa029f7476a3C8620829Dba
- TradeExecutor:       https://testnet.bscscan.com/address/0xdAEC327D96a479ddbcC7f72eD5B1cf71dA4Baf2a
- PlatformRegistry:    https://testnet.bscscan.com/address/0x6974A2Fc94FB95a7B5D5B8749c1fFFEd23eE4416
- MarketManager:       https://testnet.bscscan.com/address/0xdBE097595BeE0b3F3316c45c9e6d18f6a6a58709
- AIResolutionOracle:  https://testnet.bscscan.com/address/0x47dcF2008B82127AE907a9ba9f1f9bf727a24b52
- EmergencyManager:    https://testnet.bscscan.com/address/0x6BE2E8ab34CdFAEee45796923DD2c2332C49B013


## Key Features

### 1. Central Limit Order Book (CLOB)

```solidity
// Place limit order with expiration
placeOrder(marketId, outcome, isBuy, shares, price, expirationTime, platform)

// Cancel anytime before filled
cancelOrder(orderId)

// Auto-cleanup expired orders
cleanupExpiredOrders([orderId1, orderId2])
```

**Features:**
- Binary search price insertion (O(log n))
- Price-time priority matching
- Partial fills supported
- Order expiration with auto-cleanup
- BUSD locked for buy orders

### 2. Platform Staking System

**Three-Phase Unstaking Process:**

```
Phase 1: Halt Markets (0 active markets required)
    ↓
Phase 2: Post-Halt Lock (30 days) → Request Unstake
    ↓
Phase 3: Redemption Queue (7 days) → Execute Withdrawal
```

**Slashing Mechanism:**
- Slashing authority can propose slashing for malicious behavior
- Partial or full stake slashing to treasury
- Platform immediately marked as `Slashed` state

### 3. AI Resolution System

**Agent Reputation System:**
- Start: 70% reputation score
- Success: +1% per correct resolution
- Failure: -2% per incorrect resolution
- Autonomy granted at 95%+ reputation

**Resolution Methods:**
- WebSearch, PriceFeeds, SportsAPIs, NewsAPIs, Custom, MultiSource

**Confidence Scoring:**
- Min 70% to propose
- Min 85% for auto-submission
- High confidence (95%+) grants autonomy

### 4. Market Lifecycle

```
Pending → AI Moderation → Active → Closed → Resolved → Finalized
                                              ↓
                                          Disputed → Vote → Resolved
```

**Quality Scoring:**
- 60-89: Normal approval
- 90-100: High quality (2x creator rewards)
- 40-59: Rejected (50% bond slashed)
- 0-39: Rejected (full bond returned)

### 5. Emergency Management

**Guardian Roles:**
- Minimum 3 guardians required
- Multi-sig approval (3/N threshold)
- 48-hour timelock for critical actions

**Capabilities:**
- Global emergency shutdown
- Circuit breakers per contract
- Fund recovery with multi-sig
- Emergency action proposals

## Contract Interactions

### Creating a Market

```solidity
marketManager.createMarket(
    platform,           // Platform address
    "Will BTC hit $100k by EOY?",
    "Bitcoin price prediction",
    ["Yes", "No"],     // Outcomes
    endTime,           // Event conclusion
    "CoinGecko API",   // Resolution source
    "Price at 23:59 UTC",
    Category.Crypto
)
```

**Requirements:**
- 500 BUSD creation bond
- Platform must be active
- 2-10 outcomes
- End time > 1 hour from now

### Trading on Markets

```solidity
// Place limit order
orderBook.placeOrder(marketId, 0, true, 100, 5500, 0, platform)
// 100 shares, outcome 0, buy at $55.00, no expiration

// Execute market order
tradeExecutor.executeMarketOrder(
    marketId,
    0,              // Outcome
    true,           // Buy
    100,            // Shares
    500,            // Max 5% slippage
    platform
)
```

### Platform Registration

```solidity
// Approve PRED tokens
predToken.approve(platformRegistry, 1_000_000e18)

// Register platform
platformRegistry.registerPlatform("My Platform", 50) // 0.5% fee
```

## Deployment

### Prerequisites

```bash
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @openzeppelin/contracts
```

### Configuration

Create `.env`:

```env
PRIVATE_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_key
BSC_RPC_URL=https://bsc-dataseed.binance.org/
TESTNET_RPC_URL=https://data-seed-prebsc-1-s1.binance.org:8545/
```

Update `hardhat.config.ts`:

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    bscTestnet: {
      url: process.env.TESTNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 97
    },
    bsc: {
      url: process.env.BSC_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 56
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY
  }
};

export default config;
```

### Deploy

```bash
# Compile contracts
npx hardhat compile

# Deploy to local network
npx hardhat run scripts/deploy.ts

# Deploy to BSC testnet
npx hardhat run scripts/deploy.ts --network bscTestnet

# Deploy to BSC mainnet
npx hardhat run scripts/deploy.ts --network bsc

# Verify contracts
npx hardhat verify --network bscTestnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```


## Security Features

### Access Control
- Owner-only admin functions
- Role-based access (AI agents, guardians, council)
- Multi-sig for critical operations

### Safety Mechanisms
- ReentrancyGuard on all external functions
- Pausable contracts for emergency stops
- Circuit breakers for individual contracts
- Input validation and bounds checking

### Economic Security
- Platform staking (1M PRED)
- Multi-phase unstaking (37 days total)
- Slashing for malicious behavior
- Market creation bonds (500 BUSD)
- Dispute bonds (300 BUSD)

## Gas Optimization

- Binary search for price insertion
- O(1) order removal with index mapping
- Packed structs for storage efficiency
- View functions for read operations
- Batch operations where possible

## Constants & Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| Platform Stake | 1,000,000 PRED | Required to operate |
| Market Bond | 500 BUSD | Market creation deposit |
| Dispute Bond | 300 BUSD | Challenge resolution |
| Post-Halt Lock | 30 days | After market halt |
| Redemption Queue | 7 days | Before withdrawal |
| Challenge Period | 1 hour | Dispute window |
| Dispute Voting | 48 hours | Vote duration |
| Min Price | 0.01 BUSD | Order minimum |
| Max Price | 99.00 BUSD | Order maximum |
| Max Platform Fee | 2% | Fee cap |


## API Integration

### Web3 Integration Example

```typescript
import { ethers } from "ethers";
import OrderBookABI from "./abis/OrderBook.json";

const provider = new ethers.JsonRpcProvider(RPC_URL);
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

const orderBook = new ethers.Contract(
  ORDERBOOK_ADDRESS,
  OrderBookABI,
  signer
);

// Place order
const tx = await orderBook.placeOrder(
  marketId,
  outcome,
  isBuy,
  shares,
  price,
  expiration,
  platform
);

await tx.wait();
console.log("Order placed:", tx.hash);
```

## Events

All contracts emit detailed events for off-chain tracking:

```solidity
// OrderBook
event OrderPlaced(bytes32 indexed orderId, ...)
event OrderCancelled(bytes32 indexed orderId, ...)
event OrderFilled(bytes32 indexed orderId, ...)

// MarketManager
event MarketCreated(bytes32 indexed marketId, ...)
event ResolutionProposed(bytes32 indexed marketId, ...)
event DisputeRaised(bytes32 indexed marketId, ...)

// TradeExecutor
event TradeExecuted(address indexed trader, ...)
event PositionUpdated(address indexed user, ...)
```


## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact & Resources

- **Website**: https://bnb.predictlink.online
- **Twitter**: @PredictLink
- **Telegram**: https://t.me/predictlink
- **GitHub**: https://github.com/predictlink

## Acknowledgments

Built with:
- [OpenZeppelin Contracts](https://openzeppelin.com/contracts/)
- [Hardhat](https://hardhat.org/)
- [Ethers.js](https://docs.ethers.org/)

---

**⚠️ Disclaimer**: This software is provided "as is", without warranty of any kind. Use at your own risk. Not financial advice.