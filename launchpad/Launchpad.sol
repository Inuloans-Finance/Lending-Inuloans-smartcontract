// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../openzeppelin/v3/token/ERC20/ERC20.sol";
import "../openzeppelin/v3/access/AccessControl.sol";
import "../openzeppelin/v3/access/Ownable.sol";

contract Launchpad is Ownable, AccessControl {
    using SafeMath for uint256;
    IERC20 public tokenA;
    IERC20 public tokenB;
    uint256 public rate = 5000; //div by 1000
    uint256 public feerate = 0;
    address public feeTo;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    constructor(
        address _tokenA,
        address _tokenB,
        address _merchant,
        address _feeTo,
        address _admin
    ) public {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        feeTo = _feeTo;
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(ADMIN_ROLE, _admin);
        _setupRole(MERCHANT_ROLE, _merchant);
    }

    function swap(uint256 _amount) public {
        require(_amount > 100000000000000000, "amount to small");
        uint256 _payback = _amount.mul(rate).div(1000);
        uint256 _payfee = _amount.mul(feerate).div(100);

        // contract must have funds to keep this commitment
        require(
            tokenB.balanceOf(address(this)) > _payback,
            "insufficient contract bal"
        );

        require(
            tokenA.transferFrom(msg.sender, address(this), _amount),
            "transfer failed"
        );
        require(tokenB.transfer(msg.sender, _payback), "transfer failed");
        if (feerate > 0) {
            require(tokenA.transfer(feeTo, _payfee), "transfer failed");
        }
    }

    function isMerchant(address _merchant) public view returns (bool) {
        return hasRole(MERCHANT_ROLE, _merchant);
    }

    function setFeeTo(address _feeTo) public {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "Caller is not a administrator"
        );
        feeTo = _feeTo;
    }

    function setFeeRate(uint256 _feerate) public {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "Caller is not a administrator"
        );
        feerate = _feerate;
    }

    function setRate(uint256 _rate) public {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "Caller is not a administrator"
        );
        rate = _rate;
    }

    function aBalance() public view returns (uint256) {
        return tokenA.balanceOf(address(this));
    }

    function bBalance() public view returns (uint256) {
        return tokenB.balanceOf(address(this));
    }

    function ownerReclaimA() public {
        require(hasRole(MERCHANT_ROLE, msg.sender), "Caller is not a merchant");
        tokenA.transfer(msg.sender, tokenA.balanceOf(address(this)));
    }

    function ownerReclaimB() public {
        require(hasRole(MERCHANT_ROLE, msg.sender), "Caller is not a merchant");
        tokenB.transfer(msg.sender, tokenB.balanceOf(address(this)));
    }

    function TransferB(address _buyer, uint256 _amount) public {
        require(hasRole(TRANSFER_ROLE, msg.sender), "Caller is no permission");
        tokenB.transfer(_buyer, _amount);
    }

    function flushBNB() public {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "Caller is not a administrator"
        );
        uint256 bal = address(this).balance.sub(1);
        msg.sender.transfer(bal);
    }
}
