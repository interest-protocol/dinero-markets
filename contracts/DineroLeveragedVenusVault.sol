//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/IVenusController.sol";
import "./interfaces/IVToken.sol";
import "./interfaces/IVenusVault.sol";
import "./interfaces/IPancakeRouter02.sol";

import "./lib/Math.sol";
import "./lib/IntERC20.sol";
import "./lib/SafeCastLib.sol";

import "./tokens/Dinero.sol";

import "./SafeVenus.sol";

/**
 * @dev This is a Vault to mint Dinero. The idea is to always keep the vault assets 1:1 to Dinero minted.
 * @dev IMPORT to note that VTokens do not usually have 18 decimals. But their exchangeRate has a mantissa of 18. https://github.com/VenusProtocol/venus-protocol/blob/master/contracts/VToken.sol comment on line 21
 * The vault can incur a loss even though, we employ very conservative strategy. But the returns from the {DINERO} lent out, should cover it.
 * Losses can occur if the price of XVS drops drastically or there is a lot of demand for USDC compared to suppliers depending on the interest rate model.
 * This contract needs the {MINTER_ROLE} from {DINERO}.
 * Depositors will earn an interest on their deposits while losing 0 liquidity.
 * The vault employs Venus Protocol, https://app.venus.io/dashboard, to investment all it's assets by supplying them and opening loans of the same asset and keep doing this process as long as it is profitable.
 * We rely on the {SafeVenus} contract to safely interact with Venus to avoid liquidation. The vault employes a conservative strategy by always borrowing and supplying the same asset at a ratio lower than required by the Venus Protocol.
 * Core functions can be paused in case of a security issue.
 * Due to Venus being the leading lending platform in the ecosystem with 2bn in TVL. We feel confident to use it.
 * If Venus's markets get compromised the 1:1 Dinero peg will suffer. So we need to monitor Venus activity to use {emergencyRecovery} in case we feel a new feature is not properly audited. The contract then can be upgraded to properly give the underlying to depositors.
 */
