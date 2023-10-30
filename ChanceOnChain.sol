// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IChanceOnChain.sol";
import "./interfaces/IAdminController.sol";
import "./interfaces/ISettingsStorage.sol";
import "./interfaces/ILuckyRefunder.sol";
import "./MathTestLib.sol";
import "./Entities.sol";
import "./Errors.sol";

contract ChanceOnChain {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;
  using MathTestLib for MathTestLib.MathTest;

  uint32 constant MAX_BPS = 10_000;

  IERC20 immutable USDT;

  address public upkeeper;
  address public raffleUpdater;

  IAdminController private immutable adminController;
  ISettingsStorage private immutable settingsStorage;
  ILuckyRefunder private immutable luckyRefunder;

  Raffle[] private _raffles;
  mapping(RaffleStatus => EnumerableSet.UintSet) private _rafflesByStatus;
  EnumerableSet.UintSet private _rafflesRerollWinner;
  mapping(uint256 => Entry[]) private _raffleEntries;
  mapping(address => EnumerableSet.UintSet) private _userRaffles;
  mapping(uint256 => Participant[]) private _raffleParticipants;
  mapping(uint256 => MathTestLib.MathTest) private _raffleMathTest;
  mapping(uint256 => mapping(address => bool)) private _raffleExcludedWinners;
  mapping(uint256 => uint256) private _raffleRerollAttempts;
  mapping(uint256 => mapping(address => uint256)) private _raffleParticipantIndex;

  // Events
  event CreateRaffle(uint256 indexed raffleId);
  event BuyTickets(uint256 indexed raffleId, address indexed user, uint256 numTickets);
  event ClaimPrize(uint256 indexed raffleId, address indexed user, bool cashAlternative, uint256 amount);
  event ClaimRefund(uint256 indexed raffleId, address indexed user, uint256 refundAmount);
  event SelectWinner(uint256 indexed raffleId, address indexed user);
  event ChangeStatus(uint256 indexed raffleId, RaffleStatus oldStatus, RaffleStatus newStatus);
  event SetRaffleRecurrency(uint256 indexed raffleId, bool recurrent);
  event UpdateRaffle(uint256 indexed raffleId);
  event SetUpkeeper(address indexed upkeeper);
  event SetRaffleUpdater(address indexed updater);
  event FailedSkillTest(uint256 indexed raffleId, address indexed user);
  event WithdrawUnclaimedRefund(uint256 indexed _raffleId, uint256 amount);
  event WithdrawUnclaimedPrize(uint256 indexed _raffleId, uint256 charityWalletAmount, uint256 expenseWalletAmount, uint256 treasuryWalletAmount);

  // Constructor
  constructor(address _usdtAddress, address _adminController, address _settingsStorage, address _luckyRefunder) {
    USDT = IERC20(_usdtAddress);
    adminController = IAdminController(_adminController);
    settingsStorage = ISettingsStorage(_settingsStorage);
    luckyRefunder = ILuckyRefunder(_luckyRefunder);
    luckyRefunder.setChanceOnChain(address(this));
  }

  // View functions

  function raffleParticipantIndex(uint256 raffleId, address user) public view returns (uint256) {
    return _raffleParticipantIndex[raffleId][user];
  }

  function getRaffle(uint256 _raffleId) public view returns (Raffle memory) {
    return _raffles[_raffleId];
  }

  function rafflesLength() public view returns (uint256) {
    return _raffles.length;
  }

  function raffleEntriesLength(uint256 _raffleId) public view returns (uint256) {
    return _raffleEntries[_raffleId].length;
  }

  function raffleParticipants(uint256 raffleId) public view returns (Participant[] memory) {
    return _raffleParticipants[raffleId];
  }

  function raffleParticipantsLength(uint256 _raffleId) public view returns (uint256) {
    return _raffleParticipants[_raffleId].length;
  }

  function raffleParticipant(uint256 _raffleId, address _participant) public view returns (Participant memory participant) {
    uint256 index = _raffleParticipantIndex[_raffleId][_participant];
    if (index != 0) {
      participant = _raffleParticipants[_raffleId][index - 1];
    }
  }

  function raffleParticipantByIndex(uint256 _raffleId, uint256 _index) public view returns (Participant memory) {
    return _raffleParticipants[_raffleId][_index];
  }

  function rafflesByStatusLength(RaffleStatus _status) public view returns (uint256) {
    return _rafflesByStatus[_status].length();
  }

  function rafflesByStatusIds(RaffleStatus _status) public view returns (uint256[] memory) {
    return _rafflesByStatus[_status].values();
  }

  function rafflesRerollWinnerIds() public view returns (uint256[] memory) {
    return _rafflesRerollWinner.values();
  }

  function isRerollWinnerRaffle(uint256 id) public view returns (bool) {
    return _rafflesRerollWinner.contains(id);
  }

  function userRafflesIds(address _user) public view returns (uint256[] memory) {
    return _userRaffles[_user].values();
  }

  function raffleMathTest(uint256 _raffleId) public view returns (MathTestLib.MathTest memory) {
    return _raffleMathTest[_raffleId];
  }

  function calcTickets(
    uint256 _prizeValue,
    uint256 _ticketPrice,
    uint256 _margin,
    uint256 _maxMargin
  ) public pure returns (uint256 minTickets, uint256 maxTickets) {
    minTickets = _calcTicketsCount((_prizeValue * (MAX_BPS + _margin)) / MAX_BPS, _ticketPrice);
    maxTickets = _calcTicketsCount((_prizeValue * (MAX_BPS + _maxMargin)) / MAX_BPS, _ticketPrice);
  }

  // User functions

  /**
   * @dev Buy tickets for a raffle
   */
  function buyTickets(uint256 _raffleId, uint256 _numTickets) public {
    Raffle storage raffle = _raffles[_raffleId];
    _ensureRaffleIsOpen(raffle.status, raffle.startTime);
    if (raffle.endTime <= block.timestamp) {
      revert RaffleEnded();
    }
    if (_numTickets == 0) {
      revert CannotBeZero();
    }
    if (raffle.ticketsSold + _numTickets > raffle.maxTickets) {
      revert NotEnoughTicketsLeft();
    }

    uint256 totalCost = raffle.ticketPrice * _numTickets;
    USDT.safeTransferFrom(msg.sender, address(this), totalCost);

    // Update participant ticket count
    _updateParticipant(_raffleId, totalCost, _numTickets);

    if (!_userRaffles[msg.sender].contains(_raffleId)) {
      _userRaffles[msg.sender].add(_raffleId);
    }

    raffle.ticketsSold += _numTickets;
    _raffleEntries[_raffleId].push(Entry(msg.sender, raffle.ticketsSold));

    if (raffle.status == RaffleStatus.SCHEDULED) {
      _switchRaffleStatus(_raffleId, raffle.status, RaffleStatus.OPENED);
    }

    emit BuyTickets(_raffleId, msg.sender, _numTickets);
  }

  function _ensureRaffleIsOpen(RaffleStatus status, uint256 startTime) private view {
    if (!((status == RaffleStatus.SCHEDULED && startTime <= block.timestamp) || status == RaffleStatus.OPENED || status == RaffleStatus.HAPPENING)) {
      revert RaffleNotOpen();
    }
  }

  function _updateParticipant(uint256 _raffleId, uint256 totalCost, uint256 _numTickets) private {
    uint256 index = _raffleParticipantIndex[_raffleId][msg.sender];
    if (index == 0) {
      _raffleParticipants[_raffleId].push(
        Participant({
          addr: msg.sender,
          ticketCount: _numTickets,
          amount: totalCost,
          winner: false,
          skillTestFailed: false,
          cashAlternativeClaimed: false,
          refundClaimed: false
        })
      );
      _raffleParticipantIndex[_raffleId][msg.sender] = _raffleParticipants[_raffleId].length;
    } else {
      _raffleParticipants[_raffleId][index - 1].ticketCount += _numTickets;
      _raffleParticipants[_raffleId][index - 1].amount += totalCost;
    }
  }

  /**
   * @dev Claim raffle prize
   */
  function claimReward(uint256 _raffleId, int256 mathTestAnswer, bool _claimCashAlternative) public returns (bool) {
    Raffle storage raffle = _raffles[_raffleId];
    if (raffle.status != RaffleStatus.CLOSED) {
      revert RaffleNotClaimable();
    }
    if (raffle.closedTime + raffle.claimRewardDuration < block.timestamp) {
      revert ClaimTimeIsOver();
    }
    if (raffle.winner != msg.sender) {
      revert NotWinner();
    }
    /**
     * Reset winner data on wrong math test answer to reroll a winner
     */
    Participant storage participant = _raffleParticipants[_raffleId][_raffleParticipantIndex[_raffleId][msg.sender] - 1];
    if (!_raffleMathTest[_raffleId].verify(mathTestAnswer)) {
      _onSkillTestFailed(raffle, participant);
      return false;
    }

    if (raffle.category == RaffleCategory.MONEY) {
      _claimCashAlternative = true;
    } else if (!raffle.cashAlternativeAvailable) {
      _claimCashAlternative = false;
    }

    raffle.endedTime = block.timestamp;
    raffle.prizeClaimed = true;
    participant.cashAlternativeClaimed = _claimCashAlternative;
    _switchRaffleStatus(_raffleId, RaffleStatus.CLOSED, RaffleStatus.ENDED);

    (
      uint256 treasuryWalletAmount,
      uint256 charityWalletAmount,
      uint256 expenseWalletAmount,
      uint256 cashAlternative,
      uint256 serviceFeeAmount
    ) = _calculateRaffleAllocations(_raffleId, _claimCashAlternative);

    // Transfer prize to the winner
    if (_claimCashAlternative) {
      raffle.prizeCashAmount = cashAlternative;
      _safeTransfer(msg.sender, cashAlternative);
    }

    _safeTransfer(_globalOrRaffleCharityWallet(_raffleId), charityWalletAmount);
    _safeTransfer(_globalOrRaffleExpenseWallet(_raffleId), expenseWalletAmount);
    _safeTransfer(_globalOrRaffleTreasuryWallet(_raffleId), treasuryWalletAmount);
    _safeTransfer(settingsStorage.getSettings().serviceFeeWallet, serviceFeeAmount);

    emit ClaimPrize(_raffleId, msg.sender, _claimCashAlternative, cashAlternative);
    return true;
  }

  function _onSkillTestFailed(Raffle storage raffle, Participant storage participant) private {
    raffle.winner = address(0);
    raffle.closedTime = block.timestamp;
    participant.winner = false;
    participant.skillTestFailed = true;
    _raffleExcludedWinners[raffle.id][msg.sender] = true;
    _rafflesRerollWinner.add(raffle.id);
    emit FailedSkillTest(raffle.id, msg.sender);
  }

  /**
   * @dev Claim raffle refund
   */
  function claimRefund(uint256 _raffleId) public {
    if (_raffleParticipantIndex[_raffleId][msg.sender] == 0) {
      revert OnlyParticipant();
    }

    Raffle storage raffle = _raffles[_raffleId];
    if (raffle.status != RaffleStatus.REFUND || raffle.refundStartTime + raffle.claimRefundDuration < block.timestamp) {
      revert RaffleNotRefundable();
    }

    Participant storage participant = _raffleParticipants[_raffleId][_raffleParticipantIndex[_raffleId][msg.sender] - 1];
    if (participant.refundClaimed) {
      revert AlreadyClaimed();
    }

    participant.refundClaimed = true;
    uint256 refundAmount = participant.ticketCount * raffle.ticketPrice;
    raffle.claimedRefundAmount += refundAmount;

    _safeTransfer(msg.sender, refundAmount);

    emit ClaimRefund(_raffleId, msg.sender, refundAmount);
  }

  function onClaimLuckyRefund(uint256 _raffleId, address _user) public {
    if (msg.sender != address(luckyRefunder)) {
      revert NotAllowed();
    }

    _raffleExcludedWinners[_raffleId][_user] = true;
  }

  // Upkeeper functions

  function switchRaffleStatus(uint256 _raffleId, RaffleStatus _oldStatus, RaffleStatus _newStatus) external {
    onlyUpkeeper();

    _switchRaffleStatus(_raffleId, _oldStatus, _newStatus);
  }

  function selectWinner(uint256 raffleId, uint256 randomness) external {
    onlyUpkeeper();

    Raffle storage raffle = _raffles[raffleId];

    if (raffle.status != RaffleStatus.CLOSED) {
      revert RaffleNotClosed();
    }
    if (raffle.winner != address(0)) {
      revert WinnerAlreadySelected();
    }

    // Select a winner
    bool selected = _selectWinner(raffleId, randomness);

    if (_rafflesRerollWinner.contains(raffleId)) {
      _raffleRerollAttempts[raffleId]++;
      if (selected) {
        _raffleRerollAttempts[raffleId] = 0;
        _rafflesRerollWinner.remove(raffleId);
      } else if (_raffleRerollAttempts[raffleId] >= settingsStorage.getSettings().maxRerollAttempts) {
        _rafflesRerollWinner.remove(raffleId);
        _switchRaffleStatus(raffleId, RaffleStatus.CLOSED, RaffleStatus.AUTO_ENDED);
      }
      return;
    }

    uint256 luckyRefundAmount = luckyRefunder.onSelectWinner(raffleId);
    USDT.approve(address(luckyRefunder), luckyRefundAmount);

    if (!raffle.recurrent) {
      return;
    }

    // Create new raffle with same parameters if recurrent
    _createRaffle(
      RaffleData({
        prizeValue: raffle.prizeValue,
        ticketPrice: raffle.ticketPrice,
        startTime: 0,
        duration: raffle.duration,
        prizeName: raffle.prizeName,
        category: raffle.category,
        durationUnit: raffle.durationUnit
      }),
      raffle.entityName,
      raffle.recurrent,
      // Keep the link to the first origin raffle
      raffle.isDescendant ? raffle.originId : raffle.id,
      true,
      raffle.cashAlternativeAvailable,
      raffle.treasuryWallet,
      raffle.expenseWallet,
      raffle.charityWallet
    );
  }

  function _selectWinner(uint256 raffleId, uint256 randomness) private returns (bool) {
    uint256 winningNumber = (randomness % _raffles[raffleId].ticketsSold) + 1;
    uint left = 0;
    uint right = _raffleEntries[raffleId].length - 1;
    while (left < right) {
      uint mid = left + (right - left) / 2;

      if (_raffleEntries[raffleId][mid].cumulativeCount < winningNumber) {
        left = mid + 1;
      } else {
        right = mid;
      }
    }
    address winner = _raffleEntries[raffleId][left].user;
    if (_raffleExcludedWinners[raffleId][winner]) {
      return false;
    }
    _raffleParticipants[raffleId][_raffleParticipantIndex[raffleId][winner] - 1].winner = true;
    _raffles[raffleId].winner = winner;

    // Winner cannot claim lucky refund
    luckyRefunder.excludeUser(raffleId, winner);

    // Generate raffle math test
    _raffleMathTest[raffleId] = MathTestLib.generate(randomness);

    emit SelectWinner(raffleId, _raffles[raffleId].winner);

    return true;
  }

  function withdrawUnclaimedFunds(uint256 _raffleId) public {
    onlyOwner();

    Raffle storage raffle = _raffles[_raffleId];
    if (raffle.status != RaffleStatus.AUTO_ENDED) {
      revert RaffleNotClaimable();
    }

    Settings memory settings = settingsStorage.getSettings();

    if (raffle.refundStartTime > 0) {
      if (raffle.claimedRefundAmount == raffle.ticketPrice * raffle.ticketsSold) {
        revert AlreadyClaimed();
      }

      uint256 leftAmount = raffle.ticketPrice * raffle.ticketsSold - raffle.claimedRefundAmount;
      uint256 serviceFeeAmount = (leftAmount * settings.serviceFeeBP) / MAX_BPS;
      _safeTransfer(settings.treasuryWallet, leftAmount - serviceFeeAmount);
      _safeTransfer(settings.serviceFeeWallet, serviceFeeAmount);
      raffle.claimedRefundAmount += leftAmount;

      emit WithdrawUnclaimedRefund(_raffleId, leftAmount - serviceFeeAmount);
    } else {
      if (raffle.prizeClaimed) {
        revert AlreadyClaimed();
      }

      raffle.prizeClaimed = true;

      (
        uint256 treasuryWalletAmount,
        uint256 charityWalletAmount,
        uint256 expenseWalletAmount,
        uint256 cashAlternative,
        uint256 serviceFeeAmount
      ) = _calculateRaffleAllocations(_raffleId, true);

      // Take service fee from cashAlternative
      uint256 serviceFeeCashAmount = (cashAlternative * settings.serviceFeeBP) / MAX_BPS;
      cashAlternative -= serviceFeeCashAmount;

      _safeTransfer(_globalOrRaffleCharityWallet(_raffleId), charityWalletAmount);
      _safeTransfer(_globalOrRaffleExpenseWallet(_raffleId), expenseWalletAmount);
      _safeTransfer(_globalOrRaffleTreasuryWallet(_raffleId), treasuryWalletAmount + cashAlternative);
      _safeTransfer(settings.serviceFeeWallet, serviceFeeAmount + serviceFeeCashAmount);

      emit WithdrawUnclaimedPrize(_raffleId, charityWalletAmount, expenseWalletAmount, treasuryWalletAmount + cashAlternative);
    }
  }

  function setUpkeeper(address _upkeeper) public {
    onlyOwner();
    if (_upkeeper == address(0)) {
      revert InvalidAddress();
    }
    upkeeper = _upkeeper;

    emit SetUpkeeper(_upkeeper);
  }

  function setRaffleUpdater(address _raffleUpdater) public {
    onlyOwner();
    if (_raffleUpdater == address(0)) {
      revert InvalidAddress();
    }
    raffleUpdater = _raffleUpdater;

    emit SetRaffleUpdater(_raffleUpdater);
  }

  // Admin functions

  function createRaffle(
    RaffleData memory data,
    string memory entityName,
    bool recurrent,
    bool cashAlternativeAvailable,
    address treasuryWallet,
    address expenseWallet,
    address charityWallet
  ) public {
    onlyAdmin();

    if (data.startTime != 0 && data.startTime <= block.timestamp) {
      revert InvalidStartTime();
    }
    if (data.duration == 0) {
      revert CannotBeZero();
    }
    if (data.prizeValue == 0) {
      revert CannotBeZero();
    }
    if (data.ticketPrice == 0) {
      revert CannotBeZero();
    }

    _createRaffle(data, entityName, recurrent, 0, false, cashAlternativeAvailable, treasuryWallet, expenseWallet, charityWallet);
  }

  function updateRaffle(Raffle memory raffle) public {
    onlyRaffleUpdater();

    if (_raffles[raffle.id].status != RaffleStatus.SCHEDULED) {
      revert NotAllowed();
    }
    if (raffle.startTime < block.timestamp) {
      revert InvalidStartTime();
    }
    if (raffle.duration == 0) {
      revert CannotBeZero();
    }
    if (raffle.minTickets == 0) {
      revert CannotBeZero();
    }
    if (raffle.maxTickets < raffle.minTickets) {
      revert MinTicketsTooBig();
    }
    if (raffle.prizeValue == 0) {
      revert CannotBeZero();
    }
    if (raffle.ticketPrice == 0) {
      revert CannotBeZero();
    }

    _raffles[raffle.id] = raffle;
    emit UpdateRaffle(raffle.id);
  }

  function setRaffleRecurrency(uint256 _raffleId, bool _recurrent) public {
    onlyAdmin();
    _raffles[_raffleId].recurrent = _recurrent;

    emit SetRaffleRecurrency(_raffleId, _recurrent);
  }

  function setRaffleStatus(uint256 _raffleId, RaffleStatus _newStatus) public {
    onlyAdmin();
    Raffle memory raffle = _raffles[_raffleId];
    RaffleStatus oldStatus = raffle.status;
    if (
      oldStatus == RaffleStatus.REFUND ||
      oldStatus == RaffleStatus.CANCELED ||
      oldStatus == RaffleStatus.CLOSED ||
      oldStatus == RaffleStatus.ENDED ||
      oldStatus == RaffleStatus.AUTO_ENDED
    ) {
      revert NotAllowed();
    }

    /**
     * Can change raffle status when:
     * 1. _newStatus is PAUSE
     * 2. Current raffle status is SCHEDULE and _newStatus is CANCEL
     * 3. Current raffle status is PAUSE and _newStatus is OPEN, HAPPENING or REFUND
     */
    if (
      (_newStatus == RaffleStatus.PAUSED) ||
      (oldStatus == RaffleStatus.SCHEDULED && _newStatus == RaffleStatus.CANCELED) ||
      (oldStatus == RaffleStatus.PAUSED &&
        (_newStatus == RaffleStatus.OPENED || _newStatus == RaffleStatus.HAPPENING || _newStatus == RaffleStatus.REFUND))
    ) {
      _switchRaffleStatus(_raffleId, oldStatus, _newStatus);
    }
  }

  // Private functions

  function _createRaffle(
    RaffleData memory data,
    string memory entityName,
    bool recurrent,
    uint256 originId,
    bool isDescendant,
    bool cashAlternativeAvailable,
    address treasuryWallet,
    address expenseWallet,
    address charityWallet
  ) private {
    Settings memory settings = settingsStorage.getSettings();
    (uint256 minTickets, uint256 maxTickets) = calcTickets(
      data.prizeValue,
      data.ticketPrice,
      settings.treasuryAllocationBP + settings.charityAllocationBP + settings.luckyRefundAllocationBP,
      settings.maxMarginBP
    );

    if (minTickets > maxTickets) {
      revert MinTicketsTooBig();
    }

    // Make raffle open if it should start immediately
    RaffleStatus status = RaffleStatus.SCHEDULED;
    if (data.startTime == 0) {
      data.startTime = block.timestamp;
      status = RaffleStatus.OPENED;
    }
    uint256 endTime = data.startTime + _durationFromUnits(data.duration, data.durationUnit);
    uint256 id = _raffles.length;

    _raffles.push(
      Raffle({
        id: id,
        category: data.category,
        prizeName: data.prizeName,
        prizeValue: data.prizeValue,
        ticketPrice: data.ticketPrice,
        minTickets: minTickets,
        maxTickets: maxTickets,
        startTime: data.startTime,
        duration: data.duration,
        durationUnit: data.durationUnit,
        endTime: endTime,
        endedTime: 0,
        closedTime: 0,
        refundStartTime: 0,
        recurrent: recurrent,
        status: status,
        ticketsSold: 0,
        winner: address(0),
        prizeCashAmount: 0,
        prizeClaimed: false,
        claimedRefundAmount: 0,
        treasuryAllocationBP: settings.treasuryAllocationBP,
        charityAllocationBP: settings.charityAllocationBP,
        luckyRefundAllocationBP: settings.luckyRefundAllocationBP,
        winnerAllocationBP: settings.winnerAllocationBP,
        maxMarginBP: settings.maxMarginBP,
        claimRewardDuration: settings.claimRewardDuration,
        claimLuckyRefundDuration: settings.claimLuckyRefundDuration,
        claimRefundDuration: settings.claimRefundDuration,
        originId: originId,
        isDescendant: isDescendant,
        treasuryWallet: treasuryWallet,
        expenseWallet: expenseWallet,
        charityWallet: charityWallet,
        entityName: entityName,
        cashAlternativeAvailable: cashAlternativeAvailable
      })
    );

    _rafflesByStatus[status].add(id);

    emit CreateRaffle(id);
  }

  function _durationFromUnits(uint256 _duration, DurationUnit _unit) private pure returns (uint256) {
    if (_unit == DurationUnit.MINUTES) {
      return _duration * 1 minutes;
    }
    if (_unit == DurationUnit.DAYS) {
      return _duration * 1 days;
    }

    return _duration * 1 hours;
  }

  function _calculateRaffleAllocations(
    uint256 _raffleId,
    bool _claimCashAlternative
  )
    private
    view
    returns (
      uint256 treasuryWalletAmount,
      uint256 charityWalletAmount,
      uint256 expenseWalletAmount,
      uint256 cashAlternative,
      uint256 serviceFeeAmount
    )
  {
    Raffle memory raffle = _raffles[_raffleId];

    cashAlternative = 0;
    // Send full prize to the winner for MONEY raffle category
    if (raffle.category == RaffleCategory.MONEY) {
      cashAlternative = raffle.prizeValue;
    } else if (_claimCashAlternative) {
      cashAlternative = (raffle.prizeValue * raffle.winnerAllocationBP) / MAX_BPS;
    }

    uint256 margin = MAX_BPS + raffle.charityAllocationBP + raffle.luckyRefundAllocationBP + raffle.treasuryAllocationBP;
    uint256 minEarnAmount = raffle.ticketPrice * raffle.minTickets;

    uint256 luckyRefundAmount = (minEarnAmount * raffle.luckyRefundAllocationBP) / margin;
    charityWalletAmount = (minEarnAmount * raffle.charityAllocationBP) / margin;
    expenseWalletAmount = 0;
    if (!_claimCashAlternative) {
      expenseWalletAmount = (minEarnAmount * MAX_BPS) / margin;
    }
    treasuryWalletAmount = raffle.ticketPrice * raffle.ticketsSold - charityWalletAmount - luckyRefundAmount - expenseWalletAmount - cashAlternative;

    if (_claimCashAlternative && cashAlternative > (100 * 1e6)) {
      // Calculate remainder to the nearest $100
      uint256 remainder = cashAlternative % (100 * 1e6);
      // Add remainder to treasuryWallet amount
      if (remainder > 0) {
        cashAlternative -= remainder;
        treasuryWalletAmount += remainder;
      }
    }

    // Take service fee from treasury amount
    serviceFeeAmount = (treasuryWalletAmount * settingsStorage.getSettings().serviceFeeBP) / MAX_BPS;
    treasuryWalletAmount -= serviceFeeAmount;
  }

  function _switchRaffleStatus(uint256 _raffleId, RaffleStatus _oldStatus, RaffleStatus _newStatus) private {
    _rafflesByStatus[_oldStatus].remove(_raffleId);
    _rafflesByStatus[_newStatus].add(_raffleId);
    _raffles[_raffleId].status = _newStatus;
    // Set start time of refund period
    if (_newStatus == RaffleStatus.REFUND) {
      _raffles[_raffleId].refundStartTime = block.timestamp;
    }
    if (_newStatus == RaffleStatus.CLOSED) {
      _raffles[_raffleId].closedTime = block.timestamp;
    }
    if (_oldStatus == RaffleStatus.CLOSED && _newStatus == RaffleStatus.AUTO_ENDED) {
      _raffles[_raffleId].endedTime = block.timestamp;
    }

    emit ChangeStatus(_raffleId, _oldStatus, _newStatus);
  }

  function _calcTicketsCount(uint256 _totalAmount, uint256 _ticketPrice) private pure returns (uint256 count) {
    count = _totalAmount / _ticketPrice;
    // Round up to the nearest integer
    if (_totalAmount % _ticketPrice > 0) {
      count += 1;
    }
  }

  function _globalOrRaffleTreasuryWallet(uint256 _raffleId) private view returns (address) {
    Raffle memory raffle = _raffles[_raffleId];
    return raffle.treasuryWallet != address(0) ? raffle.treasuryWallet : settingsStorage.getSettings().treasuryWallet;
  }

  function _globalOrRaffleCharityWallet(uint256 _raffleId) private view returns (address) {
    Raffle memory raffle = _raffles[_raffleId];
    return raffle.charityWallet != address(0) ? raffle.charityWallet : settingsStorage.getSettings().charityWallet;
  }

  function _globalOrRaffleExpenseWallet(uint256 _raffleId) private view returns (address) {
    Raffle memory raffle = _raffles[_raffleId];
    return raffle.expenseWallet != address(0) ? raffle.expenseWallet : settingsStorage.getSettings().expenseWallet;
  }

  function _safeTransfer(address to, uint256 amount) private {
    if (amount == 0) {
      return;
    }
    USDT.safeTransfer(to, amount);
  }

  function onlyOwner() private {
    if (adminController.owner() != msg.sender) {
      revert NotAllowed();
    }
  }

  function onlyAdmin() private {
    if (!adminController.isAdmin(msg.sender)) {
      revert NotAllowed();
    }
  }

  function onlyUpkeeper() private view {
    if (msg.sender != upkeeper) {
      revert OnlyUpkeeper();
    }
  }

  function onlyRaffleUpdater() private view {
    if (msg.sender != raffleUpdater) {
      revert NotAllowed();
    }
  }
}
