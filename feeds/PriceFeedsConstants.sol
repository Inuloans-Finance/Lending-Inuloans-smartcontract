/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.17;

import "../interfaces/IWbaseERC20.sol";
import "../openzeppelin/v2/utils/Address.sol";


contract Constants {
    IWbaseERC20 public wbaseToken;
    IWbaseERC20 public baseToken;
    address internal protocolTokenAddress;

    function _setWbaseToken(
        address _wbaseTokenAddress)
        internal
    {
        require(Address.isContract(_wbaseTokenAddress), "_wbaseTokenAddress not a contract");
        wbaseToken = IWbaseERC20(_wbaseTokenAddress);
    }

    function _setProtocolTokenAddress(
        address _protocolTokenAddress)
        internal
    {
        require(Address.isContract(_protocolTokenAddress), "_protocolTokenAddress not a contract");
        protocolTokenAddress = _protocolTokenAddress;
    }
    
    function _setBaseToken(
        address _baseTokenAddress) 
        internal
    {
        require(Address.isContract(_baseTokenAddress), "_baseTokenAddress not a contract");
        baseToken = IWbaseERC20(_baseTokenAddress);
    }
}
