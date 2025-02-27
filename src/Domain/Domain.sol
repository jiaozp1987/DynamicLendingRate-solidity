// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;


library Domain{
    struct ReceiptDomain{
        bytes32 id;
        bool isActive;
        uint8 rate;  //利率
        address lender;  //借款人地址
        address collateralERC20; //抵押物ERC20
        uint collateralAmount; //抵押数量
        address loanERC20; //借出物ERC20
        uint loanAmount; // 最低借出物数量/实际借出物数量 
        uint32 deadline; //截至日期
        uint32 startline; // 开始时间
    }

    struct TokenDomain{
        address erc20; 
        bool isLoan;  // 可借出
        bool isDeposit; // 可存入
        uint price; // 价格  1erc20 = ?基准erc20
        uint reserve; // 存量
        uint lended; // 借出总量
    }

    struct LiquidProvideDomain{
        bytes32 id;
        bool isActive;
        address provider;  //提供人地址
        address erc20; 
        uint amount; 
        uint32 startline; // 开始时间
        uint32 deadline; //截至日期
    }
}