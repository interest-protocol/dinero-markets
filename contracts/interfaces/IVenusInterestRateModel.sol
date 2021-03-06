// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

/**
 * @dev We made them non-view functions for testing purposes. It should not present any risk to the contracts.
 */
interface IVenusInterestRateModel {
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256);

    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) external view returns (uint256);
}