//solhint-disable-next-line max-states-count
contract DineroLeveragedVenusVault is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IVenusVault
{
    /*///////////////////////////////////////////////////////////////
                            LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Math for uint256;
    using SafeCastLib for uint256;
    using IntERC20 for address;

    /*///////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed account,
        address indexed underlying,
        uint256 amount,
        uint256 vTokenAmount
    );

    event Withdraw(
        address indexed account,
        address indexed underlying,
        uint256 vTokenAmount,
        uint256 amount
    );

    event CompoundDepth(uint256 oldValue, uint256 indexed newValue);

    event CollateralLimit(uint256 oldValue, uint256 indexed newValue);

    event AddVToken(IVToken indexed vToken, address indexed underlying);

    event RemoveVToken(IVToken indexed vToken, address indexed underlying);

    event Loss(
        uint256 previousTotalUnderlying,
        uint256 currentTotalUnderlying,
        uint256 lossPerVToken
    );

    event EmergencyRecovery(uint256 vTokenAmount);

    event RepayAndRedeem(IVToken, uint256 amount);

    event DineroLTV(uint256 indexed previousValue, uint256 indexed newValue);

    /*///////////////////////////////////////////////////////////////
                                STRUCT
    //////////////////////////////////////////////////////////////*/

    struct UserAccount {
        uint128 principal; // Amount of stable coins deposited - withdrawn
        uint128 vTokens; // Amount of VTokens supplied based on principal + rewards from XVS sales.
        uint256 rewardsPaid; // Rewards paid to the user since his last interaction.
        uint256 lossVTokensAccrued; // Losses paid to the user since his last interaction.
    }

    /*///////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // Compound and by extension Venus return 0 on successful calls.
    uint256 internal constant NO_ERROR = 0;

    // Precision Factor to calculate losses and rewards
    uint256 internal constant PRECISION = 1e10;

    // solhint-disable-next-line var-name-mixedcase
    address internal constant XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    // solhint-disable-next-line var-name-mixedcase
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // 18 decimals

    // solhint-disable-next-line var-name-mixedcase
    IPancakeRouter02 internal constant ROUTER =
        IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E); // PCS router

    // solhint-disable-next-line var-name-mixedcase
    IVenusController internal constant VENUS_CONTROLLER =
        IVenusController(0xfD36E2c2a6789Db23113685031d7F16329158384); //

    //solhint-disable-next-line var-name-mixedcase
    Dinero public DINERO; // 18 decimals

    //solhint-disable-next-line var-name-mixedcase
    address public FEE_TO;

    //solhint-disable-next-line var-name-mixedcase
    SafeVenus public SAFE_VENUS;

    // How many times the contract is allowed to open loans backed by previous loans.
    uint8 public compoundDepth; // No more than 5

    // Stable coins supported by this contract.
    // BUSD - 0xe9e7cea3dedca5984780bafc599bd69add087d56 18 decimals
    // USDC - 0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d 18 decimals
    // DAI - 0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3  18 decimals
    EnumerableSetUpgradeable.AddressSet private _underlyingWhitelist;

    // UNDERLYING -> USER -> UserAccount
    mapping(address => mapping(address => UserAccount)) public accountOf;

    // VTOKEN -> AMOUNT
    mapping(IVToken => uint256) public totalFreeVTokenOf;

    // UNDERLYING -> AMOUNT
    mapping(address => uint256) public totalFreeUnderlying;

    // VTOKEN -> LOSS PER TOKEN
    mapping(IVToken => uint256) public totalLossOf;

    // VTOKEN -> REWARDS PER TOKEN
    mapping(IVToken => uint256) public rewardsOf;

    // UNDERLYING -> VTOKEN
    mapping(address => IVToken) public vTokenOf;

    // Percentage with a mantissa of 18.
    uint256 public collateralLimit;

    // % of Dinero lent to the user based on principal deposited free of charge
    uint256 public dineroLTV;

    /*///////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dinero The contract of the dinero stable coin
     * @param feeTo The address that will collect the fee
     *
     * Requirements:
     *
     * - Can only be called at once and should be called during creation to prevent front running.
     */
    function initialize(
        Dinero dinero,
        SafeVenus safeVenus,
        address feeTo
    ) external initializer {
        __Ownable_init();
        __Pausable_init();

        DINERO = dinero;
        FEE_TO = feeTo;
        SAFE_VENUS = safeVenus;

        compoundDepth = 3;
        collateralLimit = 0.5e18;
        dineroLTV = 0.9e18;

        // We trust `router` so we can fully approve because we need to sell it.
        // Venus has infinite allowance if given max uint256
        IERC20Upgradeable(XVS).safeApprove(address(ROUTER), type(uint256).max);
    }

    /*///////////////////////////////////////////////////////////////
                            MODIFIER
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Checks if `underlyin` is supported by the vault.
     *
     * @param underlying The address of the token to check if it is supported.
     */
    modifier isWhitelisted(address underlying) {
        require(
            _underlyingWhitelist.contains(underlying),
            "DV: underlying not whitelisted"
        );
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev View function to see if the Vault supports the `underlying`.
     * This function are needed because sets need to be private.
     *
     * @param underlying The address of the token to check if it is supported.
     * @return bool
     */
    function isUnderlyingSupported(address underlying)
        external
        view
        returns (bool)
    {
        return _underlyingWhitelist.contains(underlying);
    }

    /**
     * @dev Returns the underlying on index `index`.
     * This function are needed because sets need to be private.
     *
     * @param index The index to look up the underlying.
     * @return address The ERC20 compliant underlying address.
     */
    function getUnderlyingAt(uint256 index) external view returns (address) {
        return _underlyingWhitelist.at(index);
    }

    /**
     * @dev Returns the total number of underlyings supported
     * This function are needed because sets need to be private.
     *
     * @return uint256
     */
    function getTotalUnderlyings() external view returns (uint256) {
        return _underlyingWhitelist.length();
    }

    /**
     * @dev Returns an array with all underlyings
     * This function are needed because sets need to be private.
     *
     * @return address[] All underlyings
     */
    function getAllUnderlyings() external view returns (address[] memory) {
        return _underlyingWhitelist.values();
    }

    /*///////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev It accepts an `amount` of `underlyinng` from a depositor and mints an equivalent amount of `DINERO` to `msg.sender`.
     *
     * @notice `msg.sender` has to approve this contract to use the `underlying`.
     * @notice `msg.sender` will be paid rewards and incur a loss if there is one.
     *
     * @param underlying The stable coin the `msg.sender` wishes to deposit
     * @param amount How many `underlying`, the `msg.sender` wishes to deposit.
     *
     * Requirements:
     *
     * - The underlying must have been whitelisted by the owner.
     * - The contract must be unpaused.
     * - `amount` must be greater than 0, as it makes no sense to deposit nothing.
     */
    function deposit(address underlying, uint256 amount)
        external
        isWhitelisted(underlying)
        whenNotPaused
    {
        // There is no reason to call this function as "harvest" because we "compound" the rewards as they are already being supplied.
        require(amount > 0, "DV: no zero amount");
        // Get the VToken of the `underlying`.
        IVToken vToken = vTokenOf[underlying];

        // Total amount of VTokens minted by deposits from users. NOT FROM LOANS.
        uint256 totalFreeVTokens = totalFreeVTokenOf[vToken];

        uint256 lossPerVToken;

        // On first deposit or if the vault is empty. There should be no rewards to claim and give.
        if (totalFreeVTokens != 0) {
            // Update the rewards before any state mutation, to fairly distribute them.
            _investXVS(vToken);

            // In the line above, we converted XVS to `underlying` and minted VTokens. This increases the free underlying.
            // It has to be done before calculating losses.
            // Update loss losses before any mutations to fairly charge them.
            // This already updates the storage state.
            // {lossPerVToken} is vToken loss per vToken since genesis
            lossPerVToken = _updateLoss(underlying, vToken);
        }

        // Get User Account data
        UserAccount memory userAccount = accountOf[underlying][_msgSender()];

        // Get current total rewards accrued per vToken since genesis.
        uint256 rewardPerVToken = rewardsOf[vToken];

        // VTokens have different decimals, so we need to be careful when dividing and multiplying.
        uint256 decimalsFactor = 10**address(vToken).safeDecimals();

        // If the user has deposited before. He is entitled to rewards from XVS sales.
        // This also checks for totalFreeVTokens not being 0.
        if (userAccount.vTokens > 0) {
            uint256 lossInVTokens = uint256(userAccount.vTokens).mulDiv(
                lossPerVToken,
                decimalsFactor
            ) - userAccount.lossVTokensAccrued;

            // If there was a loss, we need to charge the user.
            if (lossInVTokens != 0) {
                uint256 _lossInVTokens = lossInVTokens / PRECISION;
                // Fairly calculate how much to charge the user, based on his balance and deposit length.
                // Charge the user.
                userAccount.vTokens -= _lossInVTokens.toUint128();
                // Tokens were used to cover the debt.
                totalFreeVTokens -= _lossInVTokens;
            }

            uint256 rewards = uint256(userAccount.vTokens).mulDiv(
                rewardPerVToken,
                decimalsFactor
            ) - userAccount.rewardsPaid;

            // No point to calculate if there are no rewards;
            if (rewards != 0) {
                uint256 _rewards = rewards / PRECISION;
                // We calculate the rewards based on the VToken rewards and give to the user.
                userAccount.vTokens += _rewards.toUint128();
                // They will be given to the user so they became free.
                totalFreeVTokens += _rewards;
            }
        }

        // We need to get the underlying from the `msg.sender` before we mint V Tokens.
        // Get the underlying from the user.
        IERC20Upgradeable(underlying).safeTransferFrom(
            _msgSender(),
            address(this),
            amount
        );

        // Supply underlying to Venus right away to start earning.
        // It returns the new VTokens minted.
        // This calls {accrueInterest} on VToken, so we can use _getTotalFreeUnderlying.
        uint256 vTokensMinted = _mintVToken(vToken, amount);

        // Charge a 0.5% fee on deposit
        uint256 fee = vTokensMinted.wadMul(0.005e18);

        vTokensMinted -= fee;
        accountOf[underlying][FEE_TO].vTokens += fee.toUint128();

        // Update the data
        totalFreeVTokens += vTokensMinted;
        userAccount.principal += amount.wadMul(dineroLTV).toUint128();
        userAccount.vTokens += vTokensMinted.toUint128();

        // Consider all rewards fairly paid to the user up to this point.
        userAccount.rewardsPaid = uint256(userAccount.vTokens).mulDiv(
            rewardPerVToken,
            decimalsFactor
        );

        // Consider all losses fairly charged to the user up to this point.
        userAccount.lossVTokensAccrued = uint256(userAccount.vTokens).mulDiv(
            lossPerVToken,
            decimalsFactor
        );

        // Update global state
        accountOf[underlying][_msgSender()] = userAccount;
        totalFreeVTokenOf[vToken] = totalFreeVTokens;

        // Needs to be done after ALL Mutions in exceptions of Dinero.
        totalFreeUnderlying[underlying] = _getTotalFreeUnderlying(vToken);

        // Give them `DINERO` to the `msg.sender`; essentially giving them liquidity to employ more strategies.
        DINERO.mint(_msgSender(), amount.wadMul(dineroLTV));

        emit Deposit(_msgSender(), underlying, amount, vTokensMinted);
    }

    /**
     * @dev It withdraws the underlying by redeeming an amout of Vtokens from Venus.
     * @dev UI should check the VToken liquidity before calling this function to prevent failures.
     *
     * @notice It charges a 0.5% fee.
     * @notice Withdraws will fail if Venus does not have enough liquidity. Try to withdraw a smaller amount on failure.
     *
     * @param underlying The address of the underlying the `msg.sender` wishes to withdraw.
     * @param vTokenAmount The number of VTokens the `msg.sender` wishes to withdraw.
     *
     * Requirements:
     *
     * - The underlying must have been whitelisted by the owner.
     * - The contract must be unpaused.
     * - `amount` must be greater than 0, as it makes no sense to withdraw nothing.
     * - Venus must have enough liquidity to be redeemed.
     * - Vault must have enough room to withdraw the `amount` desired.
     */
    function withdraw(address underlying, uint256 vTokenAmount)
        external
        whenNotPaused
        isWhitelisted(underlying)
    {
        // We do not support the concept of harvesting the rewards as they are "auto compounded".
        // `msg.sender` must always withdraw some VTokens.
        // Rewards will be given on top of every withdrawl.
        require(vTokenAmount > 0, "DV: no zero amount");

        // Get User Account data
        UserAccount memory userAccount = accountOf[underlying][_msgSender()];

        require(userAccount.vTokens >= vTokenAmount, "DV: not enough balance");

        // Find the vToken of the underlying.
        IVToken vToken = vTokenOf[underlying];
        // Update the rewards before any state mutation, to fairly distribute them.
        _investXVS(vToken);

        // Get the V Token rewards from the sales of XVS.
        uint256 rewardPerVToken = rewardsOf[vToken];

        // Total amount of VTokens minted by deposits from users. NOT FROM LOANS.
        uint256 totalFreeVTokens = totalFreeVTokenOf[vToken];

        // Store the rewards that will be given on this call on top of the `vTokenAmount` in underlying.
        uint256 rewards;
        uint256 lossPerVToken;

        // VTokens have different decimals, so we need to be careful when dividing and multiplying.
        uint256 decimalsFactor = 10**address(vToken).safeDecimals();

        // Uniswap style, block scoping, to prevent stack too deep local variable errors.
        {
            // It has to be done before calculating losses.
            // Best to be called after {_investXVS} as it increases the free underlying.
            // Update loss losses before any mutations to fairly charge them.
            // This already updates the storage state.
            lossPerVToken = _updateLoss(underlying, vToken);

            // If there was a loss, we need to charge the user.
            // Fairly calculate how much to charge the user, based on his balance and deposit length.
            uint256 lossInVTokens = uint256(userAccount.vTokens).mulDiv(
                lossPerVToken,
                decimalsFactor
            ) - userAccount.lossVTokensAccrued;

            if (lossInVTokens != 0) {
                uint256 _lossInVTokens = lossInVTokens / PRECISION;
                // Charge the user.
                userAccount.vTokens -= _lossInVTokens.toUint128();
                // They are no longer free because they need were used to cover the loss.
                totalFreeVTokens -= _lossInVTokens;
            }

            // Calculate the rewards the user is entitled to based on the current VTokens he holds and rewards per VTokens.
            // We do not need to update the {totalFreeVTokens} because we will give these rewards to the user.
            rewards =
                (uint256(userAccount.vTokens).mulDiv(
                    rewardPerVToken,
                    decimalsFactor
                ) - userAccount.rewardsPaid) /
                PRECISION;
        }

        // Uniswap style, block scoping, to prevent stack too deep local variable errors.
        {
            // Amount of Dinero that needs to be burned.
            // Need to calculate this before updating {userAccount.vTokens} and {userAccount.principal}.
            uint256 dineroToBurn = vTokenAmount.mulDiv(
                userAccount.principal,
                userAccount.vTokens
            );

            // We do effects before checks/updates here to save memory and we can trust this token.
            // Recover the Dinero lent to keep the ratio 1:1
            DINERO.burn(_msgSender(), dineroToBurn);

            // Update State
            totalFreeVTokens -= vTokenAmount;
            userAccount.principal -= dineroToBurn.toUint128();

            // Rewards are paid in this call; so we do not need to add here.
            // We need to update the userAccount.vTokens before updating the {lossVTokensAccrued and rewardsPaid}
            // Otherwise, the calculations for rewards and losses will be off in the next call for this user.
            userAccount.vTokens -= vTokenAmount.toUint128();
            // Consider all rewards fairly paid.
            userAccount.rewardsPaid = uint256(userAccount.vTokens).mulDiv(
                rewardPerVToken,
                decimalsFactor
            );
            // Consider all debt paid.
            userAccount.lossVTokensAccrued = uint256(userAccount.vTokens)
                .mulDiv(lossPerVToken, decimalsFactor);
        }

        // Update Global State
        accountOf[underlying][_msgSender()] = userAccount;
        totalFreeVTokenOf[vToken] = totalFreeVTokens;

        // Remove DUST
        uint256 amountOfUnderlyingToRedeem = (rewards + vTokenAmount).wadMul(
            SAFE_VENUS.viewExchangeRate(vToken)
        );

        // Uniswap style, block scoping, to prevent stack too deep local variable errors.
        {
            // save gas
            SafeVenus safeVenus = SAFE_VENUS;
            // Get a safe redeemable amount to prevent liquidation.
            uint256 safeAmount = safeVenus.safeRedeem(
                vToken,
                address(this),
                collateralLimit
            );
            uint256 balance = underlying.contractBalanceOf();

            // Upper bound to prevent infinite loops.
            uint256 maxTries;

            // If we cannot redeem enough to cover the `amountOfUnderlyingToRedeem`. We will start to deleverage; up to 10x.
            // The less we are borrowing, the more we can redeem because the loans are overcollaterized.
            // Vault needs good liquidity and moderate leverage to avoid this logic.
            while (
                amountOfUnderlyingToRedeem > safeAmount &&
                amountOfUnderlyingToRedeem > balance &&
                maxTries <= 10
            ) {
                if (1 ether > safeAmount) break;

                // This calls {accrueInterest} on VToken, so we can use _getTotalFreeUnderlying.
                _redeemAndRepay(vToken, safeAmount);
                // update the safeAmout for the next iteration.
                safeAmount = safeVenus.safeRedeem(
                    vToken,
                    address(this),
                    collateralLimit
                );
                // Add some room to compensate for DUST. SafeVenus has a large enough room to accomodate for one dollar.
                balance = underlying.contractBalanceOf() + 1 ether;
                maxTries += 1;
            }

            // Make sure we can safely withdraw the `amountOfUnderlyingToRedeem`.
            require(
                safeAmount >= amountOfUnderlyingToRedeem ||
                    balance >= amountOfUnderlyingToRedeem,
                "DV: failed to withdraw"
            );
            {
                // If the balance cannot cover, we need to redeem
                if (amountOfUnderlyingToRedeem > balance) {
                    // Redeem the underlying. It will revert if we are unable to withdraw.
                    // For dust we need to withdraw the min amount.
                    // This calls {accrueInterest} on VToken, so we can use _getTotalFreeUnderlying.

                    uint256 _safeAmount = amountOfUnderlyingToRedeem.min(
                        safeVenus.safeRedeem(
                            vToken,
                            address(this),
                            collateralLimit
                        )
                    );
                    _invariant(
                        vToken.redeemUnderlying(_safeAmount),
                        "DV: failed to redeem"
                    );
                }
            }
        }

        // Uniswap style ,block scoping, to prevent stack too deep local variable errors.
        {
            // Send underlying to user.
            underlying.safeERC20Transfer(
                _msgSender(),
                amountOfUnderlyingToRedeem
            );

            // Update current free underlying after ALL mutations in underlying.
            totalFreeUnderlying[underlying] = _getTotalFreeUnderlying(vToken);

            emit Withdraw(
                _msgSender(),
                underlying,
                amountOfUnderlyingToRedeem,
                vTokenAmount
            );
        }
    }

    /**
     * @dev It leverages the vault position in Venus. By using the current supply as collateral to borrow same token. Supply and borrow {compoundDepth} times.
     *
     * @param vToken The contract of the vToken we wish to leverage.
     *
     * Requirements:
     *
     * - The contract must be unpaused.
     */
    function leverage(IVToken vToken)
        external
        whenNotPaused
        isWhitelisted(vToken.underlying())
    {
        _leverage(vToken);
    }

    /**
     * @dev Leverages all VTokens. Explanation of leverage above.
     *
     * Requirements:
     *
     * - The contract must be unpaused.
     */
    function leverageAll() external whenNotPaused {
        // Get all underlyings.
        address[] memory underlyingArray = _underlyingWhitelist.values();

        // Get total number of underlyings.
        uint256 len = underlyingArray.length;

        // Leverage each VToken.
        for (uint256 i = 0; i < len; i++) {
            _leverage(vTokenOf[underlyingArray[i]]);
        }
    }

    /**
     * @dev It reduces the loan size to stay within a safe margin to avoid liquidations.
     *
     * @param vToken The contract of the VToken that we wish to reduce our open loan on them.
     *
     * Requirements:
     *
     * - The contract must be unpaused.
     */
    function deleverage(IVToken vToken)
        external
        whenNotPaused
        isWhitelisted(vToken.underlying())
    {
        _deleverage(vToken);
    }

    /**
     * @dev Deleverages all current VTokens positions from this vault.
     */
    function deleverageAll() external whenNotPaused {
        // Get all underlyings.
        address[] memory underlyingArray = _underlyingWhitelist.values();

        // Get total number of underlyings.
        uint256 len = underlyingArray.length;

        // Deleverage all positions in all vTokens.
        for (uint256 i = 0; i < len; i++) {
            _deleverage(vTokenOf[underlyingArray[i]]);
        }
    }

    /*///////////////////////////////////////////////////////////////
                         PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev It reduces the loan size to stay within a safe margin to avoid liquidations.
     *
     * @param vToken The contract of the VToken that we wish to reduce our open loan on them.
     */
    function _deleverage(IVToken vToken) private {
        uint256 _collateralLimit = collateralLimit;
        // save gas
        SafeVenus safeVenus = SAFE_VENUS;
        // We check if we are above our safety threshold.
        uint256 amount = safeVenus.deleverage(
            vToken,
            address(this),
            _collateralLimit
        );

        // Safety mechanism
        uint256 maxTries;

        // Stop either when deleverage returns 0 or if we are not above the max tries threshold.
        // Deleverage function from safeVenus returns 0 when we are within a safe limit.
        while (amount > 0 && maxTries < 5) {
            if (1 ether > amount) break;

            // This calls {accrueInterest} on VToken, so we can use _getTotalFreeUnderlying.
            _redeemAndRepay(vToken, amount);
            // Update the amount for the next iteration.
            amount = safeVenus.deleverage(
                vToken,
                address(this),
                _collateralLimit
            );

            maxTries += 1;
        }

        // Keep the data fresh
        totalFreeUnderlying[vToken.underlying()] = _getTotalFreeUnderlying(
            vToken
        );
    }

    /**
     * @dev It leverages the vault position in Venus. By using the current supply as collateral to borrow same token. Supply and borrow {compoundDepth} times.
     *
     * @param vToken The contract of the vToken we wish to leverage.
     */
    function _leverage(IVToken vToken) private {
        // Save Gas
        uint256 depth = compoundDepth;

        // We open a loan -> supply to the same market -> open a second loan -> ....
        // We do this process `depth` times. We will be conservative and have a value of around 3 or 4.
        // We do not need to store the information about these new minted vTokens as they loan-backed VTokens.
        for (uint256 i = 0; i < depth; i++) {
            _borrowAndSupply(vToken);
        }

        // Keep the data fresh
        totalFreeUnderlying[vToken.underlying()] = _getTotalFreeUnderlying(
            vToken
        );
    }

    /**
     * @dev It checks if there was a loss in non-debt backed underlying. In the case there is one, it updates the global state accordingly.
     *
     * @param underlying The underlying of the `vToken`, which we will check if we incurred a loss or not.
     * @param vToken The VToken market that holds the underlying.
     * @return uint256 The current total loss per token.
     */
    function _updateLoss(address underlying, IVToken vToken)
        private
        returns (uint256)
    {
        // Get previous recorded total non-debt underlying.
        uint256 prevFreeUnderlying = totalFreeUnderlying[underlying];

        // save gas
        SafeVenus safeVenus = SAFE_VENUS;

        uint256 supplyBalance = safeVenus.viewUnderlyingBalanceOf(
            vToken,
            address(this)
        );

        // Get current recorded total non-debt underlying.
        uint256 currentFreeUnderlying = supplyBalance +
            vToken.underlying().contractBalanceOf() -
            safeVenus.viewCurrentBorrow(vToken, address(this));

        // Get previous recorded total loss per vToken
        uint256 totalLoss = totalLossOf[vToken];

        // If our underlying balance decreases, we incurred a loss.
        if (prevFreeUnderlying > currentFreeUnderlying) {
            // Need to find the difference, then convert to vTokens by multiplying by the {vToken.exchangeRateCurrent}. Lastly, we need to devide by the total free vTokens.
            // Important to note the mantissa of exchangeRateCurrent is 18 while vTokens usually have a mantissa of 8.

            uint256 loss = ((prevFreeUnderlying - currentFreeUnderlying).wadDiv(
                safeVenus.viewExchangeRate(vToken)
            ) * PRECISION).mulDiv(
                    10**address(vToken).safeDecimals(),
                    totalFreeVTokenOf[vToken]
                );
            // Update the loss
            uint256 newTotalLoss = totalLoss + loss;
            totalLossOf[vToken] = newTotalLoss;
            emit Loss(prevFreeUnderlying, currentFreeUnderlying, loss);
            return newTotalLoss;
        }

        // In the case of no loss recorded. Return the current values.
        return totalLoss;
    }

    /**
     * @dev A helper function to find out how much non-debt backed underlying we have in the `vToken`.
     * This includes the underlying from rewards.
     *
     * @param vToken The market, which we want to check how much non-debt underlying we have.
     * @return uint256 The total non-debt backed underlying.
     */
    function _getTotalFreeUnderlying(IVToken vToken)
        private
        view
        returns (uint256)
    {
        // save gas
        (uint256 borrowBalance, uint256 supplyBalance) = SAFE_VENUS
            .borrowAndSupply(vToken, address(this));

        return
            supplyBalance +
            vToken.underlying().contractBalanceOf() -
            borrowBalance;
    }

    /**
     * @dev CLaims and sells all XVS on Pancake swap for the underlying of a `vToken` and supplies the new underlying on Venus.
     *
     * @param vToken The VToken market, which we wish to claim the XVS and swap to the underlying.
     */
    function _investXVS(IVToken vToken) private {
        address[] memory vTokenArray = new address[](1);

        vTokenArray[0] = address(vToken);

        // Claim XVS in the `vToken`.
        VENUS_CONTROLLER.claimVenus(address(this), vTokenArray);

        uint256 xvsBalance = XVS.contractBalanceOf();
        // There is no point to continue if there are no XVS rewards.
        if (xvsBalance == 0) return;

        address underlying = vToken.underlying();

        // Build the swap path XVS -> WBNB -> UNDERLYING
        // WBNB/XVS Pair - 0x7EB5D86FD78f3852a3e0e064f2842d45a3dB6EA2 ~4M USD liquidity - 19/02/2022
        // WBNB/USDC Pair - 0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b ~9M USD liquidity - 19/02/2022
        // WBNB/BUSD Pair - 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16 ~ 350M USD liquidity - 19/02/2022
        // WBNB/USDT Pair - 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE ~ 190M USD liquidity - 19/02/2022
        // WBNB/DAI Pair - 0xc7c3cCCE4FA25700fD5574DA7E200ae28BBd36A3 ~ 130k USDC liquidity - 19/02/2022
        // DAI support will be done only if community agrees.
        address[] memory path = new address[](3);
        path[0] = XVS;
        path[1] = WBNB; // WBNB is the bridge token in BSC
        path[2] = underlying;

        // Sell XVS to `underlying` to reinvest back to Venus, as this is a stable vault. We do not want volatile assets.
        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(
            // Assume all XVS in the contract are rewards.
            xvsBalance,
            // We do not care about slippage
            0,
            // WBNB being the bridge token in BSC. This path will be the most liquid.
            path,
            // Get the `underlying` to this contract in order to supply it to Venus.
            address(this),
            // Needs to be done in this block.
            //solhint-disable-next-line not-rely-on-time
            block.timestamp
        );

        uint256 totalFreeVTokens = totalFreeVTokenOf[vToken];

        // It should never happen, but since we will use it as a denominator, we need to consider it.
        assert(totalFreeVTokens != 0);

        uint256 minted = _mintVToken(vToken, amounts[2]) * PRECISION;

        // Assume sall current underlying are from the XVS swap.
        // This contract should never have underlyings as they should always be converted to VTokens, unless it is paused and the owner calls {emergencyRecovery}.
        rewardsOf[vToken] += minted.mulDiv(
            10**address(vToken).safeDecimals(),
            totalFreeVTokens
        );
    }

    /**
     * @dev Helper function to leverage the Vault. It borrows and then supplies.
     *
     * @param vToken The VToken market we wish to leverage our position.
     *
     * Requirements:
     *
     * - We will not leverage positions lower than 500 USD.
     */
    function _borrowAndSupply(IVToken vToken) private {
        // Calculate a safe borrow amount to avoid liquidation
        uint256 safeBorrowAmount = SAFE_VENUS.safeBorrow(
            vToken,
            address(this),
            collateralLimit
        );

        // We will not compound if we can only borrow 500 USD or less. This vault only supports USD stable coins with 18 decimal.
        if (500 ether >= safeBorrowAmount) return;

        // Borrow from the vToken. We will throw if it fails.
        _invariant(vToken.borrow(safeBorrowAmount), "DV: failed to borrow");

        // Supply the underlying we got from the loan on the same market.
        // We do not care how many VTokens are minted.
        _mintVToken(vToken, vToken.underlying().contractBalanceOf());
    }

    /**
     * @dev Helper function to redeem and repay an `amount` in a Venus `vToken` market.
     *
     * @param vToken The Venus market we wish to redeem and repay a portion of the loan.
     * @param amount The amount of the  loan we wish to pay.
     */
    function _redeemAndRepay(IVToken vToken, uint256 amount) private {
        uint256 underlyingBalance = vToken.balanceOfUnderlying(address(this));

        // Redeem `amount` from `vToken`. It will revert on failure.
        // To avoid errors due to dust. Cannot withdraw more than what we have
        _invariant(
            vToken.redeemUnderlying(amount.min(underlyingBalance)),
            "DV: failed to redeem"
        );

        uint256 borrowAmount = SAFE_VENUS.viewCurrentBorrow(
            vToken,
            address(this)
        );

        // Repay a portion, the `amount`, of the loan. It will revert on failure.
        // We need to consider dust in here. We cannot repay more than what we owe.
        _invariant(
            vToken.repayBorrow(amount.min(borrowAmount)),
            "DV: failed to repay"
        );
    }

    /**
     * @dev Helper function to supply underlying to a `vToken` to mint vTokens and know how many vTokens we got.
     * It supplies all underlying.
     *
     * @param vToken The vToken market we wish to mint.
     */
    function _mintVToken(IVToken vToken, uint256 amount)
        private
        returns (uint256 mintedAmount)
    {
        // Find how many VTokens we currently have.
        uint256 balanceBefore = address(vToken).contractBalanceOf();

        // Supply ALL underlyings present in the contract even lost tokens to mint VTokens. It will revert if it fails.
        _invariant(vToken.mint(amount), "DV: failed to mint");

        // Subtract the new balance from the previous one, to find out how many VTokens we minted.
        mintedAmount = address(vToken).contractBalanceOf() - balanceBefore;
    }

    /**
     * @dev It is used to check if Compound style functions failed or suceeded by comparing `value` to 0.
     * If they fai, it reverts with `message`.
     *
     * @param value The number we wish to compare with {NO_ERROR}. Anything other than 0 indicates an error.
     * @param message The error message.
     */
    function _invariant(uint256 value, string memory message) private pure {
        // Revert for all values other than 0 with the `message`.
        if (value == NO_ERROR) return;
        revert(message);
    }

    /**
     * @dev Function repays all loans. Essentially removes all leverage.
     * Leverage can be called once the strategy is profitable again.
     *
     * @param vToken The VToken market we wish to remove all leverage.
     */
    function _repayAll(IVToken vToken) private {
        SafeVenus safeVenus = SAFE_VENUS;

        // We will keep repaying as long as we have enough redeemable amount in our supply.
        uint256 redeemAmount = safeVenus.safeRedeem(
            vToken,
            address(this),
            collateralLimit
        );

        uint256 borrowAmount = safeVenus.viewCurrentBorrow(
            vToken,
            address(this)
        );

        // Value to store the maximum amount we want to loop in a single call
        uint256 maxTries;

        // Keep redeeming and repaying as long as we have an open loan position, have enough redeemable amount or have done it 10x in this call.
        // We intend to only have a compound depth of 3. So an upperbound of 10 is more than enough.

        while (redeemAmount > 0 && borrowAmount > 0 && maxTries <= 15) {
            // redeem and repay
            _redeemAndRepay(vToken, redeemAmount);

            emit RepayAndRedeem(vToken, redeemAmount);

            // Update the redeem and borrow amount to see if we can get to net iteration
            redeemAmount = safeVenus.safeRedeem(
                vToken,
                address(this),
                collateralLimit
            );
            borrowAmount = safeVenus.viewCurrentBorrow(vToken, address(this));
            // Update the maximum numbers we can iterate
            maxTries += 1;
        }
    }

    /**
     * @dev Enters a Venus market to enable the Vtokens to be used as collateral
     *
     * @param vToken The address of the vToken market, we wish to enter
     */
    function _enterMarket(IVToken vToken) private {
        address[] memory vTokenArray = new address[](1);

        vTokenArray[0] = address(vToken);

        // Allow the `underlying` to be used as collateral to leverage.
        uint256[] memory results = VENUS_CONTROLLER.enterMarkets(vTokenArray);

        // Check if we successfully entered the market. If not we revert.
        _invariant(results[0], "DV: failed to enter market");
    }

    /*///////////////////////////////////////////////////////////////
                           ONLY OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Adds support for an underlying/VToken to this contract.
     *
     * @param vToken The VToken contract we wish to support.
     *
     * Requirements:
     *
     * - Only the owner can call to assure proper issuance of Dinero (only support stable coins) and legitimacy of the markets.
     */
    function addVToken(IVToken vToken) external onlyOwner {
        // Get the underlying contract of the VToken.
        address underlying = vToken.underlying();

        // Give full approval to `vToken` so we can mint on deposits.
        IERC20Upgradeable(underlying).safeIncreaseAllowance(
            address(vToken),
            type(uint256).max -
                IERC20Upgradeable(underlying).allowance(
                    address(this),
                    address(vToken)
                )
        );

        // Give permission to use the assets as collateral
        _enterMarket(vToken);

        // Update global state
        _underlyingWhitelist.add(underlying);

        vTokenOf[underlying] = vToken;

        emit AddVToken(vToken, underlying);
    }

    /**
     * @dev Removes support for an underlying.
     *
     * @param vToken The Vtoken market we wish to remove support for.
     *
     * Requirements:
     *
     * - Only the owner can call to avoid griefing.
     */
    function removeVToken(IVToken vToken) external onlyOwner {
        // Get the underlying contract of the VToken.
        address underlying = vToken.underlying();

        // Remove all current allowance, since we will not be using it anymore.
        IERC20Upgradeable(underlying).safeDecreaseAllowance(
            address(vToken),
            IERC20Upgradeable(underlying).allowance(
                address(this),
                address(vToken)
            )
        );

        // Remove permission to use it as collateral
        _invariant(
            VENUS_CONTROLLER.exitMarket(address(vToken)),
            "DV: failed to exit market"
        );

        // Update global state
        _underlyingWhitelist.remove(underlying);
        delete vTokenOf[underlying];

        emit RemoveVToken(vToken, underlying);
    }

    /**
     * @dev Function repays all loans. Essentially removes all leverage.
     * Leverage can be called once the strategy is profitable again.
     *
     * @param vToken The VToken market we wish to remove all leverage.
     *
     * Requirements:
     *
     * - Only the owner can call to avoid investment losses.
     */
    function repayAll(IVToken vToken) public onlyOwner {
        _repayAll(vToken);

        _mintVToken(vToken, vToken.underlying().contractBalanceOf());
    }

    /**
     * @dev It is only to be used on an emergency to completely remove all leverage and redeem all supply. Only if there is an issue with Venus.
     *
     * Requirements:
     *
     * - Only the owner can call because there is no means to withdraw underlying directly at the moment.
     * - Contract must be paused.
     */
    function emergencyRecovery() external onlyOwner whenPaused {
        // Get all underlyings.
        address[] memory underlyingArray = _underlyingWhitelist.values();

        // Get total number of underlyings.
        uint256 len = underlyingArray.length;

        // Repay and remove all supply
        for (uint256 i = 0; i < len; i++) {
            IVToken vToken = vTokenOf[underlyingArray[i]];

            _repayAll(vToken);

            uint256 vTokenBalance = address(vToken).contractBalanceOf();
            // we do not want to try to redeem if we have no vToken

            if (vTokenBalance == 0) continue;
            _invariant(
                vToken.redeem(vTokenBalance),
                "DV: failed to redeem vtokens"
            );
            emit EmergencyRecovery(vTokenBalance);
        }
    }

    /**
     * @dev Pauses the core functions of the contract
     *
     * Requirements:
     *
     * - Only the owner can call to avoid griefing.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the core functions of the contract
     *
     * Requirements:
     *
     * - Only the owner can call to avoid griefing.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Sets a new collateral limit to be used on top of the Venus limit.
     *
     * @param _collateralLimit The new collateral limit
     *
     * Requirements:
     *
     * - Only the owner can call to avoid griefing.
     * - Must be below 90%  to avoid liquidations. In reality will not be set above 70%.
     */
    function setCollateralLimit(uint256 _collateralLimit) external onlyOwner {
        require(0.9e18 > _collateralLimit, "DV: must be lower than 90%");
        uint256 previousValue = collateralLimit;
        collateralLimit = _collateralLimit;

        emit CollateralLimit(previousValue, _collateralLimit);
    }

    /**
     * @dev Sets the {compoundDepth}, which determines how many loan-backed loans we wish to open.
     *
     * @notice We will not set it above 5.
     *
     * @param _compoundDepth The number of times to issue loan-backed loans.
     *
     * Requirements:
     *
     * - Only the owner can call to ensure we do not hage highly leveraged positions.
     */
    function setCompoundDepth(uint8 _compoundDepth) external onlyOwner {
        require(20 > _compoundDepth, "DV: must be lower than 20");
        uint256 previousValue = compoundDepth;
        compoundDepth = _compoundDepth;

        emit CompoundDepth(previousValue, _compoundDepth);
    }

    /**
     * @dev A value of 0.9e18 means that for every 1_000 USD deposit, the vault will lend 900 DNR
     *
     * @param newDineroLTV The new % of DNR emitted based on deposit
     *
     * Requirements:
     *
     * - Only the Int Governor can update this value.
     */
    function setDineroLTV(uint256 newDineroLTV) external onlyOwner {
        require(0.99e18 >= newDineroLTV, "DV: must be lower than 99%");
        uint256 previousValue = dineroLTV;
        dineroLTV = newDineroLTV;

        emit DineroLTV(previousValue, newDineroLTV);
    }

    /**
     * @dev It allows he owner to withdraw the reserves tokens to the treasury
     *
     * @notice The reserves do not incur losses nor rewards.
     *
     * @param underlying The underlying market, which vTokens will be removed
     * @param vTokenAmount The number of vTokens to withdraw
     *
     * Requirements:
     *
     * - Only the owner can call this function
     * - Market must be unpaused
     * - The underlying must be supported by this market
     * - The reserves must have enough `vTokenAmount`
     * - The `vTokenAmount` must be greater than 0
     */
    function withdrawReserves(address underlying, uint256 vTokenAmount)
        external
        onlyOwner
        whenNotPaused
        isWhitelisted(underlying)
    {
        // We do not support the concept of harvesting the rewards as they are "auto compounded".
        // `msg.sender` must always withdraw some VTokens.
        // Rewards will be given on top of every withdrawl.
        require(vTokenAmount > 0, "DV: no zero amount");

        SafeVenus safeVenus = SAFE_VENUS;
        // Get User Account data
        UserAccount memory userAccount = accountOf[underlying][FEE_TO];

        require(userAccount.vTokens >= vTokenAmount, "DV: not enough balance");

        // Find the vToken of the underlying.
        IVToken vToken = vTokenOf[underlying];

        // Update State
        userAccount.vTokens -= vTokenAmount.toUint128();

        // Update Global State
        accountOf[underlying][FEE_TO] = userAccount;

        // Remove DUST
        uint256 amountOfUnderlyingToRedeem = vTokenAmount.wadMul(
            safeVenus.viewExchangeRate(vToken)
        );
        // Uniswap style, block scoping, to prevent stack too deep local variable errors.
        {
            // Get a safe redeemable amount to prevent liquidation.
            uint256 safeAmount = safeVenus.safeRedeem(
                vToken,
                address(this),
                collateralLimit
            );
            uint256 balance = underlying.contractBalanceOf();
            // Upper bound to prevent infinite loops.
            uint256 maxTries;

            // If we cannot redeem enough to cover the `amountOfUnderlyingToRedeem`. We will start to deleverage; up to 10x.
            // The less we are borrowing, the more we can redeem because the loans are overcollaterized.
            // Vault needs good liquidity and moderate leverage to avoid this logic.
            while (
                amountOfUnderlyingToRedeem > safeAmount &&
                amountOfUnderlyingToRedeem > balance &&
                maxTries <= 10
            ) {
                if (1 ether > safeAmount) break;

                _redeemAndRepay(vToken, safeAmount);
                // update the safeAmout for the next iteration.
                safeAmount = safeVenus.safeRedeem(
                    vToken,
                    address(this),
                    collateralLimit
                );
                // Add some room to compensate for DUST. SafeVenus has a large enough room to accomodate for one dollar.
                balance = underlying.contractBalanceOf() + 1 ether;
                maxTries += 1;
            }

            // Make sure we can safely withdraw the `amountOfUnderlyingToRedeem`.
            require(
                safeAmount >= amountOfUnderlyingToRedeem ||
                    balance >= amountOfUnderlyingToRedeem,
                "DV: failed to withdraw"
            );

            // If the balance cannot cover, we need to redeem
            if (amountOfUnderlyingToRedeem > balance) {
                // Redeem the underlying. It will revert if we are unable to withdraw.
                // For dust we need to withdraw the min amount.
                _invariant(
                    vToken.redeemUnderlying(
                        amountOfUnderlyingToRedeem.min(
                            vToken.balanceOfUnderlying(address(this))
                        )
                    ),
                    "DV: failed to redeem"
                );
            }
        }

        // Send underlying to user.
        underlying.safeERC20Transfer(FEE_TO, amountOfUnderlyingToRedeem);

        // Update current free underlying after all mutations in underlying.
        totalFreeUnderlying[underlying] = _getTotalFreeUnderlying(vToken);

        emit Withdraw(
            FEE_TO,
            underlying,
            amountOfUnderlyingToRedeem,
            vTokenAmount
        );
    }

    /**
     * @dev A hook to guard the address that can update the implementation of this contract. It must be the owner.
     */
    function _authorizeUpgrade(address)
        internal
        view
        override
        onlyOwner
    //solhint-disable-next-line no-empty-blocks
    {

    }
}
