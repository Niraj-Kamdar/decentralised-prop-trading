# Fulcrum — Spot-Funded Prop Trading on Arc

**Trade with 5x or 10x leverage using a pool of LP money. No entry fee. No exit fee. First week free.**

- **Traders** put in USDC margin and trade spot crypto with more buying power.
- **LPs** deposit USDC into a vault and earn yield from trader fees and profit share.
- **Everything is on-chain.** Each trade lives in its own isolated smart wallet.

> Build, test and contribution details: [DEVELOPMENT.md](DEVELOPMENT.md)

---

## 1. The big picture

```mermaid
flowchart LR
    T([Trader]) -- "margin (USDC)" --> PM[PositionManager]
    LP([LP]) -- "deposit USDC" --> V[(LP Vault<br/>spUSDC)]
    V -- "idle funds" --> M[MetaMorpho<br/>earns yield]
    V -- "borrowed principal" --> PM
    PM -- "margin + principal" --> P[TraderProxy<br/>one per position]
    P -- "swap" --> U[Uniswap]
    O[Pyth Oracle] -. "price check" .-> PM
    K([Keeper bot]) -- "liquidate / roll / close" --> PM
    PM -- "losses first" --> I[Insurance Reserve]
```

| Piece | One-line job |
|---|---|
| **PositionManager** | The brain: opens, rolls, closes, liquidates, settles |
| **LPVault** | Holds LP money, lends it to positions, earns yield |
| **TraderProxy** | A tiny wallet per position that holds the spot asset |
| **OracleVerifier** | Pyth price, max 5s old — the source of truth |
| **InsuranceReserve** | Absorbs losses before LPs do |
| **Keeper** | Anyone running the bot; earns a bounty |

---

## 2. Opening a position

Trader brings **$100**, picks **5x** → trades **$500**. The vault lends the other **$400**.

```mermaid
sequenceDiagram
    actor T as Trader
    participant PM as PositionManager
    participant V as LP Vault
    participant P as TraderProxy (new clone)
    participant U as Uniswap
    participant O as Oracle

    T->>PM: openPosition(margin $100, 5x, asset)
    PM->>O: fresh price?
    PM->>P: create clone, send $100 margin
    PM->>V: borrow $400 for the proxy
    V-->>P: $400
    P->>U: swap $500 USDC → asset
    PM->>O: did we get a fair price?
    Note over PM,O: reverts if swap is >1% off oracle<br/>or position would already be liquidatable
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

## 4. Where does the money go? (settlement waterfall)

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

## 5. LP side: deposit, earn, exit

```mermaid
flowchart LR
    D([Deposit USDC]) --> V[(Vault)]
    V --> S1[Idle → MetaMorpho yield]
    V --> S2[Lent to positions<br/>max 85% utilised]
    S2 --> Y[Rollover fees + profit share]
    S1 --> Y
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

## 6. Who protects LP money?

```mermaid
flowchart TB
    subgraph "Layer 1 — Before the trade"
        A1[Max 85% of vault lent]
        A2[Per-asset exposure cap]
        A3[Whitelisted routers only]
    end
    subgraph "Layer 2 — During the trade"
        B1[Pyth price ≤ 5s old]
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

## 7. Keepers

Anyone can run the keeper bot (`npm run keeper` in `frontend/`). It earns a bounty for:

```mermaid
flowchart LR
    K([Keeper]) --> L[Liquidate unhealthy positions]
    K --> E[Close or roll expired epochs]
    K --> TR[Execute stop-loss / take-profit]
    K --> Q[Process LP exit queue]
```

---

## 8. Trust & safety at a glance

- **Isolated custody** — one clone wallet per position; a bug in one cannot touch another.
- **Balance-checked swaps** — the proxy measures what it actually received, not what the router claims.
- **No payout redirection** — payouts only go to the trader, so a blocklisted trader can't route funds elsewhere.
- **Always-open exits** — closing works even when the protocol is paused.
- **Governance** — ownership moves to governance via `Ownable2Step`; parameters are bounded.

## Known gaps before audit

- Oracle is Pyth only (no Chainlink fallback); USDC assumed = $1.
- No Uniswap v4 adapter yet.
- Trailing stop has no on-chain high-water tracking.
- Tests use a constant-price router; no fork tests yet.
- Solvency gate assumes keepers liquidate promptly.
- Pending exit requests block *all* new allocations (more conservative than spec).

---

**Next:** [DEVELOPMENT.md](DEVELOPMENT.md) for setup, tests, internals and contributing · [frontend/README.md](frontend/README.md) for the app.
