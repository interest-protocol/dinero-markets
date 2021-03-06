import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import {
  CakeToken,
  CakeVault,
  MasterChef,
  TestCakeVaultV2,
} from '../typechain';
import {
  CAKE,
  CAKE_MASTER_CHEF,
  CAKE_WHALE_ONE,
  CAKE_WHALE_TWO,
} from './lib/constants';
import {
  advanceBlock,
  deployUUPS,
  impersonate,
  upgrade,
} from './lib/test-utils';

const { parseEther } = ethers.utils;

describe('Master Chef CakeVault', () => {
  let cake: CakeToken;
  let cakeVault: CakeVault;
  let masterChef: MasterChef;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;

  // @notice Market does not need to be a contract for testing purposes
  let market: SignerWithAddress;
  let recipient: SignerWithAddress;

  beforeEach(async () => {
    [owner, market, recipient] = await ethers.getSigners();

    cake = await (await ethers.getContractFactory('CakeToken')).attach(CAKE);
    masterChef = await (
      await ethers.getContractFactory('MasterChef')
    ).attach(CAKE_MASTER_CHEF);

    [cakeVault, alice, bob] = await Promise.all([
      deployUUPS('CakeVault', []),
      impersonate(CAKE_WHALE_ONE),
      impersonate(CAKE_WHALE_TWO),
    ]);

    await Promise.all([
      cakeVault.connect(owner).setMarket(market.address),
      cake
        .connect(alice)
        .approve(cakeVault.address, ethers.constants.MaxUint256),
      cake.connect(bob).approve(cakeVault.address, ethers.constants.MaxUint256),
    ]);
  });

  describe('function: initialize', () => {
    it('reverts if you initialize after deployment', async () => {
      await expect(cakeVault.initialize()).to.revertedWith(
        'Initializable: contract is already initialized'
      );
    });

    it('gives maximum approval to the master chef', async () => {
      expect(
        await cake.allowance(cakeVault.address, CAKE_MASTER_CHEF)
      ).to.be.equal(ethers.constants.MaxUint256);
    });

    it('sets an owner', async () => {
      expect(await cakeVault.owner()).to.be.equal(owner.address);
    });
  });

  describe('function: setMarket', () => {
    it('reverts if it is not called byt he owner', async () => {
      await expect(
        cakeVault.connect(alice).setMarket(bob.address)
      ).to.revertedWith('Ownable: caller is not the owner');
    });
    it('reverts if we pass the address zero', async () => {
      await expect(
        cakeVault.connect(owner).setMarket(ethers.constants.AddressZero)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the market is already set', async () => {
      await expect(
        cakeVault.connect(owner).setMarket(bob.address)
      ).to.revertedWith('Vault: already set');
    });
  });

  it('shows the pending rewards in the CAKE pool', async () => {
    expect(await cakeVault.getPendingRewards()).to.be.equal(0);

    await cakeVault
      .connect(market)
      .deposit(alice.address, alice.address, parseEther('10'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    expect(await cakeVault.getPendingRewards()).to.be.equal(
      await masterChef.pendingCake(0, cakeVault.address)
    );
  });
  it('gives full approval to the master chef', async () => {
    await cakeVault
      .connect(market)
      .deposit(alice.address, alice.address, parseEther('10'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    // to get Cake rewards
    await cakeVault.compound();

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    const cakeAllowance = await cake.allowance(
      cakeVault.address,
      masterChef.address
    );

    expect(cakeAllowance.lt(ethers.constants.MaxUint256)).to.be.equal(true);

    await expect(cakeVault.approve())
      .to.emit(cake, 'Approval')
      .withArgs(
        cakeVault.address,
        masterChef.address,
        ethers.constants.MaxUint256
      );

    expect(
      await cake.allowance(cakeVault.address, masterChef.address)
    ).to.be.equal(ethers.constants.MaxUint256);
  });
  it('allows to see how many pending rewards a user has', async () => {
    expect(await cakeVault.getUserPendingRewards(alice.address)).to.be.equal(0);

    await cakeVault
      .connect(market)
      .deposit(alice.address, alice.address, parseEther('10'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    // to get Cake rewards
    await cakeVault.compound();

    cakeVault
      .connect(market)
      .deposit(bob.address, bob.address, parseEther('20'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    await Promise.all([
      cakeVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('20')),
      cakeVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('15')),
    ]);

    // to get Cake rewards
    await cakeVault.compound();

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    const [
      totalAmount,
      totalRewardsPerAmount,
      pendingRewards,
      aliceInfo,
      bobInfo,
    ] = await Promise.all([
      cakeVault.totalAmount(),
      cakeVault.totalRewardsPerAmount(),
      cakeVault.getPendingRewards(),
      cakeVault.userInfo(alice.address),
      cakeVault.userInfo(bob.address),
    ]);

    const rewardsPerAmount = totalRewardsPerAmount.add(
      pendingRewards.mul(parseEther('1')).div(totalAmount)
    );

    const aliceRewards = aliceInfo.rewards.add(
      rewardsPerAmount
        .mul(parseEther('30'))
        .div(parseEther('1'))
        .sub(aliceInfo.rewardDebt)
    );

    const bobRewards = bobInfo.rewards.add(
      rewardsPerAmount
        .mul(parseEther('35'))
        .div(parseEther('1'))
        .sub(bobInfo.rewardDebt)
    );

    expect(await cakeVault.getUserPendingRewards(alice.address)).to.be.equal(
      aliceRewards
    );

    expect(await cakeVault.getUserPendingRewards(bob.address)).to.be.equal(
      bobRewards
    );

    expect(await cakeVault.getUserPendingRewards(owner.address)).to.be.equal(0);

    // @notice pending rewards need to account for current pending cake in the pool + the auto compounded cake
    expect(aliceRewards.add(bobRewards)).to.be.equal(
      totalRewardsPerAmount
        .add(pendingRewards.mul(parseEther('1')).div(totalAmount))
        .mul(parseEther('65'))
        .div(parseEther('1'))
        .sub(aliceInfo.rewardDebt)
        .sub(bobInfo.rewardDebt)
        .add(aliceInfo.rewards)
        .add(bobInfo.rewards)
    );
  });
  it('reinvests the Cake rewards from Cake pool back in the Cake pool', async () => {
    await Promise.all([
      cakeVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('10')),
      cakeVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('30')),
    ]);

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    const [
      pendingRewards,
      totalRewardsPerAmount,
      masterChefUserInfo,
      masterChefPendingCake,
      marketCakeBalance,
    ] = await Promise.all([
      cakeVault.getPendingRewards(),
      cakeVault.totalRewardsPerAmount(),
      masterChef.userInfo(0, cakeVault.address),
      masterChef.pendingCake(0, cakeVault.address),
      cake.balanceOf(market.address),
    ]);

    // There are pending rewards that can be compounded
    expect(pendingRewards).to.be.not.equal(0);
    expect(pendingRewards).to.be.equal(masterChefPendingCake);

    expect(marketCakeBalance).to.be.equal(0);

    await expect(cakeVault.connect(market).compound())
      .to.emit(cakeVault, 'Compound')
      .to.emit(masterChef, 'Deposit')
      .to.emit(masterChef, 'Withdraw')
      .withArgs(cakeVault.address, 0, 0);

    const [
      pendingRewards2,
      totalRewardsPerAmount2,
      totalAmount,
      masterChefUserInfo2,
    ] = await Promise.all([
      cakeVault.getPendingRewards(),
      cakeVault.totalRewardsPerAmount(),
      cakeVault.totalAmount(),
      masterChef.userInfo(0, cakeVault.address),
    ]);

    // Due to delays it is possible that we already accumulated some rewards after compounding
    // So we test that there are less rewards after compounding
    expect(pendingRewards.gt(pendingRewards2)).to.be.equal(true);
    // Test that the `CAKE` pool amount increased more than the pending rewards before compound
    expect(
      masterChefUserInfo2.amount.gt(
        masterChefUserInfo.amount.add(pendingRewards)
      )
    ).to.be.equal(true);
    // Properly updated the totalRewardsPerAmount
    expect(totalRewardsPerAmount2).to.be.equal(
      totalRewardsPerAmount.add(
        masterChefUserInfo2.amount
          .sub(masterChefUserInfo.amount)
          .mul(parseEther('1'))
          .div(totalAmount)
      )
    );
    // Paid the `msg.sender`
    expect((await cake.balanceOf(market.address)).gt(0)).to.be.equal(true);
  });
  describe('function: deposit', () => {
    it('reverts if the amount is 0', async () => {
      await expect(
        cakeVault.connect(market).deposit(alice.address, alice.address, 0)
      ).to.revertedWith('Vault: no zero amount');
    });
    it('reverts if the first parameter is the zero address', async () => {
      await expect(
        cakeVault
          .connect(market)
          .deposit(ethers.constants.AddressZero, alice.address, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the second parameter is the zero address', async () => {
      await expect(
        cakeVault
          .connect(market)
          .deposit(alice.address, ethers.constants.AddressZero, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the msg.sender is not the market', async () => {
      await expect(
        cakeVault.connect(owner).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        cakeVault.connect(alice).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        cakeVault.connect(bob).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
    });
    it('allows deposits', async () => {
      const [
        aliceInfo,
        bobInfo,
        totalAmount,
        totalRewardsPerAmount,
        masterChefCakePool,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.userInfo(bob.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
      ]);

      expect(aliceInfo.rewardDebt).to.be.equal(0);
      expect(aliceInfo.rewards).to.be.equal(0);
      expect(aliceInfo.amount).to.be.equal(0);
      expect(bobInfo.rewardDebt).to.be.equal(0);
      expect(bobInfo.rewards).to.be.equal(0);
      expect(bobInfo.amount).to.be.equal(0);
      expect(totalAmount).to.be.equal(0);
      expect(totalRewardsPerAmount).to.be.equal(0);
      expect(masterChefCakePool.amount).to.be.equal(0);

      await expect(
        cakeVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20'))
      )
        .to.emit(cakeVault, 'Deposit')
        .withArgs(alice.address, alice.address, parseEther('20'))
        .to.emit(masterChef, 'Deposit')
        .withArgs(cakeVault.address, 0, parseEther('20'))
        .to.emit(cake, 'Transfer')
        .withArgs(cakeVault.address, masterChef.address, parseEther('20'))
        .to.emit(cake, 'Transfer')
        .withArgs(alice.address, cakeVault.address, parseEther('20'));

      const [
        aliceInfo2,
        totalAmount2,
        totalRewardsPerAmount2,
        masterChefCakePool2,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
      ]);

      // @notice first deposit has no rewards
      expect(aliceInfo2.rewardDebt).to.be.equal(0);
      expect(aliceInfo2.rewards).to.be.equal(0);
      expect(aliceInfo2.amount).to.be.equal(parseEther('20'));
      expect(totalAmount2).to.be.equal(parseEther('20'));
      expect(totalRewardsPerAmount2).to.be.equal(0);
      expect(masterChefCakePool2.amount).to.be.equal(parseEther('20'));

      await expect(
        cakeVault
          .connect(market)
          // Here Alice is deposing for Bob
          .deposit(alice.address, alice.address, parseEther('10'))
      )
        .to.emit(cakeVault, 'Deposit')
        .withArgs(alice.address, alice.address, parseEther('10'))
        .to.emit(masterChef, 'Deposit')
        .to.emit(cake, 'Transfer')
        .withArgs(alice.address, cakeVault.address, parseEther('10'));

      const [
        aliceInfo3,
        totalAmount3,
        totalRewardsPerAmount3,
        masterChefCakePool3,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
      ]);

      expect(aliceInfo3.rewardDebt).to.be.equal(
        totalRewardsPerAmount3.mul(parseEther('30')).div(parseEther('1'))
      );
      expect(aliceInfo3.rewards).to.be.equal(
        totalRewardsPerAmount3.mul(parseEther('20')).div(parseEther('1'))
      );
      expect(aliceInfo3.amount).to.be.equal(parseEther('30'));
      expect(totalAmount3).to.be.equal(parseEther('30'));
      expect(totalRewardsPerAmount3).to.be.equal(
        totalRewardsPerAmount2
          .add(masterChefCakePool3.amount)
          .sub(parseEther('30'))
          .mul(parseEther('1'))
          .div(totalAmount2)
      );

      // Hard to calculate precise Cake reward. if it has more than the total amount it means rewards were compounded
      expect(masterChefCakePool3.amount.gt(parseEther('30'))).to.be.equal(true);

      await expect(
        cakeVault
          .connect(market)
          // Here Alice is deposing for Bob
          .deposit(alice.address, bob.address, parseEther('10'))
      )
        .to.emit(cakeVault, 'Deposit')
        .withArgs(alice.address, bob.address, parseEther('10'))
        .to.emit(masterChef, 'Deposit')
        .to.emit(cake, 'Transfer')
        .withArgs(alice.address, cakeVault.address, parseEther('10'));

      const [
        aliceInfo4,
        bobInfo2,
        totalAmount4,
        totalRewardsPerAmount4,
        masterChefCakePool4,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.userInfo(bob.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
      ]);

      // Nothing changes for alice
      expect(aliceInfo4.rewardDebt).to.be.equal(aliceInfo3.rewardDebt);
      expect(aliceInfo4.rewards).to.be.equal(aliceInfo3.rewards);
      expect(aliceInfo4.amount).to.be.equal(aliceInfo3.amount);

      // Bob user info gets updated
      expect(bobInfo2.rewardDebt).to.be.equal(
        totalRewardsPerAmount4.mul(parseEther('10')).div(parseEther('1'))
      );
      expect(bobInfo2.rewards).to.be.equal(0);
      expect(bobInfo2.amount).to.be.equal(parseEther('10'));

      expect(totalAmount4).to.be.equal(parseEther('40'));

      expect(totalRewardsPerAmount4).to.be.equal(
        totalRewardsPerAmount3.add(
          masterChefCakePool4.amount
            .sub(masterChefCakePool3.amount)
            .sub(parseEther('10'))
            .mul(parseEther('1'))
            .div(totalAmount3)
        )
      );

      // Hard to calculate precise Cake reward. if it has more than the total amount it means rewards were compounded
      expect(masterChefCakePool4.amount.gt(parseEther('40'))).to.be.equal(true);
    });
  });
  describe('function: withdraw', () => {
    it('reverts if the amount is 0', async () => {
      await expect(
        cakeVault.connect(market).withdraw(alice.address, alice.address, 0)
      ).to.revertedWith('Vault: no zero amount');
    });
    it('reverts if the account that is withdrawing is the zero address', async () => {
      await expect(
        cakeVault
          .connect(market)
          .withdraw(ethers.constants.AddressZero, alice.address, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the recipient of the tokens and rewards is the zero address', async () => {
      await expect(
        cakeVault
          .connect(market)
          .withdraw(alice.address, ethers.constants.AddressZero, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if there are no tokens deposited in the vault', async () => {
      await expect(
        cakeVault.connect(market).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: no tokens');
    });
    it('reverts if the msg.sender is not the market', async () => {
      await expect(
        cakeVault.connect(owner).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        cakeVault.connect(alice).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        cakeVault.connect(bob).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
    });
    it('reverts if the msg.sender tries to withdraw more than the account has', async () => {
      await cakeVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('20'));

      await expect(
        cakeVault
          .connect(market)
          .withdraw(alice.address, alice.address, parseEther('20.1'))
      ).to.revertedWith('Vault: not enough tokens');
    });
    it('withdraws to one recipient and restakes Cake', async () => {
      await cakeVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('1000'));

      await cakeVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('30'));

      await network.provider.send('hardhat_mine', [
        `0x${Number(100_000).toString(16)}`,
      ]);

      await network.provider.send('hardhat_setNextBlockBaseFeePerGas', ['0x0']);

      await expect(
        cakeVault
          .connect(market)
          .withdraw(bob.address, bob.address, parseEther('0.1'))
      )
        .to.emit(masterChef, 'Withdraw')
        .withArgs(cakeVault.address, 0, parseEther('0.1'))
        .to.emit(cake, 'Transfer');
    });
    it('market to withdraw assets', async () => {
      await Promise.all([
        cakeVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20')),
        cakeVault
          .connect(market)
          .deposit(bob.address, bob.address, parseEther('30')),
      ]);

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      const [
        aliceInfo,
        totalAmount,
        totalRewardsPerAmount,
        masterChefCakePool,
        recipientCakeBalance,
        aliceCakeBalance,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
        cake.balanceOf(recipient.address),
        cake.balanceOf(alice.address),
      ]);

      expect(aliceInfo.amount).to.be.equal(parseEther('20'));
      expect(aliceInfo.rewardDebt).to.be.equal(0); // @notice she was the first to deposit
      expect(totalAmount).to.be.equal(parseEther('50'));
      expect(recipientCakeBalance).to.be.equal(0);
      // Cuz rewards got compounded
      expect(masterChefCakePool.amount.gt(parseEther('50'))).to.be.equal(true);

      await expect(
        cakeVault
          .connect(market)
          .withdraw(alice.address, recipient.address, parseEther('10'))
      )
        .to.emit(masterChef, 'Withdraw')
        .withArgs(cakeVault.address, 0, parseEther('10'))
        .to.emit(cake, 'Transfer')
        .withArgs(masterChef.address, cakeVault.address, parseEther('10'));

      const [
        aliceInfo2,
        totalAmount2,
        totalRewardsPerAmount2,
        masterChefCakePool2,
        recipientCakeBalance2,
        aliceCakeBalance2,
      ] = await Promise.all([
        cakeVault.userInfo(alice.address),
        cakeVault.totalAmount(),
        cakeVault.totalRewardsPerAmount(),
        masterChef.userInfo(0, cakeVault.address),
        cake.balanceOf(recipient.address),
        cake.balanceOf(alice.address),
      ]);

      expect(aliceInfo2.amount).to.be.equal(parseEther('10'));
      expect(aliceInfo2.rewardDebt).to.be.equal(
        totalRewardsPerAmount2.mul(parseEther('10')).div(parseEther('1'))
      );
      expect(aliceInfo2.rewards).to.be.equal(0);
      expect(totalRewardsPerAmount2.gt(totalRewardsPerAmount)).to.be.equal(
        true
      );
      expect(totalRewardsPerAmount2.isZero()).to.be.equal(false);
      // Means pool has rewards
      expect(masterChefCakePool2.amount.gt(totalAmount2)).to.be.equal(true);
      expect(totalAmount2).to.be.equal(parseEther('40'));
      // Means recipient got the cake amount + rewards
      expect(recipientCakeBalance2.eq(parseEther('10'))).to.be.equal(true);
      // Alice cake balance increase after withdraw it means she got the rewards
      expect(aliceCakeBalance2.gt(aliceCakeBalance)).to.be.equal(true);

      await Promise.all([
        cakeVault
          .connect(market)
          .withdraw(alice.address, recipient.address, parseEther('10')),
        cakeVault
          .connect(market)
          .withdraw(bob.address, recipient.address, parseEther('30')),
      ]);

      const [bobInfo, totalAmount3, totalRewardsPerAmount3] = await Promise.all(
        [
          cakeVault.userInfo(bob.address),
          cakeVault.totalAmount(),
          cakeVault.totalRewardsPerAmount(),
        ]
      );

      expect(bobInfo.rewardDebt).to.be.equal(0);
      expect(bobInfo.amount).to.be.equal(0);
      expect(totalAmount3).to.be.equal(0);
      expect(totalRewardsPerAmount3).to.be.equal(0);
    });
  });
  describe('Upgrade functionality', () => {
    it('reverts if the non-owner tries to upgrade', async () => {
      await cakeVault.connect(owner).transferOwnership(alice.address);

      await expect(upgrade(cakeVault, 'TestCakeVaultV2')).to.revertedWith(
        'Ownable: caller is not the owner'
      );
    });

    it('upgrades to version 2', async () => {
      expect(await cakeVault.getUserPendingRewards(alice.address)).to.be.equal(
        0
      );

      await cakeVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('10'));

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      // to get Cake rewards
      await cakeVault.compound();

      cakeVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('20'));

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      await Promise.all([
        cakeVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20')),
        cakeVault
          .connect(market)
          .deposit(bob.address, bob.address, parseEther('15')),
      ]);

      // to get Cake rewards
      await cakeVault.compound();

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      // Upgrade function takes time to process
      const cakeVaultV2: TestCakeVaultV2 = await upgrade(
        cakeVault,
        'TestCakeVaultV2'
      );

      const [
        totalAmount,
        totalRewardsPerAmount,
        pendingRewards,
        aliceInfo,
        bobInfo,
      ] = await Promise.all([
        cakeVaultV2.totalAmount(),
        cakeVaultV2.totalRewardsPerAmount(),
        cakeVaultV2.getPendingRewards(),
        cakeVaultV2.userInfo(alice.address),
        cakeVaultV2.userInfo(bob.address),
      ]);

      const rewardsPerAmount = totalRewardsPerAmount.add(
        pendingRewards.mul(parseEther('1')).div(totalAmount)
      );

      const aliceRewards = aliceInfo.rewards.add(
        rewardsPerAmount
          .mul(parseEther('30'))
          .div(parseEther('1'))
          .sub(aliceInfo.rewardDebt)
      );

      const bobRewards = bobInfo.rewards.add(
        rewardsPerAmount
          .mul(parseEther('35'))
          .div(parseEther('1'))
          .sub(bobInfo.rewardDebt)
      );

      const [
        alicePendingRewards,
        bobPendingRewards,
        ownerPendingRewards,
        version,
      ] = await Promise.all([
        cakeVaultV2.getUserPendingRewards(alice.address),
        cakeVaultV2.getUserPendingRewards(bob.address),
        cakeVaultV2.getUserPendingRewards(owner.address),
        cakeVaultV2.version(),
      ]);

      expect(alicePendingRewards).to.be.equal(aliceRewards);

      expect(bobPendingRewards).to.be.equal(bobRewards);

      expect(ownerPendingRewards).to.be.equal(0);

      expect(version).to.be.equal('V2');

      // @notice pending rewards need to account for current pending cake in the pool + the auto compounded cake
      expect(aliceRewards.add(bobRewards)).to.be.equal(
        totalRewardsPerAmount
          .add(pendingRewards.mul(parseEther('1')).div(totalAmount))
          .mul(parseEther('65'))
          .div(parseEther('1'))
          .sub(aliceInfo.rewardDebt)
          .sub(bobInfo.rewardDebt)
          .add(aliceInfo.rewards)
          .add(bobInfo.rewards)
      );
    });
  });
}).timeout(4000);
