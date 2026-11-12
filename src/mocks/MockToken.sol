// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title The burnable test token Arms is bonded and paid in on Sepolia
/// @notice Plain ERC-20 with `burn(uint256)`. Its owner (the launch's `$owner`, never the factory)
/// mints; that is the one trusted role in the Sepolia deployment and it sits outside the core.
contract MockToken is ERC20, ERC20Burnable, Ownable {
    constructor(address owner_) ERC20("Arms Test Token", "ARMT") Ownable(owner_) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
