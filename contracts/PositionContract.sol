pragma solidity ^0.5.2;
import {CErc20, CToken, ComptrollerInterface} from "./CErc20.sol";
import {CEther} from "./CEther.sol";
import {UniswapExchangeInterface} from "./uniswap.sol";
import {ERC20Interface} from "./ERC20.sol";
import {Comptroller} from "./Comptroller.sol";

contract PositionContract {

    // The user's address
    address public ownerAddress;
    string public tradeType;
    string public asset;

    ERC20Interface token;
    CErc20 cToken;
    UniswapExchangeInterface tokenExchange;

    ERC20Interface collateral;
    UniswapExchangeInterface collateralExchange;
    CErc20 cCollateral;

    uint256 public positionSize;

    uint256 private tokenBalance;
    uint256 private borrowBalance;
    uint256 private supplyBalance;
    uint256 private collateralToSupply;

    address private factoryAddress;

    constructor (address owneraddr,
        string memory _asset,
        address _collateralAddr,
        address _cCollateralAddr,
        address _collateralExchangeAddr,
        address _tokenAddr,
        address _cTokenAddr,
        address _tokenExchangeAddr,
        string memory _tradeType) public{
        // Ensures that the factory contract is the only one instantiating new shortContracts
        factoryAddress = msg.sender;
        ownerAddress = owneraddr;
        // "s" for short, "l" for leverage
        tradeType = _tradeType;
        asset = _asset;
        tokenBalance = 0;
        positionSize = 0;

        collateralExchange = UniswapExchangeInterface(_collateralExchangeAddr);
        cCollateral = CErc20(_cCollateralAddr);
        collateral = ERC20Interface(_collateralAddr);
        token = ERC20Interface(_tokenAddr);
        cToken = CErc20(_cTokenAddr);
        tokenExchange = UniswapExchangeInterface(_tokenExchangeAddr);
    }

    // This function transfers in the collateral
    function transferInCollateral(uint256 collateralAmt) private {
        require(msg.sender == ownerAddress);
        require(collateralAmt > 0);

        // TODO: ensure that approve happens in javascript before this is even called
        collateral.transferFrom(msg.sender, address(this), collateralAmt);
    }

    // This function mints a new compound cCollateral token
    function mintCollateral(uint256 amt) private {
        require(amt > 0);
        collateral.approve(address(cCollateral), amt); // approve the transfer
        assert(cCollateral.mint(amt) == 0); // mint the cTokens and assert there is no error
    }

    // This function borrows the token being shorted from compound
    function borrowToken(uint256 amt) private {
        require(amt > 0);
        //TODO: remeber to change comptroller address for mainnet
        Comptroller troll = Comptroller(0x2EAa9D77AE4D8f9cdD9FAAcd44016E746485bddb);
        address[] memory ct = new address[](2);
        ct[0] = address(cToken);
        ct[1] = address(cCollateral);
        uint[] memory errors = troll.enterMarkets(ct);
        require(errors[0] == 0);
        require(errors[1] == 0);
        uint error = cToken.borrow(amt);
        assert(error == 0);
    }


    // This function exchanges the token borrowed from compound for more collateral tokens on uniswap
    function swapTokenToCollateral(uint256 amt) private {
        require(amt > 0);

        token.approve(address(tokenExchange), 1000000000000000000000000000000000000000);
        tokenExchange.tokenToTokenTransferInput(amt, 1, 1, 16517531290, ownerAddress, address(collateral));
    }

    // This function opens a new short position of token against collateral
    function openPosition (uint256 collateralAmt, uint256 borrowAmt, string memory _tradeType) public {
        require(msg.sender == ownerAddress);
        determineTradeType(_tradeType);
        transferInCollateral(collateralAmt);
        mintCollateral(collateralAmt);
        borrowToken(borrowAmt);
        swapTokenToCollateral(borrowAmt);
        if (keccak256(abi.encodePacked(_tradeType)) == keccak256(abi.encodePacked("s"))) {
            positionSize += borrowAmt;
        } else {
            positionSize += collateralAmt;
        }
    }

    // This function checks if the trade type made matches the trade type of the contract. If it doesn't, it tries to swap it.
    // You should only be able to swap it, if you have no open Positions.
    function determineTradeType(string memory _tradeType) private {
        // Ensure this is an 'l' or an 's'
        if (keccak256(abi.encodePacked(_tradeType)) != keccak256(abi.encodePacked(tradeType))) {
            calcBorrowBal();
            // TODO: test this. borrowBalance shoud be negligible.
            require(positionSize == 0);
            tradeType = _tradeType;

            UniswapExchangeInterface ex = collateralExchange;
            collateralExchange = tokenExchange;
            tokenExchange = ex;

            CErc20 ct = cCollateral;
            cCollateral = cToken;
            cToken = ct;

            ERC20Interface t = collateral;
            collateral = token;
            token = t;
        }
    }

    // This functiom calculates the borrow balance of the token (including interest) from compound
    function calcBorrowBal() private returns (uint256) {
        borrowBalance = cToken.borrowBalanceCurrent(address(this));
        return borrowBalance;
    }

    // This functiom calculates the supplyBalance balance of the collateral (including interest) from compound
    function calcSupplyBal() private returns (uint256){
        supplyBalance = cCollateral.balanceOf(address(this)) * cCollateral.exchangeRateCurrent() / (10**18);
        return supplyBalance;
    }

    function getBorrowBalance() public view returns (uint256) {
        return cToken.borrowBalanceStored(address(this));
    }

    function getAccountLiquidity() public view returns (uint, uint, uint) {
        Comptroller troll = Comptroller(0x2EAa9D77AE4D8f9cdD9FAAcd44016E746485bddb);
        return troll.getAccountLiquidity(address(this));
    }

    function swapCollateralToToken(uint256 collateralAmt) public returns (uint256){
        require(msg.sender == ownerAddress);
        require(collateralAmt > 0);

        collateral.approve(address(collateralExchange), 1000000000000000000000000000000000000000);
        tokenBalance = collateralExchange.tokenToTokenSwapInput(collateralAmt, 1, 1, 16517531290, address(token));
        return tokenBalance;
    }

    // This function repays the borrowed token to compound
    function repayBorrowToken(int256 borrowAmt) public {
        token.approve(address(cToken), 1000000000000000000000000000000000000000);
        require(cToken.repayBorrow(uint(borrowAmt)) == 0);
    }

    // This function gets back the supplied collateral from compound
    function redeemCollateral(uint256 collateralAmt) public {
        // err1 = cCollateral.redeem(collateralAmt);
        require(cCollateral.redeem(collateralAmt) == 0);
    }

    function getSupplyBalance() public view returns (uint256) {
        return cCollateral.balanceOf(address(this));
    }


    // This function sends the remaining collateral back to the user
    function TransferCollateralOut () public {
        uint256 collateralAmt = collateral.balanceOf(address(this));
        collateral.approve(ownerAddress, collateralAmt);
        collateral.transfer(ownerAddress, collateralAmt);
    }

    // This function sends the remaining intermediate tokens as fees to the factory contract
    function transferRemaining () public {
        // uint256 collateralBal = collateral.balanceOf(address(this));
        uint256 tokenBal = token.balanceOf(address(this));
        // collateral.approve(factoryAddress, collateralBal);
        // collateral.transfer(factoryAddress, collateralBal);
        token.approve(factoryAddress, tokenBal);
        token.transfer(factoryAddress, tokenBal);
    }

    // This function calls uniswap to get the prices
    function getCollateralToSupply(uint256 repayAmt) public view returns (uint256){
        uint256 bBal = getBorrowBalance();
        uint256 colToSupply = 0;
        if (bBal > 0 && repayAmt <= bBal) {
            uint256 ethToSupply = tokenExchange.getEthToTokenOutputPrice(repayAmt);
            colToSupply = collateralExchange.getTokenToEthOutputPrice(ethToSupply);
        }
        return colToSupply;
    }
    // The calculations for the values happen in JS
    // This function closes some part of the position.
    function closePosition2(uint256 collateralAmt, uint128 repayAmt, uint256 withdrawAmt, uint256 amtClosed) public {
        require(msg.sender == ownerAddress);
        calcBorrowBal();
        if (borrowBalance > 0) {
            transferInCollateral(collateralAmt);
            tokenBalance = swapCollateralToToken(collateralAmt);
            if (positionSize == amtClosed) {
                require(tokenBalance >= borrowBalance);
                repayBorrowToken(-1);
                calcSupplyBal();
                redeemCollateral(withdrawAmt);
                TransferCollateralOut();
                transferRemaining ();
                positionSize -= amtClosed;
            } else {
                require(repayAmt > 0);
                require(tokenBalance >= repayAmt);
                repayBorrowToken(int256(repayAmt));
                calcSupplyBal();
                redeemCollateral(withdrawAmt);
                TransferCollateralOut();
                transferRemaining ();
                require(amtClosed <= positionSize);
                positionSize -= amtClosed;
            }
        }
    }

    // This function lets the user top up collateral.
    function addCollateral(uint256 collateralAmt) public {
        require(msg.sender == ownerAddress);
        transferInCollateral(collateralAmt);
        mintCollateral(collateralAmt);
    }
}