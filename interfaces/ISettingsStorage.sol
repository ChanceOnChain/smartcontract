// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "../Entities.sol";

interface ISettingsStorage {
  function getSettings() external view returns (Settings memory);
}
