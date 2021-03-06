/*


██╗███╗░░██╗████████╗███████╗██████╗░███████╗░██████╗████████╗  ░█████╗░██████╗░░█████╗░░█████╗░██╗░░░░░███████╗
██║████╗░██║╚══██╔══╝██╔════╝██╔══██╗██╔════╝██╔════╝╚══██╔══╝  ██╔══██╗██╔══██╗██╔══██╗██╔══██╗██║░░░░░██╔════╝
██║██╔██╗██║░░░██║░░░█████╗░░██████╔╝█████╗░░╚█████╗░░░░██║░░░  ██║░░██║██████╔╝███████║██║░░╚═╝██║░░░░░█████╗░░
██║██║╚████║░░░██║░░░██╔══╝░░██╔══██╗██╔══╝░░░╚═══██╗░░░██║░░░  ██║░░██║██╔══██╗██╔══██║██║░░██╗██║░░░░░██╔══╝░░
██║██║░╚███║░░░██║░░░███████╗██║░░██║███████╗██████╔╝░░░██║░░░  ╚█████╔╝██║░░██║██║░░██║╚█████╔╝███████╗███████╗
╚═╝╚═╝░░╚══╝░░░╚═╝░░░╚══════╝╚═╝░░╚═╝╚══════╝╚═════╝░░░░╚═╝░░░  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝░╚════╝░╚══════╝╚══════╝

*/

//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IOracle.sol";

import "./lib/Math.sol";
import "./lib/IntERC20.sol";
import "./lib/SafeCastLib.sol";

import "./PancakeOracle.sol";

/**
 * @dev A wrapper around the Chainlink oracles to feed prices to the markets. It aims to house all oracle logic of the protocol.
 *
 * @notice Auditors please check that the contract always return the price with 18 decimals both from Chainlink and PCS.
 * @notice The lending markets rely on this being the case.
 * @notice Security of this contract relies on Chainlink.
 * @notice We scale all decimals to 18 to follow the same decimals as WBNB and BUSD.
 * @notice It supports LP tokens.
 * @notice We intend to add a back up oracle using PCS TWAPS before main net release.
 * @notice It does not treat in case of a price of 0 or failure.
 * @notice Only supports tokens supported by Chainlink  https://docs.chain.link/docs/binance-smart-chain-addresses/.
 * @notice We assume that BUSD is USD - 0x4Fabb145d64652a948d72533023f6E7A623C7C53
 */
