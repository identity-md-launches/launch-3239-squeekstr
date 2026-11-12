// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SqueekstrToken} from "../src/SqueekstrToken.sol";

/// @title Deploy script for SqueekstrToken
/// @notice The token takes no constructor arguments; whoever sends the creation transaction receives
///         the whole supply. The IMD launch deploys the token through its factory, so this script is
///         a reviewable reference for a manual deployment, not something the launch runs.
/// @dev `deploy()` holds the deployment logic so tests can call it directly without a broadcast or
///      any environment variable. `run()` only wraps it in a broadcast.
contract DeploySqueekstrToken is Script {
    /// @notice Deploys the token. The caller of this function's creation frame (the broadcaster in
    ///         `run()`, or the test contract when called directly) receives the whole supply.
    function deploy() public returns (SqueekstrToken token) {
        token = new SqueekstrToken();
    }

    function run() external returns (SqueekstrToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
