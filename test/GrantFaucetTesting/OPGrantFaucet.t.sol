// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../../src/OPGrantFaucet.sol";
import "../utils/MockERC20.sol";

/**
 * @title OPGrantFaucetTest
 * @notice Tests for the BountyAndPriceRequest contract (OPGrantFaucet.sol)
 * @dev Uses mock tokens since the contract has hardcoded Optimism addresses
 */
contract OPGrantFaucetTest is Test {
    OpenOracle internal oracle;
    openOracleBounty internal bountyContract;
    BountyAndPriceRequest internal faucet;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal opToken;

    address internal owner = address(0x1);
    address internal reporter = address(0x2);
    address internal randomUser = address(0x3);

    // Optimism mainnet addresses (hardcoded in OPGrantFaucet)
    address constant WETH_OP = 0x4200000000000000000000000000000000000006;
    address constant USDC_OP = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant OP_TOKEN = 0x4200000000000000000000000000000000000042;

    function setUp() public {
        // Deploy oracle and bounty contract
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));

        // Deploy mock tokens at the hardcoded addresses
        _deployMockAtAddress(WETH_OP, "Wrapped Ether", "WETH", 18);
        _deployMockAtAddress(USDC_OP, "USD Coin", "USDC", 6);
        _deployMockAtAddress(OP_TOKEN, "Optimism", "OP", 18);

        weth = MockERC20(WETH_OP);
        usdc = MockERC20(USDC_OP);
        opToken = MockERC20(OP_TOKEN);

        // Deploy faucet with initial OP prices
        faucet = new BountyAndPriceRequest(address(oracle), address(bountyContract), owner, 5e14, 15e17);

        // Fund faucet with OP tokens for bounties
        opToken.transfer(address(faucet), 100 ether);

        // Fund faucet with ETH for oracle fees
        vm.deal(address(faucet), 10 ether);

        // Fund reporter with tokens and ETH
        weth.transfer(reporter, 100 ether);
        usdc.transfer(reporter, 1_000_000e6);
        vm.deal(reporter, 10 ether);

        // Reporter approves bounty contract
        vm.startPrank(reporter);
        weth.approve(address(bountyContract), type(uint256).max);
        usdc.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function _deployMockAtAddress(address target, string memory name, string memory symbol, uint8 decimals) internal {
        // Deploy mock token at specific address using vm.etch
        MockERC20 mock = new MockERC20(name, symbol);

        // Get the bytecode of the deployed mock
        bytes memory code = address(mock).code;

        // Set the code at target address
        vm.etch(target, code);

        // Initialize storage - mint tokens to this test contract
        MockERC20 targetToken = MockERC20(target);

        // Use vm.store to set balances directly since constructor won't run
        // balanceOf mapping is at slot 0 for most ERC20s
        // For OpenZeppelin ERC20, _balances is at slot 0
        bytes32 slot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(target, slot, bytes32(uint256(1_000_000 ether)));

        // Set total supply at slot 2
        vm.store(target, bytes32(uint256(2)), bytes32(uint256(1_000_000 ether)));
    }

    // ============ Constructor Tests ============

    function testConstructor_SetsImmutables() public view {
        assertEq(address(faucet.oracle()), address(oracle), "Oracle should be set");
        assertEq(address(faucet.bounty()), address(bountyContract), "Bounty contract should be set");
        assertEq(faucet.owner(), owner, "Owner should be set");
    }

    function testConstructor_RevertsZeroOracleAddress() public {
        vm.expectRevert("oracle address cannot be 0");
        new BountyAndPriceRequest(address(0), address(bountyContract), owner, 5e14, 15e17);
    }

    function testConstructor_RevertsZeroBountyAddress() public {
        vm.expectRevert("bounty address cannot be 0");
        new BountyAndPriceRequest(address(oracle), address(0), owner, 5e14, 15e17);
    }

    function testConstructor_InitializesGameTimers() public view {
        assertEq(faucet.gameTimer(0), 60 * 3, "Game 0 timer should be 3 minutes");
        assertEq(faucet.gameTimer(1), 60 * 10, "Game 1 timer should be 10 minutes");
        assertEq(faucet.gameTimer(2), 60 * 60, "Game 2 timer should be 1 hour");
        assertEq(faucet.gameTimer(3), 60 * 60 * 24, "Game 3 timer should be 24 hours");
    }

    function testConstructor_InitializesBountyForGame() public view {
        assertEq(faucet.bountyForGame(0), 0, "Game 0 uses bounty params 0");
        assertEq(faucet.bountyForGame(1), 0, "Game 1 uses bounty params 0");
        assertEq(faucet.bountyForGame(2), 1, "Game 2 uses bounty params 1");
        assertEq(faucet.bountyForGame(3), 2, "Game 3 uses bounty params 2");
    }

    function testConstructor_InitializesGames() public view {
        // Check Game 0 params
        (
            uint256 exactToken1Report,
            uint256 escalationHalt,
            uint256 settlerReward,
            address token1Address,
            uint48 settlementTime,
            uint24 disputeDelay,
            uint24 protocolFee,
            address token2Address,
            uint32 callbackGasLimit,
            uint24 feePercentage,
            uint16 multiplier,
            bool timeType,
            bool trackDisputes,
            bool keepFee,
            address callbackContract,
            bytes4 callbackSelector,
            address protocolFeeRecipient
        ) = faucet.games(0);

        assertEq(exactToken1Report, 2000000000000000, "Game 0 exactToken1Report");
        assertEq(escalationHalt, 20000000000000000, "Game 0 escalationHalt");
        assertEq(token1Address, WETH_OP, "Game 0 token1 should be WETH");
        assertEq(token2Address, USDC_OP, "Game 0 token2 should be USDC");
        assertEq(settlementTime, 10, "Game 0 settlementTime");
        assertEq(multiplier, 125, "Game 0 multiplier");
        assertTrue(timeType, "Game 0 should use timestamp");
    }

    function testConstructor_InitializesBountyParams() public view {
        // Check bounty params 0
        (
            uint256 bountyStartAmt,
            address creator,
            address editor,
            uint16 bountyMultiplier,
            uint16 maxRounds,
            bool timeType,
            uint256 forwardStartTime,
            address bountyToken,
            uint256 maxAmount,
            uint256 roundLength,
            bool recallOnClaim,
            uint48 recallDelay
        ) = faucet.bountyParams(0);

        assertEq(bountyStartAmt, 1666666660000000, "Bounty 0 startAmt");
        assertEq(creator, address(faucet), "Bounty 0 creator should be faucet");
        assertEq(editor, address(faucet), "Bounty 0 editor should be faucet");
        assertEq(bountyMultiplier, 11500, "Bounty 0 multiplier");
        assertEq(maxRounds, 35, "Bounty 0 maxRounds");
        assertEq(bountyToken, OP_TOKEN, "Bounty 0 token should be OP");
        assertTrue(recallOnClaim, "Bounty 0 should recall on claim");
    }

    // ============ Helper to get bounty fields ============

    function _getBounty(uint256 reportId) internal view returns (
        uint256 totalAmtDeposited,
        uint256 bountyStartAmt,
        uint256 bountyClaimed,
        uint256 start,
        uint256 forwardStartTime,
        uint256 roundLength,
        uint256 recallUnlockAt,
        address payable creator,
        address editor,
        address bountyToken,
        uint16 bountyMultiplier,
        uint16 maxRounds,
        bool claimed,
        bool recalled,
        bool timeType,
        bool recallOnClaim
    ) {
        return bountyContract.Bounty(reportId);
    }

    // ============ bountyAndPriceRequest Tests ============

    function testBountyAndPriceRequest_CreatesReportAndBounty() public {
        uint256 reportIdBefore = oracle.nextReportId();

        uint256 reportId = faucet.bountyAndPriceRequest(0);

        // Should create a new report
        assertEq(reportId, reportIdBefore, "Should return correct reportId");
        assertEq(oracle.nextReportId(), reportIdBefore + 1, "Oracle should have new report");

        // Check bounty was created
        (,,,,,,,,,address bountyToken,,uint16 maxRounds,,,,) = _getBounty(reportId);
        assertGt(maxRounds, 0, "Bounty should exist");
        assertEq(bountyToken, OP_TOKEN, "Bounty token should be OP");
    }

    function testBountyAndPriceRequest_UpdatesLastGameTime() public {
        uint256 timeBefore = faucet.lastGameTime(0);
        assertEq(timeBefore, 0, "lastGameTime should start at 0");

        faucet.bountyAndPriceRequest(0);

        assertEq(faucet.lastGameTime(0), block.timestamp, "lastGameTime should be updated");
    }

    function testBountyAndPriceRequest_EmitsGameCreated() public {
        uint256 expectedReportId = oracle.nextReportId();

        vm.expectEmit(true, true, false, false);
        emit BountyAndPriceRequest.GameCreated(expectedReportId, 0);

        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_RevertsBadGameId() public {
        // Games 0-5 are valid, 6+ are invalid
        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(6);

        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(7);

        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(255);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game0() public {
        uint256 startTime = block.timestamp;

        // First call should succeed
        faucet.bountyAndPriceRequest(0);

        // Immediate second call should fail
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);

        // Warp 2 minutes - still too early (game 0 timer is 3 minutes)
        vm.warp(startTime + 2 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);

        // Warp past timer (4 minutes total from start)
        vm.warp(startTime + 4 minutes);
        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game1() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(1);

        // Warp 9 minutes - still too early (game 1 timer is 10 minutes)
        vm.warp(block.timestamp + 9 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(1);

        // Warp past timer
        vm.warp(block.timestamp + 2 minutes);
        faucet.bountyAndPriceRequest(1);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game2() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(2);

        // Warp 59 minutes - still too early (game 2 timer is 1 hour)
        vm.warp(block.timestamp + 59 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(2);

        // Warp past timer
        vm.warp(block.timestamp + 2 minutes);
        faucet.bountyAndPriceRequest(2);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game3() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(3);

        // Warp 23 hours - still too early (game 3 timer is 24 hours)
        vm.warp(block.timestamp + 23 hours);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(3);

        // Warp past timer
        vm.warp(block.timestamp + 2 hours);
        faucet.bountyAndPriceRequest(3);
    }

    function testBountyAndPriceRequest_DifferentGamesIndependent() public {
        // Create game 0
        faucet.bountyAndPriceRequest(0);

        // Game 1 should still work (different game)
        faucet.bountyAndPriceRequest(1);

        // Game 0 should still be blocked
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_UsesCorrectBountyParams() public {
        // Game 0 and 1 use bountyParams[0]
        uint256 reportId0 = faucet.bountyAndPriceRequest(0);
        vm.warp(block.timestamp + 10 minutes);
        uint256 reportId1 = faucet.bountyAndPriceRequest(1);

        (, uint256 bountyStartAmt0,,,,,,,,, uint16 bountyMultiplier0,,,,,) = _getBounty(reportId0);
        (, uint256 bountyStartAmt1,,,,,,,,, uint16 bountyMultiplier1,,,,,) = _getBounty(reportId1);

        // Both should have same bounty params (from bountyParams[0])
        assertEq(bountyStartAmt0, bountyStartAmt1, "Same bounty start amount");
        assertEq(bountyMultiplier0, bountyMultiplier1, "Same multiplier");

        // Game 2 uses bountyParams[1] - different maxAmount
        vm.warp(block.timestamp + 1 hours);
        uint256 reportId2 = faucet.bountyAndPriceRequest(2);
        (, uint256 bountyStartAmt2,,,,,,,,,,,,,,) = _getBounty(reportId2);

        assertGt(bountyStartAmt2, bountyStartAmt0, "Game 2 should have higher bounty start");
    }

    function testBountyAndPriceRequest_AnyoneCanCall() public {
        uint256 startTime = block.timestamp;

        // Owner can call
        vm.prank(owner);
        faucet.bountyAndPriceRequest(0);

        // Warp past game timer (3 minutes)
        vm.warp(startTime + 4 minutes);

        // Random user can call
        vm.prank(randomUser);
        faucet.bountyAndPriceRequest(0);

        // Warp past game timer again
        vm.warp(startTime + 8 minutes);

        // Reporter can call
        vm.prank(reporter);
        faucet.bountyAndPriceRequest(0);
    }

    // ============ sweep Tests ============

    function testSweep_OnlyOwnerCanCall() public {
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.sweep(address(opToken), 1 ether);

        vm.prank(reporter);
        vm.expectRevert("not owner");
        faucet.sweep(address(opToken), 1 ether);
    }

    function testSweep_ERC20() public {
        uint256 faucetBalBefore = opToken.balanceOf(address(faucet));
        uint256 ownerBalBefore = opToken.balanceOf(owner);
        uint256 sweepAmount = 10 ether;

        vm.prank(owner);
        faucet.sweep(address(opToken), sweepAmount);

        assertEq(opToken.balanceOf(address(faucet)), faucetBalBefore - sweepAmount, "Faucet balance decreased");
        assertEq(opToken.balanceOf(owner), ownerBalBefore + sweepAmount, "Owner balance increased");
    }

    function testSweep_ETH() public {
        uint256 faucetBalBefore = address(faucet).balance;
        uint256 ownerBalBefore = owner.balance;
        uint256 sweepAmount = 1 ether;

        vm.prank(owner);
        faucet.sweep(address(0), sweepAmount);

        assertEq(address(faucet).balance, faucetBalBefore - sweepAmount, "Faucet ETH decreased");
        assertEq(owner.balance, ownerBalBefore + sweepAmount, "Owner ETH increased");
    }

    function testSweep_ETHFailsToRejectingContract() public {
        // Deploy owner as a contract that rejects ETH
        ETHRejecter rejecter = new ETHRejecter();

        // Create new faucet with rejecter as owner
        BountyAndPriceRequest faucetWithRejecter = new BountyAndPriceRequest(
            address(oracle),
            address(bountyContract),
            address(rejecter),
            5e14,
            15e17
        );
        vm.deal(address(faucetWithRejecter), 10 ether);

        vm.prank(address(rejecter));
        vm.expectRevert("eth transfer failed");
        faucetWithRejecter.sweep(address(0), 1 ether);
    }

    // ============ recallBounties Tests ============

    function testRecallBounties_OnlyOwnerCanCall() public {
        uint256[] memory reportIds = new uint256[](1);
        reportIds[0] = 1;

        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.recallBounties(reportIds);
    }

    function testRecallBounties_RecallsSingleBounty() public {
        // Create a game (which creates a bounty)
        uint256 reportId = faucet.bountyAndPriceRequest(0);

        // Get bounty info
        (,,,,,,,,,,,, , bool recalledBefore,,) = _getBounty(reportId);
        assertFalse(recalledBefore, "Bounty should not be recalled yet");

        uint256[] memory reportIds = new uint256[](1);
        reportIds[0] = reportId;

        // Warp past recall delay and recall
        vm.warp(block.timestamp + 1);

        vm.prank(owner);
        faucet.recallBounties(reportIds);

        // Check bounty was recalled
        (,,,,,,,,,,,, , bool recalledAfter,,) = _getBounty(reportId);
        assertTrue(recalledAfter, "Bounty should be recalled");
    }

    function testRecallBounties_RecallsMultipleBounties() public {
        // Create multiple games
        uint256 reportId0 = faucet.bountyAndPriceRequest(0);
        uint256 reportId1 = faucet.bountyAndPriceRequest(1);

        uint256[] memory reportIds = new uint256[](2);
        reportIds[0] = reportId0;
        reportIds[1] = reportId1;

        // Warp past recall delays
        vm.warp(block.timestamp + 1);

        vm.prank(owner);
        faucet.recallBounties(reportIds);

        // Check both bounties were recalled
        (,,,,,,,,,,,, , bool recalled0,,) = _getBounty(reportId0);
        (,,,,,,,,,,,, , bool recalled1,,) = _getBounty(reportId1);
        assertTrue(recalled0, "Bounty 0 should be recalled");
        assertTrue(recalled1, "Bounty 1 should be recalled");
    }

    function testRecallBounties_HandlesFailuresGracefully() public {
        // Create a bounty
        uint256 reportId = faucet.bountyAndPriceRequest(0);

        // Warp past recall delay and recall it manually first
        vm.warp(block.timestamp + 1);
        vm.prank(address(faucet));
        bountyContract.recallBounty(reportId);

        // Now try to recall again via faucet - should not revert due to try/catch
        uint256[] memory reportIds = new uint256[](2);
        reportIds[0] = reportId; // Already recalled
        reportIds[1] = 999; // Non-existent bounty

        // Should not revert
        vm.prank(owner);
        faucet.recallBounties(reportIds);
    }

    function testRecallBounties_EmptyArraySucceeds() public {
        uint256[] memory reportIds = new uint256[](0);

        vm.prank(owner);
        faucet.recallBounties(reportIds);
    }

    // ============ receive() Tests ============

    function testReceive_AcceptsETH() public {
        uint256 balBefore = address(faucet).balance;

        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        (bool success,) = address(faucet).call{value: 1 ether}("");

        assertTrue(success, "Should accept ETH");
        assertEq(address(faucet).balance, balBefore + 1 ether, "Balance should increase");
    }

    // ============ Integration Tests ============

    function testIntegration_FullFlow() public {
        // 1. Create a game
        uint256 reportId = faucet.bountyAndPriceRequest(0);

        // 2. Warp past the bounty's forwardStartTime (10 seconds)
        vm.warp(block.timestamp + 15);

        // 3. Get state hash from oracle
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // 4. Reporter submits initial report through bounty contract
        (uint256 exactToken1Report,,,,,,,,,,,) = oracle.reportMeta(reportId);
        uint256 amount1 = exactToken1Report;
        uint256 amount2 = 6 * 1e6; // ~$6 worth of USDC for 0.002 ETH

        uint256 reporterOPBefore = opToken.balanceOf(reporter);

        vm.prank(reporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);

        // 5. Reporter should have received bounty
        uint256 reporterOPAfter = opToken.balanceOf(reporter);
        assertGt(reporterOPAfter, reporterOPBefore, "Reporter should receive OP bounty");

        // 6. Bounty should be recalled to faucet (recallOnClaim = true)
        (,,,,,,,,,,,, bool claimed, bool recalled,,) = _getBounty(reportId);
        assertTrue(claimed, "Bounty should be claimed");
        assertTrue(recalled, "Bounty should be auto-recalled");
    }

    function testIntegration_MultipleGamesOverTime() public {
        // Create all 4 game types
        uint256 reportId0 = faucet.bountyAndPriceRequest(0);
        uint256 reportId1 = faucet.bountyAndPriceRequest(1);
        uint256 reportId2 = faucet.bountyAndPriceRequest(2);
        uint256 reportId3 = faucet.bountyAndPriceRequest(3);

        // Verify all bounties were created
        (,,,,,,,,,,, uint16 maxRounds0,,,,) = _getBounty(reportId0);
        (,,,,,,,,,,, uint16 maxRounds1,,,,) = _getBounty(reportId1);
        (,,,,,,,,,,, uint16 maxRounds2,,,,) = _getBounty(reportId2);
        (,,,,,,,,,,, uint16 maxRounds3,,,,) = _getBounty(reportId3);
        assertTrue(maxRounds0 > 0, "Game 0 bounty exists");
        assertTrue(maxRounds1 > 0, "Game 1 bounty exists");
        assertTrue(maxRounds2 > 0, "Game 2 bounty exists");
        assertTrue(maxRounds3 > 0, "Game 3 bounty exists");

        // Warp 24+ hours and create another round
        vm.warp(block.timestamp + 25 hours);

        uint256 reportId0_2 = faucet.bountyAndPriceRequest(0);
        uint256 reportId1_2 = faucet.bountyAndPriceRequest(1);
        uint256 reportId2_2 = faucet.bountyAndPriceRequest(2);
        uint256 reportId3_2 = faucet.bountyAndPriceRequest(3);

        // All should be new report IDs
        assertGt(reportId0_2, reportId3, "New report IDs should be higher");
    }
}

// Contract that rejects ETH transfers
contract ETHRejecter {
    // No receive() or fallback(), so ETH transfers will fail
}
