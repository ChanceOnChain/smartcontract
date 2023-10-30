// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "./interfaces/IChanceOnChain.sol";
import "./interfaces/IAdminController.sol";
import "./Entities.sol";

contract DigitalPrizeEscrow is IERC721Receiver {
  using SafeERC20 for IERC20;

  IChanceOnChain public chanceOnChain;
  IAdminController private immutable adminController;

  enum TokenStandard {
    ERC20,
    ERC721
  }

  struct DigitalPrize {
    bool claimed;
    TokenStandard tokenStandard;
    address tokenAddress;
    uint256 tokenIdOrAmount;
  }

  mapping(uint256 => DigitalPrize) public raffleDigitalPrize;

  event DepositDigitalPrize(uint256 indexed raffleId, address indexed tokenAddress, uint256 tokenIdOrAmount);
  event ClaimDigitalPrize(uint256 indexed raffleId, address indexed tokenAddress, uint256 tokenIdOrAmount);
  event WithdrawUnclaimedDigitalPrize(uint256 indexed raffleId, address indexed tokenAddress, uint256 tokenIdOrAmount);

  modifier onlyOwner() {
    require(adminController.owner() == msg.sender, "Not allowed");
    _;
  }

  constructor(address _chanceOnChain, address _adminController) {
    chanceOnChain = IChanceOnChain(_chanceOnChain);
    adminController = IAdminController(_adminController);
  }

  function deposit(uint256 raffleId, address tokenAddress, uint256 tokenIdOrAmount) public onlyOwner {
    Raffle memory raffle = chanceOnChain.getRaffle(raffleId);
    require(raffle.status == RaffleStatus.SCHEDULED || raffle.status == RaffleStatus.OPENED, "Not allowed");
    require(raffle.category == RaffleCategory.DIGITAL, "Only DIGITAL raffle");
    require(tokenAddress != address(0), "Empty token address");
    require(
      raffleDigitalPrize[raffleId].tokenAddress != tokenAddress || raffleDigitalPrize[raffleId].tokenIdOrAmount != tokenIdOrAmount,
      "Same token address and amount"
    );

    // Withdraw previously deposited tokens
    if (raffleDigitalPrize[raffleId].tokenAddress != address(0)) {
      if (raffleDigitalPrize[raffleId].tokenStandard == TokenStandard.ERC721) {
        IERC721(raffleDigitalPrize[raffleId].tokenAddress).safeTransferFrom(address(this), msg.sender, raffleDigitalPrize[raffleId].tokenIdOrAmount);
      } else {
        IERC20(raffleDigitalPrize[raffleId].tokenAddress).safeTransfer(msg.sender, raffleDigitalPrize[raffleId].tokenIdOrAmount);
      }
    }

    TokenStandard tokenStandard;
    bool supportsInterface;
    try IERC721(tokenAddress).supportsInterface(type(IERC721).interfaceId) returns (bool _supportsInterface) {
      supportsInterface = _supportsInterface;
    } catch {}

    if (supportsInterface) {
      IERC721(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenIdOrAmount);
      tokenStandard = TokenStandard.ERC721;
    } else {
      require(tokenIdOrAmount > 0, "Zero token amount");
      IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenIdOrAmount);
      tokenStandard = TokenStandard.ERC20;
    }

    raffleDigitalPrize[raffleId] = DigitalPrize({
      tokenAddress: tokenAddress,
      tokenIdOrAmount: tokenIdOrAmount,
      claimed: false,
      tokenStandard: tokenStandard
    });

    emit DepositDigitalPrize(raffleId, tokenAddress, tokenIdOrAmount);
  }

  function claim(uint256 raffleId) public {
    Raffle memory raffle = chanceOnChain.getRaffle(raffleId);
    require(raffle.status == RaffleStatus.ENDED, "Raffle is not ended");
    require(raffle.winner == msg.sender, "Not a winner");
    require(raffle.prizeCashAmount == 0, "Cash alternative already claimed");
    require(!raffleDigitalPrize[raffleId].claimed, "Already claimed");

    DigitalPrize storage prize = raffleDigitalPrize[raffleId];
    address tokenAddress = prize.tokenAddress;
    uint256 tokenIdOrAmount = prize.tokenIdOrAmount;
    if (prize.tokenStandard == TokenStandard.ERC721) {
      IERC721(tokenAddress).safeTransferFrom(address(this), msg.sender, tokenIdOrAmount);
    } else {
      IERC20(tokenAddress).safeTransfer(msg.sender, tokenIdOrAmount);
    }

    prize.claimed = true;

    emit ClaimDigitalPrize(raffleId, tokenAddress, tokenIdOrAmount);
  }

  function withdrawUnclaimed(uint256 raffleId) public onlyOwner {
    Raffle memory raffle = chanceOnChain.getRaffle(raffleId);
    require(
      raffle.status == RaffleStatus.SCHEDULED ||
        raffle.status == RaffleStatus.AUTO_ENDED ||
        (raffle.status == RaffleStatus.ENDED && (raffle.prizeCashAmount > 0 || raffle.ticketsSold == 0)),
      "Not allowed"
    );
    require(raffleDigitalPrize[raffleId].tokenAddress != address(0), "Nothing to withdraw");

    DigitalPrize storage prize = raffleDigitalPrize[raffleId];
    address tokenAddress = prize.tokenAddress;
    uint256 tokenIdOrAmount = prize.tokenIdOrAmount;
    if (prize.tokenStandard == TokenStandard.ERC721) {
      IERC721(tokenAddress).safeTransferFrom(address(this), msg.sender, tokenIdOrAmount);
    } else {
      IERC20(tokenAddress).safeTransfer(msg.sender, tokenIdOrAmount);
    }

    prize.tokenAddress = address(0);
    prize.tokenIdOrAmount = 0;

    emit WithdrawUnclaimedDigitalPrize(raffleId, tokenAddress, tokenIdOrAmount);
  }

  function onERC721Received(address, address, uint, bytes calldata) external pure override returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }
}
