// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../external/Decimal.sol";
import "../openzeppelin/v4/utils/math/SafeCast.sol";
import "../openzeppelin/v4/access/Ownable.sol";
import "../openzeppelin/v4/utils/Address.sol";

interface IOracle {

    // ----------- State changing API -----------

    function update() external;

    // ----------- Getters -----------

    function read() external view returns (Decimal.D256 memory, bool);

    function isOutdated() external view returns (bool);

    function getTimestamp() external view returns (uint);
    
}


interface IPriceFeedsExt {
    function latestAnswer() external view returns (uint256);
}

contract TokenFeed is IPriceFeedsExt, Ownable {

    using Decimal for Decimal.D256;
    using SafeCast for int256;


    /// @notice the oracle reference by the contract
    IOracle public oracle;

    /// @notice the backup oracle reference by the contract
    IOracle public backupOracle;

    /// @notice number of decimals to scale oracle price by, i.e. multiplying by 10^(decimalsNormalizer)
    int256 public decimalsNormalizer;

    bool public doInvert;

    /// @notice OracleRef constructor
    /// @param _oracle oracle to reference
    /// @param _backupOracle backup oracle to reference
    /// @param _decimalsNormalizer number of decimals to normalize the oracle feed if necessary
    /// @param _doInvert invert the oracle price if this flag is on
    constructor(
        address _oracle,
        address _backupOracle,
        int256 _decimalsNormalizer,
        bool _doInvert
    )
    {
        _setOracle(_oracle);
        if (_backupOracle != address(0) && _backupOracle != _oracle) {
            _setBackupOracle(_backupOracle);
        }
        _setDoInvert(_doInvert);
        _setDecimalsNormalizer(_decimalsNormalizer);
    }

    /// @notice sets the referenced oracle
    /// @param newOracle the new oracle to reference
    function setOracle(address newOracle) external onlyOwner {
        _setOracle(newOracle);
    }

    /// @notice sets the flag for whether to invert or not
    /// @param newDoInvert the new flag for whether to invert
    function setDoInvert(bool newDoInvert) external onlyOwner {
        _setDoInvert(newDoInvert);
    }

        /// @notice sets the new decimalsNormalizer
    /// @param newDecimalsNormalizer the new decimalsNormalizer
    function setDecimalsNormalizer(int256 newDecimalsNormalizer) external  onlyOwner {
        _setDecimalsNormalizer(newDecimalsNormalizer);
    }
    /// @notice sets the referenced backup oracle
    /// @param newBackupOracle the new backup oracle to reference
    function setBackupOracle(address newBackupOracle) external onlyOwner {
        _setBackupOracle(newBackupOracle);
    }

    /// @notice invert a peg price
    /// @param price the peg price to invert
    /// @return the inverted peg as a Decimal
    /// @dev the inverted peg would be X per FEI
    function invert(Decimal.D256 memory price)
        public
        pure
        returns (Decimal.D256 memory)
    {
        return Decimal.one().div(price);
    }
    
    function latestAnswer() external view override returns (uint256 _price) {

        (Decimal.D256 memory _rate, bool valid) = oracle.read();

        if (!valid && address(backupOracle) != address(0)) {
            (_rate, valid) = backupOracle.read();
        }

        require(valid, "OracleRef: oracle invalid");

        uint256 scalingFactor;
        if (decimalsNormalizer < 0) {
            scalingFactor = 10 ** (-1 * decimalsNormalizer).toUint256();
            _rate = _rate.div(scalingFactor);
        } else {
            scalingFactor = 10 ** decimalsNormalizer.toUint256();
            _rate = _rate.mul(scalingFactor);
        }

        if (doInvert) {
            _rate = invert(_rate);
        }


        _price = _rate.asUint256();
    }

    function latestTimestamp() external view returns (uint256 _timestamp) {

        uint256 data = oracle.getTimestamp();
        _timestamp = data;   

    }

    function _setOracle(address newOracle) internal {
        require(newOracle != address(0), "OracleRef: zero address");
        oracle = IOracle(newOracle);
    }

        // Supports zero address if no backup
    function _setBackupOracle(address newBackupOracle) internal {
        backupOracle = IOracle(newBackupOracle);
    }

    function _setDoInvert(bool newDoInvert) internal {
        bool oldDoInvert = doInvert;
        doInvert = newDoInvert;
        
        if (oldDoInvert != newDoInvert) {
            _setDecimalsNormalizer( -1 * decimalsNormalizer);
        }

    }

    function _setDecimalsNormalizer(int256 newDecimalsNormalizer) internal {
        decimalsNormalizer = newDecimalsNormalizer;
    }
  
}