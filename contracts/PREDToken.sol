// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PREDToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, Ownable, ReentrancyGuard {
    
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18;
    
    mapping(address => bool) public minters;
    mapping(address => bool) public blacklisted;
    
    bool public transfersEnabled;
    uint256 public launchTime;
    
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event BlacklistUpdated(address indexed account, bool status);
    event TransfersEnabled(uint256 timestamp);
    event TokensMinted(address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    error TransfersDisabled();
    error Blacklisted();
    error NotMinter();
    error MaxSupplyExceeded();
    error InvalidAddress();
    error AlreadyMinter();
    error NotAMinter();

    modifier whenTransfersEnabled() {
        if (!transfersEnabled && msg.sender != owner()) revert TransfersDisabled();
        _;
    }

    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert Blacklisted();
        _;
    }

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter();
        _;
    }

    constructor(address initialOwner) 
        ERC20("PredictLink Token", "PRED") 
        ERC20Permit("PredictLink Token")
        Ownable(initialOwner) 
    {
        _mint(initialOwner, INITIAL_SUPPLY);
        transfersEnabled = false;
    }

    function mint(address to, uint256 amount) external onlyMinter nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    function addMinter(address minter) external onlyOwner {
        if (minter == address(0)) revert InvalidAddress();
        if (minters[minter]) revert AlreadyMinter();
        
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        if (!minters[minter]) revert NotAMinter();
        
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    function updateBlacklist(address account, bool status) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function enableTransfers() external onlyOwner {
        require(!transfersEnabled, "Transfers already enabled");
        transfersEnabled = true;
        launchTime = block.timestamp;
        emit TransfersEnabled(block.timestamp);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).transfer(to, amount);
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }

    function transfer(address to, uint256 amount) 
        public 
        override 
        whenTransfersEnabled 
        notBlacklisted(msg.sender) 
        notBlacklisted(to) 
        returns (bool) 
    {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) 
        public 
        override 
        whenTransfersEnabled 
        notBlacklisted(from) 
        notBlacklisted(to) 
        returns (bool) 
    {
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    receive() external payable {}
}