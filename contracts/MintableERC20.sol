// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/ERC20.sol";

contract MintableERC20 is ERC20 {
    address private _operator;

    event OperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );

    modifier onlyOperator() {
        require(
            operator() == _msgSender(),
            "HEARN: caller is not the operator"
        );
        _;
    }

    constructor(string memory tokenName, string memory tokenSymbol)
        ERC20(tokenName, tokenSymbol)
    {
        _operator = _msgSender();
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing
     * the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token operator
     */
    function mint(address to, uint256 amount)
        external
        onlyOperator
        returns (bool)
    {
        _mint(to, amount);
        return true;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `msg.sender`, increasing
     * the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token operator
     */
    function mint(uint256 amount) external onlyOperator returns (bool) {
        _mint(_msgSender(), amount);
        return true;
    }

    function operator() public view virtual returns (address) {
        return _operator;
    }

    function transferOperator(address newOperator) public virtual onlyOperator {
        require(
            newOperator != address(0),
            "HEARN: new operator is the zero address"
        );
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

    function recoverToken(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // do not allow recovering self token
        require(tokenAddress != address(this), "Self withdraw");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }
}

