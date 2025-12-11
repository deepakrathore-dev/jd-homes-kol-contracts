// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReferalRewardsDistributor} from "../src/ReferalRewardsDistributor.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MerkleHelper} from "./utils/MerkleHelper.sol";

contract ReferalRewardsDistributorTest is Test {
    ReferalRewardsDistributor public distributor;
    ERC20Mock public token;
    using MerkleHelper for MerkleHelper.Leaf[];

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 public constant PROPERTY_ID = 1;
    uint256 public constant TOTAL_ALLOCATION = 1000e18;

    bytes32 public merkleRoot;
    MerkleHelper.Leaf[] public leaves;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy contracts
        distributor = new ReferalRewardsDistributor();
        token = new ERC20Mock();

        // Setup merkle tree with test data
        leaves.push(MerkleHelper.Leaf({index: 0, account: user1, amount: 100e18}));
        leaves.push(MerkleHelper.Leaf({index: 1, account: user2, amount: 200e18}));
        leaves.push(MerkleHelper.Leaf({index: 2, account: user3, amount: 300e18}));

        // Build merkle tree root
        merkleRoot = leaves.computeMerkleRoot();
    }

    /* ========== ADMIN TESTS ========== */

    function test_Admin_CreateCampaign() public {
        uint256 campaignId = distributor.createCampaign(
            PROPERTY_ID,
            address(token),
            merkleRoot,
            TOTAL_ALLOCATION,
            0, // no expiry
            true // active
        );

        assertEq(campaignId, 1);

        (address tokenAddr, bytes32 root, uint256 totalAlloc,,, uint256 expiry, bool active) =
            distributor.campaigns(campaignId);

        assertEq(tokenAddr, address(token));
        assertEq(root, merkleRoot);
        assertEq(totalAlloc, TOTAL_ALLOCATION);
        assertEq(expiry, 0);
        assertTrue(active);

        // Check property campaigns
        uint256[] memory propertyCampaigns = distributor.getPropertyCampaigns(PROPERTY_ID);
        assertEq(propertyCampaigns.length, 1);
        assertEq(propertyCampaigns[0], campaignId);
    }

    function test_Admin_FundCampaign() public {
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        // Mint tokens to owner
        token.mint(owner, TOTAL_ALLOCATION);

        // Approve and fund
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        (,,, uint256 totalFunded,,,) = distributor.campaigns(campaignId);
        assertEq(totalFunded, TOTAL_ALLOCATION);
        assertEq(token.balanceOf(address(distributor)), TOTAL_ALLOCATION);
    }

    function test_Admin_SetCampaignActive() public {
        uint256 campaignId = distributor.createCampaign(
            PROPERTY_ID,
            address(token),
            merkleRoot,
            TOTAL_ALLOCATION,
            0,
            false // inactive
        );

        // Activate
        distributor.setCampaignActive(campaignId, true);

        (,,,,,, bool active) = distributor.campaigns(campaignId);
        assertTrue(active);

        // Deactivate
        distributor.setCampaignActive(campaignId, false);

        (,,,,,, active) = distributor.campaigns(campaignId);
        assertFalse(active);
    }

    function test_Admin_WithdrawUnclaimed() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, expiry, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // Claim only for user1
        bytes32[] memory proof = MerkleHelper.generateProof(leaves, 0);
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof);

        // Fast forward past expiry
        vm.warp(expiry + 1);

        // Withdraw unclaimed
        uint256 unclaimed = TOTAL_ALLOCATION - 100e18;
        distributor.withdrawUnclaimed(campaignId, owner, unclaimed);

        assertEq(token.balanceOf(owner), unclaimed);
        assertEq(token.balanceOf(address(distributor)), 0); // Only claimed amount remains
    }

    function test_Admin_MultipleProperties() public {
        // Create campaign for property 1
        uint256 campaignId1 = distributor.createCampaign(1, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        // Create campaign for property 2
        bytes32 merkleRoot2 = bytes32(uint256(999));
        uint256 campaignId2 = distributor.createCampaign(2, address(token), merkleRoot2, TOTAL_ALLOCATION * 2, 0, true);

        // Check property campaigns
        uint256[] memory prop1Campaigns = distributor.getPropertyCampaigns(1);
        uint256[] memory prop2Campaigns = distributor.getPropertyCampaigns(2);

        assertEq(prop1Campaigns.length, 1);
        assertEq(prop1Campaigns[0], campaignId1);

        assertEq(prop2Campaigns.length, 1);
        assertEq(prop2Campaigns[0], campaignId2);
    }

    /* ========== USER TESTS ========== */
    function test_User_ClaimSingle() public {
        // Create and fund campaign
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // Generate proof for user1
        bytes32[] memory proof = MerkleHelper.generateProof(leaves, 0);

        // Claim for user1
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof);

        // Check balances
        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token.balanceOf(address(distributor)), TOTAL_ALLOCATION - 100e18);

        // Check claimed status
        assertTrue(distributor.isClaimed(campaignId, 0));

        // Check campaign stats
        (,,,, uint256 totalClaimed,,) = distributor.campaigns(campaignId);
        assertEq(totalClaimed, 100e18);
    }

    function test_User_ClaimMultipleUsers() public {
        // Create and fund campaign
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // Claim for user1
        bytes32[] memory proof1 = MerkleHelper.generateProof(leaves, 0);
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof1);

        // Claim for user2
        bytes32[] memory proof2 = MerkleHelper.generateProof(leaves, 1);
        vm.prank(user2);
        distributor.claim(campaignId, 1, user2, 200e18, proof2);

        // Claim for user3
        bytes32[] memory proof3 = MerkleHelper.generateProof(leaves, 2);
        vm.prank(user3);
        distributor.claim(campaignId, 2, user3, 300e18, proof3);

        // Check balances
        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token.balanceOf(user2), 200e18);
        assertEq(token.balanceOf(user3), 300e18);
        assertEq(token.balanceOf(address(distributor)), TOTAL_ALLOCATION - 600e18);

        // Check all claimed
        assertTrue(distributor.isClaimed(campaignId, 0));
        assertTrue(distributor.isClaimed(campaignId, 1));
        assertTrue(distributor.isClaimed(campaignId, 2));

        // Check total claimed
        (,,,, uint256 totalClaimed,,) = distributor.campaigns(campaignId);
        assertEq(totalClaimed, 600e18);
    }

    function test_User_ClaimRevert_InvalidProof() public {
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // Try to claim with invalid proof
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(uint256(12345));

        vm.prank(user1);
        vm.expectRevert("invalid proof");
        distributor.claim(campaignId, 0, user1, 100e18, invalidProof);
    }

    function test_User_ClaimRevert_InvalidAddress() public {
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // Try to claim with invalid proof
        bytes32[] memory proof = MerkleHelper.generateProof(leaves, 1);
        address maliciousUser = address(0x4);
        vm.prank(user1);
        vm.expectRevert("invalid proof");
        distributor.claim(campaignId, 1, maliciousUser, 200e18, proof);
    }

    function test_User_ClaimRevert_AlreadyClaimed() public {
        uint256 campaignId =
            distributor.createCampaign(PROPERTY_ID, address(token), merkleRoot, TOTAL_ALLOCATION, 0, true);

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        // First claim
        bytes32[] memory proof = MerkleHelper.generateProof(leaves, 0);
        vm.prank(user1);
        distributor.claim(campaignId, 0, user1, 100e18, proof);

        // Try to claim again
        vm.prank(user1);
        vm.expectRevert("already claimed");
        distributor.claim(campaignId, 0, user1, 100e18, proof);
    }

    function test_User_ClaimRevert_CampaignNotActive() public {
        uint256 campaignId = distributor.createCampaign(
            PROPERTY_ID,
            address(token),
            merkleRoot,
            TOTAL_ALLOCATION,
            0,
            false // inactive
        );

        token.mint(owner, TOTAL_ALLOCATION);
        token.approve(address(distributor), TOTAL_ALLOCATION);
        distributor.fundCampaign(campaignId, TOTAL_ALLOCATION);

        bytes32[] memory proof = MerkleHelper.generateProof(leaves, 0);

        vm.prank(user1);
        vm.expectRevert("campaign not active");
        distributor.claim(campaignId, 0, user1, 100e18, proof);
    }
}
