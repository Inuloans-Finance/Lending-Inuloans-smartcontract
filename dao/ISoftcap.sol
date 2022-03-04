
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;


interface ISoftcap {
  function getCap() external pure returns(uint);
}