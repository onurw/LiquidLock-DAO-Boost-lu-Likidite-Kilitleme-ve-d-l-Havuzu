require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.24",
  networks: {
    hardhat: {}
    // örnek:
    // sepolia: { url: process.env.SEPOLIA_RPC, accounts: [process.env.PRIVATE_KEY] }
  }
};
