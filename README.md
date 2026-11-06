# Spot-Funded Prop Trading on Arc

Leveraged spot trading (5x / 10x) on Arc. Each position gets its own isolated EIP-1167 `TraderProxy`. The trader's
USDC margin is paired with principal borrowed from an ERC-4626 LP vault, whose idle funds earn yield in MetaMorpho.
The protocol charges no entry or exit fees, and the first 7-day epoch is free. Later epochs roll over at 8% APR.

## Layout

| Contract | Role |
|---|---|
| `src/PositionManager.sol` | Entry point for traders and keepers: opens positions, rolls epochs, liquidates and runs the settlement waterfall |
| `src/LPVault.sol` | `spUSDC` ERC-4626 vault (UUPS): Morpho buffer, lending to proxies, 12h linear profit vesting, 85% utilization cap |
| `src/TraderProxy.sol` | Per-position custody clone that swaps only through whitelisted routers and checks its own balance after each swap |
| `src/InsuranceReserve.sol` | First-loss bucket and ops-treasury bucket |
| `src/OracleVerifier.sol` | Pyth pull oracle wrapper: data must be at most 5s old with confidence within 50 bps; prices normalised to 1e18 |
| `script/Deploy.s.sol` | Arc deployment and wiring, then hand-off to governance through Ownable2Step |

## Build & test

```bash
npm install                 # forge 1.7.1 + OpenZeppelin 5.4.0 from npm
git submodule update --init # forge-std
npm test                    # 35 tests incl. 512-run settlement-conservation fuzz
npm run build               # prints contract sizes (PositionManager ~17.7 KB)
```

## Implementation decisions beyond / deviating from the spec

1. **Every exit swap is bounded by the oracle, including the trader's own close.** If only `liquidate()` were
   bounded, a trader could close into a pool they had manipulated themselves. The swap output would come out low,
   the shortfall would land on LP principal, and the trader would pocket the difference through the pool. For the
   same reason, `openPosition` rejects any fill worse than `maxEntrySlippageBps` against the oracle.
2. **The proxy measures its own balance changes.** It does not rely on what the router reports. Router calldata
   that sends the proceeds to a different recipient therefore fails the `minOut` check.
3. **Rollover debt is charged up front for each epoch and accrues lazily.** If keepers are late, `closePosition`,
   `liquidate` and `executeTrigger` first charge every epoch that has fallen due. A pure roll in `processEpoch`
   pays no bounty, because skipping it never lets debt go unaccrued.
4. **An expired position that is also below the liquidation threshold settles as a liquidation, not an expiry.**
   The same applies to a triggered stop-loss below the threshold. A trader therefore cannot use a stop order to
   avoid the liquidation penalty.
5. **`addMargin` repays vault principal directly.** It lowers B, which reduces both the liquidation threshold and
   the base for rollover fees. M₀ grows by the same amount, so the trader gets it back before the profit split.
6. **The Pyth fee is paid without any payable function.** On Arc the native balance and the `0x3600` ERC-20
   balance are the same USDC. `PositionManager` therefore takes the fee from the caller as an ERC-20 transfer to
   `OracleVerifier`, which then pays Pyth in native units.
7. **There is no "claim to another address" path.** With one, a trader on the Circle blocklist could route
   deferred payouts to a clean address.
8. **Swap instructions are explicit `{router, minAmountOut, data}` structs** rather than an opaque `bytes swapData`.
9. **Uniswap v4 / UniversalRouter goes through a whitelisted adapter.** The proxy grants a plain exact ERC-20
    approval and revokes it after the swap. UniversalRouter pulls tokens through Permit2, so it needs a small
    adapter that pulls with `transferFrom` and calls Permit2 itself.
10. **USDC is enforced at deployment.** The constructor and initializer require `0x3600…0000` whenever the chain
    ID is 5042 or 5042002, and they also check that the token has 6 decimals.
11. **The LP vault applies a virtual-share offset of 6** against first-depositor inflation attacks, so `spUSDC`
    shares have 12 decimals.

## Known gaps before audit

- `OracleVerifier` integrates Pyth only. Chainlink fallback is not implemented, and USDC is assumed to equal $1.
- No Uniswap v4 adapter is included yet (see decision 9).
- Bad debt hits the share price immediately. An LP watching prices could withdraw ahead of a gap down.
- `executeTrigger` lets the trader or an operator raise `trailingStopPrice`. There is no on-chain high-water tracking.
- The tests use a constant-price router. No fork tests have been run against real Arc pools or MetaMorpho.
