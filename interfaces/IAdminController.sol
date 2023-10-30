// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

interface IAdminController {
  function owner() external returns (address);

  function getAdmins() external returns (address[] memory);

  function isAdmin(address _user) external returns (bool);
}
