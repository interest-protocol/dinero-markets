import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers, network } from 'hardhat';

import ERC20ABI from '../abi/erc20.json';
import MasterChefABI from '../abi/master-chef.json';
import { ERC20, LPVault, MasterChef, TestLPVaultV2 } from '../typechain';
import {
  CAKE,
  CAKE_MASTER_CHEF,
  WBNB_CAKE_LP_HOLDER,
  WBNB_CAKE_LP_HOLDER_TWO,
  WBNB_CAKE_LP_TOKEN_POOL_ID,
  WBNB_CAKE_PAIR_LP_TOKEN,
} from './lib/constants';
import {
  advanceBlock,
  deployUUPS,
  impersonate,
  upgrade,
} from './lib/test-utils';

const { parseEther } = ethers.utils;

describe('Master Chef LPVault', () => {
  let lpVault: LPVault;
  const CakeContract = new ethers.Contract(
    CAKE,
    ERC20ABI,
    ethers.provider
  ) as ERC20;
  const LPTokenContract = new ethers.Contract(
    WBNB_CAKE_PAIR_LP_TOKEN,
    ERC20ABI,
    ethers.provider
  ) as ERC20;
  const MasterChefContract = new ethers.Contract(
    CAKE_MASTER_CHEF,
    MasterChefABI,
    ethers.provider
  ) as MasterChef;

  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;

  // @notice Market does not need to be a contract for testing purposes
  let market: SignerWithAddress;
  let recipient: SignerWithAddress;

  beforeEach(async () => {
    [owner, market, recipient] = await ethers.getSigners();

    [lpVault, alice, bob] = await Promise.all([
      deployUUPS('LPVault', [
        WBNB_CAKE_PAIR_LP_TOKEN,
        WBNB_CAKE_LP_TOKEN_POOL_ID,
      ]),
      impersonate(WBNB_CAKE_LP_HOLDER),
      impersonate(WBNB_CAKE_LP_HOLDER_TWO),
    ]);

    await Promise.all([
      recipient.sendTransaction({ to: alice.address, value: parseEther('10') }),
      recipient.sendTransaction({ to: bob.address, value: parseEther('10') }),
      lpVault.connect(owner).setMarket(market.address),
    ]);

    await Promise.all([
      LPTokenContract.connect(alice).approve(
        lpVault.address,
        ethers.constants.MaxUint256
      ),
      LPTokenContract.connect(bob).approve(
        lpVault.address,
        ethers.constants.MaxUint256
      ),
    ]);
  });

  describe('function: initialize', () => {
    it('reverts if you initialize after deployment', async () => {
      await expect(
        lpVault.initialize(WBNB_CAKE_PAIR_LP_TOKEN, WBNB_CAKE_LP_TOKEN_POOL_ID)
      ).to.revertedWith('Initializable: contract is already initialized');
    });

    it('gives maximum approval to the master chef', async () => {
      expect(
        await CakeContract.allowance(lpVault.address, CAKE_MASTER_CHEF)
      ).to.be.equal(ethers.constants.MaxUint256);
      expect(
        await LPTokenContract.allowance(lpVault.address, CAKE_MASTER_CHEF)
      ).to.be.equal(ethers.constants.MaxUint256);
    });

    it('reverts if the pool id is 0', async () => {
      expect(
        deployUUPS('LPVault', [WBNB_CAKE_PAIR_LP_TOKEN, 0])
      ).to.revertedWith('LPVault: this is a LP vault');
    });

    it('sets the initial state correctly', async () => {
      const [_market, _stakingToken, _poolId] = await Promise.all([
        lpVault.MARKET(),
        lpVault.STAKING_TOKEN(),
        lpVault.POOL_ID(),
      ]);

      expect(_market).to.be.equal(market.address);
      expect(_stakingToken).to.be.equal(WBNB_CAKE_PAIR_LP_TOKEN);
      expect(_poolId).to.be.equal(WBNB_CAKE_LP_TOKEN_POOL_ID);
    });
  });

  describe('function: setMarket', () => {
    it('reverts if it is not called by the owner', async () => {
      await expect(
        lpVault.connect(alice).setMarket(bob.address)
      ).to.revertedWith('Ownable: caller is not the owner');
    });
    it('reverts if we pass the address zero', async () => {
      await expect(
        lpVault.connect(owner).setMarket(ethers.constants.AddressZero)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the market is already set', async () => {
      await expect(
        lpVault.connect(owner).setMarket(bob.address)
      ).to.revertedWith('Vault: already set');
    });
    it('sets the market', async () => {
      const vault = (await deployUUPS('LPVault', [
        WBNB_CAKE_PAIR_LP_TOKEN,
        WBNB_CAKE_LP_TOKEN_POOL_ID,
      ])) as LPVault;

      expect(await vault.MARKET()).to.be.equal(ethers.constants.AddressZero);

      await vault.connect(owner).setMarket(owner.address);

      expect(await vault.MARKET()).to.be.equal(owner.address);
    });
  });

  it('shows the pending rewards in the CAKE and lp token pools', async () => {
    expect(await lpVault.getPendingRewards()).to.be.equal(0);

    await lpVault
      .connect(market)
      .deposit(alice.address, alice.address, parseEther('100'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    // to get Cake rewards
    await lpVault.compound();

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    const [cakePoolRewards, farmRewards, pendingRewards] = await Promise.all([
      MasterChefContract.pendingCake(0, lpVault.address),
      MasterChefContract.pendingCake(
        WBNB_CAKE_LP_TOKEN_POOL_ID,
        lpVault.address
      ),
      lpVault.getPendingRewards(),
    ]);

    expect(pendingRewards).to.be.equal(cakePoolRewards.add(farmRewards));
  });

  it('increases allowance to masterchef for cake and staking token', async () => {
    await Promise.all([
      lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('300')),
      lpVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('100')),
    ]);

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    // to get Cake rewards
    await lpVault.compound();

    const [lpTokenAllowance, cakeAllowance] = await Promise.all([
      LPTokenContract.allowance(lpVault.address, MasterChefContract.address),
      CakeContract.allowance(lpVault.address, MasterChefContract.address),
    ]);

    expect(lpTokenAllowance).to.be.equal(ethers.constants.MaxUint256);
    expect(cakeAllowance.lt(ethers.constants.MaxUint256)).to.be.equal(true);

    await expect(lpVault.approve())
      .to.emit(CakeContract, 'Approval')
      .withArgs(
        lpVault.address,
        MasterChefContract.address,
        ethers.constants.MaxUint256
      );

    expect(
      await CakeContract.allowance(lpVault.address, MasterChefContract.address)
    ).to.be.equal(ethers.constants.MaxUint256);
  });

  it('allows to see how many pending rewards a user has', async () => {
    expect(await lpVault.getUserPendingRewards(alice.address)).to.be.equal(0);

    await lpVault
      .connect(market)
      .deposit(alice.address, alice.address, parseEther('10'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    // to get Cake rewards
    await lpVault.compound();

    lpVault.connect(market).deposit(bob.address, bob.address, parseEther('20'));

    // accrue some cake
    await advanceBlock(ethers);
    await advanceBlock(ethers);

    await Promise.all([
      lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('20')),
      lpVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('15')),
    ]);

    // to get Cake rewards
    await lpVault.compound();

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
      lpVault.totalAmount(),
      lpVault.totalRewardsPerAmount(),
      lpVault.getPendingRewards(),
      lpVault.userInfo(alice.address),
      lpVault.userInfo(bob.address),
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

    expect(await lpVault.getUserPendingRewards(alice.address)).to.be.equal(
      aliceRewards
    );

    expect(await lpVault.getUserPendingRewards(bob.address)).to.be.equal(
      bobRewards
    );

    expect(await lpVault.getUserPendingRewards(owner.address)).to.be.equal(0);

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

  it('reinvests the Cake rewards from the farm and Cake pool back in the Cake pool', async () => {
    await Promise.all([
      lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('10')),
      lpVault
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
      aliceCakeBalance,
    ] = await Promise.all([
      lpVault.getPendingRewards(),
      lpVault.totalRewardsPerAmount(),
      MasterChefContract.userInfo(0, lpVault.address),
      CakeContract.balanceOf(alice.address),
    ]);

    // There are pending rewards that can be compounded
    expect(pendingRewards).to.be.not.equal(0);

    await expect(lpVault.connect(alice).compound())
      .to.emit(lpVault, 'Compound')
      .to.emit(MasterChefContract, 'Deposit')
      .to.emit(MasterChefContract, 'Withdraw');

    const [
      pendingRewards2,
      totalRewardsPerAmount2,
      totalAmount,
      masterChefUserInfo2,
      aliceCakeBalance2,
    ] = await Promise.all([
      lpVault.getPendingRewards(),
      lpVault.totalRewardsPerAmount(),
      lpVault.totalAmount(),
      MasterChefContract.userInfo(0, lpVault.address),
      CakeContract.balanceOf(alice.address),
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
    expect(aliceCakeBalance2.gt(aliceCakeBalance)).to.be.equal(true);
  });

  describe('function: deposit', () => {
    it('reverts if the amount is smaller or 0', async () => {
      await expect(
        lpVault.connect(market).deposit(alice.address, alice.address, 0)
      ).to.revertedWith('Vault: no zero amount');
    });
    it('reverts if the first parameter is the zero address', async () => {
      await expect(
        lpVault
          .connect(market)
          .deposit(ethers.constants.AddressZero, alice.address, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the second parameter is the zero address', async () => {
      await expect(
        lpVault
          .connect(market)
          .deposit(alice.address, ethers.constants.AddressZero, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the msg.sender is not the market', async () => {
      await expect(
        lpVault.connect(owner).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        lpVault.connect(alice).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        lpVault.connect(bob).deposit(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
    });
    it('allows deposits', async () => {
      const [
        aliceInfo,
        totalAmount,
        totalRewardsPerAmount,
        masterChefCakePool,
        masterChefLpPool,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
      ]);

      expect(aliceInfo.rewardDebt).to.be.equal(0);
      expect(aliceInfo.rewards).to.be.equal(0);
      expect(aliceInfo.amount).to.be.equal(0);
      expect(totalAmount).to.be.equal(0);
      expect(totalRewardsPerAmount).to.be.equal(0);
      expect(masterChefCakePool.amount).to.be.equal(0);
      expect(masterChefLpPool.amount).to.be.equal(0);

      await expect(
        lpVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20'))
      )
        .to.emit(lpVault, 'Deposit')
        .withArgs(alice.address, alice.address, parseEther('20'))
        .to.emit(MasterChefContract, 'Deposit')
        .withArgs(lpVault.address, WBNB_CAKE_LP_TOKEN_POOL_ID, parseEther('20'))
        .to.emit(LPTokenContract, 'Transfer')
        .withArgs(alice.address, lpVault.address, parseEther('20'));

      const [
        aliceInfo2,
        totalAmount2,
        totalRewardsPerAmount2,
        masterChefCakePool2,
        masterChefLpPool2,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
      ]);

      expect(aliceInfo2.rewardDebt).to.be.equal(0);
      expect(aliceInfo2.rewards).to.be.equal(0);
      expect(aliceInfo2.amount).to.be.equal(parseEther('20'));
      expect(totalAmount2).to.be.equal(parseEther('20'));
      expect(totalRewardsPerAmount2).to.be.equal(0);
      expect(masterChefCakePool2.amount).to.be.equal(0);
      expect(masterChefLpPool2.amount).to.be.equal(parseEther('20'));

      await expect(
        lpVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('10'))
      )
        .to.emit(lpVault, 'Deposit')
        .withArgs(alice.address, alice.address, parseEther('10'))
        .to.emit(MasterChefContract, 'Deposit')
        .withArgs(lpVault.address, WBNB_CAKE_PAIR_LP_TOKEN, parseEther('10'))
        // Rewards were reinvested to Cake Pool
        .to.emit(MasterChefContract, 'Deposit')
        // Rewards were taken from lpToken Farm
        .withArgs(lpVault.address, WBNB_CAKE_PAIR_LP_TOKEN, 0)
        .to.emit(LPTokenContract, 'Transfer')
        .withArgs(alice.address, lpVault.address, parseEther('10'));

      const [
        aliceInfo3,
        bobInfo,
        totalAmount3,
        totalRewardsPerAmount3,
        masterChefCakePool3,
        masterChefLpPool3,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.userInfo(bob.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
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
          .mul(parseEther('1'))
          .div(totalAmount2)
      );
      // Hard to calculate precise Cake reward
      expect(masterChefCakePool3.amount.gt(0)).to.be.equal(true);
      expect(masterChefLpPool3.amount).to.be.equal(parseEther('30'));

      expect(bobInfo.amount).to.be.equal(0);
      expect(bobInfo.rewardDebt).to.be.equal(0);
      expect(bobInfo.rewards).to.be.equal(0);

      await expect(
        lpVault
          .connect(market)
          .deposit(alice.address, bob.address, parseEther('10'))
      )
        .to.emit(lpVault, 'Deposit')
        .withArgs(alice.address, bob.address, parseEther('10'))
        .to.emit(MasterChefContract, 'Deposit')
        .withArgs(lpVault.address, WBNB_CAKE_LP_TOKEN_POOL_ID, parseEther('10'))
        // Rewards were reinvested to Cake Pool
        .to.emit(MasterChefContract, 'Deposit')
        // Rewards were taken from lpToken Farm
        .withArgs(lpVault.address, WBNB_CAKE_LP_TOKEN_POOL_ID, 0)
        .to.emit(LPTokenContract, 'Transfer')
        .withArgs(alice.address, lpVault.address, parseEther('10'));

      const [
        aliceInfo4,
        bobInfo2,
        totalAmount4,
        totalRewardsPerAmount4,
        masterChefCakePool4,
        masterChefLpPool4,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.userInfo(bob.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
      ]);

      // Alice info does not change
      expect(aliceInfo3.rewardDebt).to.be.equal(aliceInfo4.rewardDebt);
      expect(aliceInfo3.rewards).to.be.equal(aliceInfo4.rewards);
      expect(aliceInfo3.amount).to.be.equal(aliceInfo4.amount);

      // Bob info gets updated
      expect(bobInfo2.amount).to.be.equal(parseEther('10'));
      expect(bobInfo2.rewards).to.be.equal(0);
      expect(bobInfo2.rewardDebt).to.be.equal(
        totalRewardsPerAmount4.mul(parseEther('10')).div(parseEther('1'))
      );
      expect(totalAmount4).to.be.equal(totalAmount3.add(parseEther('10')));
      expect(masterChefLpPool4.amount).to.be.equal(
        masterChefLpPool3.amount.add(parseEther('10'))
      );
      expect(totalRewardsPerAmount4).to.be.equal(
        totalRewardsPerAmount3.add(
          masterChefCakePool4.amount
            .sub(masterChefCakePool3.amount)
            .mul(parseEther('1'))
            .div(totalAmount3)
        )
      );
    });
  });

  describe('function: withdraw', () => {
    it('reverts if the amount is 0', async () => {
      await expect(
        lpVault.connect(market).withdraw(alice.address, alice.address, 0)
      ).to.revertedWith('Vault: no zero amount');
    });
    it('reverts if the account that is withdrawing is the zero address', async () => {
      await expect(
        lpVault
          .connect(market)
          .withdraw(ethers.constants.AddressZero, alice.address, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if the recipient of the tokens and rewards is the zero address', async () => {
      await expect(
        lpVault
          .connect(market)
          .withdraw(alice.address, ethers.constants.AddressZero, 10)
      ).to.revertedWith('Vault: no zero address');
    });
    it('reverts if there are no tokens deposited in the vault', async () => {
      await expect(
        lpVault.connect(market).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: no tokens');
    });
    it('reverts if the msg.sender is not the market', async () => {
      await expect(
        lpVault.connect(owner).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        lpVault.connect(alice).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
      await expect(
        lpVault.connect(bob).withdraw(alice.address, alice.address, 10)
      ).to.revertedWith('Vault: only market');
    });
    it('reverts if the msg.sender tries to withdraw more than the account has', async () => {
      await lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('20'));

      await expect(
        lpVault
          .connect(market)
          .withdraw(alice.address, alice.address, parseEther('20.1'))
      ).to.revertedWith('Vault: not enough tokens');
    });
    it('withdraws to one recipient and restakes Cake', async () => {
      await lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('300'));

      await lpVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('30'));

      await network.provider.send('hardhat_mine', [
        `0x${Number(100_000).toString(16)}`,
      ]);

      await network.provider.send('hardhat_setNextBlockBaseFeePerGas', ['0x0']);

      await expect(
        lpVault
          .connect(market)
          .withdraw(bob.address, bob.address, parseEther('0.1'))
      )
        .to.emit(MasterChefContract, 'Withdraw')
        .withArgs(lpVault.address, 0, parseEther('0.1'))
        .to.emit(CakeContract, 'Transfer');

      await lpVault
        .connect(market)
        .withdraw(alice.address, alice.address, parseEther('300'));

      await lpVault
        .connect(market)
        .withdraw(bob.address, bob.address, parseEther('29.9'));
    });
    it('market to withdraw assets', async () => {
      await Promise.all([
        lpVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20')),
        lpVault
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
        masterChefLpPool,
        recipientLpTokenBalance,
        aliceCakeBalance,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
        LPTokenContract.balanceOf(recipient.address),
        CakeContract.balanceOf(alice.address),
      ]);

      expect(aliceInfo.amount).to.be.equal(parseEther('20'));
      expect(aliceInfo.rewardDebt).to.be.equal(0); // @notice she was the first to deposit
      expect(totalAmount).to.be.equal(parseEther('50'));
      expect(masterChefLpPool.amount).to.be.equal(parseEther('50'));
      expect(recipientLpTokenBalance).to.be.equal(0);
      expect(masterChefCakePool.amount.gt(0)).to.be.equal(true);

      await expect(
        lpVault
          .connect(market)
          .withdraw(alice.address, recipient.address, parseEther('10'))
      )
        .to.emit(MasterChefContract, 'Withdraw')
        .withArgs(lpVault.address, 0, 0)
        .to.emit(MasterChefContract, 'Withdraw')
        .withArgs(lpVault.address, 1, parseEther('10'))
        .to.emit(CakeContract, 'Transfer')
        .to.emit(LPTokenContract, 'Transfer')
        .withArgs(lpVault.address, recipient.address, parseEther('10'));

      const [
        aliceInfo2,
        totalAmount2,
        totalRewardsPerAmount2,
        masterChefCakePool2,
        masterChefLpPool2,
        recipientLpTokenBalance2,
        aliceCakeBalance2,
      ] = await Promise.all([
        lpVault.userInfo(alice.address),
        lpVault.totalAmount(),
        lpVault.totalRewardsPerAmount(),
        MasterChefContract.userInfo(0, lpVault.address),
        MasterChefContract.userInfo(
          WBNB_CAKE_LP_TOKEN_POOL_ID,
          lpVault.address
        ),
        LPTokenContract.balanceOf(recipient.address),
        CakeContract.balanceOf(alice.address),
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
      expect(totalAmount2).to.be.equal(parseEther('40'));
      expect(masterChefLpPool2.amount).to.be.equal(parseEther('40'));
      expect(recipientLpTokenBalance2).to.be.equal(parseEther('10'));
      expect(aliceCakeBalance2.gt(aliceCakeBalance)).to.be.equal(true);

      await Promise.all([
        lpVault
          .connect(market)
          .withdraw(alice.address, recipient.address, parseEther('10')),
        lpVault
          .connect(market)
          .withdraw(bob.address, recipient.address, parseEther('30')),
      ]);

      const [bobInfo, totalAmount3, totalRewardsPerAmount3] = await Promise.all(
        [
          lpVault.userInfo(bob.address),
          lpVault.totalAmount(),
          lpVault.totalRewardsPerAmount(),
        ]
      );
      expect(
        masterChefCakePool2.amount.lt(masterChefLpPool.amount)
      ).to.be.equal(true);
      expect(bobInfo.rewardDebt).to.be.equal(0);
      expect(bobInfo.amount).to.be.equal(0);
      expect(totalAmount3).to.be.equal(0);
      expect(totalRewardsPerAmount3).to.be.equal(0);
    });
  });

  describe('Upgrade functionality', () => {
    it('reverts if a non-owner tries to update', async () => {
      await lpVault.connect(owner).transferOwnership(alice.address);

      await expect(upgrade(lpVault, 'TestLPVaultV2')).to.revertedWith(
        'Ownable: caller is not the owner'
      );
    });

    it('upgrades to version 2', async () => {
      expect(await lpVault.getUserPendingRewards(alice.address)).to.be.equal(0);

      await lpVault
        .connect(market)
        .deposit(alice.address, alice.address, parseEther('10'));

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      // to get Cake rewards
      await lpVault.compound();

      lpVault
        .connect(market)
        .deposit(bob.address, bob.address, parseEther('20'));

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      await Promise.all([
        lpVault
          .connect(market)
          .deposit(alice.address, alice.address, parseEther('20')),
        lpVault
          .connect(market)
          .deposit(bob.address, bob.address, parseEther('15')),
      ]);

      // to get Cake rewards
      await lpVault.compound();

      // accrue some cake
      await advanceBlock(ethers);
      await advanceBlock(ethers);
      await advanceBlock(ethers);

      const lpVaultV2: TestLPVaultV2 = await upgrade(lpVault, 'TestLPVaultV2');

      const [
        totalAmount,
        totalRewardsPerAmount,
        pendingRewards,
        aliceInfo,
        bobInfo,
      ] = await Promise.all([
        lpVaultV2.totalAmount(),
        lpVaultV2.totalRewardsPerAmount(),
        lpVaultV2.getPendingRewards(),
        lpVaultV2.userInfo(alice.address),
        lpVaultV2.userInfo(bob.address),
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
        lpVaultV2.getUserPendingRewards(alice.address),
        lpVaultV2.getUserPendingRewards(bob.address),
        lpVaultV2.getUserPendingRewards(owner.address),
        lpVaultV2.version(),
      ]);

      expect(alicePendingRewards).to.be.equal(aliceRewards);

      expect(bobPendingRewards).to.be.equal(bobRewards);

      expect(ownerPendingRewards).to.be.equal(0);

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

      expect(version).to.be.equal('V2');
    });
  });
}).timeout(50_000);
