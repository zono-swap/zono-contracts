// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/IERC20.sol";

/**
 * @notice Anti-Bot Helper
 * Blacklis feature
 * Max TX Amount feature
 * Max Wallet Amount feature
 */
contract AntiBotHelper is Ownable {
    using SafeMath for uint256;

    uint256 public constant MAX_TX_AMOUNT_MIN_LIMIT = 10000 ether;
    uint256 public constant MAX_WALLET_AMOUNT_MIN_LIMIT = 1000000 ether;

    mapping(address => bool) private _isExcludedFromAntiWhales;
    mapping(address => bool) private _blacklist;

    uint256 public _maxTxAmount = 1000 ether;
    uint256 public _maxWalletAmount = 10000 ether;

    event ExcludedFromBlacklist(address indexed account);
    event IncludedInBlacklist(address indexed account);
    event ExcludedFromAntiWhales(address indexed account);
    event IncludedInAntiWhales(address indexed account);

    /**
     * @notice Exclude the account from black list
     * @param account: the account to be excluded
     * @dev Only callable by owner
     */
    function excludeFromBlacklist(address account) public onlyOwner {
        _blacklist[account] = false;
        emit ExcludedFromBlacklist(account);
    }

    /**
     * @notice Include the account in black list
     * @param account: the account to be included
     * @dev Only callable by owner
     */
    function includeInBlacklist(address account) public onlyOwner {
        _blacklist[account] = true;
        emit IncludedInBlacklist(account);
    }

    /**
     * @notice Check if the account is included in black list
     * @param account: the account to be checked
     */
    function isIncludedInBlacklist(address account) public view returns (bool) {
        return _blacklist[account];
    }

    /**
     * @notice Exclude the account from anti whales limit
     * @param account: the account to be excluded
     * @dev Only callable by owner
     */
    function excludeFromAntiWhales(address account) public onlyOwner {
        _isExcludedFromAntiWhales[account] = true;
        emit ExcludedFromAntiWhales(account);
    }

    /**
     * @notice Include the account in anti whales limit
     * @param account: the account to be included
     * @dev Only callable by owner
     */
    function includeInAntiWhales(address account) public onlyOwner {
        _isExcludedFromAntiWhales[account] = false;
        emit IncludedInAntiWhales(account);
    }

    /**
     * @notice Check if the account is excluded from anti whales limit
     * @param account: the account to be checked
     */
    function isExcludedFromAntiWhales(address account)
        public
        view
        returns (bool)
    {
        return _isExcludedFromAntiWhales[account];
    }

    /**
     * @notice Set anti whales limit configuration
     * @param maxTxAmount: max amount of token in a transaction
     * @param maxWalletAmount: max amount of token can be kept in a wallet
     * @dev Only callable by owner
     */
    function setAntiWhalesConfiguration(
        uint256 maxTxAmount,
        uint256 maxWalletAmount
    ) external onlyOwner {
        require(
            maxTxAmount >= MAX_TX_AMOUNT_MIN_LIMIT,
            "Max tx amount too small"
        );
        require(
            maxWalletAmount >= MAX_WALLET_AMOUNT_MIN_LIMIT,
            "Max wallet amount too small"
        );
        _maxTxAmount = maxTxAmount;
        _maxWalletAmount = maxWalletAmount;
    }

    function checkBot(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal view {
        require(amount > 0, "Transfer amount must be greater than zero");

        require(
            !_blacklist[from] && !_blacklist[to],
            "Transfer from or to the blacklisted account"
        );

        // Check max tx limit
        if (
            !_isExcludedFromAntiWhales[from] || !_isExcludedFromAntiWhales[to]
        ) {
            require(
                amount <= _maxTxAmount,
                "Too many tokens are going to be transferred"
            );
        }

        // Check max wallet amount limit
        if (!_isExcludedFromAntiWhales[to]) {
            require(
                token.balanceOf(to).add(amount) <= _maxWalletAmount,
                "Too many tokens are going to be stored in target account"
            );
        }
    }
}
