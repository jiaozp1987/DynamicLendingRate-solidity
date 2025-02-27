// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {console} from "forge-std/console.sol";
import "./Domain/Domain.sol";
contract DynamicLendingRate is ReentrancyGuard{
    address private owner;
    address public immutable baseERC20;  // 基准ERC20(如USDT)
    uint8 private immutable baseRate; // 基础利率
    mapping(bytes32 => Domain.ReceiptDomain) private receipts;  //借贷票据
    bytes32[] private receiptIDs;
    mapping(address => Domain.TokenDomain) private tokens; // 可贷款和抵押的ERC20
    mapping(bytes32 => Domain.LiquidProvideDomain) private liquidProvide;  //存款票据

    // 事件
    event EventLoanCreated(bytes32 indexed receiptID, address indexed lender, Domain.ReceiptDomain receipt);
    event EventLoanPayed(bytes32 indexed receiptID, address indexed lender, Domain.ReceiptDomain receipt);
    event EventTokenCreated(address indexed erc20, uint price);

    constructor(address baseERC20_, uint8 baseRate_) {
        baseERC20 = baseERC20_;
        baseRate = baseRate_;
        owner = msg.sender;
    }

    modifier onlyOwner(){
        require(msg.sender == owner);
        _;
    }
    
    modifier isERC20EXIST(address erc20_,bool shouldExist){
        Domain.TokenDomain memory token = tokens[erc20_];
        if(!shouldExist){
            require(token.reserve == 0 && token.price == 0 && !token.isLoan && !token.isDeposit,"ERC20 EXIST");
        }else{
            require(!(token.reserve == 0 && token.price == 0 && !token.isLoan && !token.isDeposit),"ERC20 NOT EXIST" );
        }
        delete token;
        _;
    }

    receive() external payable { }
    fallback() external payable { }


    // 获取 ERC20 token 的价格和可借贷量 
    function getTokensInfo(address erc20_) public view isERC20EXIST(erc20_,true) returns(Domain.TokenDomain memory token, bool reponse){
        token = tokens[erc20_];
        reponse = true;
    }

    

    // 设置可借贷的 ERC20 token
    function _createTokens(address erc20_, uint price_,bool isLoan_, bool isDeposit_,uint reserve_,uint lended_) 
    private 
    pure 
    returns(Domain.TokenDomain memory) {
        Domain.TokenDomain memory _token = Domain.TokenDomain({
            erc20:erc20_,
            isLoan:isLoan_,
            isDeposit:isDeposit_,
            price:price_,
            reserve:reserve_,
            lended:lended_
        });
        return _token;
    }


    function _updateTokens(Domain.TokenDomain memory token_) private {
        tokens[token_.erc20] = token_;
    }
    // 添加可借贷token
    function addTokens(address erc20_, uint price_) public onlyOwner isERC20EXIST(erc20_,false) returns(bool reponse){
        require(price_ >0,"PRICE < 0"); 
        _updateTokens(_createTokens(erc20_,price_,true,true,0,0));
        emit EventTokenCreated(erc20_,price_);
        reponse = true;
    }
    
    // 更新token
    function setTokens(address erc20_, uint price_,bool isLoan_, bool isDeposit_,uint reserve_,uint lended_) public onlyOwner isERC20EXIST(erc20_,true) returns(bool reponse){
        _updateTokens(_createTokens(erc20_,price_,isLoan_,isDeposit_,reserve_,lended_));
        require(liquidateLoan());
        reponse = true;
    }

    // 获取贷款利率
    function getLoanRate(address erc20_) public view isERC20EXIST(erc20_,true) returns(uint8) {
        (Domain.TokenDomain memory _token,bool r0) = getTokensInfo(erc20_);
        require(_token.isLoan && r0,"LENDING DISABLE");
        uint8 _rate = baseRate + uint8(baseRate*_token.lended*100/(_token.lended + _token.reserve)/100+1);  //基础利率+浮动利率  每天支付的利息token
        return _rate;
    }

    function getDepositRate() public view returns(uint8) {
        return baseRate;
    }

    function _createReceipt(
        bytes32 id_,
        bool isActive_,
        uint8 rate_,
        address lender_,
        address collateralERC20_,  
        uint collateralAmount_, 
        address loanERC20_,  
        uint loanAmount_,  
        uint32 deadline_
    ) private view returns(Domain.ReceiptDomain memory){
        if(id_ == bytes32(0)){  // 新增
            id_ = keccak256(abi.encode(
                block.timestamp,
                isActive_,
                rate_,
                lender_,
                collateralERC20_,
                collateralAmount_, 
                loanERC20_, 
                loanAmount_,
                deadline_
            ));
        }
        Domain.ReceiptDomain memory _token = Domain.ReceiptDomain({
            id: id_,
            isActive: isActive_,
            rate: rate_,
            lender: lender_,
            collateralERC20: collateralERC20_,
            collateralAmount: collateralAmount_,
            loanERC20:loanERC20_,
            loanAmount:loanAmount_,
            deadline: deadline_,
            startline: uint32(block.timestamp)
        });
        return _token;
    }

    function _updateLoan(Domain.ReceiptDomain memory receipt_) private returns(Domain.ReceiptDomain memory){
        receipts[receipt_.id] = receipt_;
        receiptIDs.push(receipt_.id);
        return receipt_;
    }

    function _addLoan(
        address collateralERC20_,
        uint collateralAmount_,
        address loanERC20_,
        uint loanAmount_,
        uint32 duration_
    ) private returns(Domain.ReceiptDomain memory){
        IERC20(collateralERC20_).transferFrom(msg.sender,address(this),collateralAmount_);
        IERC20(loanERC20_).transfer(msg.sender,loanAmount_);
        Domain.ReceiptDomain memory _receipt = _createReceipt(
            bytes32(0),
            true,
            getLoanRate(loanERC20_),
            msg.sender,
            collateralERC20_,
            collateralAmount_,
            loanERC20_,
            loanAmount_,
            uint32(block.timestamp) + duration_
        );
        return _updateLoan(_receipt);
    }

    function  checkLoanParam(address loanERC20_, address collateralERC20_,uint collateralAmount_,uint loanAmount_) private view returns(Domain.TokenDomain memory,Domain.TokenDomain memory){
        (Domain.TokenDomain memory _tokenOut, bool r0) = getTokensInfo(loanERC20_);
        require(_tokenOut.isLoan,"TOKEN NOT TO LOAN");
        (Domain.TokenDomain memory _tokenIn, bool r1) = getTokensInfo(collateralERC20_);
        require(r0 && r1);
        uint _loanRealAmount = _tokenIn.price*collateralAmount_/_tokenOut.price*80/100;  // 理论可借出量
        require(_loanRealAmount>=loanAmount_,"NOT AFFORD LEAST LOAN AMOUNT");
        require(_loanRealAmount<=_tokenOut.reserve,"NOT ENOUGH RESERVE");
        return (_tokenOut,_tokenIn);
    }

    // 贷款
    function loan(
        address collateralERC20_,
        uint collateralAmount_,
        address loanERC20_,
        uint loanAmount_,
        uint32 duration_
    ) external isERC20EXIST(collateralERC20_,true) isERC20EXIST(loanERC20_,true) nonReentrant returns(bytes32 id ,bool reponse){
        (Domain.TokenDomain memory _tokenOut, ) = checkLoanParam(loanERC20_,collateralERC20_,collateralAmount_,loanAmount_);
        // 记录贷款信息
        Domain.ReceiptDomain memory _receipt = _addLoan(collateralERC20_,collateralAmount_,loanERC20_,loanAmount_,duration_);
        _tokenOut.reserve = _tokenOut.reserve - loanAmount_;
        _tokenOut.lended = _tokenOut.lended + loanAmount_;
        // 更新token信息
        _updateTokens(_tokenOut);
        emit EventLoanCreated(_receipt.id, _receipt.lender,_receipt);
        id = _receipt.id;
        receiptIDs.push(id);
        console.log("receiptIDs.length=",receiptIDs.length);
        reponse = true;
    }
    // 还贷
    function repayLoan(bytes32 receiptID_) external  nonReentrant  returns(bool reponse){
        Domain.ReceiptDomain memory _receipt = receipts[receiptID_];
        require(_receipt.isActive,"UNACTIVE");
        require(block.timestamp<_receipt.deadline,"TIME OUT");
        uint _paybackAmount =  _receipt.loanAmount + _receipt.rate*(1+(block.timestamp-_receipt.startline)/1 days);
        console.log("_paybackAmount=",_paybackAmount);
        IERC20(_receipt.loanERC20).transferFrom(msg.sender,address(this),_paybackAmount);
        _receipt.isActive = false;
        _updateLoan(_receipt);
        IERC20(_receipt.collateralERC20).transfer(msg.sender,_receipt.collateralAmount);
        uint idsLength = receiptIDs.length;
        for(uint i = 0; i< idsLength; i++ ){
            if(receiptIDs[i] == _receipt.id){
                receiptIDs[i] = receiptIDs[idsLength-1];
                receiptIDs.pop();
                break;
            }
        }
        emit EventLoanPayed(_receipt.id, _receipt.lender, _receipt);
        reponse = true;
    }

    // 清算
    function liquidateLoan() public onlyOwner returns(bool reponse){
        uint i = 0;
        uint countReceipt = receiptIDs.length;
        console.log("countReceipt=",countReceipt);
        for(uint j = 0;j < countReceipt; j++){
            bool outOfPrice;
            Domain.ReceiptDomain memory _receipt = receipts[receiptIDs[i]];
            console.log("1");
            (Domain.TokenDomain memory loanToken,bool r0) = getTokensInfo(_receipt.loanERC20);
            require(r0);
            console.log("2");
            (Domain.TokenDomain memory collateralToken,bool r1) = getTokensInfo(_receipt.collateralERC20);
            require(r1);
            console.log("3");
            outOfPrice = _receipt.loanAmount * loanToken.price  > _receipt.collateralAmount * collateralToken.price * 80 /100;
            if(!_receipt.isActive || block.timestamp > _receipt.deadline || outOfPrice) {
                receipts[receiptIDs[i]].isActive = false;
                loanToken.lended = loanToken.lended - _receipt.loanAmount;  // 更新抵押ERC20的可借贷量 收不回来的就从借出总量里删除
                collateralToken.reserve = collateralToken.reserve + _receipt.collateralAmount; // 把抵押的划归到可借出量里
                _updateTokens(loanToken);
                _updateTokens(collateralToken);
                receiptIDs[i] = receiptIDs[receiptIDs.length-1];
                receiptIDs.pop();
            }
            if(i+1 >= receiptIDs.length){
                break;
            }
            i += 1;
        }
        reponse = true;
    }

    function _provideLiquid(Domain.LiquidProvideDomain memory liquidProvide_,Domain.TokenDomain memory token_) private returns (bool response){
        _updateTokens(token_);
        liquidProvide[liquidProvide_.id] = liquidProvide_;
        response =  true;
    }

    function provideLiquid(address erc20_,uint amount_,uint32 duration_)external isERC20EXIST(erc20_,true) nonReentrant returns (bytes32 id ,bool response) {
        require(amount_ > 0 && duration_>1 days,"PARAMS INVALID");
        (Domain.TokenDomain memory _token, bool _reponse) = getTokensInfo(erc20_);
        require(_reponse);
        require(_token.isLoan && _token.isDeposit,"TOKEN UNACTIVE");
        IERC20(erc20_).transferFrom(msg.sender,address(this),amount_);
        bytes32 _id = keccak256(abi.encode(
                block.timestamp,
                erc20_,
                amount_,
                duration_
        ));
        Domain.LiquidProvideDomain memory _lp = Domain.LiquidProvideDomain({
            id : _id,
            isActive: true,
            provider: msg.sender,
            erc20 : erc20_,
            amount : amount_,
            startline : uint32(block.timestamp),
            deadline : uint32(block.timestamp) + duration_
        });
        
        _token.reserve = _token.reserve + amount_;
        require(_provideLiquid(_lp,_token));
        id = _id;
        response =  true;
    }

    // 取款
    function withdraw(bytes32 id_ ) external  nonReentrant returns(bool response){
        Domain.LiquidProvideDomain memory _lp = liquidProvide[id_];
        require(_lp.isActive,"UNACTIVE LiquidProvide");
        require(block.timestamp > _lp.deadline, "LiquidProvide UNFINISHED");
        uint _payback = _lp.amount + baseRate*(_lp.deadline-_lp.startline)/1 days;
        (Domain.TokenDomain memory _token, bool _reponse) = getTokensInfo(_lp.erc20);
        require(_reponse);
        require(_token.reserve > _payback,"NOT ENOUGH BALANCE");
        _token.reserve = _token.reserve - _payback;
        _updateTokens(_token);
        _lp.isActive = false;
        liquidProvide[_lp.id] = _lp;
        IERC20(_lp.erc20).transfer(msg.sender,_payback);
        response = true;
    }
}