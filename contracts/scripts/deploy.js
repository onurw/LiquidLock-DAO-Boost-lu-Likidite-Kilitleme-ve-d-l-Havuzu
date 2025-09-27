const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1) LLT (reward/governance token)
  const LLT = await hre.ethers.getContractFactory("LLToken");
  const llt = await LLT.deploy();
  await llt.waitForDeployment();
  console.log("LLToken:", await llt.getAddress());

  // 2) Gauge: LP olarak testte LLT'yi kullan (gerçekte LP token adresi ver)
  const Gauge = await hre.ethers.getContractFactory("LiquidLockGauge");
  const gauge = await Gauge.deploy(await llt.getAddress(), await llt.getAddress());
  await gauge.waitForDeployment();
  console.log("LiquidLockGauge:", await gauge.getAddress());

  // 3) Örnek fonlama: 100_000 LLT kontrata aktar ve rewardRate = 1 LLT/saniye
  // Not: Gerçekte DAO kasasından fonlanır.
  const fundAmount = hre.ethers.parseEther("100000");
  await llt.transfer(await gauge.getAddress(), fundAmount);
  await gauge.setRewardRate(hre.ethers.parseEther("1"));
  console.log("Funded 100k LLT, rewardRate = 1 LLT/sec");
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
