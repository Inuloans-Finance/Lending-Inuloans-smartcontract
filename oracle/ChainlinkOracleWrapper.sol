// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IOracle.sol";
import "../openzeppelin/v4/security/Pausable.sol";
import "../external/chainlink/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title Chainlink oracle wrapper
/// @notice Reads a Chainlink oracle value & wrap it under the standard oracle interface
contract ChainlinkOracleWrapper is IOracle, Pausable {
    using Decimal for Decimal.D256;

    /// @notice the referenced chainlink oracle
    AggregatorV3Interface public chainlinkOracle;
    uint256 public oracleDecimalsNormalizer;

    /// @notice ChainlinkOracleWrapper constructor
    /// @param _chainlinkOracle reference to the target Chainlink oracle
    constructor(
        address _chainlinkOracle
    ) {
        chainlinkOracle = AggregatorV3Interface(_chainlinkOracle);

        _init();
    }

    // @dev: decimals of the oracle are expected to never change, if Chainlink
    // updates that behavior in the future, we might consider reading the
    // oracle decimals() on every read() call.
    function _init() internal {
        uint8 oracleDecimals = chainlinkOracle.decimals();
        oracleDecimalsNormalizer = 10 ** uint256(oracleDecimals);
    }

    /// @notice updates the oracle price
    /// @dev no-op, Chainlink is updated automatically
    function update() external view override whenNotPaused {}

    /// @notice determine if read value is stale
    /// @return true if read value is stale
    function isOutdated() external view override returns (bool) {
        (uint80 roundId,,,, uint80 answeredInRound) = chainlinkOracle.latestRoundData();
        return answeredInRound != roundId;
    }

    /// @notice read the oracle price
    /// @return oracle price
    /// @return true if price is valid
    function read() external view override returns (Decimal.D256 memory, bool) {
        (uint80 roundId, int256 price,,, uint80 answeredInRound) = chainlinkOracle.latestRoundData();
        bool valid = !paused() && price > 0 && answeredInRound == roundId;

        Decimal.D256 memory value = Decimal.from(uint256(price)).div(oracleDecimalsNormalizer);
        return (value, valid);
    }

        /**
     * Returns the latest price
     */
    function getTimestamp() public view returns (uint) {
        ( , , , uint timeStamp, ) = chainlinkOracle.latestRoundData();

        return timeStamp;
    }
}
