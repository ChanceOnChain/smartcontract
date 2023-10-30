// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "../Entities.sol";

interface IChanceOnChain {
  function getRaffle(uint256 _raffleId) external view returns (Raffle memory);

  function updateRaffle(Raffle memory raffle) external;

  function calcTickets(uint256 _prizeValue, uint256 _ticketPrice, uint256 _margin, uint256 _maxMargin) external pure returns (uint256, uint256);

  function rafflesLength() external view returns (uint256);

  function raffleParticipants(uint256 _raffleId) external view returns (Participant[] memory);

  function raffleParticipantsLength(uint256 _raffleId) external view returns (uint256);

  function raffleParticipant(uint256 _raffleId, address _participant) external view returns (Participant memory);

  function raffleParticipantByIndex(uint256 _raffleId, uint256 _index) external view returns (Participant memory);

  function rafflesByStatusLength(RaffleStatus _status) external view returns (uint256);

  function rafflesByStatusIds(RaffleStatus _status) external view returns (uint256[] memory);

  function rafflesRerollWinnerIds() external view returns (uint256[] memory);

  function isRerollWinnerRaffle(uint256 id) external view returns (bool);

  function switchRaffleStatus(uint256 _raffleId, RaffleStatus _oldStatus, RaffleStatus _newStatus) external;

  function selectWinner(uint256 raffleId, uint256 randomness) external;

  function onClaimLuckyRefund(uint256 _raffleId, address _user) external;
}
