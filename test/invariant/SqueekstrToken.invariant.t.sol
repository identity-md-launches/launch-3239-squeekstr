// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekstrToken} from "../../src/SqueekstrToken.sol";

/// @notice Drives the token with bounded random calls from a fixed set of actors and keeps an
///         independent ledger (ghosts) of what each balance, allowance and nonce must be.
contract SqueekstrHandler is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    SqueekstrToken public immutable token;
    uint256 public immutable initialSupply;

    uint256[] internal keys;
    address[] public actors;

    // Ghost ledger.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;
    uint256 public ghostBurned;
    uint256 public ghostMinted;

    // Call counters, so the run shows that each path, including the failing ones, was exercised.
    mapping(bytes32 => uint256) public calls;

    /// @dev True if any handler-observed state change disagreed with the ledger.
    bool public mismatch;

    constructor(SqueekstrToken token_, uint256[] memory keys_) {
        token = token_;
        initialSupply = token_.totalSupply();
        for (uint256 i; i < keys_.length; ++i) {
            keys.push(keys_[i]);
            actors.push(vm.addr(keys_[i]));
        }
        // actors[0] is the deployer and holds the whole supply.
        ghostBalance[actors[0]] = initialSupply;
        ghostMinted = initialSupply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _key(uint256 seed) internal view returns (uint256) {
        return keys[seed % keys.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[from];
        amount = bound(amount, 0, bal);
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        if (!ok) mismatch = true;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        calls["transfer"]++;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - bal);
        vm.prank(from);
        try token.transfer(to, bal + excess) {
            mismatch = true;
        } catch {}
        calls["transferTooMuch"]++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address o = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(o);
        if (!token.approve(spender, amount)) mismatch = true;
        ghostAllowance[o][spender] = amount;
        calls["approve"]++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 bal = ghostBalance[from];
        uint256 cap = allowed < bal ? allowed : bal;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        if (!token.transferFrom(from, to, amount)) mismatch = true;
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        calls["transferFrom"]++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        try token.transferFrom(from, to, allowed + excess) {
            mismatch = true;
        } catch {}
        calls["transferFromOverAllowance"]++;
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        token.burn(amount);
        ghostBalance[from] -= amount;
        ghostBurned += amount;
        calls["burn"]++;
    }

    function burnTooMuch(uint256 fromSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        uint256 bal = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - bal);
        vm.prank(from);
        try token.burn(bal + excess) {
            mismatch = true;
        } catch {}
        calls["burnTooMuch"]++;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 ttl) external {
        uint256 key = _key(ownerSeed);
        address o = vm.addr(key);
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + bound(ttl, 0, 365 days);
        uint256 nonce = ghostNonce[o];
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(o, spender, value, nonce, deadline));
        token.permit(o, spender, value, deadline, v, r, s);
        ghostNonce[o] = nonce + 1;
        ghostAllowance[o][spender] = value;
        calls["permit"]++;

        // The same signature never works twice.
        try token.permit(o, spender, value, deadline, v, r, s) {
            mismatch = true;
        } catch {}
    }

    function permitBySomeoneElse(uint256 ownerSeed, uint256 signerSeed, uint256 spenderSeed, uint256 value) external {
        uint256 ownerKey = _key(ownerSeed);
        uint256 signerKey = _key(signerSeed);
        if (ownerKey == signerKey) return;
        address o = vm.addr(ownerKey);
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(o, spender, value, ghostNonce[o], deadline));
        try token.permit(o, spender, value, deadline, v, r, s) {
            mismatch = true;
        } catch {}
        calls["permitBySomeoneElse"]++;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 30 days));
        calls["warp"]++;
    }

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
}

/// @notice Invariants over random call sequences: the fixed supply only ever shrinks, and only by
///         what holders burned; balances, allowances and nonces match an independent ledger; nobody
///         outside the actor set ever receives tokens.
contract SqueekstrTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SqueekstrToken internal token;
    SqueekstrHandler internal handler;

    function setUp() public {
        uint256[] memory keys = new uint256[](5);
        keys[0] = 0xFAC7; // the deployer
        keys[1] = 0xA11CE;
        keys[2] = 0xB0B;
        keys[3] = 0xCA201;
        keys[4] = 0xDA7E;

        vm.prank(vm.addr(keys[0]));
        token = new SqueekstrToken();
        handler = new SqueekstrHandler(token, keys);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = SqueekstrHandler.transfer.selector;
        selectors[1] = SqueekstrHandler.transferTooMuch.selector;
        selectors[2] = SqueekstrHandler.approve.selector;
        selectors[3] = SqueekstrHandler.transferFrom.selector;
        selectors[4] = SqueekstrHandler.transferFromOverAllowance.selector;
        selectors[5] = SqueekstrHandler.burn.selector;
        selectors[6] = SqueekstrHandler.burnTooMuch.selector;
        selectors[7] = SqueekstrHandler.permit.selector;
        selectors[8] = SqueekstrHandler.permitBySomeoneElse.selector;
        selectors[9] = SqueekstrHandler.warp.selector;
        selectors[10] = SqueekstrHandler.transfer.selector; // weight plain transfers double
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_supplyEqualsMintedMinusBurned() public view {
        assertEq(handler.ghostMinted(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned());
        assertLe(token.totalSupply(), SUPPLY, "supply grew");
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_balancesSumToSupplyAndMatchLedger() public view {
        uint256 n = handler.actorCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 bal = token.balanceOf(a);
            assertEq(bal, handler.ghostBalance(a), "balance differs from ledger");
            sum += bal;
        }
        // Every holder is an actor, so the actors' balances account for the whole supply.
        assertEq(sum, token.totalSupply(), "tokens exist outside the actor set");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_allowancesAndNoncesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address o = handler.actors(i);
            assertEq(token.nonces(o), handler.ghostNonce(o), "nonce differs from ledger");
            for (uint256 j; j < n; ++j) {
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s), "allowance differs from ledger");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_noUnexpectedSuccessOrFalseReturn() public view {
        assertFalse(handler.mismatch(), "a call that must revert succeeded, or a call returned false");
    }

    /// forge-config: default.invariant.runs = 64
    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "SQUEEKSTR");
        assertEq(token.symbol(), "SQKSTR");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }
}
