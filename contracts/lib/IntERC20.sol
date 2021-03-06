// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @dev All credits to boring crypto https://github.com/boringcrypto/BoringSolidity/blob/master/contracts/libraries/BoringERC20.sol
 */
library IntERC20 {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes4 private constant SIG_DECIMALS = 0x313ce567; // decimals()
    bytes4 private constant SIG_SYMBOL = 0x95d89b41; // symbol()

    function returnDataToString(bytes memory data)
        internal
        pure
        returns (string memory)
    {
        if (data.length >= 64) {
            return abi.decode(data, (string));
        } else if (data.length == 32) {
            uint8 i = 0;
            while (i < 32 && data[i] != 0) {
                i++;
            }
            bytes memory bytesArray = new bytes(i);
            for (i = 0; i < 32 && data[i] != 0; i++) {
                bytesArray[i] = data[i];
            }
            return string(bytesArray);
        } else {
            return "???";
        }
    }

    /// @notice Provides a safe ERC20.symbol version which returns '???' as fallback string.
    /// @param token The address of the ERC-20 token contract.
    /// @return (string) Token symbol.
    function safeSymbol(address token) internal view returns (string memory) {
        require(isContract(token), "IntERC20: not a contract");

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(SIG_SYMBOL)
        );
        return success ? returnDataToString(data) : "???";
    }

    /// @notice Provides a safe ERC20.decimals version which returns '18' as fallback value.
    /// @param token The address of the ERC-20 token contract.
    /// @return (uint8) Token decimals.
    function safeDecimals(address token) internal view returns (uint8) {
        require(isContract(token), "IntERC20: not a contract");

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(SIG_DECIMALS)
        );
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    function isPair(address token) internal view returns (bool result) {
        return
            keccak256(abi.encodePacked(safeSymbol(token))) ==
            keccak256("Cake-LP");
    }

    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /**
     * @dev Helper function to check the balance of a `token` this contract has.
     *
     * @param token An ERC20 token.
     * @return uint256 The number of `token` in this contract.
     */
    function contractBalanceOf(address token) internal view returns (uint256) {
        // Find how many ERC20 tokens this contract has.
        return IERC20Upgradeable(token).balanceOf(address(this));
    }

    /**
     * @dev Due to math limitations, some dust must be left in the calculations. To prevent such errors we will send the current balance if the amount is higher. However it should never deviate more than 1 unit
     *
     * @param token The ERC20 to send
     * @param to The address to send the ERC20
     * @param amount The number of `token` to send.
     */
    function safeERC20Transfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        uint256 balance = contractBalanceOf(token);
        IERC20Upgradeable(token).safeTransfer(
            to,
            amount > balance ? balance : amount
        );
    }
}
