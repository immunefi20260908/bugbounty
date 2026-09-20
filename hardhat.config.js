require('dotenv').config();
require('@nomicfoundation/hardhat-toolbox');

const rawPrivateKey = process.env.PRIVATE_KEY || '';
const validPrivateKey =
  rawPrivateKey.startsWith('0x') && rawPrivateKey.length === 66 ? [rawPrivateKey] : [];

module.exports = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    localhost: {
      url: 'http://127.0.0.1:8545'
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org',
      accounts: validPrivateKey
    }
  },
  etherscan: {
    apiKey: {
      baseSepolia: process.env.ETHERSCAN_API_KEY || ''
    }
  }
};
