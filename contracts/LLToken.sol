// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/**
 * @title LLToken (LLT)
 * @notice LiquidLock DAO için governance/ödül token'ı.
 */
contract LLToken extends ERC20Votes {
    constructor() ERC20("LiquidLock Token", "LLT") ERC20Permit("LiquidLock Token") {
        _mint(msg.sender, 10_000_000 ether);
    }

    // OpenZeppelin ERC20Votes için gerekli override'lar
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}
