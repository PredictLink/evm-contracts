import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "hardhat-contract-sizer";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200, 
      },
      viaIR: false, 
    },
  },

  networks: {
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: false,
      gas: "auto",
      gasPrice: "auto",
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
        count: 20,
        accountsBalance: "10000000000000000000000", 
      },
      forking: process.env.FORK_MAINNET === "true"
        ? {
            url: process.env.BSC_RPC_URL || "",
            blockNumber: process.env.FORK_BLOCK_NUMBER
              ? parseInt(process.env.FORK_BLOCK_NUMBER)
              : undefined,
          }
        : undefined,
    },

    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },

    // BSC Mainnet
    bsc: {
      url: process.env.BSC_RPC_URL || "https://bsc-dataseed1.binance.org",
      chainId: 56,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: parseInt(process.env.GAS_PRICE || "5000000000"), // 5 gwei
      gas: parseInt(process.env.GAS_LIMIT || "8000000"),
      timeout: 60000,
    },

    // BSC Testnet
    bscTestnet: {
      url:
        process.env.BSC_TESTNET_RPC_URL ||
        "https://data-seed-prebsc-1-s1.binance.org:8545",
      chainId: 97,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: parseInt(process.env.GAS_PRICE || "10000000000"), // 10 gwei
      gas: parseInt(process.env.GAS_LIMIT || "8000000"),
      timeout: 60000,
    },

   
  },

  etherscan: {
    apiKey: {
      // BSC
      bsc: process.env.BSCSCAN_API_KEY || "",
      bscTestnet: process.env.BSCSCAN_API_KEY || "",
      // Ethereum
      mainnet: process.env.ETHERSCAN_API_KEY || "",
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      // Polygon
      polygon: process.env.POLYGONSCAN_API_KEY || "",
      polygonMumbai: process.env.POLYGONSCAN_API_KEY || "",
    },
  },

  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY || "",
    token: "BNB", // For BSC
    gasPriceApi:
      "https://api.bscscan.com/api?module=proxy&action=eth_gasPrice",
    outputFile: process.env.GAS_REPORT_FILE || "gas-report.txt",
    noColors: false,
    showTimeSpent: true,
    showMethodSig: true,
    maxMethodDiff: 10,
  },

  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: process.env.CONTRACT_SIZER === "true",
    strict: true,
    only: [],
    except: ["Mock", "Test"],
  },

  mocha: {
    timeout: 200000, // 200 seconds
    parallel: false,
    bail: false,
  },

  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },

  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
};

export default config;