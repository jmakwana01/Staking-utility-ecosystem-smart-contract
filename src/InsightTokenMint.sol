// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title InsightTokenMinter
 * @dev Contract for minting InsightToken at a price determined by Chainlink price feeds.
 * Users can pay in MATIC (Polygon) to receive InsightToken at the current USD equivalent value.
 */
contract InsightTokenMinter is AccessControl, Pausable, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");
    
    // Token and price feed interfaces
    IERC20 public InsightToken;
    AggregatorV3Interface public maticUsdPriceFeed;
    
    // Price configuration
    uint256 public InsightTokenPriceInUsd; // Price in USD with 8 decimals (e.g., 100000000 = $1.00)
    uint256 public constant PRICE_PRECISION = 10**8;
    
    // Limits and fees
    uint256 public minPurchaseAmount; // Minimum MATIC that can be spent
    uint256 public maxPurchaseAmount; // Maximum MATIC that can be spent per transaction
    uint256 public serviceFeePercentage; // Fee in basis points (e.g., 100 = 1%)
    address public feeCollector;
    
    // Events
    event InsightTokenPurchased(
        address indexed buyer, 
        uint256 maticAmount, 
        uint256 InsightTokenAmount, 
        uint256 usdValue
    );
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event PurchaseLimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event MaticWithdrawn(address indexed to, uint256 amount);
    
    /**
     * @dev Constructor
     * @param _InsightToken The Insight Token contract address
     * @param _maticUsdPriceFeed The Chainlink price feed for MATIC/USD
     * @param _initialPriceInUsd Initial price of Insight Token in USD (with 8 decimals)
     * @param _admin Admin address
     */
    constructor(
        address _InsightToken,
        address _maticUsdPriceFeed,
        uint256 _initialPriceInUsd,
        address _admin
    ) {
        require(_InsightToken != address(0), "Invalid token address");
        require(_maticUsdPriceFeed != address(0), "Invalid price feed address");
        require(_initialPriceInUsd > 0, "Price must be greater than 0");
        require(_admin != address(0), "Invalid admin address");
        
        InsightToken = IERC20(_InsightToken);
        maticUsdPriceFeed = AggregatorV3Interface(_maticUsdPriceFeed);
        InsightTokenPriceInUsd = _initialPriceInUsd;
        feeCollector = _admin;
        
        // Set default values
        minPurchaseAmount = 1 * 10**16; // 0.01 MATIC
        maxPurchaseAmount = 1000 * 10**18; // 1000 MATIC
        serviceFeePercentage = 100; // 1%
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PRICE_UPDATER_ROLE, _admin);
    }
    
    /**
     * @dev Allows users to purchase Insight Tokens by sending MATIC
     * @return The amount of Insight Tokens purchased
     */
    function purchaseTokens() public payable nonReentrant whenNotPaused returns (uint256) {
        require(msg.value >= minPurchaseAmount, "Amount below minimum");
        require(msg.value <= maxPurchaseAmount, "Amount above maximum");
        
        uint256 maticAmount = msg.value;
        
        // Get MATIC/USD price from Chainlink
        (,int256 maticUsdPrice,,,) = maticUsdPriceFeed.latestRoundData();
        require(maticUsdPrice > 0, "Invalid MATIC price");
        
        // Calculate USD value of the MATIC sent
        uint256 usdValue = (maticAmount * uint256(maticUsdPrice)) / 10**18;
        
        // Calculate InsightToken amount to send based on USD value and token price
        uint256 InsightTokenAmount = (usdValue * 10**18) / InsightTokenPriceInUsd;
        
        // Apply service fee
        uint256 fee = (InsightTokenAmount * serviceFeePercentage) / 10000;
        uint256 InsightTokenAmountAfterFee = InsightTokenAmount - fee;
        
        // Check if we have enough tokens to fulfill the purchase
        require(InsightToken.balanceOf(address(this)) >= InsightTokenAmountAfterFee, "Insufficient token balance");
        
        // Transfer tokens to buyer
        require(InsightToken.transfer(msg.sender, InsightTokenAmountAfterFee), "Token transfer failed");
        
        // If fee collector is set and fee is > 0, transfer fee
        if (fee > 0 && feeCollector != address(0)) {
            require(InsightToken.transfer(feeCollector, fee), "Fee transfer failed");
        }
        
        emit InsightTokenPurchased(msg.sender, maticAmount, InsightTokenAmountAfterFee, usdValue);
        
        return InsightTokenAmountAfterFee;
    }
    
    /**
     * @dev Update the price of InsightToken in USD
     * @param _newPriceInUsd New price in USD with 8 decimals
     */
    function updatePrice(uint256 _newPriceInUsd) external onlyRole(PRICE_UPDATER_ROLE) {
        require(_newPriceInUsd > 0, "Price must be greater than 0");
        
        uint256 oldPrice = InsightTokenPriceInUsd;
        InsightTokenPriceInUsd = _newPriceInUsd;
        
        emit PriceUpdated(oldPrice, _newPriceInUsd);
    }
    
    /**
     * @dev Update service fee percentage
     * @param _newFeePercentage New fee in basis points (e.g., 100 = 1%)
     */
    function updateFee(uint256 _newFeePercentage) external onlyRole(ADMIN_ROLE) {
        require(_newFeePercentage <= 500, "Fee cannot exceed 5%");
        
        uint256 oldFee = serviceFeePercentage;
        serviceFeePercentage = _newFeePercentage;
        
        emit FeeUpdated(oldFee, _newFeePercentage);
    }
    
    /**
     * @dev Update fee collector address
     * @param _newFeeCollector New fee collector address
     */
    function updateFeeCollector(address _newFeeCollector) external onlyRole(ADMIN_ROLE) {
        require(_newFeeCollector != address(0), "Invalid fee collector address");
        
        address oldCollector = feeCollector;
        feeCollector = _newFeeCollector;
        
        emit FeeCollectorUpdated(oldCollector, _newFeeCollector);
    }
    
    /**
     * @dev Update purchase limits
     * @param _minAmount Minimum purchase amount in MATIC
     * @param _maxAmount Maximum purchase amount in MATIC
     */
    function updatePurchaseLimits(uint256 _minAmount, uint256 _maxAmount) external onlyRole(ADMIN_ROLE) {
        require(_minAmount > 0, "Min amount must be greater than 0");
        require(_maxAmount > _minAmount, "Max amount must be greater than min amount");
        
        minPurchaseAmount = _minAmount;
        maxPurchaseAmount = _maxAmount;
        
        emit PurchaseLimitsUpdated(_minAmount, _maxAmount);
    }
    
    /**
     * @dev Withdraw Insight Tokens from the contract
     * @param _to Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawTokens(address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_to != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be greater than 0");
        require(InsightToken.balanceOf(address(this)) >= _amount, "Insufficient balance");
        
        require(InsightToken.transfer(_to, _amount), "Transfer failed");
        
        emit TokensWithdrawn(_to, _amount);
    }
    
    /**
     * @dev Withdraw MATIC from the contract
     * @param _to Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawMatic(address payable _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_to != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= _amount, "Insufficient balance");
        
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit MaticWithdrawn(_to, _amount);
    }
    
    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Calculate the amount of InsightTokens that would be received for a given MATIC amount
     * @param _maticAmount Amount of MATIC
     * @return InsightTokenAmount Amount of InsightTokens that would be received
     */
    function calculateTokenAmount(uint256 _maticAmount) external view returns (uint256) {
        require(_maticAmount >= minPurchaseAmount, "Amount below minimum");
        require(_maticAmount <= maxPurchaseAmount, "Amount above maximum");
        
        // Get MATIC/USD price from Chainlink
        (,int256 maticUsdPrice,,,) = maticUsdPriceFeed.latestRoundData();
        require(maticUsdPrice > 0, "Invalid MATIC price");
        
        // Calculate USD value of the MATIC
        uint256 usdValue = (_maticAmount * uint256(maticUsdPrice)) / 10**18;
        
        // Calculate InsightToken amount based on USD value and token price
        uint256 InsightTokenAmount = (usdValue * 10**18) / InsightTokenPriceInUsd;
        
        // Apply service fee
        uint256 fee = (InsightTokenAmount * serviceFeePercentage) / 10000;
        uint256 InsightTokenAmountAfterFee = InsightTokenAmount - fee;
        
        return InsightTokenAmountAfterFee;
    }
    
    /**
     * @dev Get the current price of MATIC in USD
     * @return The MATIC/USD price with 8 decimals
     */
    function getMaticUsdPrice() external view returns (uint256) {
        (,int256 price,,,) = maticUsdPriceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }
    
    /**
     * @dev Fallback function to receive MATIC
     */
    receive() external payable {
        // Only allow direct sends if the contract is not paused
        if (!paused()) {
            purchaseTokens();
        }
    }
}