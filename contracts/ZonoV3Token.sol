// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./AntiBotHelper.sol";
import "./MintableERC20.sol";
import "./libs/IUniswapAmm.sol";

contract ZonoV3Token is MintableERC20("ZonoSwap", "ZONO"), AntiBotHelper {
    using SafeMath for uint256;
    using Address for address;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ZERO = address(0);
    uint16 public constant MAX_LIQUIFY_FEE = 500; // 5% max
    uint16 public constant MAX_MARKETING_FEE = 500; // 5% max
    uint16 public constant MAX_BURN_FEE = 500; // 5% max

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isZonoPair;

    uint16 public _buy_liquifyFee = 200; // Fee for Liquidity in buying
    uint16 public _buy_marketingFee = 100; // Fee for Marketing in buying
    uint16 public _buy_burnFee = 100; // Fee for Marketing in buying
    uint16 public _sell_liquifyFee = 100; // Fee for Liquidity in selling
    uint16 public _sell_marketingFee = 50; // Fee for Marketing in selling
    uint16 public _sell_burnFee = 100; // Fee for Marketing in selling

    address payable public _marketingWallet;

    bool public _swapAndLiquifyEnabled = true;
    uint256 public _numTokensSellToAddToLiquidity = 100 ether;

    IUniswapV2Router02 public _swapRouter;
    bool _inSwapAndLiquify;

    event LiquifyAndBurned(
        uint256 tokensSwapped,
        uint256 bnbReceived,
        uint256 tokensIntoLiqudity
    );
    event MarketingFeeTrasferred(
        address indexed marketingWallet,
        uint256 tokensSwapped,
        uint256 bnbAmount
    );
    event SwapTokensForBnbFailed(address indexed to, uint256 tokenAmount);
    event LiquifyAndBurnFaied(uint256 tokenAmount, uint256 bnbAmount);

    modifier lockTheSwap() {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    constructor() {
        _marketingWallet = payable(_msgSender());
        _swapRouter = IUniswapV2Router02(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        );

        _isExcludedFromFee[_msgSender()] = true;
        _isExcludedFromFee[DEAD] = true;
        _isExcludedFromFee[ZERO] = true;
        _isExcludedFromFee[address(this)] = true;

        excludeFromAntiWhales(_msgSender());
        excludeFromAntiWhales(DEAD);
        excludeFromAntiWhales(ZERO);
        excludeFromAntiWhales(address(this));
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}

    function setSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");

        _swapRouter = IUniswapV2Router02(newSwapRouter);
    }

    function excludeFromFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function isExcludedFromFee(address account) external view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function excludeFromZonoPair(address lpAddress) external onlyOwner {
        _isZonoPair[lpAddress] = false;
    }

    function includeInZonoPair(address lpAddress) external onlyOwner {
        _isZonoPair[lpAddress] = true;
    }

    function isZonoPair(address lpAddress) external view returns (bool) {
        return _isZonoPair[lpAddress];
    }

    function setAllFeePercent(
        uint16 buyLiquifyFee,
        uint16 buyMarketingFee,
        uint16 buyBurnFee,
        uint16 sellLiquifyFee,
        uint16 sellMarketingFee,
        uint16 sellBurnFee
    ) external onlyOwner {
        require(
            buyLiquifyFee <= MAX_LIQUIFY_FEE &&
                sellLiquifyFee <= MAX_LIQUIFY_FEE,
            "Liquidity fee overflow"
        );
        require(
            buyMarketingFee <= MAX_MARKETING_FEE &&
                sellMarketingFee <= MAX_MARKETING_FEE,
            "Buyback fee overflow"
        );
        require(
            buyBurnFee <= MAX_MARKETING_FEE && sellBurnFee <= MAX_MARKETING_FEE,
            "Burn fee overflow"
        );
        _buy_liquifyFee = buyLiquifyFee;
        _buy_marketingFee = buyMarketingFee;
        _buy_burnFee = buyBurnFee;
        _sell_liquifyFee = sellLiquifyFee;
        _sell_marketingFee = sellMarketingFee;
        _sell_burnFee = sellBurnFee;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        _swapAndLiquifyEnabled = _enabled;
    }

    function setMarketingWallet(address payable newMarketingWallet)
        external
        onlyOwner
    {
        require(newMarketingWallet != address(0), "ZERO ADDRESS");
        _marketingWallet = newMarketingWallet;
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
        // if any account belongs to _isExcludedFromFee account then remove the fee
        bool takeFee = !_isExcludedFromFee[from] &&
            !_isExcludedFromFee[to] &&
            (_isZonoPair[from] || _isZonoPair[to]);

        // Swap and liquify also triggered when the tx needs to have fee
        if (!_inSwapAndLiquify && takeFee && _swapAndLiquifyEnabled) {
            if (contractTokenBalance >= _numTokensSellToAddToLiquidity) {
                contractTokenBalance = _numTokensSellToAddToLiquidity;
                // add liquidity, send to marketing wallet
                uint16 sumOfMarketingFee = _buy_marketingFee +
                    _sell_marketingFee;
                uint16 sumOfLiquifyFee = _buy_liquifyFee + _sell_liquifyFee;
                swapAndLiquify(
                    contractTokenBalance,
                    sumOfMarketingFee,
                    sumOfLiquifyFee,
                    _marketingWallet
                );
            }
        }

        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from, to, amount, takeFee, _isZonoPair[from]);
    }

    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee,
        bool isBuyFee
    ) private {
        if (takeFee) {
            uint16 burnFee = _sell_burnFee;
            uint16 liquifyFee = _sell_liquifyFee;
            uint16 marketingFee = _sell_marketingFee;
            if (isBuyFee) {
                burnFee = _buy_burnFee;
                liquifyFee = _buy_liquifyFee;
                marketingFee = _buy_marketingFee;
            }

            uint256 burnFeeAmount = amount.mul(burnFee).div(10000);
            if (burnFeeAmount > 0) {
                super._transfer(sender, DEAD, burnFeeAmount);
                amount = amount.sub(burnFeeAmount);
            }
            uint256 otherFeeAmount = amount
                .mul(uint256(liquifyFee).add(marketingFee))
                .div(10000);
            if (otherFeeAmount > 0) {
                super._transfer(sender, address(this), otherFeeAmount);
                amount = amount.sub(otherFeeAmount);
            }
        }
        if (amount > 0) {
            super.checkBot(this, sender, recipient, amount);
            super._transfer(sender, recipient, amount);
        }
    }

    function swapAndLiquify(
        uint256 amount,
        uint16 marketingFee,
        uint16 liquifyFee,
        address payable marketingWallet
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
                success = addLiquidityAndBurn(otherHalf, bnbAmount);
                if (success) {
                    emit LiquifyAndBurned(half, bnbAmount, otherHalf);
                } else {
                    emit LiquifyAndBurnFaied(otherHalf, bnbAmount);
                }
            }
        }

        if (amount > 0) {
            (uint256 bnbAmount, bool success) = swapTokensForBnb(
                amount,
                marketingWallet
            );
            if (success) {
                emit MarketingFeeTrasferred(marketingWallet, amount, bnbAmount);
            } else {
                emit SwapTokensForBnbFailed(marketingWallet, amount);
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

    function addLiquidityAndBurn(uint256 tokenAmount, uint256 bnbAmount)
        private
        returns (bool success)
    {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_swapRouter), tokenAmount);

        // add the liquidity
        try
            _swapRouter.addLiquidityETH{value: bnbAmount}(
                address(this),
                tokenAmount,
                0, // slippage is unavoidable
                0, // slippage is unavoidable
                DEAD,
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
