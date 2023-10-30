// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

interface ILuckyRefunder {
  function raffleAmount(uint256 _raffleId) external view returns (uint256);

  function raffleAssignedAmount(uint256 _raffleId) external view returns (uint256);

  function raffleClaimedAmount(uint256 _raffleId) external view returns (uint256);

  function raffleUserAmount(uint256 raffleId, address user) external view returns (uint256);

  function isExcludedUser(uint256 raffleId, address user) external view returns (bool);

  function isSelectedUser(uint256 _raffleId, uint32 _index) external view returns (bool);

  function rafflesSelectUsersIds() external view returns (uint256[] memory);

  function paticipantDetails(uint256 _raffleId, address _user) external view returns (bool, uint256);

  function setChanceOnChain(address _chanceOnChain) external;

  function setUpkeeper(address _upkeeper) external;

  function excludeUser(uint256 _raffleId, address _user) external;

  function onSelectWinner(uint256 _raffleId) external returns (uint256);

  function addUsers(uint256 _raffleId, uint256 _refundAmount, uint32[] memory _refundees, uint256[] memory _amounts) external;
}
