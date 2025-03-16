// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title InsightTokenVesting
 * @dev A token vesting contract for team and advisors, with cliff and linear vesting
 */
contract InsightTokenVesting is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    IERC20 public InsightToken;
    
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 amountReleased;
        uint256 startTime;
        uint256 cliffDuration;
        uint256 vestingDuration;
        bool revocable;
        bool revoked;
    }
    
    // Beneficiary address to vesting schedule
    mapping(address => VestingSchedule) public vestingSchedules;
    
    // List of all beneficiaries
    address[] public beneficiaries;
    
    // Events
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary);
    
    /**
     * @dev Constructor to initialize the vesting contract
     * @param _InsightToken The InsightToken contract address
     * @param _admin Admin address
     */
    constructor(address _InsightToken, address _admin) {
        require(_InsightToken != address(0), "Invalid token address");
        require(_admin != address(0), "Invalid admin address");
        
        InsightToken = IERC20(_InsightToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
    }
    
    /**
     * @dev Create a vesting schedule for a beneficiary
     * @param beneficiary Address of the beneficiary
     * @param totalAmount Total amount of tokens to be vested
     * @param startTime Start time of the vesting period (in seconds)
     * @param cliffDuration Duration of the cliff in seconds
     * @param vestingDuration Duration of the vesting in seconds
     * @param revocable Whether the vesting is revocable or not
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable
    ) external onlyRole(ADMIN_ROLE) {
        require(beneficiary != address(0), "Invalid beneficiary address");
        require(vestingSchedules[beneficiary].totalAmount == 0, "Vesting schedule already exists");
        require(totalAmount > 0, "Amount must be greater than 0");
        require(vestingDuration > 0, "Vesting duration must be greater than 0");
        require(startTime >= block.timestamp, "Start time must be in the future");
        
        // Calculate total vesting time
        uint256 totalVestingTime = startTime + vestingDuration;
        require(totalVestingTime > block.timestamp, "Vesting end time must be in the future");
        
        // Transfer tokens to this contract
        InsightToken.safeTransferFrom(msg.sender, address(this), totalAmount);
        
        // Create vesting schedule
        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            amountReleased: 0,
            startTime: startTime,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            revocable: revocable,
            revoked: false
        });
        
        // Add beneficiary to the list
        beneficiaries.push(beneficiary);
        
        emit VestingScheduleCreated(
            beneficiary,
            totalAmount,
            startTime,
            cliffDuration,
            vestingDuration
        );
    }
    
    /**
     * @dev Calculate the releasable amount of tokens for a beneficiary
     * @param beneficiary Address of the beneficiary
     * @return Amount of tokens that can be released
     */
    function calculateReleasableAmount(address beneficiary) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        
        // If no vesting schedule exists or it's been revoked, return 0
        if (schedule.totalAmount == 0 || schedule.revoked) {
            return 0;
        }
        
        // If cliff hasn't been reached, return 0
        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }
        
        // If vesting has completed, return all unreleased tokens
        if (block.timestamp >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount - schedule.amountReleased;
        }
        
        // Calculate vested tokens based on linear vesting
        uint256 timeFromStart = block.timestamp - schedule.startTime;
        uint256 vestedAmount = (schedule.totalAmount * timeFromStart) / schedule.vestingDuration;
        
        // Return releasable amount
        return vestedAmount - schedule.amountReleased;
    }
    
    /**
     * @dev Release vested tokens to a beneficiary
     * @param beneficiary Address of the beneficiary
     */
    function release(address beneficiary) external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found");
        require(!schedule.revoked, "Vesting has been revoked");
        
        uint256 releasableAmount = calculateReleasableAmount(beneficiary);
        require(releasableAmount > 0, "No tokens available for release");
        
        // Update released amount
        schedule.amountReleased += releasableAmount;
        
        // Transfer tokens to beneficiary
        InsightToken.safeTransfer(beneficiary, releasableAmount);
        
        emit TokensReleased(beneficiary, releasableAmount);
    }
    
    /**
     * @dev Revoke the vesting schedule for a beneficiary (only if revocable)
     * @param beneficiary Address of the beneficiary
     */
    function revoke(address beneficiary) external onlyRole(ADMIN_ROLE) {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found");
        require(!schedule.revoked, "Vesting already revoked");
        require(schedule.revocable, "Vesting is not revocable");
        
        // Release any vested tokens first
        uint256 releasableAmount = calculateReleasableAmount(beneficiary);
        if (releasableAmount > 0) {
            // Update released amount
            schedule.amountReleased += releasableAmount;
            
            // Transfer tokens to beneficiary
            InsightToken.safeTransfer(beneficiary, releasableAmount);
            
            emit TokensReleased(beneficiary, releasableAmount);
        }
        
        // Calculate unreleased tokens
        uint256 unreleasedAmount = schedule.totalAmount - schedule.amountReleased;
        
        // Mark as revoked
        schedule.revoked = true;
        
        // Transfer unreleased tokens back to admin
        if (unreleasedAmount > 0) {
            InsightToken.safeTransfer(msg.sender, unreleasedAmount);
        }
        
        emit VestingRevoked(beneficiary);
    }
    
    /**
     * @dev Get vesting schedule information for a beneficiary
     * @param beneficiary Address of the beneficiary
     * @return totalAmount Total amount of tokens
     * @return amountReleased Amount already released
     * @return amountReleasable Amount currently releasable
     * @return startTime Start time of the vesting period
     * @return cliffEnd End time of the cliff period
     * @return vestingEnd End time of the vesting period
     * @return revocable Whether the vesting is revocable
     * @return revoked Whether the vesting has been revoked
     */
    function getVestingSchedule(address beneficiary) 
        external 
        view 
        returns (
            uint256 totalAmount,
            uint256 amountReleased,
            uint256 amountReleasable,
            uint256 startTime,
            uint256 cliffEnd,
            uint256 vestingEnd,
            bool revocable,
            bool revoked
        ) 
    {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        
        return (
            schedule.totalAmount,
            schedule.amountReleased,
            calculateReleasableAmount(beneficiary),
            schedule.startTime,
            schedule.startTime + schedule.cliffDuration,
            schedule.startTime + schedule.vestingDuration,
            schedule.revocable,
            schedule.revoked
        );
    }
    
    /**
     * @dev Get the number of beneficiaries
     * @return Count of beneficiaries
     */
    function getBeneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }
}