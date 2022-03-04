// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;


interface IInu {


    event DividendAdded(
        address indexed caller,
        uint256 indexed snapshotId,
        uint256 amount
    );

    event DividendClaimed(
        address indexed caller,
        uint256 indexed snapshotId,
        uint256 amount
    );

    event Locked(address indexed to, uint256 value);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account)
        external
        view
        returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount)
        external
        returns (bool);


    function snapshot()
        external;

    function pause()
        external;

    function unpause()
        external;

    function mint(address to, uint256 amount)
        external;
    
    function burnFrom(address account, uint256 amount)
        external;

    function getCurrentSnapshotId()
        external
        view
        returns (uint256);

    function claimableDividendOf(address _account, uint256 _snapshotId)
        external
        returns (uint256);

    function addDividend(uint256 _amount)
        external;
    
    function claimDividend(uint256 _snapshotId)
        external;

    function claimTokens(address token, uint256 amount)
        external;

    function unlockedSupply()
        external
        view
        returns (uint256);

    function totalLock()
        external
        view
        returns (uint256);


    function totalBalanceOf(address _account)
        external
        view
        returns (uint256);

    function lockOf(address _account)
        external
        view returns (uint256);

    function lastUnlockBlock(address _account)
        external
        view
        returns (uint256);
    
    function lock(address _account, uint256 _amount)
        external;

    function canUnlockAmount(address _account)
        external
        view
        returns (uint256);

    function unlock()
        external;


}