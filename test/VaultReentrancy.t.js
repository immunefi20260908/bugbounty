const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('VulnerableVault reentrancy', function () {
  it('should revert when a reentrancy attack tries to withdraw again before state update', async function () {
    const Token = await ethers.getContractFactory('MockToken');
    const token = await Token.deploy('TestToken', 'TST');
    await token.waitForDeployment();

    const Vault = await ethers.getContractFactory('VulnerableVault');
    const vault = await Vault.deploy(await token.getAddress());
    await vault.waitForDeployment();

    const Attacker = await ethers.getContractFactory('ReentrancyAttacker');
    const attacker = await Attacker.deploy(await vault.getAddress(), await token.getAddress());
    await attacker.waitForDeployment();

    const amount = ethers.parseEther('10');
    await token.mint(await attacker.getAddress(), amount * 3n);
    await token.mint(await vault.getAddress(), amount * 3n);
    await attacker.prepare();

    await expect(attacker.attack()).to.be.revertedWithPanic(0x11);
  });

  it('should settle a flash loan and send the configured fee to the recipient', async function () {
    const [owner] = await ethers.getSigners();
    const Token = await ethers.getContractFactory('MockToken');
    const token = await Token.deploy('TestToken', 'TST');
    await token.waitForDeployment();

    const Vault = await ethers.getContractFactory('VulnerableVault');
    const vault = await Vault.deploy(await token.getAddress());
    await vault.waitForDeployment();
    await vault.setFlashLoanFee(100);

    const Attacker = await ethers.getContractFactory('ReentrancyAttacker');
    const attacker = await Attacker.deploy(await vault.getAddress(), await token.getAddress());
    await attacker.waitForDeployment();

    const amount = ethers.parseEther('10');
    const fee = amount / 100n;
    await token.mint(await vault.getAddress(), amount * 3n);
    await token.mint(await attacker.getAddress(), fee);

    await attacker.attackFlashLoan('0x');

    expect(await token.balanceOf(await vault.getAddress())).to.equal(amount * 3n);
    expect(await token.balanceOf(await owner.getAddress())).to.equal(fee);
  });
});
