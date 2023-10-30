// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IAdminController.sol";
import "./interfaces/ISettingsStorage.sol";
import "./interfaces/IChanceOnChain.sol";
import "./Entities.sol";
import "./Errors.sol";

contract LuckyRefunder {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;

  uint32 constant MAX_BPS = 10_000;

  address public upkeeper;

  IERC20 immutable USDT;
  IAdminController private immutable adminController;
  ISettingsStorage private immutable settingsStorage;
  IChanceOnChain private chanceOnChain;

  EnumerableSet.UintSet private _rafflesSelectUsers;
  mapping(uint256 => mapping(uint32 => bool)) private _raffleSelectedUsers;
  mapping(uint256 => mapping(address => uint256)) private _raffleUserAmount;
  mapping(uint256 => mapping(address => bool)) private _raffleExcludedUsers;
  mapping(uint256 => uint256) private _raffleAmount;
  mapping(uint256 => uint256) private _raffleAssignedAmount;
  mapping(uint256 => uint256) private _raffleClaimedAmount;
  mapping(uint256 => mapping(address => bool)) _raffleParticipantClaimed;
  mapping(uint256 => mapping(address => uint256)) _raffleParticipantClaimedAmount;

  event Claim(uint256 indexed raffleId, address indexed user, uint256 amount);
  event WithdrawUnclaimedAmount(uint256 indexed _raffleId, uint256 amount);

  constructor(address _usdtAddress, address _adminController, address _settingsStorage) {
    USDT = IERC20(_usdtAddress);
    adminController = IAdminController(_adminController);
    settingsStorage = ISettingsStorage(_settingsStorage);
  }

  function raffleAmount(uint256 _raffleId) public view returns (uint256) {
    return _raffleAmount[_raffleId];
  }

  function raffleAssignedAmount(uint256 _raffleId) public view returns (uint256) {
    return _raffleAssignedAmount[_raffleId];
  }

  function raffleClaimedAmount(uint256 _raffleId) public view returns (uint256) {
    return _raffleClaimedAmount[_raffleId];
  }

  function raffleUserAmount(uint256 raffleId, address user) public view returns (uint256) {
    return _raffleUserAmount[raffleId][user];
  }

  function isExcludedUser(uint256 raffleId, address user) public view returns (bool) {
    return _raffleExcludedUsers[raffleId][user];
  }

  function isSelectedUser(uint256 _raffleId, uint32 _index) public view returns (bool) {
    return _raffleSelectedUsers[_raffleId][_index];
  }

  function rafflesSelectUsersIds() public view returns (uint256[] memory) {
    return _rafflesSelectUsers.values();
  }

  function paticipantDetails(uint256 _raffleId, address _user) public view returns (bool, uint256) {
    return (_raffleParticipantClaimed[_raffleId][_user], _raffleParticipantClaimedAmount[_raffleId][_user]);
  }

  function claim(uint256 _raffleId) public {
    Raffle memory raffle = chanceOnChain.getRaffle(_raffleId);
    // If raffle has closedTime > 0, then it can have CLOSE, END or AUTO_END status
    if (raffle.closedTime == 0) {
      revert RaffleNotClaimable();
    }
    if (_raffleExcludedUsers[_raffleId][msg.sender]) {
      revert NotAllowed();
    }
    if (raffle.endedTime > 0 && raffle.endedTime + raffle.claimLuckyRefundDuration < block.timestamp) {
      revert ClaimTimeIsOver();
    }

    Participant memory participant = chanceOnChain.raffleParticipant(_raffleId, msg.sender);
    if (participant.addr == address(0)) {
      revert OnlyParticipant();
    }
    uint256 refundAmount = _raffleUserAmount[_raffleId][msg.sender];
    if (_raffleParticipantClaimed[_raffleId][msg.sender] || refundAmount == 0) {
      revert AlreadyClaimed();
    }

    _raffleParticipantClaimed[_raffleId][msg.sender] = true;
    _raffleParticipantClaimedAmount[_raffleId][msg.sender] = refundAmount;
    _raffleClaimedAmount[_raffleId] += refundAmount;
    _raffleUserAmount[_raffleId][msg.sender] = 0;

    chanceOnChain.onClaimLuckyRefund(_raffleId, msg.sender);

    USDT.safeTransferFrom(address(chanceOnChain), msg.sender, refundAmount);

    emit Claim(_raffleId, msg.sender, refundAmount);
  }

  function withdrawUnclaimedAmount(uint256 _raffleId) public {
    onlyOwner();

    Raffle memory raffle = chanceOnChain.getRaffle(_raffleId);
    if (raffle.endedTime == 0 || raffle.endedTime + raffle.claimLuckyRefundDuration > block.timestamp) {
      revert RaffleNotClaimable();
    }
    uint256 remainingAmount = _raffleAmount[_raffleId] - _raffleClaimedAmount[_raffleId];
    if (remainingAmount == 0) {
      revert AlreadyClaimed();
    }

    _raffleClaimedAmount[_raffleId] += remainingAmount;

    USDT.safeTransferFrom(
      address(chanceOnChain),
      raffle.treasuryWallet == address(0) ? settingsStorage.getSettings().treasuryWallet : raffle.treasuryWallet,
      remainingAmount
    );

    emit WithdrawUnclaimedAmount(_raffleId, remainingAmount);
  }

  function setChanceOnChain(address _chanceOnChain) public {
    if (address(chanceOnChain) != address(0)) {
      return;
    }

    chanceOnChain = IChanceOnChain(_chanceOnChain);
  }

  function setUpkeeper(address _upkeeper) public {
    if (upkeeper != address(0)) {
      return;
    }

    upkeeper = _upkeeper;
  }

  function excludeUser(uint256 _raffleId, address _user) external {
    onlyChanceOnChain();

    _raffleExcludedUsers[_raffleId][_user] = true;
  }

  function onSelectWinner(uint256 _raffleId) external returns (uint256) {
    onlyChanceOnChain();

    Raffle memory raffle = chanceOnChain.getRaffle(_raffleId);
    _rafflesSelectUsers.add(_raffleId);
    _raffleAmount[_raffleId] =
      (raffle.ticketPrice * raffle.minTickets * raffle.luckyRefundAllocationBP) /
      (MAX_BPS + raffle.charityAllocationBP + raffle.luckyRefundAllocationBP + raffle.treasuryAllocationBP);

    return _raffleAmount[_raffleId];
  }

  function addUsers(uint256 _raffleId, uint256 _refundAmount, uint32[] memory _refundees, uint256[] memory _amounts) external {
    onlyUpkeeper();

    if (!_rafflesSelectUsers.contains(_raffleId)) {
      revert NotAllowed();
    }
    uint256 totalAmount = 0;
    for (uint256 i = 0; i < _refundees.length; i++) {
      uint32 idx = _refundees[i];
      if (_raffleSelectedUsers[_raffleId][idx]) {
        continue;
      }
      uint256 amount = _amounts[i];
      Participant memory p = chanceOnChain.raffleParticipantByIndex(_raffleId, idx);
      _raffleUserAmount[_raffleId][p.addr] = amount;
      _raffleSelectedUsers[_raffleId][idx] = true;
      totalAmount += amount;
    }

    if (totalAmount > _refundAmount) {
      revert InvalidAmount();
    }
    _raffleAssignedAmount[_raffleId] += totalAmount;
    if (_raffleAssignedAmount[_raffleId] == _raffleAmount[_raffleId]) {
      _rafflesSelectUsers.remove(_raffleId);
    }
  }

  function onlyOwner() private {
    if (adminController.owner() != msg.sender) {
      revert NotAllowed();
    }
  }

  function onlyChanceOnChain() private view {
    if (msg.sender != address(chanceOnChain)) {
      revert NotAllowed();
    }
  }

  function onlyUpkeeper() private view {
    if (msg.sender != upkeeper) {
      revert OnlyUpkeeper();
    }
  }
}
