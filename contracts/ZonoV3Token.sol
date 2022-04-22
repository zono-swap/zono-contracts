// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AntiBotHelper.sol";
import "./FeeHelper.sol";
import "./MintableERC20.sol";
import "./libs/IUniswapAmm.sol";

contract ZonoV3Token is
    MintableERC20("ZonoSwap Token V3", "ZONOV3"),
    AntiBotHelper,
    FeeHelper
{
    using SafeMath for uint256;
    using Address for address;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address payable public _marketingWallet;
    address public _charityWallet;

    bool public _swapAndLiquifyEnabled = true;
    uint256 public _numTokensSellToAddToLiquidity = 100 ether;

    IUniswapV2Router02 public _swapRouter;
    bool _inSwapAndLiquify;

    event LiquifyFeeTransferred(
        address indexed charityWallet,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event MarketingFeeTrasferred(
        address indexed marketingWallet,
        uint256 tokensSwapped,
        uint256 bnbAmount
    );
    event SwapTokensForBnbFailed(address indexed to, uint256 tokenAmount);
    event LiquifyFaied(uint256 tokenAmount, uint256 bnbAmount);

    modifier lockTheSwap() {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    constructor() {
        _marketingWallet = payable(_msgSender());
        _charityWallet = _msgSender();
        _swapRouter = IUniswapV2Router02(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        );       
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}

    function setSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");

        _swapRouter = IUniswapV2Router02(newSwapRouter);
    }

    function setSwapAndLiquifyEnabled(bool enabled) public onlyOwner {
        _swapAndLiquifyEnabled = enabled;
    }

    /**
     * @notice Set new marketing wallet
     */
    function setMarketingWallet(address payable wallet) external onlyOwner {
        require(wallet != address(0), "Invalid marketing wallet");
        _marketingWallet = wallet;
    }

    /**
     * @notice Set new charity wallet
     */
    function setCharityWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "Invalid charity wallet");
        _charityWallet = wallet;
    }

    function setNumTokensSellToAddToLiquidity(
        uint256 numTokensSellToAddToLiquidity
    ) external onlyOwner {
        require(numTokensSellToAddToLiquidity > 0, "Invalid input");
        _numTokensSellToAddToLiquidity = numTokensSellToAddToLiquidity;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is uniswap pair.
        uint256 contractTokenBalance = balanceOf(address(this));

        // indicates if fee should be deducted from transfer
        (bool feeApplied, TX_CASE txCase) = shouldFeeApplied(from, to);

        // Swap and liquify also triggered when the tx needs to have fee
        if (
            !_inSwapAndLiquify &&
            feeApplied &&
            _swapAndLiquifyEnabled &&
            contractTokenBalance >= _numTokensSellToAddToLiquidity
        ) {
            // add liquidity, send to marketing wallet
            uint16 sumOfLiquifyFee = _tokenFees[TX_CASE.TRANSFER].liquifyFee +
                _tokenFees[TX_CASE.BUY].liquifyFee +
                _tokenFees[TX_CASE.SELL].liquifyFee;
            uint16 sumOfMarketingFee = _tokenFees[TX_CASE.TRANSFER]
                .marketingFee +
                _tokenFees[TX_CASE.BUY].marketingFee +
                _tokenFees[TX_CASE.SELL].marketingFee;

            swapAndLiquify(
                _numTokensSellToAddToLiquidity,
                sumOfMarketingFee,
                sumOfLiquifyFee
            );
        }

        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from, to, amount, feeApplied, txCase);
    }

    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool feeApplied,
        TX_CASE txCase
    ) private {
        if (feeApplied) {
            uint16 liquifyFee = _tokenFees[txCase].liquifyFee;
            uint16 marketingFee = _tokenFees[txCase].marketingFee;
            uint16 burnFee = _tokenFees[txCase].burnFee;

            uint256 burnFeeAmount = amount.mul(burnFee).div(10000);
            uint256 otherFeeAmount = amount
                .mul(uint256(liquifyFee).add(marketingFee))
                .div(10000);

            if (burnFeeAmount > 0) {
                super._transfer(sender, DEAD, burnFeeAmount);
                amount = amount.sub(burnFeeAmount);
            }
            if (otherFeeAmount > 0) {
                super._transfer(sender, address(this), otherFeeAmount);
                amount = amount.sub(otherFeeAmount);
            }
        }
        if (amount > 0) {
            super.checkBot(sender, recipient, amount);
            super._transfer(sender, recipient, amount);
        }
    }

    function swapAndLiquify(
        uint256 amount,
        uint16 marketingFee,
        uint16 liquifyFee
    ) private lockTheSwap {
        //This needs to be distributed among marketing wallet and liquidity
        if (liquifyFee == 0 && marketingFee == 0) {
            return;
        }

        uint256 liquifyAmount = amount.mul(liquifyFee).div(
            uint256(marketingFee).add(liquifyFee)
        );
        if (liquifyAmount > 0) {
            amount = amount.sub(liquifyAmount);
            // split the contract balance into halves
            uint256 half = liquifyAmount.div(2);
            uint256 otherHalf = liquifyAmount.sub(half);

            (uint256 bnbAmount, bool success) = swapTokensForBnb(
                half,
                payable(address(this))
            );

            if (!success) {
                emit SwapTokensForBnbFailed(address(this), half);
            }
            // add liquidity to pancakeswap
            if (otherHalf > 0 && bnbAmount > 0 && success) {
                success = addLiquidityETH(otherHalf, bnbAmount, _charityWallet);
                if (success) {
                    emit LiquifyFeeTransferred(
                        _charityWallet,
                        otherHalf,
                        bnbAmount
                    );
                } else {
                    emit LiquifyFaied(otherHalf, bnbAmount);
                }
            }
        }

        if (amount > 0) {
            (uint256 bnbAmount, bool success) = swapTokensForBnb(
                amount,
                _marketingWallet
            );
            if (success) {
                emit MarketingFeeTrasferred(
                    _marketingWallet,
                    amount,
                    bnbAmount
                );
            } else {
                emit SwapTokensForBnbFailed(_marketingWallet, amount);
            }
        }
    }

    function swapTokensForBnb(uint256 tokenAmount, address payable to)
        private
        returns (uint256 bnbAmount, bool success)
    {
        // generate the uniswap pair path of token -> busd
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _swapRouter.WETH();

        _approve(address(this), address(_swapRouter), tokenAmount);

        // capture the target address's current BNB balance.
        uint256 balanceBefore = to.balance;

        // make the swap
        try
            _swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                0, // accept any amount of BNB
                path,
                to,
                block.timestamp.add(300)
            )
        {
            // how much BNB did we just swap into?
            bnbAmount = to.balance.sub(balanceBefore);
            success = true;
        } catch (
            bytes memory /* lowLevelData */
        ) {
            // how much BNB did we just swap into?
            bnbAmount = 0;
            success = false;
        }
    }

    function addLiquidityETH(
        uint256 tokenAmount,
        uint256 bnbAmount,
        address to
    ) private returns (bool success) {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_swapRouter), tokenAmount);

        // add the liquidity
        try
            _swapRouter.addLiquidityETH{value: bnbAmount}(
                address(this),
                tokenAmount,
                0, // slippage is unavoidable
                0, // slippage is unavoidable
                to,
                block.timestamp.add(300)
            )
        {
            success = true;
        } catch (
            bytes memory /* lowLevelData */
        ) {
            success = false;
        }
    }
}
