// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MBankMint
 * @notice Token minting contract — two-phase mechanism (UUPS upgradeable)
 *
 *   Phase 1: Mint Phase (first 5 days)
 *     User specifies a nominal amount (nominalAmount), only pays discounted USDT:
 *     - Actual payment = nominalAmount * discount rate (Day 1: 95%, Day 2: 96%, ...)
 *     - Minted amount  = nominalAmount * mintRatio (1:10 based on nominal amount)
 *     - User receives  = nominalAmount / market price
 *     - Remaining tokens retained in contract
 *     - Daily mint cap: 10 million tokens
 *
 *     Example (Day 1, 95% discount, token price $10):
 *       User specifies 1000U -> actual payment 950U
 *       Minted: 1000 * 10 = 10,000 tokens
 *       User:   1000 / $10 = 100 tokens
 *       Retained: 9,900 tokens
 *
 *   Phase 2: Buy Phase (from Day 6 onwards)
 *     - 100% USDT used to buy tokens on DEX, all given to user
 *
 *   Admin Mint (adminMint):
 *     - Mints at mintRatio (1:10), no daily cap, no discount, no market price limit
 */

// DEX Router interface (Uniswap V2 style)
interface IDEXRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

// DEX Pair interface
interface IDEXPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

// Mintable token interface
interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

