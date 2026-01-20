// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ReferralRewardsDistributor} from "../src/ReferralRewardsDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//  Simple Mock Token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Test Token", "TEST") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

contract ReferralRewardsDistributorTest is Test {
    ReferralRewardsDistributor public distributor;
    MockERC20 public token;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 public constant TOTAL_ALLOCATION = 1000e18;

    // Merkle Tree Data
    bytes32[] public leaves;
    bytes32 public merkleRoot;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy contracts
        distributor = new ReferralRewardsDistributor();
        token = new MockERC20();

        // ----------------------------------------------------
        // Generate Merkle Tree (Simple implementation for test)
        // ----------------------------------------------------
        // Leaf 0: User1, 100e18
        leaves.push(keccak256(abi.encodePacked(uint256(0), user1, uint256(100e18))));
        // Leaf 1: User2, 200e18
        leaves.push(keccak256(abi.encodePacked(uint256(1), user2, uint256(200e18))));
        // Leaf 2: User3, 300e18
        leaves.push(keccak256(abi.encodePacked(uint256(2), user3, uint256(300e18))));
        // Leaf 3: Dummy to make tree balanced (optional but good practice)
        leaves.push(keccak256(abi.encodePacked(uint256(3), address(0), uint256(0))));

        // Compute Root (Hashed pairwise)
        bytes32 h01 = _hashPair(leaves[0], leaves[1]);
        bytes32 h23 = _hashPair(leaves[2], leaves[3]);
        merkleRoot = _hashPair(h01, h23);
    }

    // Helper to hash pairs for Merkle Tree
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /* ========== TESTS: ADMIN ACTIONS ========== */

    function test_Admin_CreateCampaign_Separate() public {
        uint256 campaignId = distributor.createCampaign(
            address(token),
            merkleRoot,
            TOTAL_ALLOCATION,
            0 // no expiry
        );

        assertEq(campaignId, 1);

        // Check struct storage
        (
            address tokenAddr,
            bytes32 root,
            uint256 totalAlloc,
            uint256 totalFunded,
            uint256 totalClaimed,
            uint256 expiry,
            bool active
        ) = distributor.campaigns(campaignId);

        assertEq(tokenAddr, address(token));
        assertEq(root, merkleRoot);
        assertEq(totalAlloc, TOTAL_ALLOCATION);
        assertEq(totalFunded, 0); // Not funded yet
        assertEq(totalClaimed, 0);
        assertEq(expiry, 0);
        assertFalse(active); // Not active yet
    }

    function test_Admin_FundCampaign() public {
        // 1. Create
        uint256 campaignId = distributor.createCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0);

        // 2. Approve
        token.approve(address(distributor), TOTAL_ALLOCATION);

        // 3. Fund
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        (,,, uint256 totalFunded,,, bool active) = distributor.campaigns(campaignId);

        assertEq(totalFunded, TOTAL_ALLOCATION);
        assertTrue(active); // Should auto-activate
        assertEq(token.balanceOf(address(distributor)), TOTAL_ALLOCATION);
    }

    // *** THIS IS THE NEW APPROACH YOU ASKED ABOUT ***
    function test_Admin_CreateAndFund_Combined() public {
        // 1. Approve first
        token.approve(address(distributor), TOTAL_ALLOCATION);

        // 2. Call the combined function
        uint256 campaignId = distributor.createAndFundCampaign(
            address(token),
            merkleRoot,
            TOTAL_ALLOCATION,
            0,
            TOTAL_ALLOCATION // Funding amount
        );

        // 3. Verify everything happened in one go
        (,,, uint256 totalFunded,,, bool active) = distributor.campaigns(campaignId);

        assertEq(campaignId, 1);
        assertEq(totalFunded, TOTAL_ALLOCATION);
        assertTrue(active);
        assertEq(token.balanceOf(address(distributor)), TOTAL_ALLOCATION);
    }

    function test_Admin_UpdateCampaignStatus() public {
        // Create & Fund
        token.approve(address(distributor), TOTAL_ALLOCATION);
        uint256 campaignId =
            distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);

        // Deactivate
        distributor.updateCampaignStatus(campaignId, false);
        (,,,,,, bool active) = distributor.campaigns(campaignId);
        assertFalse(active);

        // Activate
        distributor.updateCampaignStatus(campaignId, true);
        (,,,,,, active) = distributor.campaigns(campaignId);
        assertTrue(active);
    }

    function test_Admin_WithdrawUnclaimed() public {
        uint256 expiry = block.timestamp + 1 days;

        // Create & Fund
        token.approve(address(distributor), TOTAL_ALLOCATION);
        uint256 campaignId =
            distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, expiry, TOTAL_ALLOCATION);

        // Fast forward past expiry
        vm.warp(expiry + 1);

        // Withdraw all (since none claimed)
        uint256 balanceBefore = token.balanceOf(owner);
        distributor.withdrawUnclaimed(campaignId, owner, TOTAL_ALLOCATION);
        uint256 balanceAfter = token.balanceOf(owner);

        assertEq(balanceAfter - balanceBefore, TOTAL_ALLOCATION);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_View_GetAllCampaigns() public {
        token.approve(address(distributor), TOTAL_ALLOCATION * 10);

        // Create Campaign 1
        distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);
        // Create Campaign 2
        distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);

        // Call the view function
        ReferralRewardsDistributor.Campaign[] memory list = distributor.getAllCampaigns();

        // Assertions
        assertEq(list.length, 2);
        // Verify index 0 contains ID 1
        assertEq(list[0].totalAllocation, TOTAL_ALLOCATION);
        // Verify index 1 contains ID 2
        assertEq(list[1].totalAllocation, TOTAL_ALLOCATION);
    }

    /* ========== TESTS: USER ACTIONS ========== */

    function test_User_Claim_Valid() public {
        // Setup Campaign
        token.approve(address(distributor), TOTAL_ALLOCATION);
        uint256 campaignId =
            distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);

        // Prepare Proof for User 1 (Index 0)
        // Proof path: sibling of 0 is 1, sibling of (01) is (23)
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1]; // Sibling of User 1
        proof[1] = _hashPair(leaves[2], leaves[3]); // Sibling of the Hash(0,1)

        // Action
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof);

        // Assertions
        assertEq(token.balanceOf(user1), 100e18);
        assertTrue(distributor.isClaimed(campaignId, 0));
        (,,,, uint256 totalClaimed,,) = distributor.campaigns(campaignId);
        assertEq(totalClaimed, 100e18);
    }

    function test_User_Claim_Revert_DoubleClaim() public {
        token.approve(address(distributor), TOTAL_ALLOCATION);
        uint256 campaignId =
            distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = _hashPair(leaves[2], leaves[3]);

        // 1. First Claim - Success
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof);

        // 2. Second Claim - Fail
        vm.prank(user1);
        vm.expectRevert("Already claimed"); // Match string in contract
        distributor.claim(campaignId, 0, user1, 100e18, proof);
    }

    function test_User_Claim_Revert_InvalidProof() public {
        token.approve(address(distributor), TOTAL_ALLOCATION);
        uint256 campaignId =
            distributor.createAndFundCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0, TOTAL_ALLOCATION);

        // Create Fake Proof
        bytes32[] memory badProof = new bytes32[](2);
        badProof[0] = bytes32(uint256(999999));
        badProof[1] = bytes32(uint256(888888));

        vm.prank(user1);
        vm.expectRevert("Invalid proof");
        distributor.claim(campaignId, 0, user1, 100e18, badProof);
    }

    function test_User_Claim_Revert_CampaignInactive() public {
        // Create but DON'T fund (so it stays inactive)
        uint256 campaignId = distributor.createCampaign(address(token), merkleRoot, TOTAL_ALLOCATION, 0);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1];
        proof[1] = _hashPair(leaves[2], leaves[3]);

        vm.prank(user1);
        vm.expectRevert("Campaign not active");
        distributor.claim(campaignId, 0, user1, 100e18, proof);
    }
}