contract Oracle is Initializable, OwnableUpgradeable, UUPSUpgradeable, IOracle {
    /*///////////////////////////////////////////////////////////////
                            LIBRARIES
    //////////////////////////////////////////////////////////////*/
    using SafeCastLib for *;
    using Math for uint256;
    using IntERC20 for address;

    /*///////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    // To dictate if it is a BNB or USD feed.
    enum FeedType {
        USD,
        BNB
    }

    /*///////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // solhint-disable-next-line var-name-mixedcase
    AggregatorV3Interface internal constant BNB_USD =
        AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);

    // solhint-disable-next-line var-name-mixedcase
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // 18 decimals

    // solhint-disable-next-line var-name-mixedcase
    address internal constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    // solhint-disable-next-line var-name-mixedcase
    PancakeOracle public TWAP;

    // Token Address -> Chainlink feed with USD base.
    mapping(address => AggregatorV3Interface) public getUSDFeeds;
    // Token Address -> Chainlink feed with BNB base.
    mapping(address => AggregatorV3Interface) public getBNBFeeds;

    /*///////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @param twap The address of our internal PCS TWAP
     *
     * Requirements:
     *
     * - Can only be called at once and should be called during creation to prevent front running.
     */
    function initialize(PancakeOracle twap) external initializer {
        __Ownable_init();

        TWAP = twap;
    }

    /*///////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Adjusts the price to have 18 decimal houses to work easier with most {ERC20}.
     *
     * @param price The price of the token
     * @param decimals The current decimals the price has
     * @return uint256 the new price supporting 18 decimal houses
     */
    function _scaleDecimals(uint256 price, uint8 decimals)
        private
        pure
        returns (uint256)
    {
        uint256 baseDecimals = 18;

        if (decimals == baseDecimals) return price;

        if (decimals < baseDecimals)
            return price * 10**(baseDecimals - decimals);

        return price / 10**(decimals - baseDecimals);
    }

    /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev It returns usd value of {ERC20} tokens and checks if they are a PCS LP token or not.
     *
     * @notice Note the usd price has a mantissa of 1e18.
     *
     * @param token The address of the {ERC20} token
     * @param amount The number of `token` to evaluate the USD amount
     * @return usdValue The value in usd.
     */
    function getUSDPrice(address token, uint256 amount)
        external
        view
        returns (uint256 usdValue)
    {
        // Check if it is a pancake pair.
        if (
            keccak256(abi.encodePacked(IPancakePair(token).symbol())) ==
            keccak256("Cake-LP")
        ) {
            (, usdValue) = getLPTokenPx(IPancakePair(token), amount);
        } else {
            usdValue = getTokenUSDPrice(token, amount);
        }
    }

    /**
     * @dev It calls chainlink to get the USD price of a token and adjusts the decimals.
     *
     * @notice On the TWAP we assume 1 BUSD is 1 USD.
     * @notice The amount will have 18 decimals
     * @notice We assume that TWAP will support token/BNB as this is the most common pairing and not token/BUSD or token/USDC.
     *
     * @param token The address of the token for the feed.
     * @param amount The number of tokens to calculate the value in USD.
     * @return price uint256 The price of the token in USD.
     */
    function getTokenUSDPrice(address token, uint256 amount)
        public
        view
        returns (uint256 price)
    {
        require(token != address(0), "Oracle: no address zero");
        // BNB feed is not saved in a mapping for gas optimization.
        if (token == WBNB) return getBNBUSDPrice(amount);

        AggregatorV3Interface feed = getUSDFeeds[token];

        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256,
            uint80
        ) {
            price = _scaleDecimals(answer.toUint256(), feed.decimals()).wadMul(
                amount
            );
        } catch Error(string memory) {
            // Get the token price in BNB as token/BUSD pairs are rare
            uint256 bnbPrice = _scaleDecimals(
                TWAP.consult(token, amount, WBNB),
                WBNB.safeDecimals()
            );

            // Then get BNB price in
            // We just need price for 1BNB because we already computed the amount above
            price = bnbPrice.wadMul(getBNBUSDPrice(1 ether));
        } catch (bytes memory) {
            // Get the token price in BNB as token/BUSD pairs are rare
            uint256 bnbPrice = _scaleDecimals(
                TWAP.consult(token, amount, WBNB),
                WBNB.safeDecimals()
            );

            // Then get BNB price in
            // We just need price for 1BNB because we already computed the amount above
            price = bnbPrice.wadMul(getBNBUSDPrice(1 ether));
        }
    }

    /**
     * @dev It returns the both price BNB and USD value for an amount of LP tokens based on the fair liquidity.
     *
     * @param pair The Pancake pair we wish to get the fair bnb value
     * @param amount The number of LPs we wish to have the value for
     * @return valueInBNB valueInUSD (uint256 , uint256) A pair with both the value in BNB and USD
     */
    function getLPTokenPx(IPancakePair pair, uint256 amount)
        public
        view
        returns (uint256 valueInBNB, uint256 valueInUSD)
    {
        uint256 fairBNBValue = getLPTokenBNBPrice(pair);
        // Since amount and price both have a mantissa of 1e18, we need to divide by 1e18.
        valueInBNB = fairBNBValue.wadMul(amount);
        // Since bnb and usd both have a mantissa of 1e18, we need to divide by 1e18.
        valueInUSD = valueInBNB.wadMul(getBNBUSDPrice(1 ether));
    }

    /**
     * @dev It calculates the price in BNB for 1 lp token based on the K of the pair. Wanna thank Alpha Finance for this <3!
     *
     * @param pair The Pancakeswap pair to find it's fair BNB value.
     * @return uint256 price of 1 lp token in BNB
     *
     * The formula breakdown can be found in the links below:
     *
     * https://cmichel.io/pricing-lp-tokens/
     * https://blog.alphafinance.io/fair-lp-token-pricing/
     *
     * We changed the implementation from alpha finance to remove the Q112 encoding found here:
     * https://github.com/AlphaFinanceLab/alpha-homora-v2-contract/blob/master/contracts/oracle/UniswapV2Oracle.sol
     *
     */
    function getLPTokenBNBPrice(IPancakePair pair)
        public
        view
        returns (uint256)
    {
        address token0 = pair.token0();
        address token1 = pair.token1();
        uint256 totalSupply = pair.totalSupply();
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();

        // Get square root of K
        uint256 sqrtK = Math.sqrt(reserve0 * (reserve1)) / totalSupply;

        // Relies on chainlink to get the token value in BNB
        uint256 price0 = getTokenBNBPrice(token0, 1 ether);
        uint256 price1 = getTokenBNBPrice(token1, 1 ether);

        // Get fair price of LP token in BNB by re-engineering the K formula.
        return (((sqrtK * 2 * (Math.sqrt(price0)))) * (Math.sqrt(price1)));
    }

    /**
     * @dev We first try to get the price from Chainlink as it is more accurate. But in case it fails we will read from a PCS TWAP.
     *
     * @notice We know that WBNB has 18 decimals and we are asking for the price in WBNB. So we do not need to scale the decimals.
     * @notice We assume that the `token` and {WBNB} pair exists in Pancake Swap.
     *
     * @param token The address of the token we wish to find the price in BNB amount
     * @param amount The amount of tokens
     * @return price The amount of BNB `amount` of `token` is worth.
     *
     */
    function getTokenBNBPrice(address token, uint256 amount)
        public
        view
        returns (uint256 price)
    {
        // 1 BNB is always 1 BNB
        if (token == WBNB) return amount;
        require(token != address(0), "Oracle: no address zero");

        AggregatorV3Interface feed = getBNBFeeds[token];
        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256,
            uint80
        ) {
            price = _scaleDecimals(answer.toUint256(), feed.decimals()).wadMul(
                amount
            );
        } catch Error(string memory) {
            price = _scaleDecimals(
                TWAP.consult(token, amount, WBNB),
                WBNB.safeDecimals()
            );
        } catch (bytes memory) {
            price = _scaleDecimals(
                TWAP.consult(token, amount, WBNB),
                WBNB.safeDecimals()
            );
        }
    }

    /**
     * @dev Get the current price of BNB in USD.
     *
     * @param amount How many BNB one wishes to get the price for
     * @return uint256 A pair that has the value price and the decimal houses in the right
     */
    function getBNBUSDPrice(uint256 amount) public view returns (uint256) {
        try BNB_USD.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256,
            uint80
        ) {
            return
                (_scaleDecimals(answer.toUint256(), BNB_USD.decimals())).wadMul(
                    amount
                );
        } catch Error(string memory) {
            return
                _scaleDecimals(
                    TWAP.consult(WBNB, amount, BUSD),
                    BUSD.safeDecimals()
                );
        } catch (bytes memory) {
            return
                _scaleDecimals(
                    TWAP.consult(WBNB, amount, BUSD),
                    BUSD.safeDecimals()
                );
        }
    }

    /*///////////////////////////////////////////////////////////////
                            OWNER ONLY FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Sets a chain link {AggregatorV3Interface} feed for an asset.
     *
     * @param asset The token that will be associated with a feed.
     * @param feed The address of the chain link oracle contract.
     * @param feedType A enum representing which kind of feed to update
     *
     * **** IMPORTANT ****
     * @notice This contract only supports tokens with 18 decimals.
     * @notice You can find the avaliable feeds here https://docs.chain.link/docs/binance-smart-chain-addresses/
     *
     * Requirements:
     *
     * - This function has the modifier {onlyOwner} because the whole protocol depends on the quality and veracity of these feeds. It will be behind a multisig and timelock as soon as possible.
     */
    function setFeed(
        address asset,
        AggregatorV3Interface feed,
        FeedType feedType
    ) external onlyOwner {
        if (feedType == FeedType.BNB) {
            getBNBFeeds[asset] = feed;
        } else {
            getUSDFeeds[asset] = feed;
        }
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
