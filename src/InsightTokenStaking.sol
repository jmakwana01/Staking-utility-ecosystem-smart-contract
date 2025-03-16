// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title InsightTokenStaking
 * @dev Advanced staking contract for InsightToken with tiers and rewards
 */
contract InsightTokenStaking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    
    IERC20 public InsightToken;
    
    // Staking tiers
    struct StakingTier {
        uint256 minimumStake;
        uint256 rewardMultiplier; // Multiplier in basis points (e.g., 12000 = 1.2x)
        string tierName;
        bool accessToPremiumContent;
        bool accessToExclusiveWebinars;
        bool prioritySupport;
    }
    
    // User staking info
    struct StakerInfo {
        uint256 stakedAmount;
        uint256 lastStakeTimestamp;
        uint256 accumulatedRewards;
        uint256 lastClaimTimestamp;
        uint256 stakingTier;
    }
    
    // Mapping from user address to staking info
    mapping(address => StakerInfo) public stakerInfo;
    
    // Array of staking tiers (index is the tier level)
    StakingTier[] public stakingTiers;
    
    // Total staked tokens
    uint256 public totalStaked;
    
    // Reward rate in tokens per second per token staked (scaled by 1e18)
    uint256 public rewardRate = 1e15; // 0.001 tokens per day per token staked by default
    
    // Minimum staking duration
    uint256 public minStakingDuration = 7 days;
    
    // Early unstaking fee percentage (in basis points, e.g., 500 = 5%)
    uint256 public earlyUnstakeFee = 500;
    
    // Events
    event Staked(address indexed user, uint256 amount, uint256 tier);
    event Unstaked(address indexed user, uint256 amount, uint256 fee);
    event RewardsClaimed(address indexed user, uint256 amount);
    event TierAdded(uint256 tierId, string name, uint256 minimumStake);
    event TierUpdated(uint256 tierId, string name, uint256 minimumStake);
    event RewardRateUpdated(uint256 newRate);
    
    /**
     * @dev Constructor to initialize the staking contract
     * @param _InsightToken The InsightToken contract address
     * @param _admin Admin address
     * @param _rewardsManager Rewards manager address
     */
    constructor(
        address _InsightToken, 
        address _admin,
        address _rewardsManager
    ) {
        require(_InsightToken != address(0), "Invalid token address");
        require(_admin != address(0), "Invalid admin address");
        require(_rewardsManager != address(0), "Invalid rewards manager address");
        
        InsightToken = IERC20(_InsightToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REWARDS_MANAGER_ROLE, _rewardsManager);
        
        // Initialize staking tiers
        // Tier 0: Basic
        stakingTiers.push(StakingTier({
            minimumStake: 100 * 1e18, // 100 tokens
            rewardMultiplier: 10000, // 1.0x (base)
            tierName: "Basic",
            accessToPremiumContent: true,
            accessToExclusiveWebinars: false,
            prioritySupport: false
        }));
        
        // Tier 1: Silver
        stakingTiers.push(StakingTier({
            minimumStake: 500 * 1e18, // 500 tokens
            rewardMultiplier: 12000, // 1.2x
            tierName: "Silver",
            accessToPremiumContent: true,
            accessToExclusiveWebinars: true,
            prioritySupport: false
        }));
        
        // Tier 2: Gold
        stakingTiers.push(StakingTier({
            minimumStake: 1000 * 1e18, // 1000 tokens
            rewardMultiplier: 15000, // 1.5x
            tierName: "Gold",
            accessToPremiumContent: true,
            accessToExclusiveWebinars: true,
            prioritySupport: true
        }));
    }
    
    /**
     * @dev Pause staking functionality
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause staking functionality
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Stake tokens
     * @param amount Amount to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Cannot stake 0 tokens");
        
        // Update rewards first if already staking
        if (stakerInfo[msg.sender].stakedAmount > 0) {
            _updateRewards(msg.sender);
        }
        
        // Transfer tokens to this contract
        InsightToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update staker info
        stakerInfo[msg.sender].stakedAmount += amount;
        stakerInfo[msg.sender].lastStakeTimestamp = block.timestamp;
        if (stakerInfo[msg.sender].lastClaimTimestamp == 0) {
            stakerInfo[msg.sender].lastClaimTimestamp = block.timestamp;
        }
        
        // Update total staked
        totalStaked += amount;
        
        // Determine staking tier
        uint256 tier = _determineStakingTier(stakerInfo[msg.sender].stakedAmount);
        stakerInfo[msg.sender].stakingTier = tier;
        
        emit Staked(msg.sender, amount, tier);
    }
    
    /**
     * @dev Unstake tokens
     * @param amount Amount to unstake
     */
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Cannot unstake 0 tokens");
        require(stakerInfo[msg.sender].stakedAmount >= amount, "Insufficient staked balance");
        
        // Update rewards first
        _updateRewards(msg.sender);
        
        // Calculate fee for early unstaking
        uint256 fee = 0;
        if (block.timestamp < stakerInfo[msg.sender].lastStakeTimestamp + minStakingDuration) {
            fee = (amount * earlyUnstakeFee) / 10000;
        }
        
        uint256 amountToTransfer = amount - fee;
        
        // Update staker info
        stakerInfo[msg.sender].stakedAmount -= amount;
        
        // Update total staked
        totalStaked -= amount;
        
        // Update tier
        uint256 newTier = _determineStakingTier(stakerInfo[msg.sender].stakedAmount);
        stakerInfo[msg.sender].stakingTier = newTier;
        
        // Transfer tokens back to user
        InsightToken.safeTransfer(msg.sender, amountToTransfer);
        
        // If there was a fee, send it to the rewards pool
        if (fee > 0) {
            address rewardsPool = address(this); // In this case, fees go back to the staking contract
            InsightToken.safeTransfer(rewardsPool, fee);
        }
        
        emit Unstaked(msg.sender, amount, fee);
    }
    
    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external nonReentrant whenNotPaused {
        // Update rewards first
        _updateRewards(msg.sender);
        
        uint256 rewards = stakerInfo[msg.sender].accumulatedRewards;
        require(rewards > 0, "No rewards to claim");
        
        // Reset accumulated rewards
        stakerInfo[msg.sender].accumulatedRewards = 0;
        stakerInfo[msg.sender].lastClaimTimestamp = block.timestamp;
        
        // Transfer rewards to user
        InsightToken.safeTransfer(msg.sender, rewards);
        
        emit RewardsClaimed(msg.sender, rewards);
    }
    
    /**
     * @dev Add a new staking tier
     * @param minimumStake Minimum stake amount for this tier
     * @param rewardMultiplier Reward multiplier in basis points
     * @param tierName Name of the tier
     * @param accessToPremiumContent Whether this tier has access to premium content
     * @param accessToExclusiveWebinars Whether this tier has access to exclusive webinars
     * @param prioritySupport Whether this tier has priority support
     */
    function addStakingTier(
        uint256 minimumStake,
        uint256 rewardMultiplier,
        string calldata tierName,
        bool accessToPremiumContent,
        bool accessToExclusiveWebinars,
        bool prioritySupport
    ) external onlyRole(ADMIN_ROLE) {
        require(bytes(tierName).length > 0, "Tier name cannot be empty");
        require(rewardMultiplier >= 10000, "Multiplier must be at least 1.0x");
        
        // Ensure new tier has higher minimum stake than the last tier
        if (stakingTiers.length > 0) {
            require(
                minimumStake > stakingTiers[stakingTiers.length - 1].minimumStake,
                "New tier must have higher stake requirement"
            );
        }
        
        stakingTiers.push(StakingTier({
            minimumStake: minimumStake,
            rewardMultiplier: rewardMultiplier,
            tierName: tierName,
            accessToPremiumContent: accessToPremiumContent,
            accessToExclusiveWebinars: accessToExclusiveWebinars,
            prioritySupport: prioritySupport
        }));
        
        emit TierAdded(stakingTiers.length - 1, tierName, minimumStake);
    }
    
    /**
     * @dev Update an existing staking tier
     * @param tierId ID of the tier to update
     * @param minimumStake New minimum stake
     * @param rewardMultiplier New reward multiplier
     * @param tierName New tier name
     * @param accessToPremiumContent Whether this tier has access to premium content
     * @param accessToExclusiveWebinars Whether this tier has access to exclusive webinars
     * @param prioritySupport Whether this tier has priority support
     */
    function updateStakingTier(
        uint256 tierId,
        uint256 minimumStake,
        uint256 rewardMultiplier,
        string calldata tierName,
        bool accessToPremiumContent,
        bool accessToExclusiveWebinars,
        bool prioritySupport
    ) external onlyRole(ADMIN_ROLE) {
        require(tierId < stakingTiers.length, "Invalid tier ID");
        require(bytes(tierName).length > 0, "Tier name cannot be empty");
        require(rewardMultiplier >= 10000, "Multiplier must be at least 1.0x");
        
        // Ensure consistent ordering of tiers
        if (tierId > 0) {
            require(
                minimumStake > stakingTiers[tierId - 1].minimumStake,
                "Tier must have higher stake than previous tier"
            );
        }
        
        if (tierId < stakingTiers.length - 1) {
            require(
                minimumStake < stakingTiers[tierId + 1].minimumStake,
                "Tier must have lower stake than next tier"
            );
        }
        
        stakingTiers[tierId] = StakingTier({
            minimumStake: minimumStake,
            rewardMultiplier: rewardMultiplier,
            tierName: tierName,
            accessToPremiumContent: accessToPremiumContent,
            accessToExclusiveWebinars: accessToExclusiveWebinars,
            prioritySupport: prioritySupport
        });
        
        emit TierUpdated(tierId, tierName, minimumStake);
    }
    
    /**
     * @dev Set the reward rate (only by rewards manager)
     * @param newRate New reward rate
     */
    function setRewardRate(uint256 newRate) external onlyRole(REWARDS_MANAGER_ROLE) {
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }
    
    /**
     * @dev Set the minimum staking duration
     * @param newDuration New minimum staking duration in seconds
     */
    function setMinStakingDuration(uint256 newDuration) external onlyRole(ADMIN_ROLE) {
        minStakingDuration = newDuration;
    }
    
    /**
     * @dev Set the early unstake fee
     * @param newFee New early unstake fee in basis points
     */
    function setEarlyUnstakeFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        require(newFee <= 1000, "Fee cannot be more than 10%");
        earlyUnstakeFee = newFee;
    }
    
    /**
     * @dev Get the current tier of a user
     * @param user User address
     * @return Tier ID
     */
    function getUserTier(address user) external view returns (uint256) {
        return stakerInfo[user].stakingTier;
    }
    
    /**
     * @dev Get the pending rewards of a user
     * @param user User address
     * @return Pending rewards
     */
    function getPendingRewards(address user) external view returns (uint256) {
        if (stakerInfo[user].stakedAmount == 0) {
            return stakerInfo[user].accumulatedRewards;
        }
        
        uint256 timeElapsed = block.timestamp - stakerInfo[user].lastClaimTimestamp;
        uint256 baseRewards = (stakerInfo[user].stakedAmount * rewardRate * timeElapsed) / 1e18;
        
        // Apply tier multiplier
        uint256 tierMultiplier = stakingTiers[stakerInfo[user].stakingTier].rewardMultiplier;
        uint256 newRewards = (baseRewards * tierMultiplier) / 10000;
        
        return stakerInfo[user].accumulatedRewards + newRewards;
    }
    
    /**
     * @dev Get the total number of tiers
     * @return Number of tiers
     */
    function getTierCount() external view returns (uint256) {
        return stakingTiers.length;
    }
    function getStakedAmount(address user) external view returns (uint256) {
    return stakerInfo[user].stakedAmount;
}
    /**
     * @dev Determine the staking tier based on staked amount
     * @param amount Staked amount
     * @return Tier ID
     */
    function _determineStakingTier(uint256 amount) internal view returns (uint256) {
        // Start from the highest tier and go down
        for (uint256 i = stakingTiers.length; i > 0; i--) {
            if (amount >= stakingTiers[i - 1].minimumStake) {
                return i - 1;
            }
        }
        
        // If no tier matches, return the lowest tier
        return 0;
    }
    
    /**
     * @dev Update the rewards for a user
     * @param user User address
     */
    function _updateRewards(address user) internal {
        if (stakerInfo[user].stakedAmount == 0) {
            return;
        }
        
        uint256 timeElapsed = block.timestamp - stakerInfo[user].lastClaimTimestamp;
        if (timeElapsed > 0) {
            uint256 baseRewards = (stakerInfo[user].stakedAmount * rewardRate * timeElapsed) / 1e18;
            
            // Apply tier multiplier
            uint256 tierMultiplier = stakingTiers[stakerInfo[user].stakingTier].rewardMultiplier;
            uint256 rewards = (baseRewards * tierMultiplier) / 10000;
            
            stakerInfo[user].accumulatedRewards += rewards;
            stakerInfo[user].lastClaimTimestamp = block.timestamp;
        }
    }
    
    /**
     * @dev Check if user has specific privileges based on their tier
     * @param user User address
     * @return hasPremiumContent Whether user has access to premium content
     * @return hasExclusiveWebinars Whether user has access to exclusive webinars
     * @return hasPrioritySupport Whether user has priority support
     */
    function getUserPrivileges(address user) external view returns (
        bool hasPremiumContent,
        bool hasExclusiveWebinars,
        bool hasPrioritySupport
    ) {
        if (stakerInfo[user].stakedAmount == 0) {
            return (false, false, false);
        }
        
        uint256 tier = stakerInfo[user].stakingTier;
        return (
            stakingTiers[tier].accessToPremiumContent,
            stakingTiers[tier].accessToExclusiveWebinars,
            stakingTiers[tier].prioritySupport
        );
    }
    
    /**
     * @dev Emergency withdraw function for rewards manager
     * @param amount Amount to withdraw
     * @param to Address to send tokens to
     */
    function emergencyWithdraw(uint256 amount, address to) external onlyRole(REWARDS_MANAGER_ROLE) {
        require(to != address(0), "Invalid address");
        require(amount <= InsightToken.balanceOf(address(this)) - totalStaked, "Cannot withdraw staked tokens");
        
        InsightToken.safeTransfer(to, amount);
    }
}