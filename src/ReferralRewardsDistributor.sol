// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title ReferralRewardsDistributor
 * @notice
 *  - Admin can register multiple campaigns.
 *  - Includes two function to create campaigns, function createCampaign and fundCampaign for create and fund later one for combined "createAndFundCampaign" function for efficiency.
 */
contract ReferralRewardsDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MerkleProof for bytes32[];

    struct Campaign {
        address token; // ERC20 token address
        bytes32 merkleRoot; // Merkle root
        uint256 totalAllocation; // Expected total allocation
        uint256 totalFunded; // Actual funded amount
        uint256 totalClaimed; // Amount claimed
        bool active; // Is campaign open for claims
    }

    // Campaign ID starts at 1
    mapping(uint256 => Campaign) public campaigns;
    uint256 public nextCampaignId;

    // claimed bitmap: campaignId => wordIndex => bits
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

    event CampaignCreated(uint256 indexed campaignId, address token, bytes32 merkleRoot, uint256 totalAllocation);
    event CampaignFunded(uint256 indexed campaignId, address indexed token, uint256 amount, uint256 totalFunded);
    event Claimed(uint256 indexed campaignId, uint256 indexed index, address indexed account, uint256 amount);
    event CampaignStatusChanged(uint256 indexed campaignId, bool active);
    event UnclaimedWithdrawn(uint256 indexed campaignId, address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {
        nextCampaignId = 1;
    }

    /* ========== ADMIN ACTIONS ========== */

    /**
     * @notice Create a campaign without funding it yet.
     */
    function createCampaign(address token, bytes32 merkleRoot, uint256 totalAllocation)
        public
        onlyOwner
        returns (uint256)
    {
        require(token != address(0), "Invalid token address");
        require(merkleRoot != bytes32(0), "Zero merkle root");
        require(totalAllocation > 0, "Zero total allocation");

        uint256 id = nextCampaignId++;
        campaigns[id] = Campaign({
            token: token,
            merkleRoot: merkleRoot,
            totalAllocation: totalAllocation,
            totalFunded: 0,
            totalClaimed: 0,
            active: false
        });

        emit CampaignCreated(id, token, merkleRoot, totalAllocation);
        return id;
    }

    /**
     * @notice Fund an existing campaign.
     * @dev Requires prior ERC20 approval.
     */
    function fundCampaign(uint256 campaignId) public onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];

        require(c.merkleRoot != bytes32(0), "Campaign does not exist");
        require(!c.active, "Campaign already funded");
        require(c.totalFunded == 0, "Already funded");

        uint256 amount = c.totalAllocation;
        require(amount > 0, "Zero allocation");

        IERC20(c.token).safeTransferFrom(msg.sender, address(this), amount);

        c.totalFunded = amount;
        c.active = true;

        emit CampaignFunded(campaignId, c.token, amount, amount);
    }

    /**
     * @notice COMBINED APPROACH: Create and Fund in one call.
     * @dev This is the efficient approach. Requires prior ERC20 approval.
     */
    function createAndFundCampaign(address token, bytes32 merkleRoot, uint256 totalAllocation)
        external
        onlyOwner
        returns (uint256)
    {
        // 1. Create
        uint256 id = createCampaign(token, merkleRoot, totalAllocation);

        // 2. Fund
        fundCampaign(id);

        return id;
    }

    /**
     * @notice Manually toggle campaign status.
     */
    function updateCampaignStatus(uint256 campaignId, bool active) external onlyOwner {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "Campaign does not exist");
        c.active = active;
        if (!active) emit CampaignStatusChanged(campaignId, active);
    }

    /* ========== USER ACTIONS ========== */

    /**
     * @notice Claim tokens.
     */
    function claim(uint256 campaignId, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
        external
        nonReentrant
    {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "Campaign does not exist");
        require(c.active, "Campaign not active");
        require(!isClaimed(campaignId, index), "Already claimed");
        require(amount > 0, "Zero amount");
        require(c.totalClaimed + amount <= c.totalFunded, "Insufficient campaign funds");

        // Verify Merkle Proof
        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        require(merkleProof.verify(c.merkleRoot, node), "Invalid proof");

        // Mark as claimed
        _setClaimed(campaignId, index);

        // Update stats
        c.totalClaimed += amount;

        // Transfer tokens
        IERC20(c.token).safeTransfer(account, amount);

        emit Claimed(campaignId, index, account, amount);
    }

    /* ========== INTERNAL & VIEW HELPERS ========== */

    function isClaimed(uint256 campaignId, uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitMap[campaignId][wordIndex];
        return (word & (uint256(1) << bitIndex)) != 0;
    }

    function _setClaimed(uint256 campaignId, uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[campaignId][wordIndex] |= (uint256(1) << bitIndex);
    }

    /**
     * @notice Returns all campaigns.
     * @dev starting from ID 1
     */
    function getAllCampaigns() external view returns (Campaign[] memory) {
        uint256 count = nextCampaignId - 1;
        Campaign[] memory result = new Campaign[](count);

        // Map ID 1 -> Array Index 0
        for (uint256 i = 1; i <= count; i++) {
            result[i - 1] = campaigns[i];
        }

        return result;
    }

    /* ========== ADMIN WITHDRAWALS ========== */

    /**
     * @notice Withdraw unclaimed funds .
     */
    function withdrawUnclaimed(uint256 campaignId, address to, uint256 amount) external onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "Campaign does not exist");
        require(!c.active, "Campaign not active");

        uint256 available = c.totalFunded - c.totalClaimed;
        require(available >= amount, "Insufficient unclaimed balance");

        c.totalFunded -= amount;
        IERC20(c.token).safeTransfer(to, amount);

        emit UnclaimedWithdrawn(campaignId, to, amount);
    }

    /**
     * @notice Emergency recover any ERC20 (including campaign tokens if absolutely needed).
     */
    function emergencyRecoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
    }
}
