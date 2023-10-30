// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import "./interfaces/IChanceOnChain.sol";
import "./interfaces/IAdminController.sol";
import "./interfaces/ILuckyRefunder.sol";
import "./Entities.sol";
import "./Errors.sol";

contract ChanceOnChainUpkeep is VRFConsumerBaseV2, KeeperCompatibleInterface {
  enum UpkeepAction {
    OPEN_SCHEDULED_RAFFLES,
    HAPPEN_OPENED_RAFFLES,
    CLOSE_HAPPENING_RAFFLES,
    REFUND_OPENED_RAFFLES,
    AUTO_END_CLOSED_RAFFLES,
    AUTO_END_REFUND_RAFFLES,
    SELECT_LUCKY_REFUND_USERS,
    REROLL_WINNERS
  }

  uint32 constant MAX_USERS_IN_BATCH = 80;
  uint32 constant MAX_RAFFLES_IN_BATCH = 50;

  VRFCoordinatorV2Interface immutable COORDINATOR;
  uint32 constant CALLBACK_GAS_LIMIT = 2500000;
  uint64 immutable subscriptionId;
  bytes32 immutable keyHash;

  address public keeperRegistryAddress;
  mapping(address => bool) public operators;

  IChanceOnChain public chanceOnChain;
  IAdminController private immutable adminController;
  ILuckyRefunder private immutable luckyRefunder;

  mapping(uint256 => uint256) internal requestIdToRaffleId;
  mapping(uint256 => uint256) internal raffleIdToRandomNumber;

  event SetOperator(address indexed operator, bool allowed);

  // Modifiers
  modifier onlyOwner() {
    if (adminController.owner() != msg.sender) {
      revert NotAllowed();
    }
    _;
  }

  modifier onlyOwnerOrOperator() {
    if (adminController.owner() != msg.sender && !operators[msg.sender]) {
      revert OnlyOperator();
    }
    _;
  }

  constructor(
    address _chanceOnChain,
    address _adminController,
    address _luckyRefunder,
    address _vrfCoordinator,
    uint64 _subscriptionId,
    bytes32 _keyHash
  ) VRFConsumerBaseV2(_vrfCoordinator) {
    chanceOnChain = IChanceOnChain(_chanceOnChain);
    adminController = IAdminController(_adminController);
    luckyRefunder = ILuckyRefunder(_luckyRefunder);
    COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
    subscriptionId = _subscriptionId;
    keyHash = _keyHash;
    operators[msg.sender] = true;

    luckyRefunder.setUpkeeper(address(this));
  }

  function setOperator(address _operator, bool _allowed) public onlyOwner {
    operators[_operator] = _allowed;
    emit SetOperator(_operator, _allowed);
  }

  function setChanceOnChain(IChanceOnChain _chanceOnChain) public onlyOwner {
    chanceOnChain = _chanceOnChain;
  }

  function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData) {
    UpkeepAction action = abi.decode(checkData, (UpkeepAction));

    if (action == UpkeepAction.OPEN_SCHEDULED_RAFFLES) {
      uint256[] memory ids = _getScheduledRafflesToOpen();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.HAPPEN_OPENED_RAFFLES) {
      uint256[] memory ids = _getOpenedRafflesToHappen();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.CLOSE_HAPPENING_RAFFLES) {
      uint256[] memory ids = _getHappeningRafflesToClose();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.REFUND_OPENED_RAFFLES) {
      uint256[] memory ids = _getOpenedRafflesToRefund();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.AUTO_END_CLOSED_RAFFLES) {
      uint256[] memory ids = _getClosedRafflesToAutoEnd();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.AUTO_END_REFUND_RAFFLES) {
      uint256[] memory ids = _getRefundRafflesToAutoEnd();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.SELECT_LUCKY_REFUND_USERS) {
      (uint256 raffleId, uint256 refundAmount, uint32[] memory refundees, uint256[] memory amounts) = _getLuckyRefundUsers();
      upkeepNeeded = refundees.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(raffleId, refundAmount, refundees, amounts));
      }
      return (upkeepNeeded, performData);
    } else if (action == UpkeepAction.REROLL_WINNERS) {
      uint256[] memory ids = _getRerollWinnerRaffles();
      upkeepNeeded = ids.length > 0;
      if (upkeepNeeded) {
        performData = abi.encode(action, abi.encode(ids));
      }
      return (upkeepNeeded, performData);
    }

    return (false, bytes(""));
  }

  function _getScheduledRafflesToOpen() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.SCHEDULED);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (chanceOnChain.getRaffle(id).startTime <= block.timestamp) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getOpenedRafflesToHappen() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.OPENED);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (chanceOnChain.getRaffle(id).ticketsSold >= chanceOnChain.getRaffle(id).minTickets) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getHappeningRafflesToClose() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.HAPPENING);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (
        chanceOnChain.getRaffle(id).ticketsSold == chanceOnChain.getRaffle(id).maxTickets ||
        (chanceOnChain.getRaffle(id).ticketsSold >= chanceOnChain.getRaffle(id).minTickets && chanceOnChain.getRaffle(id).endTime <= block.timestamp)
      ) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getOpenedRafflesToRefund() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.OPENED);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (
        chanceOnChain.getRaffle(id).ticketsSold < chanceOnChain.getRaffle(id).minTickets && chanceOnChain.getRaffle(id).endTime <= block.timestamp
      ) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getClosedRafflesToAutoEnd() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.CLOSED);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (chanceOnChain.getRaffle(id).closedTime + chanceOnChain.getRaffle(id).claimRewardDuration <= block.timestamp) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getRefundRafflesToAutoEnd() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesByStatusIds(RaffleStatus.REFUND);
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      uint256 id = allIds[i];
      if (chanceOnChain.getRaffle(id).refundStartTime + chanceOnChain.getRaffle(id).claimRefundDuration <= block.timestamp) {
        ids[count] = id;
        count++;
      }
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getRerollWinnerRaffles() internal view returns (uint256[] memory ids) {
    uint256[] memory allIds = chanceOnChain.rafflesRerollWinnerIds();
    ids = new uint256[](allIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < allIds.length; i++) {
      ids[count] = allIds[i];
      count++;
      if (count == MAX_RAFFLES_IN_BATCH) {
        break;
      }
    }

    if (count < allIds.length) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(ids, count)
      }
    }
  }

  function _getLuckyRefundUsers()
    internal
    view
    returns (uint256 raffleId, uint256 refundAmount, uint32[] memory refundees, uint256[] memory amounts)
  {
    uint256[] memory ids = luckyRefunder.rafflesSelectUsersIds();
    if (ids.length == 0) {
      return (raffleId, refundAmount, refundees, amounts);
    }
    raffleId = ids[0];

    uint256 remainingAmount = luckyRefunder.raffleAmount(raffleId) - luckyRefunder.raffleAssignedAmount(raffleId);

    // Select lucky refund winners
    uint256 participantsLength = chanceOnChain.raffleParticipantsLength(raffleId);
    bool[] memory selected = new bool[](participantsLength);
    refundees = new uint32[](MAX_USERS_IN_BATCH);
    amounts = new uint256[](MAX_USERS_IN_BATCH);
    uint count = 0;
    uint randomResult = raffleIdToRandomNumber[raffleId];
    while (refundAmount < remainingAmount && count < participantsLength && count != MAX_USERS_IN_BATCH) {
      randomResult = uint(keccak256(abi.encode(randomResult, block.timestamp)));
      uint32 index = uint32(randomResult % participantsLength);

      // To avoid refunding the same person twice
      if (selected[index] || luckyRefunder.isSelectedUser(raffleId, index)) {
        continue;
      }

      Participant memory participant = chanceOnChain.raffleParticipantByIndex(raffleId, index);
      uint256 amountToRefund;
      if (participant.amount > remainingAmount - refundAmount) {
        amountToRefund = remainingAmount - refundAmount;
      } else {
        amountToRefund = participant.amount;
      }
      if (amountToRefund == 0) {
        break;
      }
      refundAmount += amountToRefund;

      selected[index] = true;
      refundees[count] = index;
      amounts[count] = amountToRefund;
      count++;
    }

    if (count < MAX_USERS_IN_BATCH) {
      /// @solidity memory-safe-assembly
      assembly {
        mstore(refundees, count)
        mstore(amounts, count)
      }
    }

    return (raffleId, refundAmount, refundees, amounts);
  }

  function performUpkeep(bytes calldata performData) external override onlyOwnerOrOperator {
    (UpkeepAction action, bytes memory data) = abi.decode(performData, (UpkeepAction, bytes));

    if (action == UpkeepAction.OPEN_SCHEDULED_RAFFLES) {
      _performOpenScheduledRaffles(data);
    } else if (action == UpkeepAction.HAPPEN_OPENED_RAFFLES) {
      _performHappenOpenedRaffles(data);
    } else if (action == UpkeepAction.CLOSE_HAPPENING_RAFFLES) {
      _performCloseHappeningRaffles(data);
    } else if (action == UpkeepAction.REFUND_OPENED_RAFFLES) {
      _performRefundOpenedRaffles(data);
    } else if (action == UpkeepAction.AUTO_END_CLOSED_RAFFLES) {
      _performAutoEndClosedRaffles(data);
    } else if (action == UpkeepAction.AUTO_END_REFUND_RAFFLES) {
      _performAutoEndRefundRaffles(data);
    } else if (action == UpkeepAction.SELECT_LUCKY_REFUND_USERS) {
      _performLuckyRefundUsersUpkeep(data);
    } else if (action == UpkeepAction.REROLL_WINNERS) {
      _performRerollWinnerRaffles(data);
    }
  }

  // OPEN raffles in SCHEDULE state
  function _performOpenScheduledRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (raffle.status == RaffleStatus.SCHEDULED && raffle.startTime <= block.timestamp) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.SCHEDULED, RaffleStatus.OPENED);
      }
    }
  }

  // HAPPENING raffles in OPEN state
  function _performHappenOpenedRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (raffle.status == RaffleStatus.OPENED && raffle.ticketsSold >= raffle.minTickets) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.OPENED, RaffleStatus.HAPPENING);
      }
    }
  }

  // CLOSE raffles in HAPPENING state with minTickets sold
  function _performCloseHappeningRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (
        raffle.status == RaffleStatus.HAPPENING &&
        (raffle.ticketsSold == raffle.maxTickets || (raffle.ticketsSold >= raffle.minTickets && raffle.endTime <= block.timestamp))
      ) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.HAPPENING, RaffleStatus.CLOSED);
        _requestRandomness(ids[i]);
      }
    }
  }

  // REFUND raffles in OPEN state
  function _performRefundOpenedRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (raffle.status == RaffleStatus.OPENED && raffle.ticketsSold < raffle.minTickets && raffle.endTime <= block.timestamp) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.OPENED, raffle.ticketsSold == 0 ? RaffleStatus.AUTO_ENDED : RaffleStatus.REFUND);
      }
    }
  }

  // AUTO_END raffles in CLOSE state
  function _performAutoEndClosedRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (raffle.status == RaffleStatus.CLOSED && raffle.closedTime + raffle.claimRewardDuration <= block.timestamp) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.CLOSED, RaffleStatus.AUTO_ENDED);
      }
    }
  }

  // AUTO_END raffles in REFUND state
  function _performAutoEndRefundRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      Raffle memory raffle = chanceOnChain.getRaffle(ids[i]);
      if (raffle.status == RaffleStatus.REFUND && raffle.refundStartTime + raffle.claimRefundDuration <= block.timestamp) {
        chanceOnChain.switchRaffleStatus(ids[i], RaffleStatus.REFUND, RaffleStatus.AUTO_ENDED);
      }
    }
  }

  function _performRerollWinnerRaffles(bytes memory performData) internal {
    uint256[] memory ids = abi.decode(performData, (uint256[]));

    for (uint256 i = 0; i < ids.length; i++) {
      if (!chanceOnChain.isRerollWinnerRaffle(ids[i])) {
        continue;
      }
      _requestRandomness(ids[i]);
    }
  }

  function _performLuckyRefundUsersUpkeep(bytes memory performData) internal {
    (uint256 raffleId, uint256 refundAmount, uint32[] memory refundees, uint256[] memory amounts) = abi.decode(
      performData,
      (uint256, uint256, uint32[], uint256[])
    );

    if (
      luckyRefunder.raffleAmount(raffleId) == luckyRefunder.raffleAssignedAmount(raffleId) ||
      refundees.length != amounts.length ||
      refundees.length == 0
    ) {
      return;
    }

    luckyRefunder.addUsers(raffleId, refundAmount, refundees, amounts);
  }

  function _requestRandomness(uint256 _raffleId) internal {
    uint256 requestId = COORDINATOR.requestRandomWords(keyHash, subscriptionId, 10, CALLBACK_GAS_LIMIT, 1);
    requestIdToRaffleId[requestId] = _raffleId;
  }

  function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
    uint256 randomness = randomWords[0];
    uint256 raffleId = requestIdToRaffleId[requestId];

    raffleIdToRandomNumber[raffleId] = randomness;

    chanceOnChain.selectWinner(raffleId, randomness);
  }
}
