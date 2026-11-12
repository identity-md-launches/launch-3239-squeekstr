// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SqueekstrToken} from "../src/SqueekstrToken.sol";
import {DeploySqueekstrToken} from "../script/DeploySqueekstrToken.s.sol";

/// @dev Deploys the token from a dedicated "factory" address so the tests mirror the launch: the
///      deployer (msg.sender of the constructor) holds the whole supply and nobody else holds anything.
contract SqueekstrTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    SqueekstrToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(FACTORY);
        token = new SqueekstrToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SQUEEKSTR");
        assertEq(token.symbol(), "SQKSTR");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "SQUEEKSTR");
        assertEq(token.TOKEN_SYMBOL(), "SQKSTR");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);

        // The mint is the single Transfer event from address(0) at construction.
        vm.recordLogs();
        vm.prank(ALICE);
        SqueekstrToken fresh = new SqueekstrToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event at construction");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), ALICE);
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
    }

    function test_deployScriptMintsToCaller() public {
        DeploySqueekstrToken script = new DeploySqueekstrToken();
        SqueekstrToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        // `new` inside the script makes the script contract the constructor's msg.sender.
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(FACTORY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(FACTORY, ALICE, 1_000 ether);
        assertTrue(token.transfer(ALICE, 1_000 ether));
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        token.transfer(BOB, 6 ether);
        assertEq(token.balanceOf(ALICE), 5 ether);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, BOB, 40 ether);
        assertTrue(token.approve(BOB, 40 ether));
        assertEq(token.allowance(ALICE, BOB), 40 ether);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 30 ether));
        assertEq(token.balanceOf(BOB), 30 ether);
        assertEq(token.balanceOf(ALICE), 70 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10 ether, 11 ether)
        );
        token.transferFrom(ALICE, BOB, 11 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 60 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit (ERC-2612)
    // ---------------------------------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndConsumesNonce() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 25 ether, 0, deadline));

        vm.prank(BOB);
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 25 ether);
        assertEq(token.nonces(owner), 1);

        // Replay with the same signature fails: the nonce moved on.
        vm.expectRevert();
        token.permit(owner, BOB, 25 ether, deadline, v, r, s);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _permitDigest(owner, BOB, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, BOB, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 key = 0xA11CE;
        address owner = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        // Signed by a different key than `owner`.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, _permitDigest(owner, BOB, 1 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(0xB0B), owner));
        token.permit(owner, BOB, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------------------------------

    function test_burnReducesHolderBalanceAndSupply() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, address(0), 4 ether);
        token.burn(4 ether);
        assertEq(token.balanceOf(ALICE), 6 ether);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
    }

    function test_burnRevertsBeyondBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.burn(11 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnOnlyTouchesCaller() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        // BOB holds nothing and cannot burn ALICE's tokens by any route.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 1));
        token.burn(1);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 1));
        assertFalse(ok, "no burnFrom exists");
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // No privilege, no supply growth
    // ---------------------------------------------------------------------------------------------

    function test_noAdminEntryPointExists() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "burnFrom(address,uint256)"
        ];
        address[2] memory callers = [FACTORY, address(0xBEEF)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], callers[c], type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_launchFlowsArriveWhole() public {
        // Factory -> distributor (10%), distributor -> claimant, factory -> requester remainder.
        uint256 swarm = SUPPLY / 10;
        vm.prank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        uint256 remainder = SUPPLY / 10;
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, remainder));
        assertEq(token.balanceOf(ALICE), remainder);
        assertEq(token.balanceOf(FACTORY), SUPPLY - swarm - remainder);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != FACTORY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(address from, uint256 held, uint256 amount) public {
        vm.assume(from != address(0) && from != FACTORY);
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(FACTORY);
        token.transfer(from, held);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_burnNeverGrowsSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.burn(burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(ALICE), held - burned);
    }
}
