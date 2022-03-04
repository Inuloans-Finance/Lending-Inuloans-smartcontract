// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

import "../external/Decimal.sol";
import "../openzeppelin/v4/security/Pausable.sol";

interface IOracle {
    // ----------- Events -----------

    event Update(uint256 _peg);

    // ----------- State changing API -----------

    function update() external;

    // ----------- Getters -----------

    function read() external view returns (Decimal.D256 memory, bool);

    
}

contract ThaiFiOracle is IOracle, Pausable {
    using Decimal for Decimal.D256;
    address public maintainer;
    address private owner;
    uint256 private priceusd;
    uint256 private creationTime;
    uint256 private lastupdate;
    uint256 public oracleDecimalsNormalizer;

    constructor (
        address  _maintainer,
        uint256 oracleDecimals
        ) {
        maintainer = _maintainer;
        owner = msg.sender;
        creationTime = block.timestamp;
        oracleDecimalsNormalizer = 10 ** uint256(oracleDecimals);
    }

    modifier isOwner() {
        require(msg.sender == owner );
        _;
    }

    modifier isMaintainer() {
        require( msg.sender == owner || msg.sender == maintainer );
        _;
    }    
    function changeOwner(address newOwner) public isOwner {
        owner = newOwner;
    }

    function changeMaintainer(address newMaintainer) public isOwner {
        maintainer = newMaintainer;
    }    


    /// @notice updates the oracle price
    /// @dev no-op, Chainlink is updated automatically
    function update() external view override whenNotPaused {}


    /// @notice read the oracle price
    /// @return oracle price
    /// @return true if price is valid
    function read() external view override returns (Decimal.D256 memory, bool) {

        bool valid = !paused() && priceusd > 0;

        Decimal.D256 memory value = Decimal.from(priceusd).div(oracleDecimalsNormalizer);
        return (value, valid);
    }

    function updatePrice(uint256 price) external isMaintainer {
        priceusd = price;
        lastupdate = block.timestamp;
    }
}