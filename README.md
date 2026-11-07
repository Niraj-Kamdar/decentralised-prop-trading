# Fulcrum — Spot-Funded Prop Trading on Base

**Trade ETH and BTC with up to 10x leverage using a pool of lender money. No entry fee. No exit fee. First week free.**

Live app: https://fulcrum-trade.vercel.app · Backtest: https://fulcrum-trade.vercel.app/backtest

- **Traders** put in USDC margin and go long spot ETH or BTC with more buying power.
- **LPs** deposit USDC into a vault and earn yield from trader fees and profit share.
- **Everything is on-chain.** Each trade lives in its own isolated smart wallet.

> Build, test and contribution details: [DEVELOPMENT.md](DEVELOPMENT.md)

## Deployed on Base mainnet (8453), verified on Basescan

| Contract | Address |
|---|---|
| PositionManager (proxy) | [`0x3f3d197d4582d1D10818a115ef7D7413FD11B8d9`](https://basescan.org/address/0x3f3d197d4582d1D10818a115ef7D7413FD11B8d9) |
| LPVault (proxy) | [`0x38669C1C8fb153Ba4cCB40BF08986014EfBa0F26`](https://basescan.org/address/0x38669C1C8fb153Ba4cCB40BF08986014EfBa0F26) |
| ChainlinkOracle | [`0xAEB1d29301aaFCB8cA719e8c1B09C4cD1F6a9CE9`](https://basescan.org/address/0xAEB1d29301aaFCB8cA719e8c1B09C4cD1F6a9CE9) |
| InsuranceReserve | [`0x96621c13dc4b6c3588Ad3bFff1B37cc1328b69ff`](https://basescan.org/address/0x96621c13dc4b6c3588Ad3bFff1B37cc1328b69ff) |
| V4SwapRouter | [`0x58640556f82Fa9c7F7447392B5450099EcbbcB96`](https://basescan.org/address/0x58640556f82Fa9c7F7447392B5450099EcbbcB96) |
| TraderProxy implementation | [`0x3b7bB8b3C902A30A53485d431A3733D329587F40`](https://basescan.org/address/0x3b7bB8b3C902A30A53485d431A3733D329587F40) |

Also in [`deployments/base-mainnet.json`](deployments/base-mainnet.json).

---

## 1. The big picture

```mermaid
flowchart LR
    T([Trader]) -- "margin (USDC)" --> PM[PositionManager]
    LP([LP]) -- "deposit USDC" --> V[(LP Vault<br/>spUSDC)]
    V -- "borrowed principal" --> PM
    PM -- "margin + principal" --> P[TraderProxy<br/>one per position]
    P -- "swap" --> R[V4SwapRouter] --> U[Uniswap v4 pool]
    CL[Chainlink ETH/USD, BTC/USD] -. "mark price" .-> O[ChainlinkOracle]
    O -. "price check" .-> PM
    K([Keeper bot]) -- "liquidate / roll / close" --> PM
    PM -- "losses first" --> I[Insurance Reserve]
```

| Piece | One-line job |
|---|---|
| **PositionManager** | The brain: opens, rolls, closes, liquidates, settles |
| **LPVault** | Holds LP money, lends it to positions, earns yield |
| **TraderProxy** | A tiny wallet per position that holds the spot asset |
| **ChainlinkOracle** | Chainlink ETH/USD and BTC/USD feeds (1h staleness limit) — the mark for every risk check |
| **InsuranceReserve** | Absorbs losses before LPs do |
| **Keeper** | Bot that liquidates, rolls and closes positions; earns a $0.50 bounty. **Required** for liquidations |

---

## 2. Opening a position

Trader brings **$100**, picks **5x** → buys **$500** of ETH or BTC. The vault lends the other **$400**.
How much a wallet may deposit and which leverage it may use depends on its trader level (section 3).

```mermaid
sequenceDiagram
    actor T as Trader
    participant PM as PositionManager
    participant V as LP Vault
    participant P as TraderProxy (new clone)
    participant U as Uniswap v4
    participant O as Oracle

    T->>PM: openPosition(margin $100, 5x, asset)
    PM->>O: Chainlink price
    PM->>P: create clone, send $100 margin
    PM->>V: borrow $400 for the proxy
    V-->>P: $400
    P->>U: swap $500 USDC → asset
    PM->>O: did we get a fair price vs Chainlink?
    Note over PM,O: reverts if swap is >1% worse than the oracle<br/>or position would already be liquidatable
    PM-->>T: position #N open (7-day epoch)
```

---

## 3. Trader levels

Every wallet starts at Starter. Levels move automatically on each close, from realised PnL since entering the level.

| Level | Max leverage | Max deposit | Lenders' cut of profit | Treasury cut | Move up | Move down |
|---|---|---|---|---|---|---|
| Starter (L0) | 5x | $50 | 15% | 5% | 5 trades and +$25 | never |
| Trader (L1) | 10x | $250 | 10% | 3% | 10 trades and +$100 | at −$50 |
| Pro (L2) | 10x | $1,000 | 7% | 2% | top level | at −$200 |

Levels are owner-configurable (`setLevel`). New traders pay lenders more; proven ones keep more.

---

## 4. Life of a position

```mermaid
stateDiagram-v2
    [*] --> Open: openPosition
    Open --> Open: epoch ends → roll over (8% APR)
    Open --> Closed: trader closes / TP / SL
    Open --> Closed: epoch ends, no auto-roll
    Open --> Liquidated: value ≤ threshold
    Closed --> [*]: payout
    Liquidated --> [*]: remainder → insurance
```

**Epochs:** each position lives in 7-day epochs. The **first is free**. After that, a rollover fee of **8% APR on the borrowed amount** is charged.

**Liquidation line** — you are liquidated when:

```
position value  ≤  borrowed + rollover debt + maintenance %
```

| Tier | Borrowed | Maintenance | Rough drop to liquidation |
|---|---|---|---|
| 5x | 4× margin | 4% of size | ~ −16% |
| 10x | 9× margin | 2% of size | ~ −8% |

---

## 5. How prices work (Chainlink)

Marks come from Chainlink's ETH/USD and BTC/USD feeds on Base. Trades fill on Uniswap v4 (WETH/USDC 0.30%, cbBTC/USDC 0.05%), and every fill is checked against the Chainlink price, so pushing the pool cannot fool the protocol.

```mermaid
flowchart LR
    F[Chainlink feed] --> G{Checks}
    G --> G1[answer > 0, round complete]
    G --> G2[updated within 1 hour]
    G1 & G2 --> M[Mark price]
    M --> D[Entry · exit · liquidation · TP/SL]
    U[Uniswap v4 fill] --> C{Within 1% of mark?<br/>2% for liquidations}
    M --> C
```

Trade-offs: a stale or broken feed reverts every priced action until it recovers; in a fast crash, exits wait until the pool is back within the slippage band. An L2 sequencer-uptime check exists (`setSequencerUptimeFeed`) but is off by default.

---

## 6. Where does the money go? (settlement waterfall)

When a position ends, the USDC from selling the spot asset is paid out **in this order**:

```mermaid
flowchart TD
    S[Sale proceeds] --> B{Forced close?}
    B -- yes --> K[1. Keeper bounty]
    B -- no --> R
    K --> R[2. Repay LP principal]
    R --> L{Enough to repay?}
    L -- no --> BD[Insurance covers the gap<br/>then LPs eat the rest]
    L -- yes --> D[3. Pay rollover debt<br/>80% LPs · 20% insurance]
    D --> Q{Liquidation?}
    Q -- yes --> PEN[4a. Everything left → Insurance]
    Q -- no --> PR{Profit?}
    PR -- "no" --> TL[4b. Trader gets what's left]
    PR -- "yes" --> SPLIT[4c. Split the profit]
    SPLIT --> TP[Trader keeps 80–91%]
    SPLIT --> LPC[LPs 7–15%]
    SPLIT --> TRE[Treasury 2–5%]
```

**Profit split** is set by the trader's level (section 3): Starter keeps 80%, Trader 87%, Pro 91%.

**Worked example** (Trader level, 10x, $100 margin, price +10%): position sells for $1,100 → repay $900 → $200 left → profit is $100 → trader gets **$187** back (their $100 + $87), LPs get $10, treasury $3.

---

## 7. LP side: deposit, earn, exit

```mermaid
flowchart LR
    D([Deposit USDC]) --> V[(Vault)]
    V --> S2[Lent to positions<br/>max 85% utilised]
    V --> M[Idle USDC supplied to<br/>a MetaMorpho vault]
    S2 --> Y[Rollover fees + profit share]
    Y -- "12h linear vesting" --> V
```

### Exiting is a queue (ERC-7540)

```mermaid
sequenceDiagram
    actor LP
    participant V as Vault
    LP->>V: requestRedeem(shares)
    Note over V: shares stop earning<br/>30-day cooldown
    V-->>V: processRedemptions() — FIFO, anyone can call
    V-->>LP: claim USDC via redeem()
```

### Stress protection

| When the pool is… | What happens |
|---|---|
| **Calm** (< 80% utilised) | Normal exits |
| **Stressed** (≥ 80%) | Exit forfeits 25% of earned yield → goes to the **bonus pot** |
| **Stressed** | New depositors can lock funds 90 days and share the bonus pot |
| **Any time** | Exits only paid if the pool still survives a **−20% crash** (solvency gate) |

```mermaid
flowchart LR
    X[Early exits<br/>forfeit yield] --> POT[(Bonus pot)]
    POT --> N[New locked depositors<br/>up to 20% APR]
    N -. "breaks early → returns bonus" .-> POT
```

Traders are never affected by any of this: **LP queue logic cannot block, delay, or reduce a trader payout.**

---

## 8. Who protects LP money?

```mermaid
flowchart TB
    subgraph "Layer 1 — Before the trade"
        A1[Max 85% of vault lent]
        A2[Per-asset exposure cap]
        A3[Whitelisted routers only]
    end
    subgraph "Layer 2 — During the trade"
        B1[Chainlink marks, staleness-checked]
        B2[Keepers liquidate early<br/>at maintenance margin]
        B3[Every swap checked<br/>against the oracle]
    end
    subgraph "Layer 3 — After a loss"
        C1[Trader margin absorbs first]
        C2[Insurance reserve]
        C3[LP principal — last resort]
    end
    A1 --> B1 --> C1 --> C2 --> C3
```

**Why the oracle checks every swap:** otherwise a trader could push a pool's price, trade into it, and make LPs pay the difference. Entry, exit *and* liquidation swaps must land near the oracle price.

---

## 9. Keepers

The keeper bot (`npm run keeper` in `frontend/`) is critical infrastructure. Anyone can run one; it earns a bounty for:

```mermaid
flowchart LR
    K([Keeper]) --> L[Liquidate unhealthy positions]
    K --> E[Close or roll expired epochs]
    K --> TR[Execute stop-loss / take-profit]
    K --> Q[Process LP exit queue]
```

---

## 10. Trust & safety at a glance

- **Isolated custody** — one clone wallet per position; a bug in one cannot touch another.
- **Protocol-built swaps** — callers pass only a minimum output; the contract builds the Uniswap call itself.
- **Balance-checked swaps** — the proxy measures what it actually received, not what the router claims.
- **No payout redirection** — payouts only go to the trader, so a blocklisted trader can't route funds elsewhere.
- **Always-open exits** — closing works even when the protocol is paused.
- **Governance** — ownership moves to governance via `Ownable2Step`; parameters are bounded.

## Known gaps before audit

- **Keepers must run**: if none do, unhealthy positions are not liquidated.
- **Chainlink is a single price source**: a stale feed (over 1 hour) pauses every priced action for that asset.
- **Launch caps are small on purpose**: $10k vault deposit cap, $100 per wallet, 35% of the vault per asset.
- USDC assumed = $1.
- Trailing stop has no on-chain high-water tracking.
- MetaMorpho integration is optional (`IDLE_VAULT` at deploy).
- Solvency gate assumes keepers liquidate promptly.
- Pending exit requests block *all* new allocations (more conservative than spec).

---

## Backtest

`sim/` replays every hour of ETH and BTC since 2020 against real trader behaviour (342 Hyperliquid traders, 6,967 positions) and publishes the results to [Arkiv](sponsors/arkiv/README.md). When lenders ask for 10% a year, deposits settle at about $86k and lenders earn 10.2% APY, with no lender losses in the 7 worst crashes. Details on the [backtest page](https://fulcrum-trade.vercel.app/backtest).

---

**Next:** [DEVELOPMENT.md](DEVELOPMENT.md) for setup, tests, internals and contributing · [frontend/README.md](frontend/README.md) for the app.
