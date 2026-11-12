// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SqueekstrToken} from "../src/SqueekstrToken.sol";

/// @dev Deploys the token from inside a contract with CREATE2, the way the launch factory does.
contract Create2Deployer {
    function deploy(bytes32 salt) external returns (SqueekstrToken token) {
        token = new SqueekstrToken{salt: salt}();
    }
}

/// @notice Edge and failure paths the main suite does not reach: zero addresses on every entry
///         point, boundaries at zero / one wei / the full supply / uint256 max, allowance arithmetic,
///         and every way a permit signature can be wrong.
contract SqueekstrTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    uint256 internal constant OWNER_KEY = 0x5EED;
    address internal owner;

    SqueekstrToken internal token;

    function setUp() public {
        vm.prank(FACTORY);
        token = new SqueekstrToken();
        owner = vm.addr(OWNER_KEY);
        vm.prank(FACTORY);
        token.transfer(owner, 1_000 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    function test_create2DeployMintsToDeployingContract() public {
        Create2Deployer deployer = new Create2Deployer();
        SqueekstrToken t = deployer.deploy(bytes32(uint256(7)));
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(address(deployer)), SUPPLY);
        assertEq(t.balanceOf(address(this)), 0);
        // Same salt twice collides: the token cannot be re-deployed at the same address to re-mint.
        vm.expectRevert();
        deployer.deploy(bytes32(uint256(7)));
    }

    function test_eip712DomainFields() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
            token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "SQUEEKSTR");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SQUEEKSTR"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers at the edges
    // ---------------------------------------------------------------------------------------------

    function test_transferWholeSupplyThenOneWeiMoreReverts() public {
        uint256 rest = token.balanceOf(FACTORY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(BOB, rest));
        assertEq(token.balanceOf(FACTORY), 0);
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, 0, 1));
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(BOB) + token.balanceOf(owner), SUPPLY);
    }

    function test_transferExactBalanceSucceedsOneMoreReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 1_000 ether, 1_000 ether + 1)
        );
        token.transfer(BOB, 1_000 ether + 1);
        vm.prank(owner);
        token.transfer(BOB, 1_000 ether);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(BOB), 1_000 ether);
    }

    function test_transferUint256MaxReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, SUPPLY - 1_000 ether, type(uint256).max
            )
        );
        token.transfer(BOB, type(uint256).max);
    }

    function test_selfTransferKeepsBalance() public {
        vm.prank(owner);
        assertTrue(token.transfer(owner, 400 ether));
        assertEq(token.balanceOf(owner), 1_000 ether);
        // Self transfer beyond balance still reverts.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 1_000 ether, 1_001 ether)
        );
        token.transfer(owner, 1_001 ether);
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferToTokenContractIsNotBlockedButIsStuck() public {
        vm.prank(owner);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances at the edges
    // ---------------------------------------------------------------------------------------------

    function test_approveZeroSpenderReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_approveOverwritesNotAdds() public {
        vm.startPrank(owner);
        token.approve(BOB, 10 ether);
        token.approve(BOB, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(owner, BOB), 3 ether);
        vm.prank(owner);
        token.approve(BOB, 0);
        assertEq(token.allowance(owner, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(owner, BOB, 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(owner);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(owner, address(0), 1 ether);
        assertEq(token.allowance(owner, BOB), 10 ether, "a reverted transferFrom must not spend allowance");
    }

    function test_transferFromAllowanceOkButBalanceShortReverts() public {
        vm.prank(owner);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 1_000 ether, 1_000 ether + 1)
        );
        token.transferFrom(owner, CAROL, 1_000 ether + 1);
        assertEq(token.balanceOf(owner), 1_000 ether);
        assertEq(token.balanceOf(CAROL), 0);
    }

    function test_transferFromExactAllowanceDrainsToZero() public {
        vm.prank(owner);
        token.approve(BOB, 7 ether);
        vm.prank(BOB);
        token.transferFrom(owner, CAROL, 7 ether);
        assertEq(token.allowance(owner, BOB), 0);
        assertEq(token.balanceOf(CAROL), 7 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(owner, CAROL, 1);
    }

    function test_allowanceMaxMinusOneIsDecremented() public {
        vm.prank(owner);
        token.approve(BOB, type(uint256).max - 1);
        vm.prank(BOB);
        token.transferFrom(owner, CAROL, 1);
        assertEq(token.allowance(owner, BOB), type(uint256).max - 2);
    }

    function test_selfTransferFromStillNeedsAllowance() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, owner, 0, 1));
        token.transferFrom(owner, BOB, 1);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(owner, CAROL, 0));
        assertEq(token.balanceOf(owner), 1_000 ether);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(owner);
        token.approve(BOB, 5 ether);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1 ether));
        token.transferFrom(owner, CAROL, 1 ether);
        assertEq(token.allowance(owner, BOB), 5 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Burn at the edges
    // ---------------------------------------------------------------------------------------------

    function test_burnZeroIsANoOp() public {
        vm.prank(BOB);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnWholeSupply() public {
        vm.prank(owner);
        token.burn(1_000 ether);
        vm.prank(FACTORY);
        token.burn(SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_burnDoesNotSpendAllowanceOrTouchOthers() public {
        vm.prank(owner);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 10 ether));
        token.burn(10 ether);
        assertEq(token.allowance(owner, BOB), 10 ether);
        assertEq(token.balanceOf(owner), 1_000 ether);
    }

    function test_burnUint256MaxReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, 1_000 ether, type(uint256).max
            )
        );
        token.burn(type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Permit failure paths
    // ---------------------------------------------------------------------------------------------

    function _digest(address o, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, o, spender, value, nonce, deadline))
            )
        );
    }

    function test_permitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 5 ether);
    }

    function test_permitExpiresOneSecondAfterDeadline() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitSignedForOtherSpenderReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, CAROL, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, CAROL), 0);
    }

    function test_permitWithAlteredValueReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, BOB, 6 ether, deadline, v, r, s);
    }

    function test_permitWithFutureNonceReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 1, deadline));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitHighSMalleatedSignatureReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, BOB, 5 ether, deadline, flippedV, r, highS);
        // The original still works once, then is spent.
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitWithInvalidVReverts() public {
        uint256 deadline = block.timestamp + 1;
        (, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, BOB, 5 ether, deadline, 29, r, s);
    }

    function test_permitZeroSignatureCannotApproveForZeroOwner() public {
        // ecrecover on garbage yields address(0); OZ rejects it rather than matching owner == 0.
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), BOB, 5 ether, block.timestamp, 27, bytes32(0), bytes32(0));
        assertEq(token.allowance(address(0), BOB), 0);
    }

    function test_permitToZeroSpenderReverts() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, address(0), 5 ether, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "the reverted permit must not consume the nonce");
    }

    function test_permitSignatureNotValidOnOtherChain() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "domain separator must follow the chain id");
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
    }

    function test_permitSignatureNotValidOnAnotherDeployment() public {
        vm.prank(FACTORY);
        SqueekstrToken other = new SqueekstrToken();
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(owner, BOB, 5 ether, deadline, v, r, s);
    }

    function test_permitSequentialNoncesAndOverwrite() public {
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 5 ether, 0, deadline));
        token.permit(owner, BOB, 5 ether, deadline, v, r, s);
        (v, r, s) = vm.sign(OWNER_KEY, _digest(owner, BOB, 1 ether, 1, deadline));
        token.permit(owner, BOB, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, BOB), 1 ether, "permit sets, it does not add");
        assertEq(token.nonces(owner), 2);
    }

    function test_permitDoesNotMoveBalances() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(owner, BOB, type(uint256).max, 0, deadline));
        token.permit(owner, BOB, type(uint256).max, deadline, v, r, s);
        assertEq(token.balanceOf(owner), 1_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        vm.prank(BOB);
        token.transferFrom(owner, BOB, 1_000 ether);
        assertEq(token.allowance(owner, BOB), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Stateless fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromSpendsExactAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        amount = bound(amount, 0, 1_000 ether);
        vm.prank(owner);
        token.approve(BOB, allowance);
        vm.prank(BOB);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowance, amount)
            );
            token.transferFrom(owner, CAROL, amount);
            assertEq(token.allowance(owner, BOB), allowance);
            assertEq(token.balanceOf(owner), 1_000 ether);
        } else {
            assertTrue(token.transferFrom(owner, CAROL, amount));
            assertEq(token.allowance(owner, BOB), allowance - amount);
            assertEq(token.balanceOf(CAROL), amount);
            assertEq(token.balanceOf(owner), 1_000 ether - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferBetweenThirdPartiesDoesNotTouchOthers(address from, address to, uint256 amount) public {
        from = address(uint160(bound(uint160(from), 1, type(uint160).max)));
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        vm.assume(from != FACTORY && from != owner && to != FACTORY && to != owner);
        amount = bound(amount, 0, 1_000 ether);
        vm.prank(FACTORY);
        token.transfer(from, amount);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        token.transfer(to, amount);
        if (from == to) {
            assertEq(token.balanceOf(to), toBefore);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(from), 0);
        }
        assertEq(token.balanceOf(owner), 1_000 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1_000 ether - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_permitRoundTrip(uint256 key, address spender, uint256 value, uint256 deadline) public {
        key = bound(key, 1, SECP256K1_N - 1);
        address signer = vm.addr(key);
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        uint256 nonce = token.nonces(signer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(signer, spender, value, nonce, deadline));
        token.permit(signer, spender, value, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), value);
        assertEq(token.nonces(signer), nonce + 1);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(signer, spender, value, deadline, v, r, s);
    }
}
