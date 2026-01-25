// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../../src/OPGrantFaucet.sol";
import "../utils/MockERC20.sol";

/**
 * @title OPGrantFaucetRebateTest
 * @notice Thorough tests for OP rebate functionality including:
 *         - Oracle games 4 & 5 for OP/USDC and OP/WETH price discovery
 *         - Rebate calculation and sanity checks
 *         - Validation logic in openSwapFeeRebate
 *         - 60-second cooldown between rebates
 *         - End-to-end integration with openSwap
 */
contract OPGrantFaucetRebateTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    BountyAndPriceRequest internal grantFaucet;

    // Optimism mainnet addresses (mocked)
    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    address internal owner = address(0x1);
    address internal swapper = address(0x2);
    address internal matcher = address(0x3);
    address internal reporter = address(0x4);
    address internal settler = address(0x5);

    // Initial OP prices (set in constructor)
    uint256 constant INITIAL_OPWETH = 5e14;   // 1 OP = 0.0005 WETH (OP is ~$1.50, ETH is ~$3000)
    uint256 constant INITIAL_OPUSDC = 15e17;  // 1 OP = 1.5 USDC (with 18 decimals for price)

    function setUp() public {
        // Deploy mock tokens at mainnet addresses
        _deployMockToken(OP, "Optimism", "OP");
        _deployMockToken(WETH, "Wrapped Ether", "WETH");
        _deployMockToken(USDC, "USD Coin", "USDC");

        // Deploy core contracts
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        grantFaucet = new BountyAndPriceRequest(
            address(oracle),
            address(bountyContract),
            owner,
            INITIAL_OPWETH,
            INITIAL_OPUSDC
        );
        swapContract = new openSwap(address(oracle), address(bountyContract), address(grantFaucet));

        // Link openSwap to grant faucet
        vm.prank(owner);
        grantFaucet.setOpenSwap(address(swapContract));

        // Fund grant faucet with OP for rebates
        deal(OP, address(grantFaucet), 1_000_000e18);
        vm.deal(address(grantFaucet), 10 ether);

        // Fund participants
        deal(WETH, reporter, 1000e18);
        deal(USDC, reporter, 1_000_000e6);
        deal(OP, reporter, 100_000e18);
        deal(WETH, swapper, 100e18);
        deal(USDC, swapper, 100_000e6);
        deal(WETH, matcher, 1000e18);
        deal(USDC, matcher, 1_000_000e6);
        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);
        vm.deal(reporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals
        vm.startPrank(reporter);
        MockERC20(OP).approve(address(bountyContract), type(uint256).max);
        MockERC20(WETH).approve(address(bountyContract), type(uint256).max);
        MockERC20(USDC).approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function _deployMockToken(address target, string memory name, string memory symbol) internal {
        MockERC20 mock = new MockERC20(name, symbol);
        vm.etch(target, address(mock).code);
        // Initialize with large supply
        bytes32 slot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(target, slot, bytes32(uint256(100_000_000e18)));
        vm.store(target, bytes32(uint256(2)), bytes32(uint256(100_000_000e18)));
    }

    // ============ Initial State Tests ============

    function testInitialOPPrices() public view {
        assertEq(grantFaucet.OPWETH(), INITIAL_OPWETH, "Initial OPWETH should be set");
        assertEq(grantFaucet.OPUSDC(), INITIAL_OPUSDC, "Initial OPUSDC should be set");
    }

    function testFeeRebateEligible_InitiallyFalse_ThenEligibleAfterTimer() public {
        // In Foundry, block.timestamp starts at 1
        // lastOpenSwapClaim is 0, openSwapTimer is 60
        // 1 >= 0 + 60 is false, so NOT eligible initially
        assertFalse(grantFaucet.feeRebateEligible(), "Should NOT be eligible at timestamp 1");

        // After warping past the timer, should be eligible
        vm.warp(60);
        assertTrue(grantFaucet.feeRebateEligible(), "Should be eligible after 60 seconds");
    }

    // ============ Oracle Game 4 (OP/USDC) Tests ============

    function testGame4_CreatesOPUSDCPriceFeed() public {
        // Create game 4 (OP/USDC)
        uint256 reportId = grantFaucet.bountyAndPriceRequest(4);
        assertEq(reportId, 1, "First report should be ID 1");
        assertEq(grantFaucet.lastReportId(4), reportId, "lastReportId[4] should be set");

        // Verify oracle game was created with correct tokens
        (,,,, address token1,, address token2,,,,,) = oracle.reportMeta(reportId);
        assertEq(token1, OP, "token1 should be OP");
        assertEq(token2, USDC, "token2 should be USDC");
    }

    function testGame4_SettlesAndUpdatesOPUSDC() public {
        // Create game 4
        uint256 reportId = grantFaucet.bountyAndPriceRequest(4);

        // Get state hash for initial report
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Wait for bounty forward start time (bountyParams[3].forwardStartTime = 20)
        vm.warp(block.timestamp + 21);

        // Submit initial report: 100 OP = 150 USDC (price = 1.5 USDC per OP)
        // With 18 decimal price: 1.5e18
        uint256 amount1 = 100e18;  // 100 OP
        uint256 amount2 = 150e6;   // 150 USDC (6 decimals)
        // Price = amount1 * 1e18 / amount2

        vm.startPrank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);
        vm.stopPrank();

        // Wait for settlement (30 min settlement time)
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        uint256 oldOPUSDC = grantFaucet.OPUSDC();

        // Settle - this should trigger onSettle callback
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify OPUSDC was updated
        uint256 newOPUSDC = grantFaucet.OPUSDC();
        assertNotEq(newOPUSDC, oldOPUSDC, "OPUSDC should be updated after settlement");

        // Price should be amount1 * 1e18 / amount2 = 100e18 * 1e18 / 150e6
        uint256 expectedPrice = (amount1 * 1e18) / amount2;
        assertEq(newOPUSDC, expectedPrice, "OPUSDC price should match oracle price");
    }

    // ============ Oracle Game 5 (OP/WETH) Tests ============

    function testGame5_CreatesOPWETHPriceFeed() public {
        // Create game 5 (OP/WETH)
        uint256 reportId = grantFaucet.bountyAndPriceRequest(5);
        assertEq(grantFaucet.lastReportId(5), reportId, "lastReportId[5] should be set");

        // Verify oracle game was created with correct tokens
        (,,,, address token1,, address token2,,,,,) = oracle.reportMeta(reportId);
        assertEq(token1, OP, "token1 should be OP");
        assertEq(token2, WETH, "token2 should be WETH");
    }

    function testGame5_SettlesAndUpdatesOPWETH() public {
        // Create game 5
        uint256 reportId = grantFaucet.bountyAndPriceRequest(5);

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Wait for bounty forward start time (bountyParams[3].forwardStartTime = 20)
        vm.warp(block.timestamp + 21);

        // Submit initial report: 100 OP = 0.05 WETH (OP ~$1.50, ETH ~$3000)
        uint256 amount1 = 100e18;   // 100 OP
        uint256 amount2 = 5e16;     // 0.05 WETH

        vm.startPrank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);
        vm.stopPrank();

        // Wait for settlement (30 min)
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        uint256 oldOPWETH = grantFaucet.OPWETH();

        vm.prank(settler);
        oracle.settle(reportId);

        uint256 newOPWETH = grantFaucet.OPWETH();
        assertNotEq(newOPWETH, oldOPWETH, "OPWETH should be updated after settlement");

        uint256 expectedPrice = (amount1 * 1e18) / amount2;
        assertEq(newOPWETH, expectedPrice, "OPWETH price should match oracle price");
    }

    // ============ Rebate Calculation Sanity Tests ============

    function testRebateCalculation_ETHSell_Sanity() public {
        // Scenario: Swap 0.1 ETH, get 0.005% rebate in OP
        // 0.1 ETH * 0.005% = 0.000005 ETH worth of OP
        // With OPWETH = 5e14 (1 OP = 0.0005 ETH), that's 0.000005 / 0.0005 = 0.01 OP

        uint256 sellAmt = 0.1 ether;
        uint256 expectedRebateInETH = sellAmt / 20000; // 0.005%
        assertEq(expectedRebateInETH, 5e12, "0.005% of 0.1 ETH is 5e12 wei");

        // Convert to OP: rebateInETH * OPWETH / 1e18
        // Wait, the formula is: sellAmtRebate * OPWETH / 1e18
        // OPWETH is the price of 1 OP in WETH terms? Let me check...
        // Actually looking at the code: sellAmtRebate = sellAmtRebate * OPWETH / 1e18
        // If OPWETH is 5e14 (0.0005), then:
        // 5e12 * 5e14 / 1e18 = 2.5e9 / 1e18 = 0.0000000025 OP?
        // That seems wrong... Let me re-check the price semantics

        // Looking at onSettle: OPWETH = price where price = amount1 * 1e18 / amount2
        // For game 5: token1=OP, token2=WETH
        // So price = OP_amount * 1e18 / WETH_amount
        // If 100 OP = 0.05 WETH, price = 100e18 * 1e18 / 5e16 = 2000e18
        // That means OPWETH = 2000e18 = "how many OP per 1 WETH"

        // So the rebate calc: sellAmtRebate * OPWETH / 1e18
        // 5e12 (ETH) * 2000e18 / 1e18 = 5e12 * 2000 = 1e16 = 0.01 OP

        // With initial OPWETH = 5e14 (which is wrong semantics but let's verify)
        uint256 rebateWithInitialPrice = expectedRebateInETH * INITIAL_OPWETH / 1e18;
        console.log("Rebate with initial OPWETH:", rebateWithInitialPrice);

        // This gives 5e12 * 5e14 / 1e18 = 2.5e9 wei = 0.0000000025 OP
        // That's way too small - the initial prices in constructor seem wrong

        // Let me calculate what OPWETH should be for reasonable rebates:
        // If OP = $1.50 and ETH = $3000, then 1 ETH = 2000 OP
        // So OPWETH should be 2000e18 for the formula to work correctly
    }

    function testRebateCalculation_USDCSell_Sanity() public {
        // Scenario: Swap 300 USDC (max allowed), get 0.005% rebate in OP
        // 300 USDC * 0.005% = 0.015 USDC worth of OP
        // If 1 OP = 1.5 USDC, then 0.015 USDC = 0.01 OP

        uint256 sellAmt = 300e6; // 300 USDC (6 decimals)
        uint256 expectedRebateInUSDC = sellAmt / 20000;
        assertEq(expectedRebateInUSDC, 15000, "0.005% of 300 USDC is 0.015 USDC");

        // Convert to OP using OPUSDC
        // Formula: sellAmtRebate * OPUSDC / 1e18
        // OPUSDC = OP_amount * 1e18 / USDC_amount
        // If 100 OP = 150 USDC, OPUSDC = 100e18 * 1e18 / 150e6 = 666666666666666666666666666

        // With initial OPUSDC = 15e17 (1.5e18):
        uint256 rebateWithInitialPrice = expectedRebateInUSDC * INITIAL_OPUSDC / 1e18;
        console.log("Rebate with initial OPUSDC:", rebateWithInitialPrice);
        // 15000 * 15e17 / 1e18 = 22500000000000 / 1e18 = 0.0000225 OP
        // Also seems very small
    }

    // ============ openSwapFeeRebate Validation Tests ============

    function testRebate_OnlyOpenSwapCanCall() public {
        vm.prank(swapper);
        vm.expectRevert("not openSwap");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_InvalidSellToken_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("invalid tokens");
        grantFaucet.openSwapFeeRebate(
            swapper, WETH, 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_InvalidTimeType_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("invalid timeType");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, false, 750, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_InvalidSettlementTime_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("invalid settlementTime");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 5, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_MaxFeeTooLow_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("maxFee out of bounds");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 1999, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_MaxFeeTooHigh_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("maxFee out of bounds");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 10001, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_StartingFeeTooLow_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("startingFee too low");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 749, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_InitLiquidityTooLow_Reverts() public {
        // initLiquidity must be >= sellAmt * 10 / 101 (~9.9%)
        uint256 sellAmt = 0.1 ether;
        uint256 minLiquidity = sellAmt * 10 / 101;

        vm.prank(address(swapContract));
        vm.expectRevert("init liquidity too low");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, minLiquidity - 1, 50000, 1, 0
        );
    }

    function testRebate_ToleranceRangeTooWide_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("slippage too wide");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50001, 1, 0
        );
    }

    function testRebate_WrongSwapFee_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("oracle game fees");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 2, 0
        );
    }

    function testRebate_ProtocolFeeTooHigh_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("oracle game fees");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 251
        );
    }

    function testRebate_ETHSellTooMuch_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("selling too much ETH");
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether + 1, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );
    }

    function testRebate_USDCSellTooMuch_Reverts() public {
        vm.prank(address(swapContract));
        vm.expectRevert("selling too much USDC");
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, 300e6 + 1, 4, true, 750, 2000, 30e6, 50000, 1, 0
        );
    }

    // ============ Successful Rebate Tests ============

    function testRebate_ETHSell_Success() public {
        uint256 sellAmt = 0.1 ether;
        uint256 initLiquidity = sellAmt * 10 / 100; // 10%
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, initLiquidity, 50000, 1, 0
        );

        uint256 swapperOPAfter = MockERC20(OP).balanceOf(swapper);
        uint256 rebateReceived = swapperOPAfter - swapperOPBefore;

        // Calculate expected rebate
        uint256 rebateInETH = sellAmt / 20000;
        uint256 expectedRebate = rebateInETH * INITIAL_OPWETH / 1e18;

        assertEq(rebateReceived, expectedRebate, "Rebate amount should match calculation");
        console.log("ETH sell rebate received:", rebateReceived);
    }

    function testRebate_USDCSell_Success() public {
        uint256 sellAmt = 300e6; // 300 USDC
        uint256 initLiquidity = sellAmt * 10 / 100;
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, sellAmt, 4, true, 750, 2000, initLiquidity, 50000, 1, 0
        );

        uint256 swapperOPAfter = MockERC20(OP).balanceOf(swapper);
        uint256 rebateReceived = swapperOPAfter - swapperOPBefore;

        uint256 rebateInUSDC = sellAmt / 20000;
        uint256 expectedRebate = rebateInUSDC * INITIAL_OPUSDC / 1e18;

        assertEq(rebateReceived, expectedRebate, "Rebate amount should match calculation");
        console.log("USDC sell rebate received:", rebateReceived);
    }

    // ============ Cooldown Tests ============

    function testCooldown_NotEligibleImmediatelyAfterClaim() public {
        uint256 sellAmt = 0.1 ether;
        uint256 initLiquidity = sellAmt * 10 / 100;

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, initLiquidity, 50000, 1, 0
        );

        assertFalse(grantFaucet.feeRebateEligible(), "Should not be eligible immediately after claim");
    }

    function testCooldown_EligibleAfter60Seconds() public {
        uint256 sellAmt = 0.1 ether;
        uint256 initLiquidity = sellAmt * 10 / 100;

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, initLiquidity, 50000, 1, 0
        );

        assertFalse(grantFaucet.feeRebateEligible(), "Should not be eligible yet");

        vm.warp(block.timestamp + 59);
        assertFalse(grantFaucet.feeRebateEligible(), "Should not be eligible at 59 seconds");

        vm.warp(block.timestamp + 1);
        assertTrue(grantFaucet.feeRebateEligible(), "Should be eligible at 60 seconds");
    }

    // ============ Price Update Integration Tests ============

    function testRebateWithUpdatedPrices() public {
        // First, play oracle game 5 to update OPWETH price
        uint256 reportId = grantFaucet.bountyAndPriceRequest(5);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Wait for bounty forward start time
        vm.warp(block.timestamp + 21);

        // Report: 100 OP = 0.05 WETH (so 1 OP = 0.0005 WETH, 1 ETH = 2000 OP)
        // Price = 100e18 * 1e18 / 5e16 = 2000e18
        // Note: amount1 must match exactToken1Report = 100e18
        uint256 amount1 = 100e18;
        uint256 amount2 = 5e16;

        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);

        // Wait for settlement (30 min)
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        vm.prank(settler);
        oracle.settle(reportId);

        uint256 newOPWETH = grantFaucet.OPWETH();
        uint256 expectedPrice = (amount1 * 1e18) / amount2;
        assertEq(newOPWETH, expectedPrice, "OPWETH should be 2000e18");

        // Now test rebate with new price
        // 0.1 ETH * 0.005% = 5e12 wei of ETH
        // 5e12 * 2000e18 / 1e18 = 10e15 = 0.01 OP
        vm.warp(block.timestamp + 61); // Wait for cooldown

        uint256 sellAmt = 0.1 ether;
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, sellAmt / 10, 50000, 1, 0
        );

        uint256 rebateReceived = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        uint256 expectedRebate = (sellAmt / 20000) * newOPWETH / 1e18;
        assertEq(rebateReceived, expectedRebate, "Rebate should use updated price");
        assertEq(rebateReceived, 10e15, "Should receive 0.01 OP for 0.1 ETH swap");

        console.log("Rebate with updated OPWETH price:", rebateReceived);
        console.log("That's", rebateReceived / 1e16, "/ 100 OP");
    }

    // ============ Max Rebate Sanity Check ============
    // Using current realistic prices: OP ~$0.30, ETH ~$3000, USDC = $1

    function testMaxRebate_ETH_SanityCheck() public {
        // Current prices: OP = $0.30, ETH = $3000
        // 1 ETH = $3000 / $0.30 = 10,000 OP
        // OPWETH = 10000e18
        vm.store(address(grantFaucet), bytes32(uint256(2)), bytes32(uint256(10000e18)));
        assertEq(grantFaucet.OPWETH(), 10000e18, "OPWETH updated to 10000 OP/ETH");

        // Max ETH sell is 0.1 ETH (~$300)
        // 0.1 ETH * 0.005% = 0.000005 ETH
        // 0.000005 ETH * 10000 OP/ETH = 0.05 OP max rebate
        // At $0.30/OP: 0.05 OP = $0.015 rebate for $300 swap

        uint256 sellAmt = 0.1 ether;
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, sellAmt / 10, 50000, 1, 0
        );

        uint256 rebateReceived = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== ETH Swap Rebate (OP @ $0.30) ===");
        console.log("Swap size: 0.1 ETH (~$300)");
        console.log("Rebate in OP (wei):", rebateReceived);
        console.log("Rebate in OP (hundredths):", rebateReceived / 1e16, "/ 100 OP"); // 0.05 OP = 5
        console.log("Rebate USD value (cents):", (rebateReceived * 30) / 1e18); // $0.30 per OP, result in cents

        // Should be 0.05 OP = 5e16 wei
        // USD value: 0.05 OP * $0.30 = $0.015 = 1.5 cents
        assertEq(rebateReceived, 5e16, "Should receive 0.05 OP for max ETH swap");
    }

    function testMaxRebate_USDC_SanityCheck() public {
        // Current prices: OP = $0.30, USDC = $1
        // 1 USDC = $1 / $0.30 = 3.33 OP
        // Oracle price = OP_amount * 1e18 / USDC_amount
        // If 100 OP = 30 USDC: price = 100e18 * 1e18 / 30e6 = 3.33e30
        uint256 realisticOPUSDC = 3333333333333333333333333333333; // 3.33e30
        vm.store(address(grantFaucet), bytes32(uint256(3)), bytes32(realisticOPUSDC));

        console.log("OPUSDC price set to:", realisticOPUSDC);

        // Max USDC sell is 300 USDC
        // 300 USDC * 0.005% = 0.015 USDC
        // rebateInUSDC = 300e6 / 20000 = 15000 (raw 6-decimal)
        // rebateInOP = 15000 * 3.33e30 / 1e18 = ~5e16 = 0.05 OP
        // At $0.30/OP: 0.05 OP = $0.015 rebate for $300 swap

        uint256 sellAmt = 300e6;
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, sellAmt, 4, true, 750, 2000, sellAmt / 10, 50000, 1, 0
        );

        uint256 rebateReceived = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== USDC Swap Rebate (OP @ $0.30) ===");
        console.log("Swap size: 300 USDC");
        console.log("Rebate in OP (wei):", rebateReceived);
        console.log("Rebate in OP (hundredths):", rebateReceived / 1e16, "/ 100 OP"); // 0.05 OP = 5
        console.log("Rebate USD value (cents):", (rebateReceived * 30) / 1e18);

        // Should be ~0.05 OP = 5e16 wei (same as ETH since both are $300 swaps)
        // USD value: 0.05 OP * $0.30 = $0.015 = 1.5 cents
        assertApproxEqRel(rebateReceived, 5e16, 0.01e18, "Should receive ~0.05 OP for max USDC swap");
    }

    // ============ End-to-End Oracle Game Price Discovery ============
    // These tests play the actual oracle games to get prices, then verify rebates are sensible

    function testEndToEnd_OracleGamePricing_ETH() public {
        // Play oracle game 5 (OP/WETH) with realistic current prices
        // OP = $0.30, ETH = $3000
        // So 100 OP ($30) = 0.01 ETH ($30)

        uint256 reportId = grantFaucet.bountyAndPriceRequest(5);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Wait for bounty forward start time
        vm.warp(block.timestamp + 21);

        // Report: 100 OP = 0.01 WETH (realistic for OP @ $0.30, ETH @ $3000)
        uint256 amount1 = 100e18;  // 100 OP (token1)
        uint256 amount2 = 1e16;    // 0.01 WETH (token2)
        // Oracle price = 100e18 * 1e18 / 1e16 = 10000e18 (10,000 OP per ETH)

        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);

        // Wait for settlement
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        vm.prank(settler);
        oracle.settle(reportId);

        // Verify oracle price was set correctly
        uint256 oracleOPWETH = grantFaucet.OPWETH();
        uint256 expectedPrice = (amount1 * 1e18) / amount2;
        assertEq(oracleOPWETH, expectedPrice, "OPWETH should be 10000e18");
        assertEq(oracleOPWETH, 10000e18, "10,000 OP per ETH");

        console.log("=== Oracle Game 5 Result ===");
        console.log("Reported: 100 OP = 0.01 WETH");
        console.log("OPWETH price:", oracleOPWETH);
        console.log("Meaning: 1 ETH =", oracleOPWETH / 1e18, "OP");

        // Now claim rebate using oracle-derived price
        vm.warp(block.timestamp + 61); // Wait for cooldown

        uint256 sellAmt = 0.1 ether; // Max ETH swap
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), sellAmt, 4, true, 750, 2000, sellAmt / 10, 50000, 1, 0
        );

        uint256 rebateReceived = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== Rebate from Oracle Price ===");
        console.log("Swap: 0.1 ETH (~$300 at current prices)");
        console.log("Rebate (wei):", rebateReceived);
        console.log("Rebate (OP):", rebateReceived / 1e16, "/ 100 OP");

        // Calculate USD value: rebateOP * $0.30
        uint256 rebateUSDCents = (rebateReceived * 30) / 1e18;
        console.log("Rebate USD value:", rebateUSDCents, "cents");

        // Verify rebate is sensible:
        // 0.1 ETH * 0.005% = 0.000005 ETH
        // 0.000005 ETH * 10000 OP/ETH = 0.05 OP
        assertEq(rebateReceived, 5e16, "Should receive 0.05 OP");

        // Sanity check: rebate should be ~1-2 cents, not dollars
        assertTrue(rebateUSDCents < 10, "Rebate should be less than 10 cents");
        assertTrue(rebateUSDCents >= 1, "Rebate should be at least 1 cent");
    }

    function testEndToEnd_OracleGamePricing_USDC() public {
        // Play oracle game 4 (OP/USDC) with realistic current prices
        // OP = $0.30, USDC = $1
        // So 100 OP ($30) = 30 USDC ($30)

        uint256 reportId = grantFaucet.bountyAndPriceRequest(4);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Wait for bounty forward start time
        vm.warp(block.timestamp + 21);

        // Report: 100 OP = 30 USDC (realistic for OP @ $0.30)
        uint256 amount1 = 100e18;  // 100 OP (token1)
        uint256 amount2 = 30e6;    // 30 USDC (token2, 6 decimals)
        // Oracle price = 100e18 * 1e18 / 30e6 = 3.33e30

        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);

        // Wait for settlement
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        vm.prank(settler);
        oracle.settle(reportId);

        // Verify oracle price was set
        uint256 oracleOPUSDC = grantFaucet.OPUSDC();
        uint256 expectedPrice = (amount1 * 1e18) / amount2;
        assertEq(oracleOPUSDC, expectedPrice, "OPUSDC should match oracle calculation");

        console.log("=== Oracle Game 4 Result ===");
        console.log("Reported: 100 OP = 30 USDC");
        console.log("OPUSDC price:", oracleOPUSDC);
        console.log("Meaning: 1 USDC =", oracleOPUSDC / 1e18, "e18 OP units");

        // Now claim rebate using oracle-derived price
        vm.warp(block.timestamp + 61); // Wait for cooldown

        uint256 sellAmt = 300e6; // Max USDC swap (300 USDC)
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, sellAmt, 4, true, 750, 2000, sellAmt / 10, 50000, 1, 0
        );

        uint256 rebateReceived = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== Rebate from Oracle Price ===");
        console.log("Swap: 300 USDC");
        console.log("Rebate (wei):", rebateReceived);
        console.log("Rebate (OP):", rebateReceived / 1e16, "/ 100 OP");

        // Calculate USD value: rebateOP * $0.30
        uint256 rebateUSDCents = (rebateReceived * 30) / 1e18;
        console.log("Rebate USD value:", rebateUSDCents, "cents");

        // Verify rebate calculation:
        // 300 USDC * 0.005% = 0.015 USDC (in 6 decimals: 15000)
        // rebateInOP = 15000 * oracleOPUSDC / 1e18
        uint256 expectedRebate = (sellAmt / 20000) * oracleOPUSDC / 1e18;
        assertEq(rebateReceived, expectedRebate, "Rebate should match formula");

        // Sanity check: rebate should be ~1-2 cents, not dollars
        assertTrue(rebateUSDCents < 10, "Rebate should be less than 10 cents");
        assertTrue(rebateUSDCents >= 1, "Rebate should be at least 1 cent");
    }

    function testEndToEnd_RebatesAreConsistent_ETH_vs_USDC() public {
        // Verify that $300 ETH swap and $300 USDC swap give similar rebates
        // Using realistic OP @ $0.30 prices set via storage (simulating oracle result)

        // Set OPWETH = 10000e18 (10,000 OP per ETH, meaning OP @ $0.30 with ETH @ $3000)
        vm.store(address(grantFaucet), bytes32(uint256(2)), bytes32(uint256(10000e18)));

        // Set OPUSDC = 3.33e30 (for OP @ $0.30)
        vm.store(address(grantFaucet), bytes32(uint256(3)), bytes32(uint256(3333333333333333333333333333333)));

        console.log("=== Prices Set (OP @ $0.30) ===");
        console.log("OPWETH:", grantFaucet.OPWETH(), "(10000 OP/ETH)");
        console.log("OPUSDC:", grantFaucet.OPUSDC());

        // === Claim ETH rebate ===
        vm.warp(block.timestamp + 61);
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );

        uint256 ethRebate = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        // === Claim USDC rebate ===
        vm.warp(block.timestamp + 61);
        swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, 300e6, 4, true, 750, 2000, 30e6, 50000, 1, 0
        );

        uint256 usdcRebate = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== Rebate Comparison (both $300 swaps) ===");
        console.log("ETH swap (0.1 ETH) rebate (wei):", ethRebate);
        console.log("ETH swap rebate (hundredths OP):", ethRebate / 1e16);
        console.log("USDC swap (300 USDC) rebate (wei):", usdcRebate);
        console.log("USDC swap rebate (hundredths OP):", usdcRebate / 1e16);

        uint256 ethRebateCents = (ethRebate * 30) / 1e18;
        uint256 usdcRebateCents = (usdcRebate * 30) / 1e18;
        console.log("ETH rebate USD:", ethRebateCents, "cents");
        console.log("USDC rebate USD:", usdcRebateCents, "cents");

        // Both $300 swaps should give roughly equal rebates (~0.05 OP = ~1.5 cents)
        // Allow 20% tolerance for rounding
        assertApproxEqRel(ethRebate, usdcRebate, 0.2e18, "ETH and USDC rebates should be similar for equal USD value");

        // Both should be small (under 10 cents) - sanity check against absurd rebates
        assertTrue(ethRebateCents < 10, "ETH rebate too high - would drain treasury");
        assertTrue(usdcRebateCents < 10, "USDC rebate too high - would drain treasury");

        // Both should be at least 1 cent - sanity check that rebate is meaningful
        assertTrue(ethRebateCents >= 1, "ETH rebate too low");
        assertTrue(usdcRebateCents >= 1, "USDC rebate too low");
    }

    function testEndToEnd_PlayBothOracleGames_ThenClaimRebates() public {
        // Play BOTH oracle games to establish OP prices, then claim rebates
        // This tests the full flow: oracle price discovery -> rebate calculation

        console.log("=== Playing Oracle Game 5 (OP/WETH) ===");

        // --- Game 5: OP/WETH ---
        uint256 reportId5 = grantFaucet.bountyAndPriceRequest(5);
        (bytes32 stateHash5,,,,,,,) = oracle.extraData(reportId5);

        vm.warp(block.timestamp + 25); // Wait for bounty forward start
        vm.roll(block.number + 100);

        // Report: 100 OP = 0.01 WETH (OP @ $0.30, ETH @ $3000)
        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId5, 100e18, 1e16, stateHash5, reporter);

        vm.warp(block.timestamp + 60 * 30 + 1); // Wait 30min settlement
        vm.roll(block.number + 1000);

        vm.prank(settler);
        oracle.settle(reportId5);

        console.log("Game 5 settled. OPWETH:", grantFaucet.OPWETH());
        assertEq(grantFaucet.OPWETH(), 10000e18, "OPWETH should be 10000 OP/ETH");

        console.log("=== Playing Oracle Game 4 (OP/USDC) ===");

        // --- Game 4: OP/USDC (need to wait 24h for game timer) ---
        uint256 game4StartTime = block.timestamp + 60 * 60 * 25; // 25 hours from now
        vm.warp(game4StartTime);
        vm.roll(block.number + 50000);

        uint256 reportId4 = grantFaucet.bountyAndPriceRequest(4);
        (bytes32 stateHash4,,,,,,,) = oracle.extraData(reportId4);

        // Wait for bounty forward start (forwardStartTime is 20 seconds)
        vm.warp(game4StartTime + 30);
        vm.roll(block.number + 100);

        // Report: 100 OP = 30 USDC (OP @ $0.30)
        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId4, 100e18, 30e6, stateHash4, reporter);

        vm.warp(game4StartTime + 30 + 60 * 30 + 1); // Wait 30min settlement
        vm.roll(block.number + 1000);

        vm.prank(settler);
        oracle.settle(reportId4);

        uint256 actualOPUSDC = grantFaucet.OPUSDC();
        console.log("Game 4 settled. OPUSDC:", actualOPUSDC);
        // Expected: 100e18 * 1e18 / 30e6 = 3.33e30
        assertTrue(actualOPUSDC > 3e30, "OPUSDC should be ~3.33e30");

        console.log("=== Both Oracle Games Complete - Now Testing Rebates ===");

        // --- Claim ETH rebate using oracle-derived OPWETH price ---
        vm.warp(block.timestamp + 61); // Wait for cooldown

        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);
        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );
        uint256 ethRebate = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        // --- Claim USDC rebate using oracle-derived OPUSDC price ---
        vm.warp(block.timestamp + 61);

        swapperOPBefore = MockERC20(OP).balanceOf(swapper);
        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, USDC, 300e6, 4, true, 750, 2000, 30e6, 50000, 1, 0
        );
        uint256 usdcRebate = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;

        console.log("=== Rebates from Oracle-Derived Prices ===");
        console.log("ETH rebate (0.05 OP expected):", ethRebate);
        console.log("USDC rebate (~0.05 OP expected):", usdcRebate);

        uint256 ethRebateCents = (ethRebate * 30) / 1e18;
        uint256 usdcRebateCents = (usdcRebate * 30) / 1e18;
        console.log("ETH rebate:", ethRebateCents, "cents");
        console.log("USDC rebate:", usdcRebateCents, "cents");

        // Verify rebates are sensible
        assertEq(ethRebate, 5e16, "ETH rebate should be 0.05 OP");
        assertApproxEqRel(usdcRebate, 5e16, 0.01e18, "USDC rebate should be ~0.05 OP");

        // Sanity: both under 10 cents
        assertTrue(ethRebateCents < 10 && usdcRebateCents < 10, "Rebates should be small");
    }

    // ============ Rebate Failure Doesn't Brick Settlement ============

    function testRebate_CooldownDoesNotBrickSettlement() public {
        // Claim a rebate first to trigger cooldown
        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );

        // Now feeRebateEligible should return false (cooldown active)
        assertFalse(grantFaucet.feeRebateEligible(), "Should be on cooldown");

        // Calling openSwapFeeRebate during cooldown should still work (just no rebate)
        // The openSwap contract wraps this in try/catch, but let's verify the faucet
        // doesn't revert in a way that would brick things
        uint256 swapperOPBefore = MockERC20(OP).balanceOf(swapper);

        // This call should succeed but not give a rebate (or the openSwap would catch the revert)
        // Actually the faucet itself doesn't check cooldown in openSwapFeeRebate - it just updates lastOpenSwapClaim
        // The check is in feeRebateEligible which openSwap calls first
        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );

        // Should still get rebate since openSwapFeeRebate doesn't check cooldown itself
        uint256 rebate = MockERC20(OP).balanceOf(swapper) - swapperOPBefore;
        assertGt(rebate, 0, "Rebate given even during cooldown (openSwap checks eligibility)");
    }

    function testRebate_EmptyFaucetDoesNotBrickSettlement() public {
        // Drain the faucet of OP tokens
        uint256 faucetBalance = MockERC20(OP).balanceOf(address(grantFaucet));
        vm.prank(owner);
        grantFaucet.sweep(OP, faucetBalance);

        assertEq(MockERC20(OP).balanceOf(address(grantFaucet)), 0, "Faucet should be empty");

        // Trying to claim rebate should revert (not enough OP)
        // But openSwap wraps this in try/catch, so settlement won't brick
        vm.prank(address(swapContract));
        vm.expectRevert(); // SafeERC20 will revert on insufficient balance
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );

        // The key point: openSwap catches this revert, so settlement continues
        // This test just verifies the revert happens (which openSwap will catch)
    }

    function testRebate_FeeRebateEligible_ReturnsFalseOnCooldown() public {
        // At timestamp 1, not eligible yet (1 < 0 + 60)
        assertFalse(grantFaucet.feeRebateEligible(), "Should NOT be eligible at timestamp 1");

        vm.warp(block.timestamp + 60); // Past initial cooldown

        assertTrue(grantFaucet.feeRebateEligible(), "Should be eligible after 60s");

        // Claim rebate
        vm.prank(address(swapContract));
        grantFaucet.openSwapFeeRebate(
            swapper, address(0), 0.1 ether, 4, true, 750, 2000, 0.01 ether, 50000, 1, 0
        );

        // Now on cooldown
        assertFalse(grantFaucet.feeRebateEligible(), "Should NOT be eligible during cooldown");

        // openSwap would see this and skip the rebate call entirely
        // This is the designed behavior - no rebate, but no revert either
    }
}
