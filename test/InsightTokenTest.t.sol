// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/InsightToken.sol";

contract InsightTokenTest is Test {
    InsightToken public insightToken;
    
    address public admin = address(1);
    address public rewardsPool = address(2);
    address public developmentFund = address(3);
    address public user1 = address(4);
    address public user2 = address(5);
    address public user3 = address(6);
    uint256 public constant INITIAL_MINT = 1000 * 10**18;
    
    event TokensStaked(address indexed user, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 amount);
    event RewardPointsEarned(address indexed user, uint256 points, string activity);
    event FeeDistributed(uint256 burnAmount, uint256 rewardsAmount, uint256 developmentAmount);
    
    function setUp() public {
        vm.startPrank(admin);
        insightToken = new InsightToken(rewardsPool, developmentFund, admin);
        
        // Grant minter role to admin
        insightToken.grantRole(keccak256("MINTER_ROLE"), admin);
        
        // Mint tokens to test users
        insightToken.mint(user1, INITIAL_MINT);
        insightToken.mint(user2, INITIAL_MINT);
        insightToken.mint(user3, INITIAL_MINT);
        vm.stopPrank();
    }
    
    function testInitialTokenDistribution() public {
        uint256 expectedRewardsPoolAmount = (insightToken.MAX_SUPPLY() * 40) / 100;
        uint256 expectedDevFundAmount = (insightToken.MAX_SUPPLY() * 20) / 100;
        
        assertEq(insightToken.balanceOf(rewardsPool), expectedRewardsPoolAmount);
        assertEq(insightToken.balanceOf(developmentFund), expectedDevFundAmount);
    }
    
    function testTokenTransferWithFee() public {
        uint256 transferAmount = 100 * 10**18;
        uint256 fee = (transferAmount * insightToken.TRANSACTION_FEE_PERCENT()) / 10000;
        uint256 expectedReceived = transferAmount - fee;
        
        uint256 burnAmount = (fee * insightToken.BURN_RATIO()) / 100;
        uint256 rewardsAmount = (fee * insightToken.REWARDS_RATIO()) / 100;
        uint256 developmentAmount = (fee * insightToken.DEVELOPMENT_RATIO()) / 100;
        
        uint256 user1BalanceBefore = insightToken.balanceOf(user1);
        uint256 user2BalanceBefore = insightToken.balanceOf(user2);
        uint256 rewardsBalanceBefore = insightToken.balanceOf(rewardsPool);
        uint256 devBalanceBefore = insightToken.balanceOf(developmentFund);
        uint256 totalSupplyBefore = insightToken.totalSupply();
        
        vm.startPrank(user1);
        
        // Expect the FeeDistributed event to be emitted with correct parameters
        vm.expectEmit(false, false, false, true);
        emit FeeDistributed(burnAmount, rewardsAmount, developmentAmount);
        
        insightToken.transfer(user2, transferAmount);
        vm.stopPrank();
        
        // Verify user balances
        assertEq(insightToken.balanceOf(user1), user1BalanceBefore - transferAmount);
        assertEq(insightToken.balanceOf(user2), user2BalanceBefore + expectedReceived);
        
        // Verify fee distribution
        assertEq(insightToken.balanceOf(rewardsPool), rewardsBalanceBefore + rewardsAmount);
        assertEq(insightToken.balanceOf(developmentFund), devBalanceBefore + developmentAmount);
        
        // Verify burn
        assertEq(insightToken.totalSupply(), totalSupplyBefore - burnAmount);
        assertEq(insightToken.totalBurned(), burnAmount);
    }
    
    function testStaking() public {
        uint256 stakeAmount = 100 * 10**18;
        
        vm.startPrank(user1);
        
        // Expect the TokensStaked event
        vm.expectEmit(true, false, false, true);
        emit TokensStaked(user1, stakeAmount);
        
        insightToken.stake(stakeAmount);
        vm.stopPrank();
        
        // Verify staked balance
        assertEq(insightToken.stakedBalances(user1), stakeAmount);
        
        // Verify user balance decreased
        assertEq(insightToken.balanceOf(user1), INITIAL_MINT - stakeAmount);
        
        // Verify contract balance increased
        assertEq(insightToken.balanceOf(address(insightToken)), stakeAmount);
    }
    
   function testUnstaking() public {
    uint256 stakeAmount = 100 * 10**18;
    
    // First stake tokens
    vm.startPrank(user1);
    insightToken.stake(stakeAmount);
    
    // Unstake half the amount
    uint256 unstakeAmount = stakeAmount / 2;
    
    // Expect the TokensUnstaked event with the correct amount
    vm.expectEmit(true, false, false, true);
    emit TokensUnstaked(user1, unstakeAmount);
    
    insightToken.unstake(unstakeAmount);
    vm.stopPrank();
    
    // Verify staked balance decreased
    assertEq(insightToken.stakedBalances(user1), stakeAmount - unstakeAmount);
    
    // Verify user balance increased
    assertEq(insightToken.balanceOf(user1), INITIAL_MINT - stakeAmount + unstakeAmount);
    
    // Verify contract balance decreased
    assertEq(insightToken.balanceOf(address(insightToken)), stakeAmount - unstakeAmount);
}
function testRewardPoints() public {
    vm.startPrank(admin);
    
    // Award reward points to user
    uint256 points = 100;
    string memory activity = "Completed course";
    
    // Expect the RewardPointsEarned event
    vm.expectEmit(true, false, false, true);
    emit RewardPointsEarned(user1, points, activity);
    
    insightToken.awardRewardPoints(user1, points, activity);
    vm.stopPrank();
    
    // Verify reward points were awarded
    assertEq(insightToken.userRewardPoints(user1), points);
    
    // Test redeeming points
    uint256 rewardsPoolBalanceBefore = insightToken.balanceOf(rewardsPool);
    uint256 user1BalanceBefore = insightToken.balanceOf(user1);
    
    vm.startPrank(user1);
    insightToken.redeemRewardPoints(points);
    vm.stopPrank();
    
    // Calculate expected tokens (1 point = 0.01 token)
    uint256 tokenAmount = points * 10**16;
    
    // Calculate the fee (1%)
    uint256 fee = (tokenAmount * insightToken.TRANSACTION_FEE_PERCENT()) / 10000;
    
    // Calculate portion of fee that goes back to rewards pool (25% of fee)
    uint256 rewardsPortionOfFee = (fee * insightToken.REWARDS_RATIO()) / 100;
    
    // Verify reward points were reset
    assertEq(insightToken.userRewardPoints(user1), 0);
    
    // Verify tokens were transferred, accounting for the portion of fee that returns to rewards pool
    assertEq(insightToken.balanceOf(rewardsPool), rewardsPoolBalanceBefore - tokenAmount + rewardsPortionOfFee);
}
    
    function testMaxSupply() public {
        uint256 currentSupply = insightToken.totalSupply();
        uint256 remainingSupply = insightToken.MAX_SUPPLY() - currentSupply;
        
        vm.startPrank(admin);
        
        // Try to mint too many tokens
        vm.expectRevert("Max supply exceeded");
        insightToken.mint(admin, remainingSupply + 1);
        
        // Should succeed with exact remaining amount
        insightToken.mint(admin, remainingSupply);
        
        // Verify total supply equals max supply
        assertEq(insightToken.totalSupply(), insightToken.MAX_SUPPLY());
        
        // Verify cannot mint more tokens
        vm.expectRevert("Max supply exceeded");
        insightToken.mint(admin, 1);
        
        vm.stopPrank();
    }
    
    function testPremiumAccess() public {
    // User with no staked tokens should not have premium access
    assertEq(insightToken.hasPremiumAccess(user1), false);
    
    // Stake enough tokens for premium access (100 tokens)
    vm.startPrank(user1);
    insightToken.stake(100 * 10**18);
    vm.stopPrank();
    
    // Verify user now has premium access
    assertEq(insightToken.hasPremiumAccess(user1), true);
    
    // Unstake below threshold
    vm.startPrank(user1);
    insightToken.unstake(50 * 10**18);
    vm.stopPrank();
    
    // Verify user no longer has premium access after dropping below threshold
    assertEq(insightToken.hasPremiumAccess(user1), false);
    
    // Unstake remaining tokens (this should be user1, not user3)
    vm.startPrank(user1);
    insightToken.unstake(50 * 10**18);
    vm.stopPrank();
    
    // Verify user still has no premium access
    assertEq(insightToken.hasPremiumAccess(user1), false);
}
    
    function testAccessControl() public {
        // Non-admin should not be able to mint tokens
        vm.startPrank(user1);
        vm.expectRevert();
        insightToken.mint(user1, 100 * 10**18);
        vm.stopPrank();
        
        // Non-admin should not be able to award reward points
        vm.startPrank(user1);
        vm.expectRevert();
        insightToken.awardRewardPoints(user2, 100, "Unauthorized award");
        vm.stopPrank();
        
        // Admin should be able to grant roles
        vm.startPrank(admin);
        insightToken.grantRole(keccak256("MINTER_ROLE"), user1);
        vm.stopPrank();
        
        // User with granted role should now be able to mint
        vm.startPrank(user1);
        insightToken.mint(user1, 100 * 10**18);
        vm.stopPrank();
        
        // Verify the tokens were minted
        assertEq(insightToken.balanceOf(user1), INITIAL_MINT + 100 * 10**18);
    }
}