contract BGCMint is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ============================================================
    //                         Constants
    // ============================================================

    uint256 public constant PERCENT_BASE = 10000;

    // ============================================================
    //                      State Variables
    // ============================================================

    IERC20Upgradeable public usdt;
    IMintableToken public mintToken;
    IDEXRouter public dexRouter;
    IDEXPair public dexPair;

    /// @notice Mint ratio: 1 USDT mints mintRatio tokens
    uint256 public mintRatio;

    // ---- Mint Phase Parameters ----

    /// @notice Mint phase start time (0 = not started)
    uint256 public mintStartTime;

    /// @notice Mint phase duration in days (default 5)
    uint256 public mintPhaseDays;

    /// @notice Daily mint cap (default 10 million tokens)
    uint256 public dailyMintCap;

    /// @notice Discount rate per day (9500 = 95%, user pays 95%)
    uint256[] public discountRates;

    /// @notice Daily minted amount: absolute UTC day => amount
    mapping(uint256 => uint256) public dailyMinted;

    // ---- Safety Parameters ----

    /// @notice Minimum nominal amount (USDT 18 decimals, 1 USDT)
    uint256 public minMintAmount;

    /// @dev Reserved storage gap for future upgrades (50 slots).
    /// When adding new state variables in V2, append them BEFORE __gap and reduce
    /// the gap size accordingly (e.g. 1 new uint256 → change __gap from 50 to 49),
    /// keeping the total storage layout length constant to prevent slot collisions.
    uint256[50] private __gap;

    // ============================================================
    //                          Events
    // ============================================================

    event MintPhaseMinted(
        address indexed user,
        uint256 nominalAmount,
        uint256 actualPayment,
        uint256 tokensMinted,
        uint256 tokensToUser,
        uint256 dayIndex,
        uint256 discountRate
    );
    event BuyPhaseBought(
        address indexed user,
        uint256 usdtAmount,
        uint256 tokensBought
    );
    event AdminMinted(address indexed to, uint256 usdtAmount, uint256 tokensMinted);
    event MintPhaseStarted(uint256 startTime, uint256 phaseDays);
    event MintRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event DailyMintCapUpdated(uint256 oldCap, uint256 newCap);
    event DiscountRatesUpdated(uint256[] newRates);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event MinMintAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event DexPairUpdated(address indexed oldPair, address indexed newPair);

    // ============================================================
    //                       Initialization
    // ============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer (replaces constructor for proxy pattern)
     * @param _usdt       USDT token address
     * @param _mintToken  Mintable token address
     * @param _dexRouter  DEX router address
     * @param _dexPair    DEX pair address
     * @param _owner      Contract owner
     */
    function initialize(
        address _usdt,
        address _mintToken,
        address _dexRouter,
        address _dexPair,
        address _owner
    ) external initializer {
        require(_usdt != address(0), "invalid usdt");
        require(_mintToken != address(0), "invalid mintToken");
        require(_dexRouter != address(0), "invalid dexRouter");
        require(_dexPair != address(0), "invalid dexPair");
        require(_owner != address(0), "invalid owner");

        __ReentrancyGuard_init();
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        // Transfer ownership if deployer is not the intended owner
        if (_owner != msg.sender) {
            transferOwnership(_owner);
        }

        usdt = IERC20Upgradeable(_usdt);
        mintToken = IMintableToken(_mintToken);
        dexRouter = IDEXRouter(_dexRouter);
        dexPair = IDEXPair(_dexPair);

        mintRatio = 10;
        minMintAmount = 1e18;
        mintPhaseDays = 5;

        // Default daily mint cap: 10 million tokens (18 decimals)
        dailyMintCap = 10_000_000 * 1e18;

        // Default discounts: Day 1 = 95%, Day 2 = 96%, ..., Day 5 = 99%
        discountRates.push(9500);
        discountRates.push(9600);
        discountRates.push(9700);
        discountRates.push(9800);
        discountRates.push(9900);
    }

    // ============================================================
    //                        Core Logic
    // ============================================================

    /**
     * @notice Unified entry point: mint phase for first 5 days, auto-switches to buy phase from day 6
     * @param usdtAmount USDT amount
     *   - Mint phase: used as nominal amount, only discounted USDT is charged
     *   - Buy phase: full amount used to buy tokens on DEX, all given to user
     * @param minTokensOut Minimum tokens expected in buy phase (calculated by frontend)
     *   - Mint phase: pass 0 (not used)
     *   - Buy phase: slippage protection against sandwich attacks
     */
    function mint(uint256 usdtAmount, uint256 minTokensOut) external nonReentrant whenNotPaused {
        require(mintStartTime > 0, "mint not started");
        require(usdtAmount >= minMintAmount, "amount too small");

        uint256 dayIndex = _utcDayIndex();

        if (dayIndex < mintPhaseDays) {
            _mintPhase(usdtAmount, dayIndex);
        } else {
            _buyPhase(usdtAmount, minTokensOut);
        }
    }

    /**
     * @dev Mint phase internal logic
     *
     * Example (Day 1, 95% discount, token price $10):
     *   nominalAmount = 1000U
     *   actualPayment = 1000 * 9500/10000 = 950U (user actually pays)
     *   tokensMinted  = 1000 * 10 = 10,000 tokens (minted based on nominal amount)
     *   tokensToUser  = 1000 / $10 = 100 tokens (calculated at market price)
     *   Retained in contract: 9,900 tokens
     */
    function _mintPhase(uint256 nominalAmount, uint256 dayIndex) internal {
        uint256 discount = discountRates[dayIndex];

        // 1. Calculate user's actual USDT payment (discounted)
        uint256 actualPayment = (nominalAmount * discount) / PERCENT_BASE;
        require(actualPayment > 0, "payment is zero");

        // 2. Collect only the discounted USDT
        usdt.safeTransferFrom(msg.sender, address(this), actualPayment);

        // 3. Mint tokens based on nominal amount * mintRatio (minted to contract)
        uint256 tokensMinted = _calcMintTokens(nominalAmount);
        require(tokensMinted > 0, "minted is zero");

        // 4. Check daily mint cap (keyed by absolute UTC day, each day independent)
        uint256 utcDay = block.timestamp / 1 days;
        require(dailyMinted[utcDay] + tokensMinted <= dailyMintCap, "daily mint cap exceeded");
        dailyMinted[utcDay] += tokensMinted;

        // 5. Calculate tokens for user at market price (both USDT and Token are 18 decimals)
        uint256 tokenPrice = getTokenPrice();
        require(tokenPrice > 0, "invalid token price");

        uint256 tokensToUser = (nominalAmount * 1e18) / tokenPrice;
        require(tokensToUser > 0, "tokens to user is zero");
        require(tokensMinted >= tokensToUser, "insufficient minted for user");

        // 6. Mint to contract, then transfer to user (remainder retained)
        mintToken.mint(address(this), tokensMinted);
        IERC20Upgradeable(address(mintToken)).safeTransfer(msg.sender, tokensToUser);

        emit MintPhaseMinted(
            msg.sender, nominalAmount, actualPayment,
            tokensMinted, tokensToUser, dayIndex, discount
        );
    }

    /**
     * @dev Buy phase internal logic: 100% USDT buys tokens on DEX, all given to user
     * @param minTokensOut Minimum tokens expected (calculated by frontend based on expected price)
     */
    function _buyPhase(uint256 usdtAmount, uint256 minTokensOut) internal {
        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        // 100% USDT -> DEX buy -> all to user
        uint256 boughtTokens = _buyTokens(usdtAmount, minTokensOut);
        require(boughtTokens > 0, "bought zero tokens");

        IERC20Upgradeable(address(mintToken)).safeTransfer(msg.sender, boughtTokens);

        emit BuyPhaseBought(msg.sender, usdtAmount, boughtTokens);
    }

    // ============================================================
    //                     Internal Utilities
    // ============================================================

    /// @dev UTC-aligned day index (0-based), split at UTC 00:00
    function _utcDayIndex() internal view returns (uint256) {
        uint256 startDay = mintStartTime / 1 days;
        uint256 currentDay = block.timestamp / 1 days;
        return currentDay - startDay;
    }

    /// @dev Calculate minted token amount by mintRatio (USDT and Token both 18 decimals, precision cancels out)
    function _calcMintTokens(uint256 usdtAmount) internal view returns (uint256) {
        return usdtAmount * mintRatio;
    }

    // ============================================================
    //                      DEX Interaction
    // ============================================================

    /// @dev DEX token purchase, slippage protection via user-supplied minTokensOut (calculated by frontend)
    function _buyTokens(uint256 usdtAmount, uint256 minTokensOut) internal returns (uint256) {
        _safeApprove(address(usdt), address(dexRouter), usdtAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(mintToken);

        uint[] memory amounts = dexRouter.swapExactTokensForTokens(
            usdtAmount,
            minTokensOut,
            path,
            address(this),
            block.timestamp
        );

        return amounts[amounts.length - 1];
    }

    /// @dev Safe approve, resets to 0 first for compatibility with tokens like USDT
    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20Upgradeable(token).safeApprove(spender, 0);
        IERC20Upgradeable(token).safeApprove(spender, amount);
    }

    // ============================================================
    //                      View Functions
    // ============================================================

    /// @notice Current phase: 0 = not started, 1 = mint phase, 2 = buy phase
    function currentPhase() external view returns (uint256) {
        if (mintStartTime == 0) return 0;
        uint256 dayIndex = _utcDayIndex();
        return dayIndex < mintPhaseDays ? 1 : 2;
    }

    /// @notice Current mint phase day index (0-based, UTC-aligned)
    function currentDayIndex() external view returns (uint256) {
        if (mintStartTime == 0) return 0;
        uint256 dayIndex = _utcDayIndex();
        return dayIndex < mintPhaseDays ? dayIndex : mintPhaseDays;
    }

    /// @notice Remaining daily mint quota (by UTC day)
    function dailyMintRemaining() external view returns (uint256) {
        if (mintStartTime == 0) return 0;
        uint256 dayIndex = _utcDayIndex();
        if (dayIndex >= mintPhaseDays) return 0;
        uint256 utcDay = block.timestamp / 1 days;
        uint256 minted = dailyMinted[utcDay];
        return minted >= dailyMintCap ? 0 : dailyMintCap - minted;
    }

    /// @notice Current discount rate (9500 = 95%), returns 0 outside mint phase
    function currentDiscount() external view returns (uint256) {
        if (mintStartTime == 0) return 0;
        uint256 dayIndex = _utcDayIndex();
        if (dayIndex >= mintPhaseDays) return 0;
        return discountRates[dayIndex];
    }

    /// @notice Get token price from DEX Pair (USDT-denominated, 18 decimal precision)
    /// @dev Both USDT and Token are 18 decimals, precision factors cancel out
    function getTokenPrice() public view returns (uint256) {
        address token0 = dexPair.token0();
        (uint112 reserve0, uint112 reserve1, ) = dexPair.getReserves();

        if (reserve0 == 0 || reserve1 == 0) return 0;

        // 1 token = ? USDT (18 decimal precision), e.g. 10e18 means $10
        if (token0 == address(mintToken)) {
            // token = reserve0, usdt = reserve1
            return (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            // usdt = reserve0, token = reserve1
            return (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }

    // ============================================================
    //                   Admin Functions (onlyOwner)
    // ============================================================

    /// @notice Start the mint phase
    function startMintPhase() external onlyOwner {
        require(mintStartTime == 0, "already started");
        mintStartTime = block.timestamp;
        emit MintPhaseStarted(block.timestamp, mintPhaseDays);
    }

    function setMintRatio(uint256 newRatio) external onlyOwner {
        require(newRatio > 0, "ratio must > 0");
        emit MintRatioUpdated(mintRatio, newRatio);
        mintRatio = newRatio;
    }

    function setDailyMintCap(uint256 newCap) external onlyOwner {
        require(newCap > 0, "cap must > 0");
        emit DailyMintCapUpdated(dailyMintCap, newCap);
        dailyMintCap = newCap;
    }

    /// @notice Set mint phase days and discount rates
    function setMintPhaseParams(uint256 _days, uint256[] calldata _rates) external onlyOwner {
        require(_days > 0, "days must > 0");
        require(_rates.length == _days, "rates length mismatch");
        for (uint256 i = 0; i < _rates.length; i++) {
            require(_rates[i] > 0 && _rates[i] <= PERCENT_BASE, "invalid rate");
        }
        mintPhaseDays = _days;
        delete discountRates;
        for (uint256 i = 0; i < _rates.length; i++) {
            discountRates.push(_rates[i]);
        }
        emit DiscountRatesUpdated(_rates);
    }

    function setMinMintAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "amount must > 0");
        emit MinMintAmountUpdated(minMintAmount, _amount);
        minMintAmount = _amount;
    }

    function setDexRouter(address _router) external onlyOwner {
        require(_router != address(0), "invalid address");
        emit DexRouterUpdated(address(dexRouter), _router);
        dexRouter = IDEXRouter(_router);
    }

    function setDexPair(address _pair) external onlyOwner {
        require(_pair != address(0), "invalid address");
        emit DexPairUpdated(address(dexPair), _pair);
        dexPair = IDEXPair(_pair);
    }

    /**
     * @notice Admin mint: mints at mintRatio (1:10), no cap, no discount
     * @param to Recipient address
     * @param usdtAmount USDT amount
     */
    function adminMint(address to, uint256 usdtAmount) external onlyOwner nonReentrant {
        require(to != address(0), "invalid address");
        require(usdtAmount >= minMintAmount, "amount too small");

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        uint256 tokensMinted = _calcMintTokens(usdtAmount);
        require(tokensMinted > 0, "tokens minted is zero");

        mintToken.mint(to, tokensMinted);

        emit AdminMinted(to, usdtAmount, tokensMinted);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Emergency withdraw tokens from contract
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20Upgradeable(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, amount);
    }

    // ============================================================
    //                    UUPS Upgrade Authorization
    // ============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
