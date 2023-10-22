// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { MockOracle } from "./MockOracle.sol";

contract Lotto {
    struct Epoch {
        uint32 winningNumber;
        uint64 deadline;
        uint128 totalReward;
    }

    // user -> epoch -> number -> deposit amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public userLottery;
    // epoch -> number -> amount
    mapping(uint256 => mapping(uint256 => uint256)) public totalPurchased;
    // epoch -> epoch info
    mapping(uint256 => Epoch) public epoch;

    uint256 public totalBalance;
    uint256 public currentEpoch;
    uint256 public maxRewardMultiplier;
    uint256 public constant FEED_BUFFER = 2 hours;

    // import MockOracle
    MockOracle public oracle;

    error InvalidEpoch();
    error InvalidTicketNumber();
    error InvalidWinningNumber();

    constructor(
        address _oracleAddress,
        uint256 _maxRewardMultiplier
    ) {
        // TODO assign oracle address
        oracle = MockOracle(_oracleAddress);
        currentEpoch = 1;
        maxRewardMultiplier = _maxRewardMultiplier;
        // TODO get next deadline from Oracle, sub for 2 hours est.
        epoch[currentEpoch] = Epoch(block.timestamp + 7 days, 0, 0);
    }

    function buy(uint256 _number, uint256 _amount) external {
        // check valid number from 000000 to 999999
        if (_number >= 1_000_000) revert InvalidTicketNumber();
        // check in current epoch
        Epoch memory _epochInfo = epoch[currentEpoch];
        if (block.timestamp > _epochInfo.deadline) revert InvalidEpoch();

        userLottery[msg.sender][currentEpoch][_number] += _amount;
        totalBalance += _amount;
        totalPurchased[currentEpoch][_number] += _amount;
    }

    function redeem(uint256 _epoch, uint256 _number) external {
        // NOTE: ignore checking _epoch, since it'll revert if _epoch is invalid anyway
        Epoch memory _epochInfo = epoch[_epoch];
        // ensure number is a winning one
        if (_epochInfo.winningNumber != _number) revert InvalidWinningNumber();
    }

    // start new epoch, reward of this epoch
    function endAndStartNewEpoch() external {
        // TODO handle oracle
        (uint128 _winningNumber, uint128 _nextFeedTime) = abi.decode(oracle.getWinningNumberAndNextDeadline(), (uint128, uint128));
        // update winning number for current epoch when ended
        Epoch storage _epochInfo = epoch[currentEpoch];
        // ensure oracle feed new reward, prevent front-run, 2 hours est.
        if (_epochInfo.deadline < _nextFeedTime - FEED_BUFFER) revert InvalidEpoch();
        _epochInfo.winningNumber = _winningNumber;
        
        // update totalBalance in pool, deduct from winning reward
        // TODO import Math
        uint256 totalReward = Math.min(totalPurchased[currentEpoch][_winningNumber] * maxRewardMultiplier, totalBalance);
        totalBalance -= totalReward;
        _epochInfo.totalReward = totalReward;

        // update next epoch info
        Epoch memory _nextEpochInfo;
        _nextEpochInfo.deadline = _nextFeedTime - FEED_BUFFER;
        currentEpoch++;
        epoch[currentEpoch] = _nextEpochInfo;
    }

}
