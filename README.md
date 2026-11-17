# PoC: `cleanupErc20sViaCall` leaves persistent, unbounded ERC20 allowances

Relay bug bounty report R-04. Run with Foundry (tested with forge 1.9.0):

```
forge test -vv
```

No setup, no network, no fork needed. All dependencies are vendored under `lib/`
(the router contracts are the unmodified sources from
`relayprotocol/relay-periphery` at commit `e221935`).

## What it proves (2/2 tests pass)

- **PRIMING** `test_allowancePersists_afterCleanupViaCall`: anyone can get the
  router to approve ANY address for ANY amount of ANY token — even while the
  router holds zero of it — and the allowance is never reset afterwards. The
  attacker calls `cleanupErc20sViaCall` with `amount = type(uint256).max`
  against an empty router; the max allowance is still present after the tx.
- **DRAIN** `test_staleAllowance_drainsInflightVictimFunds`: the full chain.
  The attacker first primes a max allowance (as above). Later, a victim's
  multicall routes 1,000 USDC through the router and invokes the attacker's
  venue; the venue pulls the router's whole in-flight balance via
  `transferFrom`. The attacker receives the victim's 1,000 USDC and the
  victim gets nothing back.

## Setup notes

- `RelayRouter` is the real contract; the USDC is a minimal mintable ERC20
  and the venue is a minimal contract that drains the router's balance
  through the stale allowance instead of swapping.
- The victim multicall precondition is explicit in the test: the victim's
  (or solver's) call list must include the venue. The attacker cannot inject
  a venue into a victim's signed call list — the venue must be one the
  victim/solver already routes through.
- Local test only; nothing here touches mainnet.
