import { ethers } from "hardhat";

async function main() {
  console.log("🚀 Starting PredictLink deployment...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  console.log("📦 Step 1: Deploying tokens...");
  
  const PREDToken = await ethers.getContractFactory("PREDToken");
  const predToken = await PREDToken.deploy(deployer.address);
  await predToken.waitForDeployment();
  const predAddress = await predToken.getAddress();
  console.log("✅ PRED Token deployed to:", predAddress);


const busdAddress = = '0xaB1a4d4f1D656d2450692D237fdD6C7f9146e814';
  console.log("✅ Mock BUSD deployed to:", busdAddress);

  console.log("\n📦 Step 2: Deploying PlatformRegistry...");
  
  const treasury = deployer.address;
  const slashingAuthority = deployer.address;

  const PlatformRegistry = await ethers.getContractFactory("PlatformRegistry");
  const platformRegistry = await PlatformRegistry.deploy(
    predAddress,
    busdAddress,
    slashingAuthority,
    treasury,
    deployer.address
  );
  await platformRegistry.waitForDeployment();
  const platformRegistryAddress = await platformRegistry.getAddress();
  console.log("✅ PlatformRegistry deployed to:", platformRegistryAddress);

  console.log("\n📦 Step 3: Deploying OrderBook...");
  
  const OrderBook = await ethers.getContractFactory("OrderBook");
  const orderBook = await OrderBook.deploy(
    busdAddress,
    platformRegistryAddress,
    deployer.address
  );
  await orderBook.waitForDeployment();
  const orderBookAddress = await orderBook.getAddress();
  console.log("✅ OrderBook deployed to:", orderBookAddress);

  console.log("\n📦 Step 4: Deploying MatchingEngine...");
  
  const MatchingEngine = await ethers.getContractFactory("MatchingEngine");
  const matchingEngine = await MatchingEngine.deploy(
    orderBookAddress,
    platformRegistryAddress,
    deployer.address
  );
  await matchingEngine.waitForDeployment();
  const matchingEngineAddress = await matchingEngine.getAddress();
  console.log("✅ MatchingEngine deployed to:", matchingEngineAddress);

  console.log("\n📦 Step 5: Deploying TradeExecutor...");
  
  const TradeExecutor = await ethers.getContractFactory("TradeExecutor");
  const tradeExecutor = await TradeExecutor.deploy(
    busdAddress,
    orderBookAddress,
    platformRegistryAddress,
    deployer.address
  );
  await tradeExecutor.waitForDeployment();
  const tradeExecutorAddress = await tradeExecutor.getAddress();
  console.log("✅ TradeExecutor deployed to:", tradeExecutorAddress);

  console.log("\n📦 Step 6: Deploying MarketManager...");
  
  const aiOracle = deployer.address;
  const emergencyCouncil = deployer.address;

  const MarketManager = await ethers.getContractFactory("MarketManager");
  const marketManager = await MarketManager.deploy(
    busdAddress,
    predAddress,
    platformRegistryAddress,
    aiOracle,
    emergencyCouncil,
    deployer.address
  );
  await marketManager.waitForDeployment();
  const marketManagerAddress = await marketManager.getAddress();
  console.log("✅ MarketManager deployed to:", marketManagerAddress);

  console.log("\n📦 Step 7: Deploying AIResolutionOracle...");
  
  const AIResolutionOracle = await ethers.getContractFactory("AIResolutionOracle");
  const aiResolutionOracle = await AIResolutionOracle.deploy(
    marketManagerAddress,
    deployer.address
  );
  await aiResolutionOracle.waitForDeployment();
  const aiOracleAddress = await aiResolutionOracle.getAddress();
  console.log("✅ AIResolutionOracle deployed to:", aiOracleAddress);

  console.log("\n📦 Step 8: Deploying EmergencyManager...");
  
  const initialGuardians = [deployer.address, deployer.address, deployer.address];

  const EmergencyManager = await ethers.getContractFactory("EmergencyManager");
  const emergencyManager = await EmergencyManager.deploy(
    treasury,
    initialGuardians,
    deployer.address
  );
  await emergencyManager.waitForDeployment();
  const emergencyManagerAddress = await emergencyManager.getAddress();
  console.log("✅ EmergencyManager deployed to:", emergencyManagerAddress);

  console.log("\n🔧 Step 9: Connecting contracts...");

  console.log("Connecting OrderBook...");
  await orderBook.setTradeExecutor(tradeExecutorAddress);
  await orderBook.setMatchingEngine(matchingEngineAddress);

  console.log("Connecting MatchingEngine...");
  await matchingEngine.setTradeExecutor(tradeExecutorAddress);

  console.log("Connecting TradeExecutor...");
  await tradeExecutor.setMatchingEngine(matchingEngineAddress);

  console.log("Connecting MarketManager with AIOracle...");
  await marketManager.setAIOracle(aiOracleAddress);

  console.log("\n✅ All contracts connected successfully!");

  console.log("\n📝 Enabling PRED token transfers...");
  await predToken.enableTransfers();
  console.log("✅ PRED transfers enabled!");

  console.log("\n" + "=".repeat(80));
  console.log("🎉 DEPLOYMENT SUMMARY");
  console.log("=".repeat(80));
  console.log("\n📌 Token Addresses:");
  console.log("   PRED Token:          ", predAddress);
  console.log("   Mock BUSD:           ", busdAddress);
  
  console.log("\n📌 Core Protocol:");
  console.log("   PlatformRegistry:    ", platformRegistryAddress);
  console.log("   OrderBook:           ", orderBookAddress);
  console.log("   MatchingEngine:      ", matchingEngineAddress);
  console.log("   TradeExecutor:       ", tradeExecutorAddress);
  console.log("   MarketManager:       ", marketManagerAddress);
  console.log("   AIResolutionOracle:  ", aiOracleAddress);
  console.log("   EmergencyManager:    ", emergencyManagerAddress);

  console.log("\n📌 Configuration:");
  console.log("   Deployer:            ", deployer.address);
  console.log("   Treasury:            ", treasury);
  console.log("   Slashing Authority:  ", slashingAuthority);
  console.log("   AI Oracle:           ", aiOracle);
  console.log("   Emergency Council:   ", emergencyCouncil);

  console.log("\n💾 Saving deployment addresses...");

  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      tokens: {
        PRED: predAddress,
        BUSD: busdAddress
      },
      core: {
        PlatformRegistry: platformRegistryAddress,
        OrderBook: orderBookAddress,
        MatchingEngine: matchingEngineAddress,
        TradeExecutor: tradeExecutorAddress,
        MarketManager: marketManagerAddress,
        AIResolutionOracle: aiOracleAddress,
        EmergencyManager: emergencyManagerAddress
      },
      config: {
        treasury,
        slashingAuthority,
        aiOracle,
        emergencyCouncil
      }
    }
  };

  const fs = require("fs");
  const path = require("path");
  
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const filename = `deployment-${Date.now()}.json`;
  fs.writeFileSync(
    path.join(deploymentsDir, filename),
    JSON.stringify(deploymentInfo, null, 2)
  );

  console.log("✅ Deployment info saved to:", `deployments/${filename}`);

  console.log("\n" + "=".repeat(80));
  console.log("✨ Deployment completed successfully!");
  console.log("=".repeat(80) + "\n");

  console.log("🔍 Next steps:");
  console.log("   1. Verify contracts on block explorer");
  console.log("   2. Set up platform registration");
  console.log("   3. Configure AI agents");
  console.log("   4. Register initial markets");
  console.log("   5. Test orderbook functionality\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:");
    console.error(error);
    process.exit(1);
  });