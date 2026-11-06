# Fulcrum — Spot-Funded Prop Trading on Arc

**Trade ETH and BTC with 5x or 10x leverage using a pool of LP money. No entry fee. No exit fee. First week free.**

- **Traders** put in USDC margin and go long spot ETH or BTC with more buying power.
- **LPs** deposit USDC into a vault and earn yield from trader fees and profit share.
- **Everything is on-chain.** Each trade lives in its own isolated smart wallet.

> Build, test and contribution details: [DEVELOPMENT.md](DEVELOPMENT.md)

---

## 1. The big picture

```mermaid
flowchart LR
    T([Trader]) -- "margin (USDC)" --> PM[PositionManager]
    LP([LP]) -- "deposit USDC" --> V[(LP Vault<br/>spUSDC)]
    V -- "borrowed principal" --> PM
    PM -- "margin + principal" --> P[TraderProxy<br/>one per position]
    P -- "swap" --> R[V4SwapRouter] --> U[Uniswap v4 pool]
    U -. "pool price" .-> O[TWAP Oracle<br/>10-min average]
    O -. "price check" .-> PM
    K([Keeper bot]) -- "records price" --> O
    K -- "liquidate / roll / close" --> PM
    PM -- "losses first" --> I[Insurance Reserve]
```

| Piece | One-line job |
|---|---|
| **PositionManager** | The brain: opens, rolls, closes, liquidates, settles |
| **LPVault** | Holds LP money, lends it to positions, earns yield |
| **TraderProxy** | A tiny wallet per position that holds the spot asset |
| **UniV4TwapOracle** | 10-minute average of the Uniswap pool price — the source of truth |
| **InsuranceReserve** | Absorbs losses before LPs do |
| **Keeper** | Bot that records prices and liquidates; earns a bounty. **Required** — no keeper, no trading |

---

## 2. Opening a position

Trader brings **$100**, picks **5x** → buys **$500** of ETH or BTC. The vault lends the other **$400**.

```mermaid
sequenceDiagram
    actor T as Trader
    participant PM as PositionManager
    participant V as LP Vault
    participant P as TraderProxy (new clone)
    participant U as Uniswap v4
    participant O as Oracle

    T->>PM: openPosition(margin $100, 5x, asset)
    PM->>O: TWAP price
    PM->>P: create clone, send $100 margin
    PM->>V: borrow $400 for the proxy
    V-->>P: $400
    P->>U: swap $500 USDC → asset
    PM->>O: did we get a fair price vs TWAP?
    Note over PM,O: reverts if swap is >1% worse than TWAP<br/>or position would already be liquidatable
    PM-->>T: position #N open (7-day epoch)
```

---

## 3. Life of a position

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

## 4. How prices work (TWAP oracle)

Uniswap pools keep no price history, so a keeper records it. Risk decisions use the **10-minute average**, not the live price, so a quick pool push can't fool the protocol.

```mermaid
flowchart LR
    P[Uniswap v4 pool] --> K[Keeper records tick<br/>every few seconds]
    K --> G{Guards}
    G --> G1[Sample within ~1% of last block]
    G --> G2[Max ~5% move per sample]
    G1 & G2 --> B[(Ring buffer)]
    B --> T[10-min TWAP]
    T --> D[Entry · exit · liquidation · TP/SL]
    B -. "keeper offline > 90s" .-> S[Stale: nothing can be priced]
```

Trade-offs: after a deploy or a long keeper outage the oracle needs **10 minutes to warm up**; in a fast crash, exits wait until the pool is back within the slippage band or the TWAP catches up.

---

## 5. Where does the money go? (settlement waterfall)

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
    SPLIT --> TP[Trader keeps ~90%]
    SPLIT --> LPC[LPs ~8–12%]
    SPLIT --> TRE[Treasury ~2–3%]
```

**Profit split**

| Tier | Trader | LPs | Treasury |
|---|---|---|---|
| 5x | 90% | 8% | 2% |
| 10x | 85% | 12% | 3% |

**Worked example** (5x, $100 margin, price +20%): position sells for $600 → repay $400 → $200 left → profit is $100 → trader gets **$190** back (their $100 + $90), LPs get $8, treasury $2.

---

## 6. LP side: deposit, earn, exit

```mermaid
flowchart LR
    D([Deposit USDC]) --> V[(Vault)]
    V --> S2[Lent to positions<br/>max 85% utilised]
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

## 7. Who protects LP money?

```mermaid
flowchart TB
    subgraph "Layer 1 — Before the trade"
        A1[Max 85% of vault lent]
        A2[Per-asset exposure cap]
        A3[Whitelisted routers only]
    end
    subgraph "Layer 2 — During the trade"
        B1[10-min TWAP, guarded recording]
        B2[Keepers liquidate early<br/>at maintenance margin]
        B3[Every swap checked<br/>against the TWAP]
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

## 8. Keepers

The keeper bot (`npm run keeper` in `frontend/`) is critical infrastructure. It records oracle prices and earns a bounty for:

```mermaid
flowchart LR
    K([Keeper]) --> REC[Record TWAP prices]
    K --> L[Liquidate unhealthy positions]
    K --> E[Close or roll expired epochs]
    K --> TR[Execute stop-loss / take-profit]
    K --> Q[Process LP exit queue]
```

---

## 9. Trust & safety at a glance

- **Isolated custody** — one clone wallet per position; a bug in one cannot touch another.
- **Protocol-built swaps** — callers pass only a minimum output; the contract builds the Uniswap call itself.
- **Balance-checked swaps** — the proxy measures what it actually received, not what the router claims.
- **No payout redirection** — payouts only go to the trader, so a blocklisted trader can't route funds elsewhere.
- **Always-open exits** — closing works even when the protocol is paused.
- **Governance** — ownership moves to governance via `Ownable2Step`; parameters are bounded.

## Known gaps before audit

- **TWAP trusts its recorders** (permissioned keepers); if all stop, pricing stops and nobody can be liquidated.
- **Thin pools** (~$15k ETH, ~$8k BTC at time of writing): a few $k moves price several %. Keep exposure caps far below pool depth.
- USDC assumed = $1; no external oracle cross-check.
- Trailing stop has no on-chain high-water tracking.
- MetaMorpho integration is optional and not covered by fork tests.
- Solvency gate assumes keepers liquidate promptly.
- Pending exit requests block *all* new allocations (more conservative than spec).

---

**Next:** [DEVELOPMENT.md](DEVELOPMENT.md) for setup, tests, internals and contributing · [frontend/README.md](frontend/README.md) for the app.
