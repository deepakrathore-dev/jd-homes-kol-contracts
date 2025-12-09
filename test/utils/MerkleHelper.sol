// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MerkleHelper {
    struct Leaf {
        uint256 index;
        address account;
        uint256 amount;
    }

    function computeMerkleRoot(Leaf[] memory _leaves) internal pure returns (bytes32) {
        uint256 numLeaves = _leaves.length;
        require(numLeaves > 0, "empty leaves");

        uint256 depth = 0;
        uint256 temp = numLeaves;
        while (temp > 1) {
            temp >>= 1;
            depth++;
        }
        if ((1 << depth) < numLeaves) depth++;

        bytes32[] memory leafHashes = new bytes32[](1 << depth);
        for (uint256 i = 0; i < numLeaves; i++) {
            leafHashes[i] = keccak256(abi.encodePacked(_leaves[i].index, _leaves[i].account, _leaves[i].amount));
        }
        for (uint256 i = numLeaves; i < (1 << depth); i++) {
            leafHashes[i] = bytes32(0);
        }

        bytes32[] memory currentLevel = leafHashes;
        uint256 currentLevelSize = 1 << depth;

        while (currentLevelSize > 1) {
            bytes32[] memory nextLevel = new bytes32[](currentLevelSize / 2);
            for (uint256 i = 0; i < currentLevelSize / 2; i++) {
                bytes32 left = currentLevel[i * 2];
                bytes32 right = currentLevel[i * 2 + 1];

                nextLevel[i] = (left <= right)
                    ? keccak256(abi.encodePacked(left, right))
                    : keccak256(abi.encodePacked(right, left));
            }
            currentLevel = nextLevel;
            currentLevelSize /= 2;
        }
        return currentLevel[0];
    }

    function generateProof(Leaf[] memory _leaves, uint256 leafIndex) internal pure returns (bytes32[] memory proof) {
        require(leafIndex < _leaves.length, "invalid leaf index");

        uint256 numLeaves = _leaves.length;

        uint256 depth = 0;
        uint256 temp = numLeaves;
        while (temp > 1) {
            temp >>= 1;
            depth++;
        }
        if ((1 << depth) < numLeaves) depth++;

        bytes32[] memory leafHashes = new bytes32[](1 << depth);
        for (uint256 i = 0; i < numLeaves; i++) {
            leafHashes[i] = keccak256(abi.encodePacked(_leaves[i].index, _leaves[i].account, _leaves[i].amount));
        }
        for (uint256 i = numLeaves; i < (1 << depth); i++) {
            leafHashes[i] = bytes32(0);
        }

        bytes32[][] memory tree = new bytes32[][](depth + 1);
        tree[0] = leafHashes;

        uint256 currentSize = 1 << depth;

        for (uint256 level = 0; level < depth; level++) {
            bytes32[] memory nextLevel = new bytes32[](currentSize / 2);
            for (uint256 i = 0; i < currentSize / 2; i++) {
                bytes32 left = tree[level][i * 2];
                bytes32 right = tree[level][i * 2 + 1];

                nextLevel[i] = (left <= right)
                    ? keccak256(abi.encodePacked(left, right))
                    : keccak256(abi.encodePacked(right, left));
            }
            tree[level + 1] = nextLevel;
            currentSize /= 2;
        }

        proof = new bytes32[](depth);
        uint256 index = leafIndex;
        for (uint256 level = 0; level < depth; level++) {
            uint256 siblingIndex = index ^ 1;
            proof[level] = tree[level][siblingIndex];
            index /= 2;
        }
    }
}
