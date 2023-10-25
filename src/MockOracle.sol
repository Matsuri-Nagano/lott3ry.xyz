// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MockOracle {
    bytes public lastAnswer;

    constructor() {
        // mock
        uint128 _winningNumber = 128450;
        uint128 _nextFeedTime = uint128(block.timestamp + 7 days);
        lastAnswer = bytes(abi.encode(_winningNumber, _nextFeedTime));
    }

    function getWinningNumberAndNextDeadline() external view returns (bytes memory) {
        return lastAnswer;
    }
}