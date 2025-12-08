// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ReferalRewardsDistributor
 * @notice
 *  - Admin can register multiple properties (assets) and for each property add multiple merkle root campaigns (root sets).
 *  - Each merkle-root campaign specifies the token to be used, an optional expiry timestamp, and an expected total allocation.
 *  - Admin funds campaigns by transferring ERC20 tokens to the contract (or contract accepts native ETH when token == address(0)).
 *  - Users claim by providing (propertyId, rootId, index, account, amount, merkleProof).
 *  - Claimed bitmap per property/root prevents double claims.
 *  - Admin can withdraw unclaimed funds after expiry.
 */
contract ReferalRewardsDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Campaign {
        address token; // token address
        bytes32 merkleRoot; // merkle root
        uint256 totalAllocation; // total allocated amount expected
        uint256 totalFunded; // total funded so far
        uint256 totalClaimed; // total claimed so far
        uint256 expiry; // unix timestamp, 0 = no expiry
        bool active; // whether campaign is active (claims allowed)
    }

    // propertyId => list of campaign ids
    mapping(uint256 => uint256[]) public propertyCampaigns;

    // global campaign id => Campaign
    mapping(uint256 => Campaign) public campaigns;
    uint256 public nextCampaignId;

    // claimed bitmap: campaignId => wordIndex => bits
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

    event CampaignCreated(
        uint256 indexed propertyId,
        uint256 indexed campaignId,
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocation,
        uint256 expiry
    );
    event CampaignFunded(uint256 indexed campaignId, address indexed token, uint256 amount, uint256 totalFunded);
    event Claimed(uint256 indexed campaignId, uint256 indexed index, address indexed account, uint256 amount);
    event CampaignClosed(uint256 indexed campaignId);
    event UnclaimedWithdrawn(uint256 indexed campaignId, address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {
        nextCampaignId = 1; // start ids at 1
    }

    /* ========== ADMIN ACTIONS ========== */

    /**
     * @notice Create a new merkle campaign for a property.
     * @param propertyId asset/property identifier
     * @param token token address (0x0 for native ETH)
     * @param merkleRoot merkle root for claims
     * @param totalAllocation expected total amount allocated for this campaign (informational but useful to check funding)
     * @param expiry unix timestamp after which admin may withdraw unclaimed funds (0 = no expiry)
     * @param active whether to enable claims immediately
     * @return campaignId created campaign id
     */
    function createCampaign(
        uint256 propertyId,
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocation,
        uint256 expiry,
        bool active
    ) external onlyOwner returns (uint256) {
        require(merkleRoot != bytes32(0), "zero merkle root");

        uint256 id = nextCampaignId++;
        campaigns[id] = Campaign({
            token: token,
            merkleRoot: merkleRoot,
            totalAllocation: totalAllocation,
            totalFunded: 0,
            totalClaimed: 0,
            expiry: expiry,
            active: active
        });

        propertyCampaigns[propertyId].push(id);

        emit CampaignCreated(propertyId, id, token, merkleRoot, totalAllocation, expiry);
        return id;
    }

    /**
     * @notice Fund campaign with ERC20 tokens (must have prior approve) or send native ETH via payable
     * @param campaignId campaign to fund
     * @param amount amount to fund
     */
    function fundCampaign(uint256 campaignId, uint256 amount) external payable onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "campaign not exists");
        require(amount > 0, "zero amount");

        require(msg.value == 0, "do not send ETH");
        IERC20(c.token).safeTransferFrom(msg.sender, address(this), amount);
        c.totalFunded += amount;
        emit CampaignFunded(campaignId, c.token, amount, c.totalFunded);
    }

    /**
     * @notice Activate or deactivate claims for a campaign
     */
    function setCampaignActive(uint256 campaignId, bool active) external onlyOwner {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "campaign not exists");
        c.active = active;
        if (!active) emit CampaignClosed(campaignId);
    }

    /**
     * @notice Update merkle root if you need to rotate the tree for a campaign.
     * WARNING: rotating root does NOT preserve claimed bitmap; use carefully.
     */
    function updateMerkleRoot(uint256 campaignId, bytes32 newRoot) external onlyOwner {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "campaign not exists");
        require(newRoot != bytes32(0), "zero root");
        c.merkleRoot = newRoot;
    }

    /* ========== USER ACTIONS ========== */

    /**
     * @notice Claim tokens for a given campaign
     * @param campaignId campaign id
     * @param index leaf index (used in leaf hash)
     * @param account claimant address (allows claiming on behalf)
     * @param amount amount allocated in leaf
     * @param merkleProof array of proof bytes32
     */
    function claim(uint256 campaignId, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
        external
        nonReentrant
    {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "campaign not exists");
        require(c.active, "campaign not active");
        require(!isClaimed(campaignId, index), "already claimed");
        require(amount > 0, "zero amount");

        // verify merkle proof (standard leaf: keccak256(abi.encodePacked(index, account, amount)))
        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        require(verifyProof(merkleProof, c.merkleRoot, node), "invalid proof");

        // mark claimed
        _setClaimed(campaignId, index);

        c.totalClaimed += amount;

        IERC20(c.token).safeTransfer(account, amount);

        emit Claimed(campaignId, index, account, amount);
    }

    /**
     * @notice Check whether the given index was already claimed
     */
    function isClaimed(uint256 campaignId, uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitMap[campaignId][wordIndex];
        uint256 mask = (1 << bitIndex);
        return (word & mask) != 0;
    }

    function _setClaimed(uint256 campaignId, uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[campaignId][wordIndex] |= (1 << bitIndex);
    }

    /* ========== ADMIN WITHDRAWALS ========== */

    /**
     * @notice Withdraw unclaimed funds from a campaign after expiry (or when owner deactivates and chooses to withdraw).
     * @param campaignId campaign to withdraw from
     * @param to recipient
     * @param amount amount to withdraw
     */
    function withdrawUnclaimed(uint256 campaignId, address to, uint256 amount) external onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.merkleRoot != bytes32(0), "campaign not exists");
        require(amount > 0, "zero amount");
        // allow only if expired (if expiry set) or if owner explicitly closed campaign
        require(c.expiry != 0 ? block.timestamp > c.expiry : true, "campaign not expired");

        uint256 available = c.totalFunded - c.totalClaimed;
        require(available >= amount, "insufficient unclaimed balance");

        c.totalFunded -= amount;

        IERC20(c.token).safeTransfer(to, amount);

        emit UnclaimedWithdrawn(campaignId, to, amount);
    }

    /* ========== HELPERS ========== */

    /**
     * @notice Merkle proof verify (calldata proof)
     */
    function verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) public pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];

            if (computedHash <= proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == root;
    }

    /* ========== VIEW HELPERS ========== */
    function getPropertyCampaigns(uint256 propertyId) external view returns (uint256[] memory) {
        return propertyCampaigns[propertyId];
    }

    // receive to accept native ETH funding
    receive() external payable {}

    fallback() external payable {}
}
