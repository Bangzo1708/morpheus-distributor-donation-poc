# Morpheus DistributorV2 — yield-token donation diverts MOR emissions (PoC)

Foundry proof of concept for a bug bounty report to Morpheus (devs@mor.org).

**Bug:** `DistributorV2.distributeRewards()` measures each pool's yield as the
growth of its yield-token balance since `lastUnderlyingBalance`, without
distinguishing genuine yield from a direct donation. Donating aWBTC straight
to the Distributor is counted as wBTC-pool yield, inflating that pool's share
of the fixed daily MOR emission at the expense of other stakers.

**Measured (mainnet fork, block 26459988):** stake 3 wBTC, donate 0.01 wBTC
of aWBTC ($591) -> wBTC pool receives 1,620 MOR, attacker pending 1,271.85
MOR (~$809) -> net +$218 per distribution. Control without donation: wBTC
pool receives 0.103 MOR. Repeatable daily; optimal donation ~$344 -> ~$249/day.

## Run

```sh
forge test
```

One command, from a clean clone. No setup beyond an internet connection
(the test forks Ethereum mainnet at block 26459988 via a public RPC).
`forge-std` is vendored under `lib/` (not a submodule), so no
`git submodule` step is needed.

Tests: `test/DonationYieldShare.t.sol` — 3 tests (attack, control, claim).
