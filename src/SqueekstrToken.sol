// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SQUEEKSTR (SQKSTR)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 SQKSTR (18 decimals) is minted
///         once, in the constructor, to the deployer. There is no owner, no minter, no pause, no
///         blocklist and no fee on transfer: after deployment nobody holds any privilege over the
///         token, and the supply can only shrink through a holder burning their own balance.
/// @dev The contract name is the launch's Solidity identifier (`SqueekstrToken`); the token's own
///      name and symbol are what `name()` and `symbol()` return. ERC-2612 `permit` is included so
///      holders can grant allowances by signature. The constructor takes no arguments and calls no
///      other contract, so it deploys on an empty chain.
contract SqueekstrToken is ERC20, ERC20Permit {
    /// @notice Token name, as `name()` returns it.
    string public constant TOKEN_NAME = "SQUEEKSTR";
    /// @notice Token symbol, as `symbol()` returns it.
    string public constant TOKEN_SYMBOL = "SQKSTR";
    /// @notice Decimals, as `decimals()` returns them.
    uint8 public constant TOKEN_DECIMALS = 18;
    /// @notice The whole supply in minor units: 1,000,000,000 * 10^18. Minted once; never grows.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the entire supply to the deployer (`msg.sender`).
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` of the caller's own tokens. Only the holder can burn their balance;
    ///         there is no `burnFrom` and no privileged burn.
    /// @param amount The amount, in minor units, to burn from `msg.sender`.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
