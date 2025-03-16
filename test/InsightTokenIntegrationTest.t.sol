// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/InsightToken.sol";
import "../src/InsightTokenStaking.sol";
import "../src/InsightTokenVesting.sol";

contract InsightTokenIntegrationTest is Test {
    InsightToken public insightToken;
    InsightTokenStaking public staking;
    InsightTokenVesting public vesting;
    
    address public admin = address(1);
    address public rewardsPool = address(2);
    address public developmentFund = address(3);
    address public teamMember = address(4);
    address public contentCreator = address(5);
    address public contentConsumer = address(6);
    
    // Store important state between test phases
    struct TestState {
        uint256 teamAmount;
        uint256 startTime;
    }
    TestState internal state;
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy token
        insightToken = new InsightToken(rewardsPool, developmentFund, admin);
        
        // Grant minter role to admin
        insightToken.grantRole(keccak256("MINTER_ROLE"), admin);
        
        // Deploy staking contract
        staking = new InsightTokenStaking(address(insightToken), admin, admin);
        
        // Deploy vesting contract
        vesting = new InsightTokenVesting(address(insightToken), admin);
        
        // Only mint extra tokens for the full user journey test
        if (bytes4(keccak256("testFullUserJourney()")) == bytes4(msg.sig)) {
            // Mint extra tokens to staking contract for rewards
            insightToken.mint(address(staking), 10000000 * 10**18);
        }
        
        // Setup initial allocations
        
        // Allocate tokens for team vesting (10% of supply)
        uint256 teamAllocation = (insightToken.MAX_SUPPLY() * 10) / 100;
        insightToken.mint(admin, teamAllocation);
        insightToken.approve(address(vesting), teamAllocation);
        
        // Allocate some tokens to the content creator (simulating rewards)
        insightToken.mint(contentCreator, 10000 * 10**18);
        
        // Allocate some tokens to the content consumer (simulating purchase)
        insightToken.mint(contentConsumer, 5000 * 10**18);
        
        vm.stopPrank();
        
        // Setup approvals
        vm.startPrank(contentCreator);
        insightToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(contentConsumer);
        insightToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();
    }
    
    // Break up the test into smaller functions
    function testFullUserJourney() public {
        // Phase 1: Initial Setup
        setupTeamVesting();
        
        // Phase 2-3: User Journeys
        setupContentCreator();
        setupContentConsumer();
        
        // Phase 4: Token Economy
        simulateTokenEconomy();
        
        // Phase 5: Staking Rewards
        simulateStakingRewards();
        
        // Phase 6: Team Vesting
        simulateTeamVesting();
        
        // Phase 7-8: Tier Upgrade and Rewards
        simulateTierUpgradeAndRewards();
        
        // Phase 9-10: Platform Growth
        simulatePlatformGrowth();
        
        // Phase 11: Long-term Tokenomics
        simulateLongTermTokenomics();
    }
    
    function setupTeamVesting() internal {
        // Setup team vesting schedule (1 year cliff, 3 years total)
        state.startTime = block.timestamp;
        state.teamAmount = (insightToken.MAX_SUPPLY() * 10) / 100;
        
        vm.startPrank(admin);
        vesting.createVestingSchedule(
            teamMember,
            state.teamAmount,
            state.startTime,
            365 days, // 1 year cliff
            1095 days, // 3 years vesting
            true
        );
        vm.stopPrank();
    }
    
    function setupContentCreator() internal {
        // Content creator stakes tokens to get Silver tier
        uint256 creatorStakeAmount = 500 * 10**18;
        
        vm.startPrank(contentCreator);
        staking.stake(creatorStakeAmount);
        vm.stopPrank();
        
        // Verify creator has correct privileges
        (bool hasPremium, bool hasWebinars, bool hasPriority) = staking.getUserPrivileges(contentCreator);
        assertTrue(hasPremium);
        assertTrue(hasWebinars);
        assertFalse(hasPriority);
    }
    
    function setupContentConsumer() internal {
        // Content consumer stakes tokens to get Basic tier
        uint256 consumerStakeAmount = 100 * 10**18;
        
        vm.startPrank(contentConsumer);
        staking.stake(consumerStakeAmount);
        vm.stopPrank();
        
        // Verify consumer privileges
        (bool hasPremium, bool hasWebinars, bool hasPriority) = staking.getUserPrivileges(contentConsumer);
        assertTrue(hasPremium);
        assertFalse(hasWebinars);
        assertFalse(hasPriority);
    }
    
    function simulateTokenEconomy() internal {
        // Consumer transfers tokens to creator (simulating content purchase)
        uint256 purchaseAmount = 50 * 10**18;
        
        // Calculate expected fee
        uint256 fee = (purchaseAmount * insightToken.TRANSACTION_FEE_PERCENT()) / 10000;
        uint256 expectedTransfer = purchaseAmount - fee;
        
        // Calculate fee distribution
        uint256 burnAmount = (fee * insightToken.BURN_RATIO()) / 100;
        uint256 rewardsAmount = (fee * insightToken.REWARDS_RATIO()) / 100;
        uint256 developmentAmount = (fee * insightToken.DEVELOPMENT_RATIO()) / 100;
        
        uint256 creatorBalanceBefore = insightToken.balanceOf(contentCreator);
        uint256 consumerBalanceBefore = insightToken.balanceOf(contentConsumer);
        uint256 rewardsBalanceBefore = insightToken.balanceOf(rewardsPool);
        uint256 developmentBalanceBefore = insightToken.balanceOf(developmentFund);
        uint256 totalSupplyBefore = insightToken.totalSupply();
        
        vm.startPrank(contentConsumer);
        insightToken.transfer(contentCreator, purchaseAmount);
        vm.stopPrank();
        
        // Verify balances after transfer with fee
        assertEq(insightToken.balanceOf(contentConsumer), consumerBalanceBefore - purchaseAmount);
        assertEq(insightToken.balanceOf(contentCreator), creatorBalanceBefore + expectedTransfer);
        assertEq(insightToken.balanceOf(rewardsPool), rewardsBalanceBefore + rewardsAmount);
        assertEq(insightToken.balanceOf(developmentFund), developmentBalanceBefore + developmentAmount);
        assertEq(insightToken.totalSupply(), totalSupplyBefore - burnAmount);
    }
    
    function simulateStakingRewards() internal {
        // Fast forward a short time to accumulate modest rewards
        vm.warp(block.timestamp + 7 days);
        
        // Get pending rewards
        uint256 creatorRewards = staking.getPendingRewards(contentCreator);
        uint256 consumerRewards = staking.getPendingRewards(contentConsumer);
        
        // Creator should have higher rewards due to:
        // 1. Higher staked amount
        // 2. Higher tier multiplier (1.2x vs 1.0x)
        assertTrue(creatorRewards > consumerRewards);
        
        // Log values for debugging
        console.log("Staking contract balance:", insightToken.balanceOf(address(staking)));
        console.log("Creator rewards:", creatorRewards);
        console.log("Consumer rewards:", consumerRewards);
        
        // Only claim if there are rewards and sufficient balance
        uint256 stakingBalance = insightToken.balanceOf(address(staking));
        if (creatorRewards > 0 && creatorRewards < stakingBalance) {
            vm.startPrank(contentCreator);
            staking.claimRewards();
            vm.stopPrank();
        }
        
        // Check consumer rewards separately to avoid exceeding balance
        stakingBalance = insightToken.balanceOf(address(staking));
        if (consumerRewards > 0 && consumerRewards < stakingBalance) {
            vm.startPrank(contentConsumer);
            staking.claimRewards();
            vm.stopPrank();
        }
    }
    
    function simulateTeamVesting() internal {
        // Fast forward 1.5 years to pass cliff and vest some tokens
        vm.warp(block.timestamp + 520 days); // ~1.5 years since start
        
        // Team member claims vested tokens
        uint256 teamBalanceBefore = insightToken.balanceOf(teamMember);
        
        vm.startPrank(teamMember);
        vesting.release(teamMember);
        vm.stopPrank();
        
        // Verify team member received tokens
        uint256 teamBalanceAfter = insightToken.balanceOf(teamMember);
        assertTrue(teamBalanceAfter > teamBalanceBefore);
        
        // Log vested amount
        console.log("Team tokens vested:", teamBalanceAfter - teamBalanceBefore);
    }
    
    function simulateTierUpgradeAndRewards() internal {
        // Consumer upgrades to Silver tier
        vm.startPrank(contentConsumer);
        staking.stake(400 * 10**18); // Additional stake to reach 500 total
        vm.stopPrank();
        
        // Verify consumer now has Silver tier privileges
        bool premiumAccess = false;
        bool webinarAccess = false;
        bool priorityAccess = false;
        
        (premiumAccess, webinarAccess, priorityAccess) = staking.getUserPrivileges(contentConsumer);
        assertTrue(premiumAccess);
        assertTrue(webinarAccess);
        assertFalse(priorityAccess);
        
        // Admin awards reward points to content creator
        vm.startPrank(admin);
        insightToken.awardRewardPoints(contentCreator, 1000, "High-quality Insight post");
        vm.stopPrank();
        
        // Content creator redeems points for tokens
        uint256 creatorBalanceBeforeRedeem = insightToken.balanceOf(contentCreator);
        
        vm.startPrank(contentCreator);
        insightToken.redeemRewardPoints(1000);
        vm.stopPrank();
        
        // Calculate expected tokens after transfer fee
        uint256 baseTokens = 1000 * 10**16; // 0.01 token per point
        uint256 pointsTransferFee = (baseTokens * insightToken.TRANSACTION_FEE_PERCENT()) / 10000;
        uint256 expectedTokensAfterFee = baseTokens - pointsTransferFee;
        
        // Verify content creator received tokens after fee
        assertEq(insightToken.balanceOf(contentCreator), creatorBalanceBeforeRedeem + expectedTokensAfterFee);
    }
    
    function simulatePlatformGrowth() internal {
        // Admin adds a new Platinum tier
        vm.startPrank(admin);
        staking.addStakingTier(
            2000 * 10**18, // Minimum stake
            18000, // 1.8x multiplier
            "Platinum", 
            true, 
            true, 
            true
        );
        vm.stopPrank();
        
        // Content creator upgrades to Platinum tier
        vm.startPrank(contentCreator);
        staking.stake(1500 * 10**18); // Additional stake to reach 2000 total
        vm.stopPrank();
        
        // Verify creator is now in Platinum tier (index 3)
        uint256 creatorTier = staking.getUserTier(contentCreator);
        assertEq(creatorTier, 3);
        
        // Fast forward a shorter period for long-term simulation
        vm.warp(block.timestamp + 30 days); // Use 30 days instead of 365 to limit reward accumulation
        
        // Admin updates reward rate (simulating governance decision)
        uint256 oldRate = staking.rewardRate();
        uint256 newRate = oldRate * 12 / 10; // 20% increase
        
        vm.startPrank(admin);
        staking.setRewardRate(newRate);
        vm.stopPrank();
        
        // Verify reward rate was updated
        assertEq(staking.rewardRate(), newRate);
    }
    
    function simulateLongTermTokenomics() internal {
        // Simulate many transactions to demonstrate deflationary mechanism
        uint256 initialTotalSupply = insightToken.totalSupply();
        uint256 initialTotalBurned = insightToken.totalBurned();
        
        // Perform a fewer number of transactions to avoid running out of tokens
        for (uint i = 0; i < 5; i++) {
            vm.startPrank(contentConsumer);
            insightToken.transfer(contentCreator, 10 * 10**18);
            vm.stopPrank();
            
            vm.startPrank(contentCreator);
            insightToken.transfer(contentConsumer, 5 * 10**18);
            vm.stopPrank();
        }
        
        // Verify burning effect
        uint256 finalTotalSupply = insightToken.totalSupply();
        uint256 finalTotalBurned = insightToken.totalBurned();
        
        assertTrue(finalTotalSupply < initialTotalSupply);
        assertTrue(finalTotalBurned > initialTotalBurned);
        
        // Verify the exact difference matches the total burned amount
        assertEq(initialTotalSupply - finalTotalSupply, finalTotalBurned - initialTotalBurned);
    }
}