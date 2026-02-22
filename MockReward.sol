// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockReward {
    bool public shouldRevert;

    event MatchHandled(address winner, address loser, bool isDraw, uint256 roomId);

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function handleMatchResult(address winner, address loser, bool isDraw, uint256 roomId) external {
        if (shouldRevert) revert("Reward reverted");
        emit MatchHandled(winner, loser, isDraw, roomId);
    }
}