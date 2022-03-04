// SPDX-License-Identifier: MIT
pragma solidity ^0.5.17;


import "../openzeppelin/v2/ownership/Ownable.sol";
import "../openzeppelin/v2/access/Roles.sol";

import '../interfaces/IERC20.sol';
import "../interfaces/IThaiFi.sol";


contract LiquidateCaller is Ownable {
    IThaiFi private lendingProtocol;

    address public receiver;


    using Roles for Roles.Role;
    Roles.Role private _liquidators;
    
    constructor(
      address _lendingProtocol,
      address _receiver
      ) public {
      lendingProtocol = IThaiFi(_lendingProtocol);
      receiver = _receiver;
    }

    modifier onlyLiquidator() {
        require(isLiquidator(_msgSender()), "DOES_NOT_HAVE_LIQUIDATOR_ROLE");
        _;
    }
    
    function setProtocol(
      address _lendingProtocol
    )
      external
      onlyOwner
    {
      lendingProtocol = IThaiFi(_lendingProtocol);
    } 

    function setReceiver(
      address _receiver
    )
      external
      onlyOwner
    {
      receiver = _receiver;
    } 

    function setLiquidator(
        address liquidator
    )
        external
        onlyOwner
    {
        _liquidators.add(liquidator);
        
    }

    function renounceLiquidator(
        address liquidator
    )
        external
        onlyOwner
    {
        _liquidators.remove(liquidator);
    }

    function isLiquidator(address account) public view returns (bool) {
        return _liquidators.has(account);
    }
    
    
    function liquidateLoan(
        address borrowedToken,
        bytes32 loanId,
        uint256 amountToLiquidate
      )
        public
        onlyLiquidator
        returns (uint256 profitAmount)
  {

    (,,,,profitAmount) = lendingProtocol.liquidate(
        loanId,
        address(this), //send back to sender
        amountToLiquidate
    );

    IERC20 TokenBorrowed = IERC20(address(borrowedToken));
    TokenBorrowed.transfer(receiver, profitAmount);


  }



}