/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;


import "../core/State.sol";
import "../events/LoanClosingsEvents.sol";
import "../mixins/VaultController.sol";
import "../mixins/InterestUser.sol";
import "../mixins/LiquidationHelper.sol";
import "../swaps/SwapsUser.sol";
import "../interfaces/ILoanPool.sol";
import "../mixins/RewardHelper.sol";
import '../interfaces/IERC20.sol';
import '../interfaces/IWbase.sol';
import '../interfaces/IWbaseERC20.sol';
import '../external/uniswap/interfaces/IUniswapV2Router02.sol';

import '../external/uniswap/UniswapV2Library.sol';

contract LoanLiquidate is LoanClosingsEvents, VaultController, InterestUser, SwapsUser, LiquidationHelper, RewardHelper {
    uint256 constant internal MONTH = 365 days / 12;
    //0.00001 BTC, would be nicer in State.sol, but would require a redeploy of the complete protocol, so adding it here instead
    //because it's not shared state anyway and only used by this contract
    uint256 constant public paySwapExcessToBorrowerThreshold = 10000000000000;



    enum CloseTypes {
        Deposit,
        Liquidation
    }

    constructor() public {}


    function()
        external
    {
        revert("fallback not allowed");
    }

    function initialize(
        address target
    )
        external
        onlyOwner
    {
        _setTarget(this.setRouterApprove.selector, target);
        _setTarget(this.setRouterParams.selector, target);
        _setTarget(this.setLiquidator.selector, target);
        _setTarget(this.renounceLiquidator.selector, target);
        _setTarget(this.isLiquidator.selector, target);
        _setTarget(this.liquidate.selector, target);
    }

    modifier onlyLiquidator() {
        require(isLiquidator(_msgSender()), "DOES_NOT_HAVE_LIQUIDATOR_ROLE");
        _;
    }



    function setRouterApprove(
        address[] calldata collateralAddrs,
        address[] calldata routerAddrs
    )
        external
        onlyOwner
    {
        require(collateralAddrs.length == routerAddrs.length, "count mismatch");

        for (uint256 i = 0; i < collateralAddrs.length; i++) {

            IERC20(address(collateralAddrs[i])).approve(address(routerAddrs[i]),uint256(-1));
        }

    }

    function setRouterParams(
        address[] calldata loanAddrs,
        address[] calldata router1Addrs,
        address[] calldata router2Addrs,
        address[] calldata tokenPairAddrs
    )
        external
        onlyOwner
    {
        require(loanAddrs.length == router1Addrs.length, "count mismatch1");
        require(loanAddrs.length == router2Addrs.length, "count mismatch2");
        require(loanAddrs.length == tokenPairAddrs.length, "count mismatch3");

        for (uint256 i = 0; i < loanAddrs.length; i++) {
            collateralPairToRouter[loanAddrs[i]] = router1Addrs[i];
            pairLoanToRouter[loanAddrs[i]] = router2Addrs[i];
            loanToTokenPair[loanAddrs[i]] = tokenPairAddrs[i];

        }

    }


    function setLiquidator(
        address liquidator
    )
        external
        onlyOwner
    {
        _liquidators.add(liquidator);
        
    }

    function renounceLiquidator(
        address liquidator
    )
        external
        onlyOwner
    {
        _liquidators.remove(liquidator);
        
    }

    function isLiquidator(address account) public view returns (bool) {
        return _liquidators.has(account);
    }
    /**
     * liquidates a loan. the caller needs to approve the closeAmount prior to calling.
     * Will not liquidate more than is needed to restore the desired margin (maintenance +5%).
     * @param loanId the ID of the loan to liquidate
     * @param receiver the receiver of the seized amount
     * @param closeAmount the amount to close in loanTokens
     * */
    function liquidate(
        bytes32 loanId,
        address receiver,
        uint256 closeAmount) // denominated in loanToken
        external
        payable
        nonReentrant
        onlyLiquidator
        returns (
            uint256 loanCloseAmount,
            uint256 seizedAmount,
            uint256 excessSeizedAmount,
            address seizedToken,
            uint256 profitAmount
        )
    {

        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];

        (uint256 currentMargin, ) = IPriceFeeds(priceFeeds).getCurrentMargin(
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanLocal.principal,
            loanLocal.collateral
        );


        if( loanLocal.endTimestamp<now && currentMargin > loanParamsLocal.maintenanceMargin ) {
            return _liquidateHealthy(
                loanId,
                receiver,
                closeAmount               
            );

        } else {

            return _liquidateUnhealthy(
                loanId,
                receiver,
                closeAmount
            );

        }

    }


    /**
     * internal function for liquidating a loan.
     * @param loanId the ID of the loan to liquidate
     * @param receiver the receiver of the seized amount
     * @param closeAmount the amount to close in loanTokens
     * */
    function _liquidateUnhealthy(
        bytes32 loanId,
        address receiver,
        uint256 closeAmount)
        internal
        returns (
            uint256 loanCloseAmount,
            uint256 seizedAmount,
            uint256 excessSeizedAmount,
            address seizedToken,
            uint256 profitAmount
        )
    {
        excessSeizedAmount = 0;
        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];

        require(loanLocal.active, "loan is closed");
        require(loanParamsLocal.id != 0, "loanParams not exists");

        (uint256 currentMargin, uint256 collateralToLoanRate) = IPriceFeeds(priceFeeds).getCurrentMargin(
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanLocal.principal,
            loanLocal.collateral
        );
        require(
            currentMargin <= loanParamsLocal.maintenanceMargin,
            "healthy position"
        );

        loanCloseAmount = closeAmount;

        //amounts to restore the desired margin (maintencance + 5%)
        (uint256 maxLiquidatable, uint256 maxSeizable,) = _getLiquidationAmounts(
            loanLocal.principal,
            loanLocal.collateral,
            currentMargin,
            loanParamsLocal.maintenanceMargin,
            collateralToLoanRate
        );

        if (loanCloseAmount < maxLiquidatable) {
            seizedAmount = maxSeizable
                .mul(loanCloseAmount)
                .div(maxLiquidatable);
        } else if (loanCloseAmount > maxLiquidatable) {
            // adjust down the close amount to the max
            loanCloseAmount = maxLiquidatable;
            seizedAmount = maxSeizable;
        } else {
            seizedAmount = maxSeizable;
        }
        

        require(loanCloseAmount != 0, "nothing to liquidate");

        seizedToken = loanParamsLocal.collateralToken;


        profitAmount = _startArbitrage(
            loanId,
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanCloseAmount,
            seizedAmount
        );


        // liquidator deposits the principal being closed
        _returnPrincipalWithCollateral(
            loanParamsLocal.loanToken,
            address(this),
            loanCloseAmount
        );

        // a portion of the principal is repaid to the lender out of interest refunded
        uint256 loanCloseAmountLessInterest = _settleInterestToPrincipal(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            loanLocal.borrower
        );

        if (loanCloseAmount > loanCloseAmountLessInterest) {
            // full interest refund goes to the borrower
            _withdrawAsset(
                loanParamsLocal.loanToken,
                loanLocal.borrower,
                loanCloseAmount - loanCloseAmountLessInterest
            );
        }

        if (loanCloseAmountLessInterest != 0) {
            // The lender always gets back an ERC20 (even wbase), so we call withdraw directly rather than
            // use the _withdrawAsset helper function
            vaultWithdraw(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                loanCloseAmountLessInterest
            );
        }


        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        _emitClosingEvents(
            loanParamsLocal,
            loanLocal,
            loanCloseAmount,
            seizedAmount,
            0,  //collateralRepayingAmount
            collateralToLoanRate,
            0, // collateralToLoanSwapRate
            currentMargin,
            CloseTypes.Liquidation
        );
    }

    function _liquidateHealthy(
        bytes32 loanId,
        address receiver,
        uint256 closeAmount)
        internal
        returns (
            uint256 loanCloseAmount,
            uint256 seizedAmount,
            uint256 excessSeizedAmount,
            address seizedToken,
            uint256 profitAmount

        )
    {
        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];

        require(loanLocal.active, "loan is closed"); // pass

        require(loanParamsLocal.id != 0, "loanParams not exists");// pass

        (uint256 currentMargin, uint256 collateralToLoanRate) = IPriceFeeds(priceFeeds).getCurrentMargin(
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanLocal.principal,
            loanLocal.collateral
        );
        

        loanCloseAmount = closeAmount;

        // //amounts to restore the desired margin (maintencance + 5%)
        (uint256 maxLiquidatable, uint256 maxSeizable,) = _getHealthyLiquidationAmounts(
            loanLocal.principal,
            loanLocal.collateral,
            currentMargin,
            loanParamsLocal.maintenanceMargin,
            collateralToLoanRate
        );

        require(
            loanCloseAmount >= maxLiquidatable,
            "close amount must excess unhealthty position level"
        );


        // adjust down the close amount to the max
        loanCloseAmount = maxLiquidatable;


        seizedAmount = loanCloseAmount
            .mul(
                liquidationIncentivePercent
                    .add(10**20)
            );

        seizedAmount = seizedAmount
            .div(collateralToLoanRate)
            .div(100);


        excessSeizedAmount =  maxSeizable - seizedAmount;

        require(loanCloseAmount != 0, "nothing to liquidate");


        seizedToken = loanParamsLocal.collateralToken;
        
        profitAmount = _startArbitrage(
            loanId,
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanCloseAmount,
            seizedAmount
        );



        // liquidator deposits the principal being closed
        _returnPrincipalWithCollateral(
            loanParamsLocal.loanToken,
            address(this),
            loanCloseAmount
        );

        // a portion of the principal is repaid to the lender out of interest refunded
        uint256 loanCloseAmountLessInterest = _settleInterestToPrincipal(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            loanLocal.borrower
        );

        if (loanCloseAmount > loanCloseAmountLessInterest) {
            // full interest refund goes to the borrower
            _withdrawAsset(
                loanParamsLocal.loanToken,
                loanLocal.borrower,
                loanCloseAmount - loanCloseAmountLessInterest
            );
        }

        if (loanCloseAmountLessInterest != 0) {
            // The lender always gets back an ERC20 (even wbase), so we call withdraw directly rather than
            // use the _withdrawAsset helper function
            vaultWithdraw(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                loanCloseAmountLessInterest
            );
        }



        if (excessSeizedAmount != 0) {
            loanLocal.collateral = loanLocal.collateral
                .sub(excessSeizedAmount);

            _withdrawAsset(
                seizedToken,
                loanLocal.borrower,
                excessSeizedAmount
            );

        }

        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        _emitClosingEvents(
            loanParamsLocal,
            loanLocal,
            loanCloseAmount,
            seizedAmount,
            excessSeizedAmount,  //collateralRepayingAmount
            collateralToLoanRate,
            0, // collateralToLoanSwapRate
            currentMargin,
            CloseTypes.Liquidation
        );
    }


    function _startArbitrage(
        bytes32 loanId,
        address loanToken,
        address collateralToken,
        uint256 loanCloseAmount,
        uint256 seizedAmount
    )
        private

        returns (
            uint256 profitAmount
        )
    {

        Loan storage loanLocal = loans[loanId];

        if (seizedAmount != 0) {
            loanLocal.collateral = loanLocal.collateral
                .sub(seizedAmount);

            uint256 loanAmountOut = _swapCollateralToLoan(
                collateralToken,
                loanToken,
                seizedAmount,
                loanCloseAmount
             );

            require(loanAmountOut > loanCloseAmount, "Slippage eats all profit : To fix transfer collateral to protocol contract");
            profitAmount = loanAmountOut - loanCloseAmount;
            IERC20(loanToken).transfer(msg.sender, profitAmount);

        }


    }


    function _swapCollateralToLoan(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutRequired
    )
        private
        returns (uint256 loanAmountOut)
    {

        address tokenPaired  = loanToTokenPair[tokenOut];
        require(tokenPaired != address(0), 'tokenPaired must be set');
        IUniswapV2Router02 FromCollateralRouter = IUniswapV2Router02(collateralPairToRouter[tokenOut]);
        require(address(FromCollateralRouter) != address(0), 'router must be set');

        if ( tokenIn == tokenPaired || tokenOut == tokenPaired ) {

            address[] memory pairedpath = new address[](2);
            pairedpath[0] = tokenIn;
            pairedpath[1] = tokenOut;

            loanAmountOut = FromCollateralRouter.swapExactTokensForTokens(
                amountIn, 
                amountOutRequired, 
                pairedpath, 
                address(this), 
                block.timestamp
            )[1];

        } else {

            address[] memory erc20path = new address[](2);
            erc20path[0] = tokenIn; 
            erc20path[1] = tokenPaired; //WBNB or BUSD

            uint256 pairAmountOut = FromCollateralRouter.swapExactTokensForTokens(
                amountIn, 
                0, 
                erc20path, 
                address(this), 
                block.timestamp
            )[1];

            erc20path[0] = tokenPaired; 
            erc20path[1] = tokenOut; 

            loanAmountOut= IUniswapV2Router02(pairLoanToRouter[tokenOut]).swapExactTokensForTokens(
                pairAmountOut, 
                amountOutRequired, 
                erc20path,
                address(this), 
                block.timestamp
            )[1];



        }

  }





    
    /**
     * @dev computes the interest which needs to be refunded to the borrower based on the amount he's closing and either
     * subtracts it from the amount which still needs to be paid back (in case outstanding amount > interest) or withdraws the
     * excess to the borrower (in case interest > outstanding).
     * @param loanLocal the loan
     * @param loanParamsLocal the loan params
     * @param loanCloseAmount the amount to be closed (base for the computation)
     * @param receiver the address of the receiver (usually the borrower)
     * */
    function _settleInterestToPrincipal(
        Loan memory loanLocal,
        LoanParams memory loanParamsLocal,
        uint256 loanCloseAmount,
        address receiver //Notice
    )
        internal
        returns (uint256)
    {
        uint256 loanCloseAmountLessInterest = loanCloseAmount;

        //compute the interest which neeeds to be refunded to the borrower (because full interest is paid on loan )
        uint256 interestRefundToBorrower = _settleInterest(
            loanParamsLocal,
            loanLocal,
            loanCloseAmountLessInterest
        );

        uint256 interestAppliedToPrincipal;
        //if the outstanding loan is bigger than the interest to be refunded, reduce the amount to be paid back / closed by the interest
        if (loanCloseAmountLessInterest >= interestRefundToBorrower) {
            // apply all of borrower interest refund torwards principal
            interestAppliedToPrincipal = interestRefundToBorrower;

            // principal needed is reduced by this amount
            loanCloseAmountLessInterest -= interestRefundToBorrower;

            // no interest refund remaining
            interestRefundToBorrower = 0;
        } else {//if the interest refund is bigger than the outstanding loan, the user needs to get back the interest
            // principal fully covered by excess interest
            interestAppliedToPrincipal = loanCloseAmountLessInterest;

            // amount refunded is reduced by this amount
            interestRefundToBorrower -= loanCloseAmountLessInterest;

            // principal fully covered by excess interest
            loanCloseAmountLessInterest = 0;

            if (interestRefundToBorrower != 0) {
                // refund overage
                _withdrawAsset(
                    loanParamsLocal.loanToken,
                    receiver,
                    interestRefundToBorrower
                );
            }
        }

        //pay the interest to the lender
        //note: this is a waste of gas, because the loanCloseAmountLessInterest is withdrawn to the lender, too. It could be done at once.
        if (interestAppliedToPrincipal != 0) {
            // The lender always gets back an ERC20 (even wbase), so we call withdraw directly rather than
            // use the _withdrawAsset helper function
            vaultWithdraw(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                interestAppliedToPrincipal
            );
        }

        return loanCloseAmountLessInterest;
    }

    // The receiver always gets back an ERC20 (even wbase)
    function _returnPrincipalWithCollateral(
        address loanToken,
        address receiver,
        uint256 principalNeeded)
        internal
    {
        if (principalNeeded != 0) {
            if (msg.value == 0) {
                vaultTransfer(
                    loanToken,
                    address(this),
                    receiver,
                    principalNeeded
                );
            } else {
                require(loanToken == address(wbaseToken), "wrong asset sent");
                require(msg.value >= principalNeeded, "not enough ether");
                wbaseToken.deposit.value(principalNeeded)();
                if (receiver != address(this)) {
                    vaultTransfer(
                        loanToken,
                        address(this),
                        receiver,
                        principalNeeded
                    );
                }
                if (msg.value > principalNeeded) {
                    // refund overage
                    Address.sendValue(
                        msg.sender,
                        msg.value - principalNeeded
                    );
                }
            }
        } else {
            require(msg.value == 0, "wrong asset sent");
        }
    }
    
    /**
     * @dev checks if the amount of the asset to be transfered is worth the transfer fee
     * @param asset the asset to be transfered
     * @param amount the amount to be transfered
     * @return True if the amount is bigger than the threshold
     * */
    function worthTheTransfer(address asset, uint256 amount) internal returns (bool){
        (uint256 rbtcRate, uint256 rbtcPrecision) = IPriceFeeds(priceFeeds).queryRate(asset, address(wbaseToken));
        uint256 amountInRbtc = amount.mul(rbtcRate).div(rbtcPrecision);
        emit swapExcess(amountInRbtc > paySwapExcessToBorrowerThreshold, amount, amountInRbtc, paySwapExcessToBorrowerThreshold);
        return amountInRbtc > paySwapExcessToBorrowerThreshold;
    }
    




    // withdraws asset to receiver
    function _withdrawAsset(
        address assetToken,
        address receiver, //Notice
        uint256 assetAmount)
        internal
    {
        if (assetAmount != 0) {
            if (assetToken == address(wbaseToken)) {
                vaultEtherWithdraw(
                    receiver,
                    assetAmount
                );
            } else {
                vaultWithdraw(
                    assetToken,
                    receiver,
                    assetAmount
                );
            }
        }
    }

    function _finalizeClose(
        Loan storage loanLocal,
        LoanParams storage loanParamsLocal,
        uint256 loanCloseAmount,
        uint256 collateralCloseAmount,
        uint256 collateralToLoanSwapRate,
        CloseTypes closeType)
        internal
    {
        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        address _priceFeeds = priceFeeds;
        uint256 currentMargin;
        uint256 collateralToLoanRate;

        // this is still called even with full loan close to return collateralToLoanRate
        (bool success, bytes memory data) = _priceFeeds.staticcall(
            abi.encodeWithSelector(
                IPriceFeeds(_priceFeeds).getCurrentMargin.selector,
                loanParamsLocal.loanToken,
                loanParamsLocal.collateralToken,
                loanLocal.principal,
                loanLocal.collateral
            )
        );
        assembly {
            if eq(success, 1) {
                currentMargin := mload(add(data, 32))
                collateralToLoanRate := mload(add(data, 64))
            }
        }
        //// Note: We can safely skip the margin check if closing via closeWithDeposit or if closing the loan in full by any method ////
        require(
            closeType == CloseTypes.Deposit ||
            loanLocal.principal == 0 || // loan fully closed
            currentMargin > loanParamsLocal.maintenanceMargin,
            "unhealthy position"
        );

        _emitClosingEvents(
            loanParamsLocal,
            loanLocal,
            loanCloseAmount,
            collateralCloseAmount,
            0,
            collateralToLoanRate,
            collateralToLoanSwapRate,
            currentMargin,
            closeType
        );
    }

    function _closeLoan(
        Loan storage loanLocal,
        uint256 loanCloseAmount)
        internal
        returns (uint256)
    {
        require(loanCloseAmount != 0, "nothing to close");

        if (loanCloseAmount == loanLocal.principal) {
            loanLocal.principal = 0;
            loanLocal.active = false;
            loanLocal.endTimestamp = block.timestamp;
            loanLocal.pendingTradesId = 0;
            activeLoansSet.removeBytes32(loanLocal.id);
            lenderLoanSets[loanLocal.lender].removeBytes32(loanLocal.id);
            borrowerLoanSets[loanLocal.borrower].removeBytes32(loanLocal.id);
        } else {
            loanLocal.principal = loanLocal.principal
                .sub(loanCloseAmount);
        }
    }

    function _settleInterest(
        LoanParams memory loanParamsLocal,
        Loan memory loanLocal,
        uint256 closePrincipal)
        internal
        returns (uint256)
    {
        // pay outstanding interest to lender
        _payInterest(
            loanLocal.lender,
            loanParamsLocal.loanToken
        );

        LoanInterest storage loanInterestLocal = loanInterest[loanLocal.id];
        LenderInterest storage lenderInterestLocal = lenderInterest[loanLocal.lender][loanParamsLocal.loanToken];

        uint256 interestTime = block.timestamp;
        if (interestTime > loanLocal.endTimestamp) {
            interestTime = loanLocal.endTimestamp;
        }

        _settleFeeRewardForInterestExpense(
            loanInterestLocal,
            loanLocal.id,
            loanParamsLocal.loanToken,
            loanLocal.borrower,
            interestTime
        );

        uint256 owedPerDayRefund;
        if (closePrincipal < loanLocal.principal) {
            owedPerDayRefund = loanInterestLocal.owedPerDay
                .mul(closePrincipal)
                .div(loanLocal.principal);
        } else {
            owedPerDayRefund = loanInterestLocal.owedPerDay;
        }

        // update stored owedPerDay
        loanInterestLocal.owedPerDay = loanInterestLocal.owedPerDay
            .sub(owedPerDayRefund);
        lenderInterestLocal.owedPerDay = lenderInterestLocal.owedPerDay
            .sub(owedPerDayRefund);

        // update borrower interest
        uint256 interestRefundToBorrower = loanLocal.endTimestamp
            .sub(interestTime);
        interestRefundToBorrower = interestRefundToBorrower
            .mul(owedPerDayRefund);
        interestRefundToBorrower = interestRefundToBorrower
            .div(1 days);

        if (closePrincipal < loanLocal.principal) {
            loanInterestLocal.depositTotal = loanInterestLocal.depositTotal
                .sub(interestRefundToBorrower);
        } else {
            loanInterestLocal.depositTotal = 0;
        }

        // update remaining lender interest values
        lenderInterestLocal.principalTotal = lenderInterestLocal.principalTotal
            .sub(closePrincipal);

        uint256 owedTotal = lenderInterestLocal.owedTotal;
        lenderInterestLocal.owedTotal = owedTotal > interestRefundToBorrower ?
            owedTotal - interestRefundToBorrower :
            0;

        return interestRefundToBorrower;
    }

    function _emitClosingEvents(
        LoanParams memory loanParamsLocal,
        Loan memory loanLocal,
        uint256 loanCloseAmount,
        uint256 collateralCloseAmount,
        uint256 collateralRepayingAmount,
        uint256 collateralToLoanRate,
        uint256 collateralToLoanSwapRate,
        uint256 currentMargin,
        CloseTypes closeType)
        internal
    {
        if (closeType == CloseTypes.Deposit) {
            emit CloseWithDeposit(
                loanLocal.borrower,                             // user (borrower)
                loanLocal.lender,                               // lender
                loanLocal.id,                                   // loanId
                msg.sender,                                     // closer
                loanParamsLocal.loanToken,                      // loanToken
                loanParamsLocal.collateralToken,                // collateralToken
                loanCloseAmount,                                // loanCloseAmount
                collateralCloseAmount,                          // collateralCloseAmount
                collateralToLoanRate,                           // collateralToLoanRate
                currentMargin                                   // currentMargin
            );
        }  else { // closeType == CloseTypes.Liquidation
            emit Liquidate(
                loanLocal.borrower,                             // user (borrower)
                msg.sender,                                     // liquidator
                loanLocal.id,                                   // loanId
                loanLocal.lender,                               // lender
                loanParamsLocal.loanToken,                      // loanToken
                loanParamsLocal.collateralToken,                // collateralToken
                loanCloseAmount,                                // loanCloseAmount
                collateralCloseAmount,                          // collateralCloseAmount
                collateralRepayingAmount,                       // collateralRepayingAmount
                collateralToLoanRate,                           // collateralToLoanRate
                currentMargin                                   // currentMargin
            );
        }
    }
}