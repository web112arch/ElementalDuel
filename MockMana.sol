// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockMana is Ownable {
    mapping(address => uint256) public manaBalance;

    event ManaMinted(address indexed to, uint256 amount);
    event ManaConsumed(address indexed from, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function mintMana(address to, uint256 amount) external onlyOwner {
        manaBalance[to] += amount;
        emit ManaMinted(to, amount);
    }

    function hasMana(address account, uint256 amount) external view returns (bool) {
        return manaBalance[account] >= amount;
    }

    function consumeMana(address account, uint256 amount) external {
        require(manaBalance[account] >= amount, "Not enough mana");
        manaBalance[account] -= amount;
        emit ManaConsumed(account, amount);
    }
}