// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;


import "../openzeppelin/v4/token/ERC20/ERC20.sol";
import "../openzeppelin/v4/token/ERC20/extensions/ERC20Snapshot.sol";
import "../openzeppelin/v4/access/Ownable.sol";


contract MockReward is ERC20, ERC20Snapshot, Ownable {
    constructor() ERC20("Reward", "RW") {}

    function snapshot() public onlyOwner {
        _snapshot();
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);
    }
}