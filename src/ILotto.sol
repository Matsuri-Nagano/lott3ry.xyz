// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILotto {
    // view state
    function userLottery(address user, uint256 epoch, uint256 number) external view returns (uint256 amount);

    function totalPurchased(uint256 epoch, uint256 number) external view returns (uint256 amount);

    function epoch(uint256 epoch) external view returns (uint32 winningNumber, uint64 deadline, uint128 totalReward);

    function poolPrizeBalance() external view returns (uint256);

    function currentEpoch() external view returns (uint256);

    function maxRewardMultiplier() external view returns (uint256);

    function usdc() external view returns (IERC20);

    function decimals() external view returns (uint8);


    // write functions
    function buy(uint256 number, uint256 amount) external;
    
    function redeem(uint256 epoch, uint256 number) external;
    
    function joinPoolPrize(uint256 amount) external;
    
    function exitPoolPrize(uint256 share) external;
    
    function endAndStartNewEpoch() external;
    
}