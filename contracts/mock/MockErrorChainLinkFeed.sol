// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

contract MockErrorChainLinkFeed {
    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(false, "TEST: ERROR");

        // Taken from https://bscscan.com/address/0x0567f2323251f0aab15c8dfb1967e4e8a7d42aee#readContract
        roundId = 36893488147419307956;
        answer = 0;
        startedAt = 1639814685;
        updatedAt = 1639814685;
        answeredInRound = 36893488147419307956;
    }
}

contract MockBytesErrorChainLinkFeed {
    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        assert(false);

        // Taken from https://bscscan.com/address/0x0567f2323251f0aab15c8dfb1967e4e8a7d42aee#readContract
        roundId = 36893488147419307956;
        answer = 0;
        startedAt = 1639814685;
        updatedAt = 1639814685;
        answeredInRound = 36893488147419307956;
    }
}
