# SQUEEKSTR (SQKSTR)

A fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `SqueekstrToken` (`src/SqueekstrToken.sol`) |
| `name()` | `SQUEEKSTR` |
| `symbol()` | `SQKSTR` |
| `decimals()` | `18` |
| Total supply | `1,000,000,000` SQKSTR = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc `0.8.26`, optimizer on (200 runs), `bytecode_hash = "none"`, EVM `cancun` |

## Behaviour

- The constructor mints the whole supply once to `msg.sender` (the launch factory) and nothing else.
  There is no `mint`, no minter role, no owner, no upgrade path: the supply can never grow.
- Transfers are plain ERC-20 transfers. No fee, no tax, no reflection, no pause, no blocklist, no
  freeze. Every launch flow (factory to distributor, distributor to claimant, pool seed, swaps through
  the Uniswap v4 PoolManager, remainder to the requester) moves exactly the amount it says.
- `burn(uint256)` lets a holder destroy their own balance. There is no `burnFrom` and no privileged
  burn, so nobody can reduce someone else's balance.
- ERC-2612 `permit` (from OpenZeppelin `ERC20Permit`) lets holders grant allowances by signature.
  The EIP-712 domain name is `SQUEEKSTR`, version `1`.
- `transferFrom` moves tokens only from an account that approved the caller, with standard allowance
  accounting (an allowance of `type(uint256).max` is not decremented).

## Layout

```
foundry.toml                      compiler pins and build settings (solc 0.8.26, bytecode_hash none)
remappings.txt                    forge-std and @openzeppelin/contracts remappings
src/SqueekstrToken.sol            the token
script/DeploySqueekstrToken.s.sol reference deploy script (deploy() is testable without a broadcast)
test/SqueekstrToken.t.sol         unit and fuzz tests
lib/forge-std                     vendored forge-std 1.9.7 (src only, plain files)
lib/openzeppelin-contracts        vendored OpenZeppelin Contracts 5.1.0 (contracts only, plain files)
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Build and test

```
forge build
forge test
forge fmt --check
```

The tests read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel. Fuzz tests run with the default 256 runs; the seed is not pinned.

## Deployment parameters

The token takes no constructor arguments. Whoever sends the creation transaction receives the whole
supply. For the IMD launch that is the factory, which then:

- sends 10% of the supply to the launch's MerkleDistributor (the swarm's share);
- seeds the Uniswap v4 pool, paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), at fee
  `12500` (1.25%) and tick spacing `60`, with `economics.poolBps = 8000` (80% of the supply) at an
  opening market cap of `4500 IMD` for the whole supply (`initialMarketCapWei = 4500000000000000000000`);
- forwards the remaining 10% to `economics.remainderTo = 0x18e0a43cb0236c3e2e6f6f229fc2ca36299a4636`.

The launch manifest (`launch.json`) is written by the manifest step after this work is accepted and is
not part of this repository. Values for it:

- `token.contract`: `SqueekstrToken`
- `token.name`: `SQUEEKSTR`
- `token.symbol`: `SQKSTR`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: `[]` (no application contracts)

The deploy script in `script/` is a reviewable reference for a manual deployment on another chain or a
testnet. It does not read environment variables; `run()` broadcasts from whatever signer `forge script`
is given. Nothing in this repository holds or reads a key.

## After launch

There is nothing to configure. The token has no owner-settable values, no setters and no roles.

## Assumptions

- The requester wants a plain fixed-supply token: no tax, reflection, vesting, governance or admin
  powers were requested, so none are implemented.
- `burn` and `permit` are standard, non-privileged conveniences that do not change the requested
  supply or transfer rules. `burn` only ever shrinks the supply, and only for the caller's own balance.
- The ERC-20 implementation is OpenZeppelin Contracts 5.1.0, vendored unchanged.
- The constructor calls no other contract and requires no address to have code, so it deploys on an
  empty chain exactly as the launch checks run it.

## Operational responsibilities

- Nobody operates this token after deployment. There is no owner, pause, upgrade or recovery path.
  Tokens sent to a wrong address, to the token contract itself, or burned cannot be recovered.
- Holders are responsible for their own keys and for the allowances they grant, including by `permit`
  signatures. A permit signature is valid until its deadline or until the owner's nonce moves.
- The launch factory, distributor and pool are IMD's; their behaviour is outside this contract.

## Security notes

- No `selfdestruct`, `delegatecall` or `callcode` in the runtime; a test scans the reachable runtime
  bytecode for them.
- No owner, so there is no privileged call that can move or freeze a holder's balance; a test probes
  the common admin and mint selectors from both the deployer and a stranger.
- Slither was not run on this machine (not available in the task's toolchain). The contract has no
  initializer, upgrade path, library linking, `abi.encodePacked` of dynamic values, shifts or
  arbitrary `transferFrom` source, which are the detectors the verifier rejects on.
- Passing tests are not an audit. An independent adversarial review is still appropriate before the
  token is used to hold value.
