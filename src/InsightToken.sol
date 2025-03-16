// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract InsightToken is ERC20, ERC20Burnable, Pausable, AccessControl, ERC20Permit {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18; // 100 million tokens
    uint256 public constant TRANSACTION_FEE_PERCENT = 100; // 1% (using basis points)
    uint256 public totalBurned;
    
    // Fee distribution ratios
    uint256 public constant BURN_RATIO = 50;
    uint256 public constant REWARDS_RATIO = 25;
    uint256 public constant DEVELOPMENT_RATIO = 25;
    
    address public rewardsPool;
    address public developmentFund;
    
    // Staking mechanism
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public stakingTimestamp;
    
    // For tracking user activities and rewards
    mapping(address => uint256) public userRewardPoints;
    
    // Events
    event TokensStaked(address indexed user, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 amount);
    event RewardPointsEarned(address indexed user, uint256 points, string activity);
    event FeeDistributed(uint256 burnAmount, uint256 rewardsAmount, uint256 developmentAmount);
    
    constructor(
        address _rewardsPool,
        address _developmentFund,
        address _initialAdmin
    ) ERC20("Insight Token", "Insight") ERC20Permit("Insight Token") {
        require(_rewardsPool != address(0), "Invalid rewards pool address");
        require(_developmentFund != address(0), "Invalid development fund address");
        require(_initialAdmin != address(0), "Invalid admin address");
        
        rewardsPool = _rewardsPool;
        developmentFund = _developmentFund;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(PAUSER_ROLE, _initialAdmin);
        _grantRole(MINTER_ROLE, _initialAdmin);
        
        // Initial token distribution
        // 40% to ecosystem rewards
        _mint(rewardsPool, (MAX_SUPPLY * 40) / 100);
        
        // 20% to development fund
        _mint(developmentFund, (MAX_SUPPLY * 20) / 100);
    }
    
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _mint(to, amount);
    }
    
    // Override _update to implement fee mechanism
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // Skip fee for minting, burning, and staking operations
        if (from != address(0) && to != address(0) && from != address(this) && to != address(this)) {
            uint256 fee = (amount * TRANSACTION_FEE_PERCENT) / 10000;
            
            if (fee > 0) {
                // Calculate fee distribution
                uint256 burnAmount = (fee * BURN_RATIO) / 100;
                uint256 rewardsAmount = (fee * REWARDS_RATIO) / 100;
                uint256 developmentAmount = (fee * DEVELOPMENT_RATIO) / 100;
                
                // Apply fee distributions
                super._update(from, address(0), burnAmount); // Burn
                super._update(from, rewardsPool, rewardsAmount); // To rewards
                super._update(from, developmentFund, developmentAmount); // To development
                
                // Update total burned
                totalBurned += burnAmount;
                
                // Emit fee distribution event
                emit FeeDistributed(burnAmount, rewardsAmount, developmentAmount);
                
                // Adjust the transfer amount
                amount -= fee;
            }
        }
        
        super._update(from, to, amount);
    }
    
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0 tokens");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Transfer tokens to the contract
        _transfer(msg.sender, address(this), amount);
        
        // Update staking data
        stakedBalances[msg.sender] += amount;
        stakingTimestamp[msg.sender] = block.timestamp;
        
        emit TokensStaked(msg.sender, amount);
    }
    
    function unstake(uint256 amount) external {
        require(amount > 0, "Cannot unstake 0 tokens");
        require(stakedBalances[msg.sender] >= amount, "Insufficient staked balance");
        
        // Update staking data
        stakedBalances[msg.sender] -= amount;
        
        // Transfer tokens back to the user
        _transfer(address(this), msg.sender, amount);
        
        emit TokensUnstaked(msg.sender, amount);
    }
    
    function awardRewardPoints(address user, uint256 points, string calldata activity) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(user != address(0), "Invalid user address");
        require(points > 0, "Points must be greater than 0");
        
        userRewardPoints[user] += points;
        
        emit RewardPointsEarned(user, points, activity);
    }
    
    function redeemRewardPoints(uint256 points) external {
        require(points > 0, "Cannot redeem 0 points");
        require(userRewardPoints[msg.sender] >= points, "Insufficient reward points");
        
        // Calculate tokens to award (1 point = 0.01 token)
        uint256 tokensToAward = (points * 10**16); // 0.01 tokens with 18 decimals
        
        // Ensure rewards pool has enough tokens
        require(balanceOf(rewardsPool) >= tokensToAward, "Insufficient tokens in rewards pool");
        
        // Reduce user's points
        userRewardPoints[msg.sender] -= points;
        
        // Transfer tokens from rewards pool to user
        _transfer(rewardsPool, msg.sender, tokensToAward);
    }
    
    function hasPremiumAccess(address user) external view returns (bool) {
        // Minimum stake requirement for premium access (100 tokens)
        uint256 minimumStakeForPremium = 100 * 10**18;
        return stakedBalances[user] >= minimumStakeForPremium;
    }
    
    function setRewardsPool(address _newRewardsPool) external onlyRole(ADMIN_ROLE) {
        require(_newRewardsPool != address(0), "Invalid rewards pool address");
        rewardsPool = _newRewardsPool;
    }
    
    function setDevelopmentFund(address _newDevelopmentFund) external onlyRole(ADMIN_ROLE) {
        require(_newDevelopmentFund != address(0), "Invalid development fund address");
        developmentFund = _newDevelopmentFund;
    }
    
    function getStakedAmount(address user) external view returns (uint256) {
        return stakedBalances[user];
    }
}