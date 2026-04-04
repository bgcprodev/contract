// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title TaxToken
 * @notice ERC20 token contract with UUPS upgradeable proxy support
 * @dev    Built on OpenZeppelin Contracts Upgradeable v4.x, Solidity 0.8.18
 *
 * Features:
 *  1. Configurable buy/sell tax rates (denominator 10000)
 *  2. Tax fees automatically sent to a designated fee receiver
 *  3. Independent buy/sell toggle switches
 *  4. Blacklist - blocks all transfers (send & receive)
 *  5. Whitelist - exempt from buy/sell switches and tax fees
 */
contract BGCToken is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // ============================================================
    //                      State Variables
    // ============================================================

    /// @notice Address that receives tax fees
    address public feeReceiver;

    /// @notice Buy tax rate (denominator 10000, e.g. 500 = 5%)
    uint256 public buyTaxRate;

    /// @notice Sell tax rate (denominator 10000)
    uint256 public sellTaxRate;

    /// @notice Buy switch (true = buying allowed)
    bool public buyEnabled;

    /// @notice Sell switch (true = selling allowed)
    bool public sellEnabled;

    /// @notice DEX pair address set (used to determine buy/sell direction)
    mapping(address => bool) public isPair;

    /// @notice Blacklist
    mapping(address => bool) public isBlacklisted;

    /// @notice Whitelist
    mapping(address => bool) public isWhitelisted;

    /// @notice Minter addresses (configurable by owner)
    mapping(address => bool) public isMinter;

    uint256 public constant TAX_DENOMINATOR = 10000;
    uint256 public constant MAX_TAX_RATE = 2500; // Max 25%
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 1e18; // Max supply 10 billion

    // ============================================================
    //                          Events
    // ============================================================

    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event BuyTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event SellTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event BuyEnabledUpdated(bool enabled);
    event SellEnabledUpdated(bool enabled);
    event PairUpdated(address indexed pair, bool status);
    event BlacklistUpdated(address indexed account, bool status);
    event WhitelistUpdated(address indexed account, bool status);
    event MinterUpdated(address indexed account, bool status);
    event Minted(address indexed minter, address indexed to, uint256 amount);

    // ============================================================
    //                       Initialization
    // ============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer (replaces constructor for proxy pattern)
     * @param name_        Token name
     * @param symbol_      Token symbol
     * @param totalSupply_  Total supply (in smallest unit)
     * @param owner_       Contract owner
     * @param feeReceiver_ Fee receiver address
     * @param buyTax_      Buy tax rate (denominator 10000)
     * @param sellTax_     Sell tax rate (denominator 10000)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address owner_,
        address feeReceiver_,
        uint256 buyTax_,
        uint256 sellTax_
    ) external initializer {
        require(owner_ != address(0), "Invalid owner");
        require(feeReceiver_ != address(0), "Invalid fee receiver");
        require(buyTax_ <= MAX_TAX_RATE, "Buy tax too high");
        require(sellTax_ <= MAX_TAX_RATE, "Sell tax too high");
        require(totalSupply_ <= MAX_SUPPLY, "Exceeds max supply");

        __ERC20_init(name_, symbol_);
        __Ownable_init();
        __UUPSUpgradeable_init();

        // OZ v4 __Ownable_init() sets msg.sender as owner.
        // If owner_ differs from deployer, transfer ownership manually.
        if (owner_ != msg.sender) {
            transferOwnership(owner_);
        }

        feeReceiver = feeReceiver_;
        buyTaxRate = buyTax_;
        sellTaxRate = sellTax_;

        buyEnabled = true;
        sellEnabled = true;

        // Add owner to whitelist by default.
        // Note: when owner_ == msg.sender, transferOwnership is not called,
        // so this is the only place where the owner's whitelist is set.
        isWhitelisted[owner_] = true;
        // Add fee receiver to whitelist by default
        isWhitelisted[feeReceiver_] = true;

        _mint(owner_, totalSupply_);
    }

    // ============================================================
    //                    Core Transfer Logic
    // ============================================================

    /**
     * @dev Override _transfer to enforce the following on each transfer:
     *   1. Blacklist check
     *   2. Buy/sell switch check (whitelist exempt)
     *   3. Tax fee deduction (whitelist exempt)
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        // ---- Blacklist check ----
        require(!isBlacklisted[from], "Sender is blacklisted");
        require(!isBlacklisted[to], "Recipient is blacklisted");

        bool isBuy  = isPair[from]; // Transfer from Pair = user is buying
        bool isSell = isPair[to];   // Transfer to Pair   = user is selling

        bool senderWhitelisted    = isWhitelisted[from];
        bool recipientWhitelisted = isWhitelisted[to];

        // ---- Buy/sell switch check (whitelist exempt) ----
        if (isBuy && !buyEnabled) {
            require(recipientWhitelisted, "Buying is disabled");
        }
        if (isSell && !sellEnabled) {
            require(senderWhitelisted, "Selling is disabled");
        }

        // ---- Calculate tax fee ----
        uint256 taxAmount = 0;

        if (isBuy && isSell) {
            // Pair-to-Pair: apply the higher tax rate
            if (!senderWhitelisted && !recipientWhitelisted) {
                uint256 rate = buyTaxRate > sellTaxRate ? buyTaxRate : sellTaxRate;
                taxAmount = (amount * rate) / TAX_DENOMINATOR;
            }
        } else if (isBuy && !recipientWhitelisted) {
            taxAmount = (amount * buyTaxRate) / TAX_DENOMINATOR;
        } else if (isSell && !senderWhitelisted) {
            taxAmount = (amount * sellTaxRate) / TAX_DENOMINATOR;
        }
        // Regular transfers (non buy/sell) are tax-free

        if (taxAmount > 0) {
            // Send tax fee to feeReceiver first
            super._transfer(from, feeReceiver, taxAmount);
            // Send remaining amount to recipient
            super._transfer(from, to, amount - taxAmount);
        } else {
            super._transfer(from, to, amount);
        }
    }

    // ============================================================
    //                   Admin Functions (onlyOwner)
    // ============================================================

    // ---- Fee Settings ----

    function setFeeReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "Invalid address");
        address oldReceiver = feeReceiver;
        emit FeeReceiverUpdated(oldReceiver, newReceiver);
        if (oldReceiver != owner()) {
            isWhitelisted[oldReceiver] = false;
        }
        feeReceiver = newReceiver;
        isWhitelisted[newReceiver] = true;
    }

    function setBuyTaxRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_TAX_RATE, "Buy tax too high");
        emit BuyTaxRateUpdated(buyTaxRate, newRate);
        buyTaxRate = newRate;
    }

    function setSellTaxRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_TAX_RATE, "Sell tax too high");
        emit SellTaxRateUpdated(sellTaxRate, newRate);
        sellTaxRate = newRate;
    }

    // ---- Buy/Sell Switches ----

    function setBuyEnabled(bool enabled) external onlyOwner {
        buyEnabled = enabled;
        emit BuyEnabledUpdated(enabled);
    }

    function setSellEnabled(bool enabled) external onlyOwner {
        sellEnabled = enabled;
        emit SellEnabledUpdated(enabled);
    }

    // ---- DEX Pair Management ----

    function setPair(address pair, bool status) external onlyOwner {
        require(pair != address(0), "Invalid pair");
        isPair[pair] = status;
        emit PairUpdated(pair, status);
    }

    // ---- Blacklist Management ----

    function setBlacklist(address account, bool status) external onlyOwner {
        require(account != address(0), "Invalid address");
        require(account != owner(), "Cannot blacklist owner");
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function setBlacklistBatch(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Invalid address");
            require(accounts[i] != owner(), "Cannot blacklist owner");
            isBlacklisted[accounts[i]] = status;
            emit BlacklistUpdated(accounts[i], status);
        }
    }

    // ---- Whitelist Management ----

    function setWhitelist(address account, bool status) external onlyOwner {
        require(account != address(0), "Invalid address");
        isWhitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setWhitelistBatch(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Invalid address");
            isWhitelisted[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    // ---- Minter Management ----

    function setMinter(address account, bool status) external onlyOwner {
        require(account != address(0), "Invalid address");
        isMinter[account] = status;
        emit MinterUpdated(account, status);
    }

    // ============================================================
    //                      Mint Functions
    // ============================================================

    /// @notice Mint tokens, restricted to minter addresses, capped by MAX_SUPPLY
    function mint(address to, uint256 amount) external {
        require(isMinter[msg.sender], "Caller is not a minter");
        require(to != address(0), "Invalid address");
        _mint(to, amount);
        emit Minted(msg.sender, to, amount);
    }

    /// @dev Override _mint to enforce total supply never exceeds 10 billion
    function _mint(address account, uint256 amount) internal virtual override {
        require(!isBlacklisted[account], "Recipient is blacklisted");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        super._mint(account, amount);
    }

    // ============================================================
    //                 Ownership Transfer (whitelist sync)
    // ============================================================

    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        address oldOwner = owner();
        isWhitelisted[newOwner] = true;
        emit WhitelistUpdated(newOwner, true);
        if (oldOwner != newOwner){
            isWhitelisted[oldOwner] = false;
            emit WhitelistUpdated(oldOwner, false);
        }
        super.transferOwnership(newOwner);
    }

    // ============================================================
    //                    UUPS Upgrade Authorization
    // ============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
