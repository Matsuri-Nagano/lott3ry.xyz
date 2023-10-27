// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Lotto contract
/// @author Matsuri-Nagano
/// @notice This contract is used for Lotto game

// interface
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// contract
import {MockOracle} from "./MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// lib
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Lotto is ERC20, Ownable {
    using SafeERC20 for IERC20;

    struct Epoch {
        uint32 winningNumber;
        uint64 deadline;
        uint128 totalReward;
    }

    // user -> epoch -> number -> deposit amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public userLottery;
    // epoch -> number -> amount
    mapping(uint256 => mapping(uint256 => uint256)) public totalPurchased;
    // epoch -> epoch info
    mapping(uint256 => Epoch) public epoch;

    uint256 public poolPrizeBalance;
    uint256 public currentEpoch;
    uint256 public maxRewardMultiplier;
    uint256 public constant FEED_BUFFER = 2 hours;

    uint8 private _decimals = 6;

    IERC20 public immutable usdc;
    MockOracle public oracle;

    event SetOracleAddress(
        address indexed oldAddress,
        address indexed newAddress
    );
    event SetMaxRewardMultiplier(
        uint256 indexed oldVal,
        uint256 indexed newVal
    );
    event Buy(
        address indexed user,
        uint256 indexed epoch,
        uint256 indexed number,
        uint256 amount
    );
    event Redeem(
        address indexed user,
        uint256 indexed epoch,
        uint256 indexed number,
        uint256 amount
    );
    event JoinPoolPrize(address indexed user, uint256 amount, uint256 share);
    event ExitPoolPrize(address indexed user, uint256 amount, uint256 share);
    event EndAndStartNewEpoch(uint256 nextEpoch, uint64 deadline);

    error InvalidAmount();
    error InvalidEpochDeadline();
    error InvalidTicketNumber();
    error InvalidWinningNumber();
    error NotPurchased();

    modifier ensureNextEpoch() {
        uint256 _currentEpoch = currentEpoch;
        Epoch storage _epochInfo = epoch[_currentEpoch];
        // ensure oracle feed new reward, prevent front-run, 2 hours est.
        if (block.timestamp > _epochInfo.deadline) {
            // check next epoch is started
            Epoch memory _nextEpochInfo = epoch[_currentEpoch + 1];
            if (_nextEpochInfo.deadline == 0) endAndStartNewEpoch();
        }
        _;
    }

    constructor(
        address _oracleAddress,
        address _usdc,
        uint256 _maxRewardMultiplier
    ) Ownable(msg.sender) ERC20("Lotto.xyz's Share Token", "LOTTO") {
        oracle = MockOracle(_oracleAddress);
        maxRewardMultiplier = _maxRewardMultiplier;
        usdc = IERC20(_usdc);
        // get next deadline from Oracle, sub for 2 hours est.
        (, uint128 _nextFeedTime) = abi.decode(
            oracle.getWinningNumberAndNextDeadline(),
            (uint128, uint128)
        );
        // styling, init epoch at 1
        currentEpoch = 1;
        epoch[1].deadline = uint64(_nextFeedTime - FEED_BUFFER);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev This function is for anyone wishes to buy ticket
     *      By inputting number and amount of USDC they wish to buy
     * @param _number number from 0000000 to 999999
     * @param _amount amount of USDC to buy
     */
    function buy(uint256 _number, uint256 _amount) external ensureNextEpoch {
        // check valid number from 000000 to 999999
        if (_number >= 1_000_000) revert InvalidTicketNumber();

        uint256 _currentEpoch = currentEpoch;

        unchecked {
            userLottery[msg.sender][_currentEpoch][_number] += _amount;
            poolPrizeBalance += _amount;
            totalPurchased[_currentEpoch][_number] += _amount;
        }

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        emit Buy(msg.sender, _currentEpoch, _number, _amount);
    }

    /**
     * @dev This function is for anyone wishes to redeem ticket
     *      By inputting epoch and number they win in that epoch, incase they won
     * @param _epoch epoch to redeem
     * @param _number number to redeem
     */
    function redeem(
        uint256 _epoch,
        uint256 _number
    ) external returns (uint256 toWithdraw) {
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

        toWithdraw =
            (_amount * _epochInfo.totalReward) /
            totalPurchased[_epoch][_number];
        userLottery[msg.sender][_epoch][_number] = 0;

        usdc.safeTransfer(msg.sender, toWithdraw);
        emit Redeem(msg.sender, _epoch, _number, toWithdraw);
    }

    /**
     * @dev end current epoch and start new epoch,
     * this public function is called by `ensureNextEpoch` modifier,
     * or could be called by anyone.
     */
    function endAndStartNewEpoch() public {
        uint256 _currentEpoch = currentEpoch;
        (uint128 _winningNumber, uint128 _nextFeedTime) = abi.decode(
            oracle.getWinningNumberAndNextDeadline(),
            (uint128, uint128)
        );
        // update winning number for current epoch when ended & ensure oracle feed new reward, prevent front-run, 2 hours est.
        Epoch storage _epochInfo = epoch[_currentEpoch];
        if (_epochInfo.deadline < _nextFeedTime - FEED_BUFFER) {
            revert InvalidEpochDeadline();
        }
        _epochInfo.winningNumber = uint32(_winningNumber);

        // update poolPrizeBalance in pool, deduct from winning reward
        uint256 totalReward = Math.min(
            totalPurchased[_currentEpoch][_winningNumber] * maxRewardMultiplier,
            poolPrizeBalance
        );
        unchecked {
            poolPrizeBalance -= totalReward;
        }
        // update totalReward for current epoch
        _epochInfo.totalReward = uint128(totalReward);

        // update next epoch info
        unchecked {
            _currentEpoch++;
            currentEpoch = _currentEpoch;
        }
        Epoch storage _nextEpochInfo = epoch[_currentEpoch];
        _nextEpochInfo.deadline = uint64(_nextFeedTime - FEED_BUFFER);

        emit EndAndStartNewEpoch(_currentEpoch, _nextEpochInfo.deadline);
    }

    /**
     * @notice This function is for anyone wishes to join pool prize
     *         which, will calculate share amount of contract's token
     *         for profit/loss calculation
     * @dev This function will mint share token to msg.sender
     * @param _amount amount of USDC to join pool prize
     * @return share amount of share token
     */
    function joinPoolPrize(
        uint256 _amount
    ) external ensureNextEpoch returns (uint256 share) {
        if (_amount == 0) revert InvalidAmount();
        uint256 _currentEpoch = currentEpoch;
        Epoch storage _epochInfo = epoch[_currentEpoch];

        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 totalSupply = totalSupply();

        share = totalSupply == 0
            ? _amount
            : (_amount * totalSupply) / poolPrizeBalance;

        unchecked {
            poolPrizeBalance += _amount;
        }

        _mint(msg.sender, share);
        emit JoinPoolPrize(msg.sender, _amount, share);
    }

    /**
     * @notice This function is for anyone wishes to exit pool prize
     *         which, will redeem input share, then calculate it
     *         into USDC amount.
     * @dev This function will burn share token from msg.sender
     * @param _share amount of USDC to join pool prize
     * @return amount amount of USDC received from redeem share
     */
    function exitPoolPrize(
        uint256 _share
    ) external ensureNextEpoch returns (uint256 amount) {
        if (_share == 0) revert InvalidAmount();

        amount = (_share * poolPrizeBalance) / totalSupply();
        _burn(msg.sender, _share);
        usdc.safeTransfer(msg.sender, amount);
        emit ExitPoolPrize(msg.sender, amount, _share);
    }

    function setOracleAddress(address _oracleAddress) external onlyOwner {
        emit SetOracleAddress(address(oracle), _oracleAddress);
        oracle = MockOracle(_oracleAddress);
    }

    function setMaxRewardMultiplier(
        uint256 _maxRewardMultiplier
    ) external onlyOwner {
        emit SetMaxRewardMultiplier(maxRewardMultiplier, _maxRewardMultiplier);
        maxRewardMultiplier = _maxRewardMultiplier;
    }
}
