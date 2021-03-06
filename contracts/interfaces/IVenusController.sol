// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

interface IVenusController {
    function enterMarkets(address[] memory _vtokens)
        external
        returns (uint256[] memory);

    function exitMarket(address _vtoken) external returns (uint256);

    function markets(address vTokenAddress)
        external
        view
        returns (
            bool,
            uint256,
            bool
        );

    function getAccountLiquidity(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function claimVenus(address holder) external;

    function claimVenus(address holder, address[] memory vTokens) external;

    function venusSpeeds(address vToken) external view returns (uint256);
}
