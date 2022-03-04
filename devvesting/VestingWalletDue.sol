// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.0 (finance/VestingWallet.sol)
pragma solidity ^0.8.0;

import "../openzeppelin/v4/access/Ownable.sol";
import "../openzeppelin/v4/token/ERC20/utils/SafeERC20.sol";
import "../openzeppelin/v4/proxy/utils/Initializable.sol";
import "../openzeppelin/v4/utils/math/SafeMath.sol";
import "../openzeppelin/v4/utils/Address.sol";
import "../openzeppelin/v4/utils/Context.sol";
import "../openzeppelin/v4/utils/math/Math.sol";


/**
 * @title VestingWallet
 * @dev This contract handles the vesting of Eth and ERC20 tokens for a given beneficiary. Custody of multiple tokens
 * can be given to this contract, which will release the token to the beneficiary following a given vesting schedule.
 * The vesting schedule is customizable through the {vestedAmount} function.
 *
 * Any token transferred to this contract will follow the vesting schedule as if they were locked from the beginning.
 * Consequently, if the vesting has already started, any amount of tokens sent to this contract will (at least partly)
 * be immediately releasable.
 */
contract VestingWalletDue is Context , Ownable, Initializable {

    using SafeMath for uint256;

    event EtherReleased(uint256 amount);
    event ERC20Released(address indexed token, uint256 amount);

    uint256 private _released;
    mapping(address => uint256) private _erc20Released;
    address private _beneficiary;
    uint64 private _start;
    uint64 private _duration;
    uint256 private _interval;

    /**
     * @dev Set the beneficiary, start timestamp and vesting duration of the vesting wallet.
     */
    function init(
        IERC20 token_,
        address beneficiaryAddress,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint256 intervalInteger,
        uint256 totalLock
    ) external initializer onlyOwner {
        require(beneficiaryAddress != address(0), "VestingWallet: beneficiary is zero address");
        require(startTimestamp + durationSeconds  > block.timestamp, "TokenTimelock: release time is before current time");
        require(totalLock == token_.balanceOf(address(this)), "Token is not yet transfered");

        _beneficiary = beneficiaryAddress;
        _start = startTimestamp;
        _duration = durationSeconds;
        _interval = intervalInteger;

    } 
    /**
     * @dev The contract should be able to receive Eth.
     */
    receive() external payable virtual {}

    /**
     * @dev Getter for the beneficiary address.
     */
    function beneficiary() public view virtual returns (address) {
        return _beneficiary;
    }

    /**
     * @dev Getter for the start timestamp.
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @dev Getter for the vesting duration.
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @dev Getter for the interval.
     */
    function interval() public view virtual returns (uint256) {
        return _interval;
    }

    /**
     * @dev Amount of eth already released
     */
    function released() public view virtual returns (uint256) {
        return _released;
    }

    /**
     * @dev Amount of token already released
     */
    function released(address token) public view virtual returns (uint256) {
        return _erc20Released[token];
    }

    /**
     * @dev Release the native token (ether) that have already vested.
     *
     * Emits a {TokensReleased} event.
     */
    function release() public virtual {
        uint256 releasable = vestedAmount(uint64(block.timestamp)) - released();
        require(releasable > 0, "VestingWallet: token relesable must not be zero");
        _released += releasable;
        emit EtherReleased(releasable);
        Address.sendValue(payable(beneficiary()), releasable);
    }

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {TokensReleased} event.
     */
    function release(address token) public virtual {
        uint256 releasable = vestedAmount(token, uint64(block.timestamp)) - released(token);
        require(releasable > 0, "VestingWallet: token relesable must not be zero");
        _erc20Released[token] += releasable;
        emit ERC20Released(token, releasable);
        SafeERC20.safeTransfer(IERC20(token), beneficiary(), releasable);
    }

    /**
     * @dev Amount of releasable token
     */
    function releasableAmount(address token) public view virtual returns (uint256) {
        uint256 releasable = vestedAmount(token, uint64(block.timestamp)) - released(token);
        return releasable;
    }

    /**
     * @dev Calculates the amount of ether that has already vested. Default implementation is a linear vesting curve.
     */
    function vestedAmount(uint64 timestamp) public view virtual returns (uint256) {
        return _vestingSchedule(address(this).balance + released(), timestamp);
    }

    /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     */
    function vestedAmount(address token, uint64 timestamp) public view virtual returns (uint256) {
        return _vestingSchedule(IERC20(token).balanceOf(address(this)) + released(token), timestamp);
    }

    /**
     * @dev Virtual implementation of the vesting formula. This returns the amout vested, as a function of time, for
     * an asset given its total historical allocation.
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {

        //eg  months in epoch
        uint256 totalParts = duration().div(interval());
        // eg 10,000 per month
        uint256 allocationByPart = totalAllocation.div(interval());

        if (timestamp < start()) {
            // paid at the begining of the month
            return allocationByPart;
        } else if (timestamp > start() + duration()) {
            return totalAllocation;
        } else {

            // (0,1) => 0  (1,2) => 1 (9,10) => 9
            uint256 pastParts = (timestamp - start()).div(totalParts);

            //Truncuate to begining of the month
            // (0,1) => 1 (1,2) => 2 (9,10) => 10
            pastParts = pastParts += 1;

            return allocationByPart.mul(pastParts);


        }
    }
}