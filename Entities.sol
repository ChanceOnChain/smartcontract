// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

enum DurationUnit {
  MINUTES,
  HOURS,
  DAYS
}

struct Settings {
  DurationUnit claimRewardDurationUnit;
  DurationUnit claimRefundDurationUnit;
  DurationUnit claimLuckyRefundDurationUnit;
  address treasuryWallet;
  address charityWallet;
  address expenseWallet;
  address serviceFeeWallet;
  uint256 claimRewardDuration;
  uint256 claimRefundDuration;
  uint256 claimLuckyRefundDuration;
  uint256 winnerAllocationBP; // Percentage towards winner in BP
  uint256 treasuryAllocationBP; // Percentage towards Treasury wallet in BP
  uint256 charityAllocationBP; // Percentage towards Charity wallet in BP
  uint256 luckyRefundAllocationBP; // Percentage towards Lucky refund in BP
  uint256 maxMarginBP; // Max margin in BP
  uint256 serviceFeeBP; // Percentage taken from treasury wallet amount as service fee in BP
  uint256 maxRerollAttempts;
}

// Enum for the category of the raffle
enum RaffleCategory {
  PHYSICAL,
  DIGITAL,
  EXPERIENCE,
  MONEY
}

// Enum for the status of the raffle
enum RaffleStatus {
  SCHEDULED,
  OPENED,
  PAUSED,
  HAPPENING,
  CLOSED,
  CANCELED,
  REFUND,
  ENDED,
  AUTO_ENDED
}

// Participant data
struct Participant {
  bool winner;
  bool skillTestFailed;
  bool cashAlternativeClaimed;
  bool refundClaimed;
  address addr;
  uint256 ticketCount;
  uint256 amount;
}

struct Entry {
  address user;
  uint cumulativeCount;
}

struct RaffleData {
  uint256 prizeValue;
  uint256 ticketPrice;
  uint256 startTime;
  uint256 duration;
  string prizeName;
  RaffleCategory category;
  DurationUnit durationUnit;
}

// Struct for the details of the raffle
struct Raffle {
  address winner;
  address treasuryWallet;
  address charityWallet;
  address expenseWallet;
  bool cashAlternativeAvailable;
  bool isDescendant;
  bool prizeClaimed;
  bool recurrent;
  RaffleCategory category;
  RaffleStatus status;
  DurationUnit durationUnit;
  uint256 id;
  uint256 prizeValue;
  uint256 ticketPrice;
  uint256 minTickets;
  uint256 maxTickets;
  uint256 startTime;
  uint256 duration;
  uint256 endTime;
  uint256 endedTime;
  uint256 closedTime;
  uint256 refundStartTime;
  uint256 ticketsSold;
  uint256 prizeCashAmount;
  uint256 claimedRefundAmount;
  uint256 treasuryAllocationBP;
  uint256 charityAllocationBP;
  uint256 luckyRefundAllocationBP;
  uint256 winnerAllocationBP;
  uint256 maxMarginBP;
  uint256 claimRewardDuration;
  uint256 claimLuckyRefundDuration;
  uint256 claimRefundDuration;
  uint256 originId;
  string prizeName;
  string entityName;
}
