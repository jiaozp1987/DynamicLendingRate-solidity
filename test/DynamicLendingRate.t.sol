// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/DynamicLendingRate.sol";
import "../src/Domain/Domain.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }
}

contract DynamicLendingRateTest is Test {
    DynamicLendingRate dynamicLendingRate;
    MockERC20 usdt;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        vm.startPrank(owner);
        console.log("Deploying MockERC20 contracts...");
        usdt = new MockERC20("USDT", "USDT");
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
        tokenC = new MockERC20("tokenC", "TKC");


        console.log("Deploying DynamicLendingRate contract...");
        dynamicLendingRate = new DynamicLendingRate(address(usdt), 5); // 基础利率为 5%
        tokenA.mint(address(dynamicLendingRate),UINT256_MAX/2);
        tokenB.mint(address(dynamicLendingRate),UINT256_MAX/2);
        tokenC.mint(address(dynamicLendingRate),UINT256_MAX/2);
        vm.stopPrank();

        console.log("Adding tokens to DynamicLendingRate...");
        vm.startPrank(owner); // 确保以 owner 身份调用
        require(dynamicLendingRate.addTokens(address(tokenA), 1 ), "Failed to add TokenA");
        require(dynamicLendingRate.addTokens(address(tokenB), 2 ), "Failed to add TokenB");
        vm.stopPrank();

        console.log("Minting tokens to users...");
        usdt.mint(user1, 1000 );
        usdt.mint(user2, 1000 );
        tokenA.mint(user1, 1000 );
        tokenB.mint(user2, 1000 );

        console.log("Approving tokens for DynamicLendingRate...");
        vm.startPrank(user1);
        usdt.approve(address(dynamicLendingRate), type(uint).max);
        tokenA.approve(address(dynamicLendingRate), type(uint).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdt.approve(address(dynamicLendingRate), type(uint).max);
        tokenB.approve(address(dynamicLendingRate), type(uint).max);
        vm.stopPrank();

        console.log("Setup completed successfully!");
    }

    function testAddTokens() public {
        vm.prank(owner);
        assertTrue(dynamicLendingRate.addTokens(address(tokenC), 3 )); // 更新 TokenB 的价格
        (Domain.TokenDomain memory token, bool exists) = dynamicLendingRate.getTokensInfo(address(tokenC));
        assertTrue(exists);
        assertEq(token.price, 3 );
    }

    function testLoan() public {
        vm.startPrank(owner);
        dynamicLendingRate.setTokens(address(tokenB), 3,true, true,6000,6000);
        vm.stopPrank();
        vm.startPrank(user1);
        (bytes32 receiptID ,)= dynamicLendingRate.loan(address(tokenA), 100 , address(tokenB), 5 , 30 days);

        // 验证贷款成功后用户的余额变化
        assertEq(tokenA.balanceOf(user1), 900 ); // 抵押了 100 TokenA
        assertEq(tokenB.balanceOf(user1), 5 );  // 获得了 50 USDT

        // 验证事件是否正确触发
        emit log_named_bytes32("Receipt ID", receiptID);
        vm.stopPrank();
    }

    function testRepayLoan() public {
        vm.startPrank(owner);
        dynamicLendingRate.setTokens(address(tokenA), 1,true, true,6000,6000);
        dynamicLendingRate.setTokens(address(tokenB), 2,true, true,6000,6000);
        tokenB.mint(user1, 1000); // 补充用户的 USDT 以支付利息
        vm.stopPrank();
        vm.startPrank(user1);
        tokenA.approve(address(dynamicLendingRate),100);
        uint8 rate = dynamicLendingRate.getLoanRate(address(tokenB));
        (bytes32 receiptID ,)= dynamicLendingRate.loan(address(tokenA), 100 , address(tokenB), 5 , 30 days);
        vm.warp(block.timestamp + 15 days); // 模拟时间流逝

        // 获取还款金额并还款
        uint loanAmount = 5 ;
        uint interest = rate*16; // 利率计算：5% 每天，15 天
        uint paybackAmount = loanAmount + interest;
        console.log("paybackAmount=",paybackAmount);

        tokenB.approve(address(dynamicLendingRate),paybackAmount);
        dynamicLendingRate.repayLoan(receiptID);
        console.log("paybackAmount=",paybackAmount);
        // 验证还款后用户的余额变化
        assertEq(tokenA.balanceOf(user1), 1000 ); // 抵押品已归还
        assertEq(tokenB.balanceOf(user1), 1000  - interest); // 还款后 USDT 减少

        vm.stopPrank();
    }

    function testLiquidateLoan() public {
        vm.startPrank(owner);
        dynamicLendingRate.setTokens(address(tokenB), 3,true, true,6000,6000);
        vm.stopPrank();
        vm.startPrank(user1);
//        tokenB.mint(address(dynamicLendingRate),1000);
        (bytes32 receiptID ,)= dynamicLendingRate.loan(address(tokenA), 100 , address(tokenB), 5 , 30 days);
        vm.warp(block.timestamp + 40 days); // 超过截止时间
        vm.stopPrank();
//        // 触发清算逻辑
        vm.startPrank(owner);
        dynamicLendingRate.liquidateLoan();

        // 验证用户的抵押品已被清算
        assertEq(tokenA.balanceOf(user1), 900 ); // 抵押品未归还

        vm.stopPrank();
    }

    function testProvideLiquid() public {
        vm.startPrank(user1);
        (bytes32 liquidID,) = dynamicLendingRate.provideLiquid(address(tokenA), 100 , 60 days);

        // 验证存款成功后用户的余额变化
        assertEq(tokenA.balanceOf(user1), 900 ); // 提供了 100 USDT

        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.startPrank(owner);
        dynamicLendingRate.setTokens(address(tokenA), 3,true, true,6000,6000);
        vm.stopPrank();
        vm.startPrank(user1);
        (bytes32 liquidID,) = dynamicLendingRate.provideLiquid(address(tokenA), 100 , 60 days);
        vm.warp(block.timestamp + 70 days); // 超过存款期限

        // 计算取款金额（本金 + 利息）
        uint depositAmount = 100 ;
        uint interest = (5 * 60) / 1; // 利率计算：5% 每天，60 天
        uint withdrawAmount = depositAmount + interest;

        dynamicLendingRate.withdraw(liquidID);

        // 验证取款后用户的余额变化
        assertEq(tokenA.balanceOf(user1), 1000  + interest); // 取回本金 + 利息

        vm.stopPrank();
    }

//    function testFailInvalidLoanParams() public {
//        vm.startPrank(user1);
//        dynamicLendingRate.loan(address(tokenA), 10 , address(usdt), 100 , 30 days); // 抵押不足
//        vm.stopPrank();
//    }
//
//    function testFailUnauthorizedAccess() public {
//        vm.startPrank(user2);
//        dynamicLendingRate.addTokens(address(tokenB), 3 ); // 只有 owner 可以调用
//        vm.stopPrank();
//    }
}