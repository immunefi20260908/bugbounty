const { ethers } = require('hardhat');

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deploying contracts with the account:', deployer.address);

  const Token = await ethers.getContractFactory('MockToken');
  const token = await Token.deploy('LabToken', 'LAB');
  await token.waitForDeployment();
  console.log('MockToken deployed to:', await token.getAddress());

  const Vault = await ethers.getContractFactory('VulnerableVault');
  const vault = await Vault.deploy(await token.getAddress());
  await vault.waitForDeployment();
  console.log('VulnerableVault deployed to:', await vault.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
