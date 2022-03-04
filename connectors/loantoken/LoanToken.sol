/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.17;

import "./AdvancedTokenStorage.sol";


contract LoanToken is AdvancedTokenStorage {

    // It is important to maintain the variables order so the delegate calls can access thaifiContractAddress and wbaseTokenAddress
    address public thaifiContractAddress;
    address public wbaseTokenAddress;
    address internal target_;

    constructor(
        address _newOwner,
        address _newTarget,
        address _thaifiContractAddress,
        address _wbaseTokenAddress)
        public
    {
        transferOwnership(_newOwner);
        _setTarget(_newTarget);
        _setThaiFiContractAddress(_thaifiContractAddress);
        _setWbaseTokenAddress(_wbaseTokenAddress);
    }

    function()
        external
        payable
    {
        if (gasleft() <= 2300) {
            return;
        }

        address target = target_;
        bytes memory data = msg.data;
        assembly {
            let result := delegatecall(gas, target, add(data, 0x20), mload(data), 0, 0)
            let size := returndatasize
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            switch result
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }

    function setTarget(
        address _newTarget)
        public
        onlyOwner
    {
        _setTarget(_newTarget);
    }

    function _setTarget(
        address _newTarget)
        internal
    {
        require(Address.isContract(_newTarget), "target not a contract");
        target_ = _newTarget;
    }

    function _setThaiFiContractAddress(
        address _thaifiContractAddress)
        internal
    {
        require(Address.isContract(_thaifiContractAddress), "thaifi not a contract");
        thaifiContractAddress = _thaifiContractAddress;
    }

    function _setWbaseTokenAddress(
        address _wbaseTokenAddress)
        internal
    {
        require(Address.isContract(_wbaseTokenAddress), "wbase not a contract");
        wbaseTokenAddress = _wbaseTokenAddress;
    }
    
    function initialize(
        address _loanTokenAddress,
        string memory _name,
        string memory _symbol)
        public
        onlyOwner
    {
        loanTokenAddress = _loanTokenAddress;

        name = _name;
        symbol = _symbol;
        decimals = IERC20(loanTokenAddress).decimals();

        initialPrice = 10**18; // starting price of 1
    }
}
