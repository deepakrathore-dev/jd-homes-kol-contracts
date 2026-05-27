// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AccessRoleManager
 * @notice Central access-control registry for the ReferralRewardsDistributor.
 *  - The owner has full control over everything (admin-only actions).
 *  - The owner can authorize additional "campaign managers" who are allowed
 *    to call createCampaign / fundCampaign on the distributor.
 *  - The owner is always implicitly a campaign manager.
 */
contract AccessRoleManager is Ownable {
    // account => can create/fund campaigns
    mapping(address => bool) public isCampaignManager;

    event CampaignManagerGranted(address indexed account);
    event CampaignManagerRevoked(address indexed account);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Authorize an account to create and fund campaigns.
     */
    function grantManager(address account) external onlyOwner {
        require(account != address(0), "Zero address");
        require(!isCampaignManager[account], "Already manager");
        isCampaignManager[account] = true;
        emit CampaignManagerGranted(account);
    }

    /**
     * @notice Revoke an account's permission to create and fund campaigns.
     */
    function revokeManager(address account) external onlyOwner {
        require(isCampaignManager[account], "Not a manager");
        isCampaignManager[account] = false;
        emit CampaignManagerRevoked(account);
    }

    /**
     * @notice True if the account may create/fund campaigns (owner or a granted manager).
     */
    function canManageCampaigns(address account) external view returns (bool) {
        return account == owner() || isCampaignManager[account];
    }
}
