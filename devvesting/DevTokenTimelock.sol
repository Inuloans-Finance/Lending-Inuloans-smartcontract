
   
// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.3.2 (token/ERC20/utils/TokenTimelock.sol)

pragma solidity ^0.8.0;

import "../openzeppelin/v4/access/Ownable.sol";
import "../openzeppelin/v4/token/ERC20/utils/SafeERC20.sol";
import "../openzeppelin/v4/proxy/utils/Initializable.sol";
import "../openzeppelin/v4/utils/math/SafeMath.sol";


/**
 * @dev A token holder contract that will allow a beneficiary to extract the
 * tokens after a given release time.
 *
 * Useful for simple vesting schedules like "advisors get all of their tokens
 * after 1 year".
 */
contract DevTokenTimelock is Ownable, Initializable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ERC20 basic token contract being held
    IERC20 private  _token;

    // beneficiary of tokens after they are released
    address private  _beneficiary1;
    address private  _beneficiary2;
    address private  _beneficiary3;

    uint256 private  _amountToClaim;
    mapping(address => uint256) private _locks;


    // timestamp when token release is enabled
    uint256 private  _releaseTime;


    modifier onlyDev() {
        require(isDev(), "Ownable: caller is not dev");
        _;
    }

        /**
     * @dev Returns true if the caller is the current owner.
     */
    function isDev() public view returns (bool) {
        if(msg.sender == _beneficiary1) {
            return true;
        } else if (msg.sender == _beneficiary2) {
            return true;
        } else if (msg.sender == _beneficiary3) {
            return true;            
        } else {
            return false;
        }
    }


    function init(
        IERC20 token_,
        address beneficiary1_,
        address beneficiary2_,
        address beneficiary3_,
        uint256 releaseTime_,
        uint256 totalLock_
    ) external initializer onlyOwner {
        require(releaseTime_ > block.timestamp, "TokenTimelock: release time is before current time");
        require(totalLock_ == token_.balanceOf(address(this)), "Token is not yet transfered");

        _token = token_;
        _beneficiary1 = beneficiary1_;
        _beneficiary2 = beneficiary2_;
        _beneficiary3 = beneficiary3_;
        _releaseTime = releaseTime_;

        _amountToClaim = totalLock_.div(3);

        _locks[_beneficiary1] = _amountToClaim;
        _locks[_beneficiary2] = _amountToClaim;
        _locks[_beneficiary3] = _amountToClaim;


    }    

    /**
     * @return the token being held.
     */
    function token() public view virtual returns (IERC20) {
        return _token;
    }

    /**
     * @return the beneficiary1 of the tokens.
     */
    function beneficiary1() public view virtual returns (address) {
        return _beneficiary1;
    }

    /**
     * @return the beneficiary2 of the tokens.
     */
    function beneficiary2() public view virtual returns (address) {
        return _beneficiary2;
    }

    /**
     * @return the beneficiary2 of the tokens.
     */
    function beneficiary3() public view virtual returns (address) {
        return _beneficiary3;
    }

    /**
     * @return the time when the tokens are released.
     */
    function releaseTime() public view virtual returns (uint256) {
        return _releaseTime;
    }

    function devBalance(address _devAddress) public view virtual returns (uint256) {
        return _locks[_devAddress];
    }

    /**
     * @notice Transfers tokens held by timelock to beneficiary.
     */
    function release() public virtual onlyDev {

        require(block.timestamp >= releaseTime(), "TokenTimelock: current time is before release time");
        require(_locks[msg.sender] == _amountToClaim , "TokenTimelock: no tokens to release");

        token().safeTransfer(msg.sender, _amountToClaim);

        _locks[msg.sender] -= _amountToClaim;
    }

    //emergency case
    function withdrawAll() public virtual onlyOwner {

        require(block.timestamp >= releaseTime(), "TokenTimelock: current time is before release time");

        uint256 amount = token().balanceOf(address(this));
        require(amount > 0, "TokenTimelock: no tokens to release");

        token().safeTransfer(msg.sender, amount);
    }

    
}