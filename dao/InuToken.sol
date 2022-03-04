// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "../openzeppelin/v4/utils/math/SafeMath.sol";
import "../openzeppelin/v4/token/ERC20/utils/SafeERC20.sol";
import "../openzeppelin/v4/token/ERC20/ERC20.sol";
import "../openzeppelin/v4/token/ERC20/extensions/ERC20Burnable.sol";
import "../openzeppelin/v4/token/ERC20/extensions/ERC20Snapshot.sol";
import "../openzeppelin/v4/access/AccessControl.sol";
import "../openzeppelin/v4/security/Pausable.sol";
import "../openzeppelin/v4/token/ERC20/extensions/draft-ERC20Permit.sol";
import "../openzeppelin/v4/token/ERC20/extensions/ERC20VotesComp.sol";

import "./ISoftcap.sol";

contract InuloansToken is
    ERC20,
    ERC20Burnable,
    ERC20Snapshot,
    AccessControl,
    Pausable,
    ERC20Permit,
    ERC20VotesComp
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    IERC20 public dividend;

    // snapshot id => dividend amount
    mapping(uint256 => uint256) public dividendVault;
    // snapshot id => account => claimed
    mapping(uint256 => mapping(address => bool)) public claimStatus;

    uint256 private _totalLock;

    uint256 public startReleaseBlock;
    uint256 public endReleaseBlock;

    mapping(address => uint256) private _locks;
    mapping(address => uint256) private _lastUnlockBlock;

    ISoftcap public softcap;

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

    constructor(
        uint256 _startReleaseBlock,
        uint256 _endReleaseBlock,
        IERC20 _dividend
    ) ERC20("InuloansToken", "INU") ERC20Permit("InuloansToken") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SNAPSHOT_ROLE, msg.sender);
        _setupRole(PAUSER_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, msg.sender);
        _setupRole(BURNER_ROLE, msg.sender);

        startReleaseBlock = _startReleaseBlock;
        endReleaseBlock = _endReleaseBlock;

        setDividendToken(_dividend);
    }

    modifier mintAllowedOnly(uint256 newTotalAmount) {
        require(
            isMintAllowed(totalSupply() + newTotalAmount),
            "Mint exceeds soft cap"
        );
        _;
    }

    function snapshot() public onlyRole(SNAPSHOT_ROLE) {
        _snapshot();
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint256 amount)
        public
        onlyRole(MINTER_ROLE)
        whenNotPaused
        mintAllowedOnly(amount)
    {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount)
        public
        override(ERC20Burnable)
        onlyRole(BURNER_ROLE)
        whenNotPaused
    {
        _burn(account, amount);
        // super.burnFrom(account, amount);
    }

    function setReleaseBlock(
        uint256 _startReleaseBlock,
        uint256 _endReleaseBlock
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        startReleaseBlock = _startReleaseBlock;
        endReleaseBlock = _endReleaseBlock;
    }

    function getCurrentSnapshotId() public view virtual returns (uint256) {
        return _getCurrentSnapshotId();
    }

    function claimableDividendOf(address _account, uint256 _snapshotId)
        public
        view
        returns (uint256)
    {
        if (claimStatus[_snapshotId][_account]) {
            return 0;
        }
        return
            balanceOfAt(_account, _snapshotId)
                .mul(dividendVault[_snapshotId])
                .div(totalSupplyAt(_snapshotId));
    }

    function setDividendToken(IERC20 _dividend)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        dividend = _dividend;
    }

    function addDividend(uint256 _amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_amount > 0, "invalid-amount");

        uint256 _snapshotId = _snapshot();
        require(totalSupplyAt(_snapshotId) > 0, "no-supply");

        dividendVault[_snapshotId] = _amount;
        dividend.safeTransferFrom(msg.sender, address(this), _amount);
        emit DividendAdded(msg.sender, _snapshotId, _amount);
    }

    function claimDividend(uint256 _snapshotId) external {
        require(!claimStatus[_snapshotId][msg.sender], "already-claimed");

        uint256 dividendAmount = claimableDividendOf(msg.sender, _snapshotId);
        require(dividendAmount > 0, "no-dividend");

        claimStatus[_snapshotId][msg.sender] = true;
        dividend.safeTransfer(msg.sender, dividendAmount);

        emit DividendClaimed(msg.sender, _snapshotId, dividendAmount);
    }

    function claimTokens(address token, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 totalAmount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(
            msg.sender,
            amount > totalAmount ? totalAmount : amount
        );
    }

    function unlockedSupply() external view returns (uint256) {
        return totalSupply().sub(totalLock());
    }

    function totalLock() public view returns (uint256) {
        return _totalLock;
    }

    function totalBalanceOf(address _account) external view returns (uint256) {
        return _locks[_account].add(balanceOf(_account));
    }

    function lockOf(address _account) external view returns (uint256) {
        return _locks[_account];
    }

    function lastUnlockBlock(address _account) external view returns (uint256) {
        return _lastUnlockBlock[_account];
    }

    function lock(address _account, uint256 _amount)
        external
        onlyRole(MINTER_ROLE)
    {
        require(_account != address(0), "no lock to address(0)");
        require(_amount <= balanceOf(_account), "no lock over balance");

        _transfer(_account, address(this), _amount);

        _locks[_account] = _locks[_account].add(_amount);
        _totalLock = _totalLock.add(_amount);

        if (_lastUnlockBlock[_account] < startReleaseBlock) {
            _lastUnlockBlock[_account] = startReleaseBlock;
        }

        emit Locked(_account, _amount);
    }

    function canUnlockAmount(address _account) public view returns (uint256) {
        // When block number less than startReleaseBlock, no INU can be unlocked
        if (block.number < startReleaseBlock) {
            return 0;
        }
        // When block number more than endReleaseBlock, all locked INU can be unlocked
        else if (block.number >= endReleaseBlock) {
            return _locks[_account];
        }
        // When block number is more than startReleaseBlock but less than endReleaseBlock,
        // some INU can be released
        else {
            uint256 releasedBlock = block.number.sub(
                _lastUnlockBlock[_account]
            );
            uint256 blockLeft = endReleaseBlock.sub(_lastUnlockBlock[_account]);
            return _locks[_account].mul(releasedBlock).div(blockLeft);
        }
    }

    function isMintAllowed(uint256 newTotalAmount) public view returns (bool) {
        return newTotalAmount < softcap.getCap();
    }

    function upgradeCap(address _implementation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        softcap = ISoftcap(_implementation);
    }

    function unlock() external {
        require(_locks[msg.sender] > 0, "no locked Token");

        uint256 amount = canUnlockAmount(msg.sender);

        _transfer(address(this), msg.sender, amount);
        _locks[msg.sender] = _locks[msg.sender].sub(amount);
        _lastUnlockBlock[msg.sender] = block.number;
        _totalLock = _totalLock.sub(amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Snapshot) whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._burn(account, amount);
    }
}
