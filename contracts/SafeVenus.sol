//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "./interfaces/IVenusController.sol";
import "./interfaces/IVToken.sol";
import "./interfaces/IVenusVault.sol";
import "./interfaces/IVenusInterestRateModel.sol";
import "./interfaces/IOracle.sol";

import "./lib/Math.sol";

/**
 * @dev This is a helper contract, similarly to a library, to calculate "safe" values. Safe in the essence that they give enough room to avoid liquidation.
 * https://github.com/VenusProtocol
 * It adds a safety room to all values to prevent a shortfall and get liquidated.
 * It prioritizes a safe position over maximizing profits.
 * The functions in this contract assume a very safe strategy of supplying and borrowing the same asset within 1 vToken contract.
 * It requires chainlink feeds to convert all amounts in USD.
 */
contract SafeVenus is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /*///////////////////////////////////////////////////////////////
                            LIBRARIES
    //////////////////////////////////////////////////////////////*/

    // We need the {wadDiv} and {wadMul} functions to safely multiply and divide with values with a 1e18 mantissa.
    using Math for uint256;

    /*///////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // solhint-disable-next-line var-name-mixedcase
    address internal constant XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    uint256 internal constant BORROW_RATE_MAX_MANTISSA = 0.0005e16;

    // solhint-disable-next-line var-name-mixedcase
    IVenusController internal constant VENUS_CONTROLLER =
        IVenusController(0xfD36E2c2a6789Db23113685031d7F16329158384);

    /**
     * @dev This is the oracle we use in the entire project. It uses Chainlink as the primary source.
     * It uses PCS TWAP only when Chainlink fails.
     */
    // solhint-disable-next-line var-name-mixedcase
    IOracle public ORACLE;

    /**
     * @param oracle The address of our maintained oracle address
     *
     * Requirements:
     *
     * - Can only be called at once and should be called during creation to prevent front running.
     */
    function initialize(IOracle oracle) external initializer {
        __Ownable_init();

        ORACLE = oracle;
    }

    /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev It returns the current borrow the `account` has in the `vToken` market. This uses the stored values
     *
     * @param vToken A Venus vToken contract
     * @param account The address that will have its borrow and supply returned
     * @return uint256 The current borrow amount
     */
    function viewCurrentBorrow(IVToken vToken, address account)
        public
        view
        returns (uint256)
    {
        uint256 priorBorrow = vToken.totalBorrows();
        uint256 updatedBorrow = viewTotalBorrowsCurrent(vToken);
        uint256 borrow = vToken.borrowBalanceStored(account);
        uint256 accrualBlock = vToken.accrualBlockNumber();

        // If there was a new borrow, deposit, repay since the last {totalBorrows}, the accrual block will match the block.number.
        if (priorBorrow == updatedBorrow || accrualBlock == block.number)
            return borrow;

        uint256 factor = borrow.wadDiv(priorBorrow);

        return factor.wadMul(updatedBorrow);
    }

    /**
     * @dev It returns a conservative collateral ratio required to back a loan.
     *
     * @param vToken A Venus vToken contract
     * @param collateralLimit A percentage that will be put on current TVL to reduce it further
     * @return uint256 The conservative collateral requirement
     */
    function safeCollateralRatio(IVToken vToken, uint256 collateralLimit)
        internal
        view
        returns (uint256)
    {
        // Get the Venus Protocol collateral requiement before liquidation
        (, uint256 venusCollateralFactor, ) = VENUS_CONTROLLER.markets(
            address(vToken)
        );

        // We give a safe margin by lowering based on the `vault` collateral limit.
        uint256 enforcedLimit = venusCollateralFactor.wadMul(collateralLimit);

        uint256 borrowRate = vToken.borrowRatePerBlock();

        if (borrowRate == 0) return enforcedLimit;

        // We calculate a percentage on based profit/cost
        uint256 optimalLimit = vToken.supplyRatePerBlock().wadDiv(borrowRate);

        // To make sure we stay within the protocol limit we take the minimum between the optimal and enforced limit.
        return enforcedLimit.min(optimalLimit);
    }

    /**
     * @dev It returns the current borrow and supply amount the `account` has in the `vToken` market. This uses the stored values
     *
     * @param vToken A Venus vToken contract
     * @param account The address that will have its borrow and supply returned
     * @return borrow The borrow amount
     * @return supply The supply amount
     */
    function borrowAndSupply(IVToken vToken, address account)
        public
        view
        returns (uint256 borrow, uint256 supply)
    {
        borrow = viewCurrentBorrow(vToken, account);
        supply = viewUnderlyingBalanceOf(vToken, account);
    }

    /**
     * @dev It calculates a borrow amount within the collateral requirements and only if there is a current net profit.
     *
     * @notice This function assumes, that we are borrowing the same asset we are using as collateral.
     *
     * @param vToken A Venus vToken contract
     * @param account Address that is asking how much it can borrow
     * @param collateralLimit A percentage that will be put on current TVL to reduce it further
     * @return uint256 The safe borrow amount.
     */
    function safeBorrow(
        IVToken vToken,
        address account,
        uint256 collateralLimit
    ) external view returns (uint256) {
        // Get a safe ratio between borrow amount and collateral required.
        uint256 _collateralLimit = safeCollateralRatio(vToken, collateralLimit);

        // Get the current positions of the `vault` in the `vToken` market.
        (uint256 borrow, uint256 supply) = borrowAndSupply(vToken, account);

        if (supply == 0) return 0;

        // Maximum amount we can borrow based on our supply.
        uint256 maxBorrowAmount = supply.wadMul(_collateralLimit);

        // If we are borrowing more than the recommended amount. We return 0;
        if (borrow >= maxBorrowAmount) return 0;

        // We calculate how much more we can borrow until we hit our safe maximum.
        // We check how much liquidity there is. We cannot borrow more than the liquidity.
        uint256 newBorrowAmount = (maxBorrowAmount - borrow).min(
            vToken.getCash()
        );

        // No point to borrow if there is no cash.
        if (newBorrowAmount == 0) return 0;

        // Take a ratio between our current borrow amount and what
        uint256 newBorrowAmountRatio = borrow > 0
            ? newBorrowAmount.wadDiv(borrow)
            : 0;

        // We ignore borrowing less than 5% of the current borrow.
        if (newBorrowAmountRatio > 0 && newBorrowAmountRatio <= 0.05e18)
            return 0;

        // Get the current cost and profit of borrowing in `vToken`.
        (
            uint256 borrowInterestUSD, // Cost of borrowing underlying
            uint256 rewardInterestUSD // This is the XVS profit.
        ) = borrowInterestPerBlock(vToken, account, newBorrowAmount);

        // Get the current profit of supplying.
        uint256 supplyInterestUSD = supplyRewardPerBlock(
            vToken,
            account,
            newBorrowAmount
        );

        // We only recomment a borrow amount if it is profitable and reduce it by 5% to give a safety margin.
        // 0 represents do not borrow.
        return
            supplyInterestUSD + rewardInterestUSD > borrowInterestUSD
                ? newBorrowAmount
                : 0;
    }

    /**
     * @dev It calculas an amount that can be redeemed without being liquidated from both supply and borrow balances.
     *
     * @param vToken A Venus vToken contract
     * @param account Address that is asking how much it can redeem
     * @param collateralLimit A percentage that will be put on current TVL to reduce it further
     * @return uint256 the safe redeem amount
     */
    function safeRedeem(
        IVToken vToken,
        address account,
        uint256 collateralLimit
    ) external view returns (uint256) {
        // Get current `vault` borrow and supply balances in `vToken`
        (uint256 borrowBalance, uint256 supplyBalance) = borrowAndSupply(
            vToken,
            account
        );
        // If we are not borrowing, we can redeem as much as the liquidity allows
        if (borrowBalance == 0) return supplyBalance.min(vToken.getCash());
        // borrowBalance / collateralLimitRatio will give us a safe supply value that we need to maintain to avoid liquidation.
        uint256 safeCollateral = borrowBalance.wadDiv(
            // Should never be 0. As Venus uses the overcollaterized loan model. Cannot borrow without having collatera.
            // If it is 0, it should throw to alert there is an issue with Venus.
            safeCollateralRatio(vToken, collateralLimit)
        );
        // If our supply is larger than the safe collateral, we can redeem the difference
        // If not, we should not redeem
        uint256 redeemAmount = supplyBalance > safeCollateral
            ? supplyBalance - safeCollateral
            : 0;
        // We cannot redeem more than the current liquidity in the market.
        // This value can be used to safely redeem from the supply or borrow.
        // C
        return redeemAmount.min(vToken.getCash());
    }

    /**
     * @dev Calculates the hypothethical borrow interest rate and XVS rewards per block with an additional `amount`.
     *
     * @notice Use the function {predictBorrowRate} if you wish an `amount` of 0.
     *
     * @param vToken A Venus vToken contract
     * @param account Address that is asking for the borrow interest rate
     * @param amount The calculation will take into account if you intent to borrow an additional `amount` of the underlying token of `vToken`.
     * @return uint256 borrow interest rate per block in USD
     * @return uint256 reward interest rate per block in USD
     */
    function borrowInterestPerBlock(
        IVToken vToken,
        address account,
        uint256 amount
    ) internal view returns (uint256, uint256) {
        uint256 totalBorrow = viewTotalBorrowsCurrent(vToken) + amount;

        // Edge case for a market to have no loans. But since we use it as a denominator, we need to address it.
        if (totalBorrow == 0)
            // It should never happen that we have no borrows and we want to know the cost of borrowing 0.
            return (0, 0);

        IOracle oracle = ORACLE;

        // Return a tuple with 1st being the borrow interest rate (cost), and the second the rewards in XVS (profit)
        return (
            oracle.getTokenUSDPrice(
                vToken.underlying(),
                predictBorrowRate(vToken, amount).wadMul(
                    vToken.borrowBalanceStored(account) + amount
                )
            ),
            oracle.getTokenUSDPrice(
                XVS,
                // Venus speed has 18 decimals
                VENUS_CONTROLLER.venusSpeeds(address(vToken)).mulDiv(
                    vToken.borrowBalanceStored(account) + amount,
                    totalBorrow
                )
            )
        );
    }

    /**
     * @dev This function predicts hypothetically the supply reward per block with an additional `amount`.
     *
     * @notice Use the function {predictSupplyRate} if you wish an `amount` of 0.
     *
     * @param vToken A Venus vToken contract
     * @param account Address that is asking for thesupply reward rate
     * @param borrowAmount An additional borrow amount to calculate the interest rate model for supplying
     * @return uint256 The supply reward rate in USD per block.
     */
    function supplyRewardPerBlock(
        IVToken vToken,
        address account,
        uint256 borrowAmount
    ) internal view returns (uint256) {
        // Total amount of supply amount in the `vToken`.
        uint256 totalSupplyAmount = IERC20Upgradeable(address(vToken))
            .totalSupply()
            .wadMul(viewExchangeRate(vToken));

        // And should not happen, but we need to address it because we use it as a denominator.
        // function above {viewExchangeRate} will throw if the supply is 0
        assert(totalSupplyAmount > 0);

        // Current amount of underlying the `vault` is supplying in the `vToken` market.
        uint256 vaultUnderlyingBalance = viewUnderlyingBalanceOf(
            IVToken(vToken),
            account
        );

        IOracle oracle = ORACLE;

        // Current amount of rewards being paid by supplying in `vToken` in XVS in USD terms per block
        uint256 xvsAmountInUSD = oracle.getTokenUSDPrice(
            XVS,
            VENUS_CONTROLLER.venusSpeeds(address(vToken)).mulDiv(
                vaultUnderlyingBalance,
                totalSupplyAmount
            )
        );

        // Get current supply rate times the amout in `vault`.
        uint256 underlyingSupplyRate = predictSupplyRate(
            IVToken(vToken),
            borrowAmount
        ).wadMul(vaultUnderlyingBalance);

        // Calculate the supply rate considering an additional borrow `amount` per block in USD and add the current XVS rewards in USD per block
        return
            oracle.getTokenUSDPrice(vToken.underlying(), underlyingSupplyRate) +
            xvsAmountInUSD;
    }

    /**
     * @dev Calculate hypothethically the borrow rate based on an additional `amount`.
     *
     * @param vToken A Venus vToken contract
     * @param amount An additional borrow amount
     * @return uint256 Borrow rate per block in underlying token
     */
    function predictBorrowRate(IVToken vToken, uint256 amount)
        internal
        view
        returns (uint256)
    {
        // Get current market liquidity (supply - borrow in underlying)
        uint256 cash = vToken.getCash();

        // Can not borrow more than the current liquidity
        if (amount > cash) amount = cash;

        // Get current interest model being used by the `vToken`.
        IVenusInterestRateModel interestRateModel = IVenusInterestRateModel(
            vToken.interestRateModel()
        );

        // Calculate the borrow rate adjust by borrowing an additional `amount`.
        return
            interestRateModel.getBorrowRate(
                cash - amount,
                viewTotalBorrowsCurrent(vToken) + amount,
                vToken.totalReserves()
            );
    }

    /**
     * @dev Calculates hypothethically the supply rate assuming an additional `borrow` amount.
     *
     * @param vToken A Venus vToken contract
     * @param amount An additional borrow amount
     * @return uint256 Supply rate per block in underlying token
     */
    function predictSupplyRate(IVToken vToken, uint256 amount)
        internal
        view
        returns (uint256)
    {
        // Current market liquidity
        uint256 cash = vToken.getCash();

        // Can not borrow more than the current liquidity
        if (amount > cash) amount = cash;

        // Get current `vToken` interest rate model.
        IVenusInterestRateModel interestRateModel = IVenusInterestRateModel(
            vToken.interestRateModel()
        );

        // Calculate the supply rate adjusted for an additional `borrow` amount.
        return
            interestRateModel.getSupplyRate(
                cash - amount,
                viewTotalBorrowsCurrent(vToken) + amount,
                vToken.totalReserves(),
                vToken.reserveFactorMantissa()
            );
    }

    /**
     * @dev Helper function to see if a vault should delverage, it deleverages much faster than {safeRedeem}.
     * It returns the amount to deleverage.
     * A 0 means the vault should not deleverage and should probably borrow.
     *
     * @param vToken A Venus vToken contract
     * @param account Address that is asking how much it can redeem
     * @param collateralLimit A percentage that will be put on current TVL to reduce it further
     */
    function deleverage(
        IVToken vToken,
        address account,
        uint256 collateralLimit
    ) external view returns (uint256) {
        // Get a safe ratio between borrow amount and collateral required.
        uint256 _collateralLimit = safeCollateralRatio(vToken, collateralLimit);

        // Get the current positions of the `vault` in the `vToken` market.
        (uint256 borrow, uint256 supply) = borrowAndSupply(vToken, account);

        // Maximum amount we can borrow based on our supply.
        uint256 maxSafeBorrowAmount = supply.wadMul(_collateralLimit);

        // If we are not above the maximum amount. We do not need to deleverage and return 0.
        if (maxSafeBorrowAmount >= borrow) return 0;

        // Get the Venus Protocol collateral requirement before liquidation
        (, uint256 venusCollateralFactor, ) = VENUS_CONTROLLER.markets(
            address(vToken)
        );

        // Get all current liquidity
        uint256 cash = vToken.getCash();

        // We add 15% safety room to the {venusCollateralFactor} to avoid liquidation.
        // We assume vaults are using values below 0.8e18 for their collateral ratio
        uint256 safeSupply = borrow.wadDiv(
            venusCollateralFactor.wadMul(0.85e18)
        );

        if (safeSupply > supply) {
            // if the supply is still lower, then it should throw
            uint256 amount = supply -
                borrow.wadDiv(venusCollateralFactor.wadMul(0.95e18));

            // Cannot withdraw more than liquidity
            return amount.min(cash);
        }

        // Cannot withdraw more than liquidity
        return (supply - safeSupply).min(cash);
    }

    /**
     * @dev Calculate the total borrows current by using view functions to reduce the cost
     *
     * @param vToken The vToken we wish to calculate it's current total borrows.
     * @return uint256 The current borrows
     */
    function viewTotalBorrowsCurrent(IVToken vToken)
        public
        view
        returns (uint256)
    {
        uint256 currentBlockNumber = block.number;
        uint256 accrualBlockNumberPrior = vToken.accrualBlockNumber();

        uint256 borrowsPrior = vToken.totalBorrows();

        // If no blocks have passed, the total borrows stored is up to date.
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return borrowsPrior;
        }

        uint256 cashPrior = vToken.getCash();
        uint256 reservesPrior = vToken.totalReserves();

        uint256 borrowRateMantissa = IVenusInterestRateModel(
            vToken.interestRateModel()
        ).getBorrowRate(cashPrior, borrowsPrior, reservesPrior);

        // Borrow rate should never be higher than this value
        require(
            borrowRateMantissa <= BORROW_RATE_MAX_MANTISSA,
            "borrow rate is absurdly high"
        );

        uint256 blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        uint256 simpleInterestFactor = borrowRateMantissa * blockDelta;

        uint256 interestAccumulated = simpleInterestFactor.wadMul(borrowsPrior);

        return interestAccumulated + borrowsPrior;
    }

    /**
     * @dev Use view functions to find out how much a user has in underlying in a vToken.
     *
     * @param vToken The vToken market, that the user has supplied some underlying
     * @param user The underlying balance of this address will be returned
     * @return uint256 Current underlying balance
     */
    function viewUnderlyingBalanceOf(IVToken vToken, address user)
        public
        view
        returns (uint256)
    {
        return vToken.balanceOf(user).wadMul(viewExchangeRate(vToken));
    }

    /**
     * @dev We calculate the current exchange rate by using view variables to reduce the gas cost.
     *
     * @param vToken The current exchange rate will be returned for this market.
     * @return uint256 exchange rate current
     */
    function viewExchangeRate(IVToken vToken) public view returns (uint256) {
        uint256 accrualBlockNumberPrior = vToken.accrualBlockNumber();

        if (accrualBlockNumberPrior == block.number)
            return vToken.exchangeRateStored();

        uint256 totalCash = vToken.getCash();
        uint256 borrowsPrior = vToken.totalBorrows();
        uint256 reservesPrior = vToken.totalReserves();

        uint256 borrowRateMantissa = IVenusInterestRateModel(
            vToken.interestRateModel()
        ).getBorrowRate(totalCash, borrowsPrior, reservesPrior);

        require(
            borrowRateMantissa <= 0.0005e16,
            "borrow rate is absurdly high"
        ); // Same as borrowRateMaxMantissa in vTokenInterfaces.sol

        uint256 interestAccumulated = (borrowRateMantissa *
            (block.number - accrualBlockNumberPrior)).wadMul(borrowsPrior);

        uint256 totalReserves = vToken.reserveFactorMantissa().wadMul(
            interestAccumulated
        ) + reservesPrior;
        uint256 totalBorrows = interestAccumulated + borrowsPrior;
        uint256 totalSupply = IERC20Upgradeable(address(vToken)).totalSupply();

        require(totalSupply > 0, "SV: no supply");

        return (totalCash + totalBorrows - totalReserves).wadDiv(totalSupply);
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
