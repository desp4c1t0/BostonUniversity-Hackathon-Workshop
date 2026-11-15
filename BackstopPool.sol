// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BackstopPool
/// @notice Stakers lock TOKEN as first-loss capital for a covered protocol. The guardian may
///         slash up to MAX_SLASH_BPS of pooled assets per event to cover a shortfall. Premiums
///         paid by the covered protocol are streamed linearly to stakers over PREMIUM_PERIOD.
///         Stake is represented by fungible, transferable shares; exiting requires a cooldown.
contract BackstopPool {
    uint256 public constant PREMIUM_PERIOD = 7 days;
    uint256 public constant COOLDOWN = 10 days;
    uint256 public constant UNSTAKE_WINDOW = 2 days;
    uint256 public constant MAX_SLASH_BPS = 3_000;
    uint256 public constant BPS = 10_000;

    string public constant name = "Backstop Share";
    string public constant symbol = "bSHR";
    uint8 public constant decimals = 18;

    IERC20Min public immutable token;
    address public guardian;
    address public pendingGuardian;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public cooldownStart;

    uint256 public storedAssets;
    uint256 public premiumRate;
    uint256 public premiumFinish;
    uint256 public lastAccrual;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Redeem(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event CooldownStarted(address indexed account, uint256 timestamp);
    event PremiumAdded(address indexed payer, uint256 amount, uint256 rate, uint256 finish);
    event Slashed(address indexed recipient, uint256 amount);
    event GuardianProposed(address indexed next);
    event GuardianAccepted(address indexed guardian);

    modifier onlyGuardian() {
        require(msg.sender == guardian, "guardian");
        _;
    }

    constructor(IERC20Min token_, address guardian_) {
        require(address(token_) != address(0) && guardian_ != address(0), "zero");
        token = token_;
        guardian = guardian_;
        lastAccrual = block.timestamp;
    }

    // ------------------------------------------------------------------ views

    function totalAssets() public view returns (uint256) {
        return storedAssets + _unaccrued();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function canRedeem(address account) public view returns (bool) {
        uint256 start = cooldownStart[account];
        if (start == 0) return false;
        uint256 open = start + COOLDOWN;
        return block.timestamp >= open && block.timestamp <= open + UNSTAKE_WINDOW;
    }

    // ---------------------------------------------------------------- staking

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(receiver != address(0), "receiver");
        _accrue();
        shares = convertToShares(assets);
        require(shares > 0, "zero shares");
        _pull(msg.sender, assets);
        storedAssets += assets;
        cooldownStart[receiver] = _nextCooldown(0, shares, receiver, balanceOf[receiver]);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function cooldown() external {
        require(balanceOf[msg.sender] > 0, "no stake");
        cooldownStart[msg.sender] = block.timestamp;
        emit CooldownStarted(msg.sender, block.timestamp);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        require(shares > 0 && receiver != address(0), "args");
        require(canRedeem(owner_), "cooldown");
        if (msg.sender != owner_) _spendAllowance(msg.sender, owner_, shares);
        _accrue();
        assets = convertToAssets(shares);
        _burn(owner_, shares);
        storedAssets -= assets;
        if (balanceOf[owner_] == 0) cooldownStart[owner_] = 0;
        _push(receiver, assets);
        emit Redeem(msg.sender, receiver, owner_, assets, shares);
    }

    // --------------------------------------------------------------- premiums

    /// @notice Adds `amount` to the premium stream. Any unstreamed remainder is rolled into
    ///         the new stream, which always runs for a full PREMIUM_PERIOD from now.
    function notifyPremium(uint256 amount) external {
        require(amount >= PREMIUM_PERIOD, "dust");
        _accrue();
        _pull(msg.sender, amount);
        uint256 leftover = block.timestamp < premiumFinish ? (premiumFinish - block.timestamp) * premiumRate : 0;
        premiumRate = (amount + leftover) / PREMIUM_PERIOD;
        premiumFinish = block.timestamp + PREMIUM_PERIOD;
        emit PremiumAdded(msg.sender, amount, premiumRate, premiumFinish);
    }

    // --------------------------------------------------------------- guardian

    function slash(uint256 bps, address recipient) external onlyGuardian returns (uint256 amount) {
        require(bps <= MAX_SLASH_BPS && recipient != address(0), "args");
        _accrue();
        amount = storedAssets * bps / BPS;
        storedAssets -= amount;
        _push(recipient, amount);
        emit Slashed(recipient, amount);
    }

    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        emit GuardianProposed(next);
    }

    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "pending");
        guardian = msg.sender;
        pendingGuardian = address(0);
        emit GuardianAccepted(msg.sender);
    }

    // ----------------------------------------------------------------- shares

    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;
        emit Approval(msg.sender, spender, shares);
        return true;
    }

    function transfer(address to, uint256 shares) external returns (bool) {
        _transfer(msg.sender, to, shares);
        return true;
    }

    function transferFrom(address from, address to, uint256 shares) external returns (bool) {
        _spendAllowance(from, msg.sender, shares);
        _transfer(from, to, shares);
        return true;
    }

    // --------------------------------------------------------------- internal

    function _unaccrued() internal view returns (uint256) {
        uint256 end = block.timestamp < premiumFinish ? block.timestamp : premiumFinish;
        return end > lastAccrual ? (end - lastAccrual) * premiumRate : 0;
    }

    /// @dev Folds streamed premiums into storedAssets and checkpoints the stream.
    function _accrue() internal {
        uint256 streamed = _unaccrued();
        if (streamed > 0) {
            storedAssets += streamed;
            lastAccrual = block.timestamp;
        }
    }

    /// @dev stkAAVE-style inheritance: incoming shares can never make a receiver's cooldown
    ///      older than it already is, so transfers cannot be used to skip the cooldown.
    function _nextCooldown(uint256 fromCooldown, uint256 amount, address to, uint256 toBalance)
        internal
        view
        returns (uint256)
    {
        uint256 toCooldown = cooldownStart[to];
        if (toCooldown == 0) return 0;
        if (block.timestamp > toCooldown + COOLDOWN + UNSTAKE_WINDOW) return 0;
        if (fromCooldown == 0) fromCooldown = block.timestamp;
        if (fromCooldown <= toCooldown) return toCooldown;
        return (amount * fromCooldown + toBalance * toCooldown) / (amount + toBalance);
    }

    function _transfer(address from, address to, uint256 shares) internal {
        require(to != address(0), "to");
        uint256 fromBal = balanceOf[from];
        uint256 toBal = balanceOf[to];
        require(fromBal >= shares, "balance");
        cooldownStart[to] = _nextCooldown(cooldownStart[from], shares, to, toBal);
        balanceOf[from] = fromBal - shares;
        balanceOf[to] = toBal + shares;
        if (fromBal == shares) cooldownStart[from] = 0;
        emit Transfer(from, to, shares);
    }

    function _spendAllowance(address owner_, address spender, uint256 shares) internal {
        uint256 allowed = allowance[owner_][spender];
        if (allowed != type(uint256).max) {
            require(allowed >= shares, "allowance");
            allowance[owner_][spender] = allowed - shares;
        }
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balanceOf[to] += shares;
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit Transfer(from, address(0), shares);
    }

    function _pull(address from, uint256 amount) internal {
        require(token.transferFrom(from, address(this), amount), "pull");
    }

    function _push(address to, uint256 amount) internal {
        require(token.transfer(to, amount), "push");
    }
}
