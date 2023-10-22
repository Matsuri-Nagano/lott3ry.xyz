// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// interface
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
// contract
import { MockOracle } from "./MockOracle.sol";
import { ERC20 } from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
// lib
import { SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-contracts/utils/math/Math.sol";

contract Lotto is ERC20 {
    using SafeERC20 for IERC20;

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

    uint256 public poolPrizeBalance;
    uint256 public currentEpoch;
    uint256 public maxRewardMultiplier;
    uint256 public constant FEED_BUFFER = 2 hours;

    // TODO assign USDC address for chain ...
    IERC20 public constant usdc = IERC20(address(0)); // USDC

    // import MockOracle
    MockOracle public oracle;

    event SetOracleAddress(address indexed oldAddress, address indexed newAddress);
    event SetMaxRewardMultiplier(uint256 indexed oldVal, uint256 indexed newVal);
    event Buy(address indexed user, uint256 indexed epoch, uint256 indexed number, uint256 amount);
    event Redeem(address indexed user, uint256 indexed epoch, uint256 indexed number, uint256 amount);
    event JoinPoolPrize(address indexed user, uint256 amount, uint256 share);
    event ExitPoolPrize(address indexed user, uint256 amount, uint256 share);

    error InvalidEpochDeadline();
    error InvalidTicketNumber();
    error InvalidWinningNumber();
    error NotPurchased();

    modifier ensureNextEpoch() {
        Epoch storage _epochInfo = epoch[currentEpoch];
        // ensure oracle feed new reward, prevent front-run, 2 hours est.
        if (block.timestamp > _epochInfo.deadline) {
            // check next epoch is started
            Epoch memory _nextEpochInfo = epoch[currentEpoch + 1];
            if (_nextEpochInfo.deadline == 0) endAndStartNewEpoch();
        }
        _;
    }

    constructor(
        address _oracleAddress,
        uint256 _maxRewardMultiplier
    ) {
        oracle = MockOracle(_oracleAddress);
        maxRewardMultiplier = _maxRewardMultiplier;
        // get next deadline from Oracle, sub for 2 hours est.
        ( , uint128 _nextFeedTime) = abi.decode(oracle.getWinningNumberAndNextDeadline(), (uint128, uint128));
        // styling, init epoch at 1
        currentEpoch = 1;
        epoch[1].deadline = _nextFeedTime - FEED_BUFFER;
    }

    function buy(uint256 _number, uint256 _amount) external ensureNextEpoch {
        // check valid number from 000000 to 999999
        if (_number >= 1_000_000) revert InvalidTicketNumber();
        // SLOAD currentEpoch
        uint256 _currentEpoch = currentEpoch;

        userLottery[msg.sender][_currentEpoch][_number] += _amount;
        unchecked {
            poolPrizeBalance += _amount;    
        }
        totalPurchased[_currentEpoch][_number] += _amount;

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        emit Buy(msg.sender, _currentEpoch, _number, _amount);
    }

    function redeem(uint256 _epoch, uint256 _number) external returns (uint256 toWithdraw) {
        // NOTE: ignore checking _epoch, since it'll revert if _epoch is invalid anyway
        Epoch memory _epochInfo = epoch[_epoch];
        if (block.timestamp > _epochInfo.deadline) {
            // check next epoch is started
            Epoch memory _nextEpochInfo = epoch[_epoch + 1];
            if (_nextEpochInfo.deadline == 0) endAndStartNewEpoch();
        }

        // ensure number is a winning one
        if (_epochInfo.winningNumber != _number) revert InvalidWinningNumber();

        uint256 _amount = userLottery[msg.sender][_epoch][_number];
        if (_amount == 0) revert NotPurchased();

        toWithdraw = _amount * _epochInfo.totalReward / totalPurchased[_epoch][_number];
        userLottery[msg.sender][_epoch][_number] = 0;

        usdc.safeTransfer(msg.sender, toWithdraw);
        emit Redeem(msg.sender, _epoch, _number, toWithdraw);
    }

    function endAndStartNewEpoch() public {
        (uint128 _winningNumber, uint128 _nextFeedTime) = abi.decode(oracle.getWinningNumberAndNextDeadline(), (uint128, uint128));
        // update winning number for current epoch when ended & ensure oracle feed new reward, prevent front-run, 2 hours est.
        Epoch storage _epochInfo = epoch[currentEpoch];
        if (_epochInfo.deadline < _nextFeedTime - FEED_BUFFER) revert InvalidEpochDeadline();
        _epochInfo.winningNumber = _winningNumber;
        
        // update poolPrizeBalance in pool, deduct from winning reward
        // TODO import Math
        uint256 totalReward = Math.min(totalPurchased[currentEpoch][_winningNumber] * maxRewardMultiplier, poolPrizeBalance);
        unchecked {
            poolPrizeBalance -= totalReward;
        }
        // update totalReward for current epoch
        _epochInfo.totalReward = totalReward;

        // update next epoch info
        unchecked {
            currentEpoch++;
        }
        Epoch storage _nextEpochInfo = epoch[currentEpoch];
        _nextEpochInfo.deadline = _nextFeedTime - FEED_BUFFER;
    }

    function joinPoolPrize(uint256 _amount) external ensureNextEpoch {
        if (_amount == 0) revert InvalidAmount();
        Epoch storage _epochInfo = epoch[currentEpoch];
        // ensure oracle feed new reward, prevent front-run, 2 hours est.
        if (block.timestamp > _epochInfo.deadline) {
            // check next epoch is started
            Epoch memory _nextEpochInfo = epoch[currentEpoch + 1];
            if (_nextEpochInfo.deadline == 0) endAndStartNewEpoch();
        }
        
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        
        uint256 share = totalSupply() == 0 ? _amount : _amount * totalSupply() / poolPrizeBalance;
        poolPrizeBalance += _amount;

        _mint(msg.sender, share);
        emit JoinPoolPrize(msg.sender, _amount, share);
    }

    function exitPoolPrize(uint256 _share) external ensureNextEpoch {
        if (_share == 0) revert InvalidAmount();
        // NOTE: leave check totalSupply() == 0, will revert anyway, gas saving
        uint256 amount = _share * poolPrizeBalance / totalSupply();
        _burn(msg.sender, _share);
        usdc.safeTransfer(msg.sender, amount);
        emit ExitPoolPrize(msg.sender, amount, _share);
    }

    // write me setter function
    function setOracleAddress(address _oracleAddress) external {
        emit SetOracleAddress(address(oracle), _oracleAddress);
        oracle = MockOracle(_oracleAddress);
    }

    // write me setter function
    function setMaxRewardMultiplier(uint256 _maxRewardMultiplier) external {
        emit SetMaxRewardMultiplier(maxRewardMultiplier, _maxRewardMultiplier);
        maxRewardMultiplier = _maxRewardMultiplier;
    }
}
