import * as dotenv from 'dotenv';
import { HardhatUserConfig, task } from 'hardhat/config';
import '@nomiclabs/hardhat-etherscan';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import 'hardhat-gas-reporter';
import 'solidity-coverage';

import 'hardhat-deploy';
import 'hardhat-deploy-ethers';
dotenv.config();
// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task('accounts', 'Prints the list of accounts', async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();
  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.9',
        settings: {
          metadata: {
            bytecodeHash: 'none',
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
      {
        version: '0.7.5',
        settings: {
          metadata: {
            bytecodeHash: 'none',
          },
          optimizer: {
            enabled: true,
            runs: 800,
          },
        },
      },
    ],
    overrides: {
      'contracts/uniswapForTest/BEP20USDT.sol': {
        version: '0.5.16',
        settings: {},
      },
      'contracts/uniswapForTest/UniswapV2Factory.sol': {
        version: '0.5.16',
        settings: {
          evmVersion: 'istanbul',
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  namedAccounts: {
    deployer: 0,
  },
  defaultNetwork: 'hardhat',
  networks: {
    bscTestnet: {
      url: process.env.BSC_TESTNET_URL || '',
      accounts: process.env.BSC_TESTNET_PRIVATE_KEY !== undefined ? [process.env.BSC_TESTNET_PRIVATE_KEY] : [],
      chainId: 97,
    },
    bsc: {
      url: process.env.BSC_URL || '',
      accounts: process.env.BSC_PRIVATE_KEY !== undefined ? [process.env.BSC_PRIVATE_KEY] : [],
      chainId: 56,
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS ? true : false,
    currency: 'USD',
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      rinkeby: process.env.ETHERSCAN_API_KEY,
      // binance smart chain
      bsc: process.env.BSCSCAN_API_KEY,
      bscTestnet: process.env.BSCSCAN_API_KEY,

      polygon: process.env.POLYGONSCAN_API_KEY,
      polygonMumbai: process.env.POLYGONSCAN_API_KEY,
    },
  },
  typechain: {
    outDir: 'typechain',
    target: 'ethers-v5',
    alwaysGenerateOverloads: false,
    externalArtifacts: ['externalArtifacts/*.json'],
  },
  paths: {
    artifacts: './artifacts',
    cache: './cache',
    sources: './contracts',
    tests: './test',
    deploy: './scripts/deploy',
    deployments: './deployments',
  },
  mocha: {
    timeout: 1000000,
  },
};

export default config;
