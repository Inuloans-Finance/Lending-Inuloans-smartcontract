pragma solidity 0.5.17;

import "../../core/State.sol";
import "../../feeds/IPriceFeeds.sol";
import "../../openzeppelin/v2/token/ERC20/SafeERC20.sol";
import "../ISwapsImpl.sol";
import "./interfaces/IThaiFiSwapNetwork.sol";
import "./interfaces/IContractRegistry.sol";


contract SwapsImplThaiFiSwap is State, ISwapsImpl {
    using SafeERC20 for IERC20;

    // bytes32 contractName = hex"42616e636f724e6574776f726b"; // "ThaiFiSwapNetwork"

    function getContractHexName(string memory source) public pure returns (bytes32 result) {
        assembly {
            result := mload(add(source, 32))
        }
    }
    
    /**
     * looks up the thaifi swap network contract registered at the given address
     * @param thaifiSwapRegistryAddress the address of the registry
     * */
    function getThaiFiSwapNetworkContract(address thaifiSwapRegistryAddress) public view returns(IThaiFiSwapNetwork){
        // state variable thaifiSwapContractRegistryAddress is part of State.sol and set in ProtocolSettings.sol
        //and this function needs to work without delegate call as well -> therefore pass it
        IContractRegistry contractRegistry = IContractRegistry(thaifiSwapRegistryAddress);
        return IThaiFiSwapNetwork(contractRegistry.addressOf(getContractHexName("ThaiFiSwapNetwork")));
    }

    /**
     * swaps the source token for the destination token on the oracle based amm.
     * on loan opening: minSourceTokenAmount = maxSourceTokenAmount and requiredDestTokenAmount = 0
     *      -> swap the minSourceTokenAmount
     * on loan rollover: (swap interest) minSourceTokenAmount = 0, maxSourceTokenAmount = complete collateral and requiredDestTokenAmount > 0
     *      -> amount of required source tokens to swap is estimated (want to fill requiredDestTokenAmount, not more). maxSourceTokenAMount is not exceeded.
     * on loan closure: minSourceTokenAmount <= maxSourceTokenAmount and requiredDestTokenAmount >= 0
     *      -> same as on rollover. minimum amount is not considered at all.
     * @param sourceTokenAddress the address of the source tokens
     * @param destTokenAddress the address of the destination tokens
     * @param receiverAddress the address to receive the swapped tokens
     * @param returnToSenderAddress the address to return unspent tokens to (when called by the protocol, it's always the protocol contract)
     * @param minSourceTokenAmount the minimum amount of source tokens to swapped (only considered if requiredDestTokens == 0)
     * @param maxSourceTokenAmount the maximum amount of source tokens to swapped
     * @param requiredDestTokenAmount the required amount of destination tokens
     * **/

    function internalSwap(
        address sourceTokenAddress,
        address destTokenAddress,
        address receiverAddress,
        address returnToSenderAddress,
        uint256 minSourceTokenAmount,
        uint256 maxSourceTokenAmount,
        uint256 requiredDestTokenAmount)
        public
        returns (uint256 destTokenAmountReceived, uint256 sourceTokenAmountUsed)
    {
        require(sourceTokenAddress != destTokenAddress, "source == dest");
        require(supportedTokens[sourceTokenAddress] && supportedTokens[destTokenAddress], "invalid tokens");

        IThaiFiSwapNetwork thaifiSwapNetwork = getThaiFiSwapNetworkContract(thaifiSwapContractRegistryAddress);
        IERC20[] memory path = thaifiSwapNetwork.conversionPath(
            IERC20(sourceTokenAddress),
            IERC20(destTokenAddress)
        );
        
        uint minReturn = 0;
        sourceTokenAmountUsed = minSourceTokenAmount;

        //if the required amount of destination tokens is passed, we need to calculate the estimated amount of source tokens
        //regardless of the minimum source token amount (name is misleading)
        if(requiredDestTokenAmount > 0){
            sourceTokenAmountUsed = estimateSourceTokenAmount(sourceTokenAddress, destTokenAddress, requiredDestTokenAmount,  maxSourceTokenAmount);
             //thaifiSwapNetwork.rateByPath does not return a rate, but instead the amount of destination tokens returned
            require(thaifiSwapNetwork.rateByPath(path, sourceTokenAmountUsed) >= requiredDestTokenAmount, "insufficient source tokens provided.");
            minReturn = requiredDestTokenAmount;
        }
        else if (sourceTokenAmountUsed > 0){
            //for some reason the thaifi swap network tends to return a bit less than the expected rate.
            minReturn = thaifiSwapNetwork.rateByPath(path, sourceTokenAmountUsed).mul(995).div(1000);
        }
        
        require(sourceTokenAmountUsed > 0, "cannot swap 0 tokens");
        
        allowTransfer(sourceTokenAmountUsed, sourceTokenAddress, address(thaifiSwapNetwork));

        //note: the kyber connector uses .call() to interact with kyber to avoid bubbling up. here we allow bubbling up.
        destTokenAmountReceived = thaifiSwapNetwork.convertByPath(path, sourceTokenAmountUsed, minReturn, address(0), address(0), 0);
        
        //if the sender is not the protocol (calling with delegatecall), return the remainder to the specified address.
        //note: for the case that the swap is used without the protocol. not sure if it should, though. needs to be discussed.
        if (returnToSenderAddress != address(this)) {
            if (sourceTokenAmountUsed < maxSourceTokenAmount) {
                // send unused source token back
                IERC20(sourceTokenAddress).safeTransfer(
                    returnToSenderAddress,
                    maxSourceTokenAmount-sourceTokenAmountUsed
                );
            }
        }

    }
    
    /**
     * check is the existing allowance suffices to transfer the needed amount of tokens.
     * if not, allows the transfer of an arbitrary amount of tokens.
     * @param tokenAmount the amount to transfer
     * @param tokenAddress the address of the token to transfer
     * @param thaifiSwapNetwork the address of the thaifiSwap network contract.
     * */
    function allowTransfer(
        uint256 tokenAmount,
        address tokenAddress,
        address thaifiSwapNetwork)
        internal
    {
        uint256 tempAllowance = IERC20(tokenAddress).allowance(address(this), thaifiSwapNetwork);
        if (tempAllowance < tokenAmount) {
            IERC20(tokenAddress).safeApprove(
                thaifiSwapNetwork,
                uint256(-1)
            );
        }
    }

    /**
     * calculates the number of source tokens to provide in order to obtain the required destination amount.
     * @param sourceTokenAddress the address of the source token address
     * @param destTokenAddress the address of the destination token address
     * @param requiredDestTokenAmount the number of destination tokens needed
     * @param maxSourceTokenAmount the maximum number of source tokens to spend
     * @return the estimated amount of source tokens needed. minimum: minSourceTokenAmount, maximum: maxSourceTokenAmount
     * */
    function estimateSourceTokenAmount(
        address sourceTokenAddress,
        address destTokenAddress,
        uint requiredDestTokenAmount,
        uint maxSourceTokenAmount)
        internal
        view
        returns(uint256 estimatedSourceAmount)
    {

        uint256 sourceToDestPrecision = IPriceFeeds(priceFeeds).queryPrecision(sourceTokenAddress, destTokenAddress);
        if (sourceToDestPrecision == 0)
            return maxSourceTokenAmount;
        
        //compute the expected rate for the maxSourceTokenAmount -> if spending less, we can't get a worse rate.
        uint256 expectedRate = internalExpectedRate(sourceTokenAddress, destTokenAddress, maxSourceTokenAmount,thaifiSwapContractRegistryAddress);

        //compute the source tokens needed to get the required amount with the worst case rate
        estimatedSourceAmount = requiredDestTokenAmount
            .mul(sourceToDestPrecision)
            .div(expectedRate);
            
        //if the actual rate is exactly the same as the worst case rate, we get rounding issues. So, add a small buffer.
        //buffer = min(estimatedSourceAmount/1000 , sourceBuffer) with sourceBuffer = 10000
        uint256 buffer = estimatedSourceAmount.div(1000);
        if(buffer > sourceBuffer)
            buffer = sourceBuffer;
        estimatedSourceAmount = estimatedSourceAmount.add(buffer);


        //never spend more than the maximum
        if (estimatedSourceAmount == 0 || estimatedSourceAmount > maxSourceTokenAmount)
            return maxSourceTokenAmount;

    }

    /**
     * returns the expected rate for 1 source token when exchanging the given amount of source tokens
     * @param sourceTokenAddress the address of the source token contract
     * @param destTokenAddress the address of the destination token contract
     * @param sourceTokenAmount the amount of source tokens to get the rate for
     * */
    function internalExpectedRate(
        address sourceTokenAddress,
        address destTokenAddress,
        uint256 sourceTokenAmount,
        address thaifiSwapContractRegistryAddress)
        public
        view
        returns (uint256)
    {
        IThaiFiSwapNetwork thaifiSwapNetwork = getThaiFiSwapNetworkContract(thaifiSwapContractRegistryAddress);
        IERC20[] memory path = thaifiSwapNetwork.conversionPath(
            IERC20(sourceTokenAddress),
            IERC20(destTokenAddress)
        );
        //is returning the total amount of destination tokens
        uint256 expectedReturn = thaifiSwapNetwork.rateByPath(path, sourceTokenAmount);

        //return the rate for 1 token with 18 decimals
        return expectedReturn.mul(10**18).div(sourceTokenAmount);
    }
}
