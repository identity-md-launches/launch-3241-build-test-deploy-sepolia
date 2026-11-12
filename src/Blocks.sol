// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Arbitrum's system precompile, at `address(100)` on every Arbitrum chain (Robinhood Chain is one).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

/// @title One place to read the chain's own block number and block hash
/// @notice On an Arbitrum Orbit chain `block.number` is the parent chain's number, so a contract that
/// seeds a draw from "a later block hash" must read the L2's own numbers from `ArbSys`. Every
/// function is internal, so the compiler inlines it and the bytecode needs no linking.
library Blocks {
    IArbSys internal constant ARB_SYS = IArbSys(address(100));

    function number(bool arbitrum) internal view returns (uint256) {
        return arbitrum ? ARB_SYS.arbBlockNumber() : block.number;
    }

    /// @dev Zero when the hash is no longer available (older than 256 blocks, or not yet mined).
    function hash(uint256 blockNumber, bool arbitrum) internal view returns (bytes32) {
        if (!arbitrum) return blockhash(blockNumber);
        if (blockNumber >= ARB_SYS.arbBlockNumber()) return bytes32(0);
        try ARB_SYS.arbBlockHash(blockNumber) returns (bytes32 h) {
            return h;
        } catch {
            return bytes32(0);
        }
    }
}
