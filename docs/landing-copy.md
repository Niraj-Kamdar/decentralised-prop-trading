# Landing page: story and copy

Judges' feedback: "we didn't get what you're building." So the page has one job. A visitor should be able to say, in one breath:

> *Traders borrow from a vault to buy real ETH or BTC with up to 10x leverage. Lenders earn a cut of every win, and the trader's own deposit takes the loss first.*

## Narrative structure (story spine)

The page is built on the story spine: each section is one beat, in order. The beats set the structure and are never shown as labels on the page.

| Beat | Section | What the visitor learns |
|---|---|---|
| *(hook)* | 1. Hero | What it is, in dollars |
| Once upon a time / Every day | 2. The problem | Today, traders who want leverage rent it from perps, and stablecoin lenders earn little |
| Until one day | 3. How it works | One vault connects the two |
| Because of that | 4. One trade, two endings | Traders get leverage, and lenders get paid first |
| Because of that | 5. Earn your leverage | Risk is priced per trader, so lenders take a bigger cut where risk is higher |
| Until finally | 6. Proof | It survived every crash since 2020 |
| Ever since then | 7. Pick a side + FAQ | Where you fit, and what to do next |

## Show it, don't write it

**Every section leads with an illustration; the copy is a caption, not a paragraph.** Judges skim. If a section needs more than about 25 words of body text to make sense, the picture is missing. Make the illustrations (SVG, built in code so the numbers stay live) before polishing any copy.

| Section | Illustration | It replaces |
|---|---|---|
| 1. Hero | A $100 coin plus a $900 stack from the vault going into one $1,000 ETH block | Explaining leverage |
| 2. Problem | Two panels: a perp's funding meter ticking up over time, and idle USDC with a small yield number | Two paragraphs about perps and lending |
| 3. How it works | Flow diagram: lenders → vault → trader position → closes back to vault, then trader | The three-step list (keep it only as labels) |
| 4. Two endings | Two stacked bars of the same $1,000 position, sliced by who gets what (lenders, insurance, Fulcrum, keeper, trader). Win on the left, liquidation on the right. Optional ETH-price slider that moves between them. | The two tables (keep them collapsed under the bars for anyone who wants exact numbers) |
| 5. Levels | Three steps of a staircase (Starter → Trader → Pro), each showing max leverage, max deposit and "you keep X%" | The level table |
| 6. Proof | The vault-value line over 6.8 years, with the 7 crashes marked on it and a "$0 lost" badge at each | Stat tiles alone |
| 7. Pick a side | Two cards with one icon each (chart for traders, vault for lenders) | n/a, already short |

Rules: one idea per illustration; label with dollars, not percentages; every illustration has a text or table equivalent for screen readers.

`{arkiv.*}` = a value read live from Arkiv through `getBacktest()` (see `docs/superpowers/plans/2026-11-07-backtest-page.md`). The value after the `=` is from the first published run (`df74b20`), for drafting only.

---

## 1. Hero *(hook)*

**Eyebrow:** Spot leverage, funded by a vault

**H1:** Buy $1,000 of ETH with $100.

**Sub:** Fulcrum lends you the other $900 from a vault of USDC lenders. Win, and you keep most of the profit. Lose, and you lose only your $100: the lenders get their money back first.

**CTAs:** `Start trading` (primary) · `Earn as a lender` (secondary)

**Proof strip** (three small stats under the CTAs, all from Arkiv; each links to `/backtest`):
- `{arkiv.lp_equilibrium.calibrated["0.055"].apy = 10.2%, vault ~$86k}` lender APY, backtested
- `${arkiv.crash.base.lp_loss_total = 0}` lender losses through `{arkiv.crash.count = 7}` crashes
- `{arkiv.meta.years = 6.8}` years of minute-by-minute prices


> Why: the old H1 ("Capital for traders. Returns for investors.") is true but abstract. A concrete dollar amount answers "what is it" before anyone scrolls.

---

## 2. The problem *(once upon a time / every day)*

**H2:** Leverage today is rented, not owned.

Two columns, one per side of the market:

**Traders.** Want leverage on ETH or BTC, so they open perps. That means paying funding for as long as they hold, and owning a contract instead of the coin. The longer you hold, the more you pay, which punishes exactly the swing traders who win most often.

**Lenders.** Hold USDC and want yield. Lending markets pay single digits, and the borrowers are mostly other lenders looping the same collateral.

**Bridge line:** One side has conviction and no capital. The other has capital and no edge.

> Keep it to these two short paragraphs. The swing-trader point comes from the Hyperliquid data: win rates rise from 25% on holds under 10 minutes to 56% on holds over a week (`{arkiv.real_traders.by_hold}`). If the team wants a cited lending-rate figure, add it here with a source; otherwise keep "single digits".

---

## 3. How it works *(until one day)*

**H2:** One vault, two sides.

Three steps (reuse the existing `STEPS` layout):
1. **Lenders fund the vault.** Anyone deposits USDC. That pool is what traders borrow from.
2. **Traders borrow up to 9x their deposit.** The contract buys real ETH or BTC with both and holds it.
3. **Close, and the contract splits it.** Lenders are repaid first, then the profit is shared. Most of it goes to the trader.

**Closing line:** The trader's deposit is the lever. The vault is the fulcrum.

---

## 4. One trade, two endings *(because of that)*

**Lead:** $100 deposit, 10x leverage, $900 borrowed from the vault. The contract buys $1,000 of ETH.

Two cards side by side (stacked on mobile). Each is a stacked bar of the $1,000+ split, then the table.

### Ending A: ETH +10%. Position is worth $1,100.

| Who | Gets | Why |
|---|---|---|
| Lenders (vault) | **$900 + $10** | Loan repaid first, then 10% of the $100 profit |
| Insurance fund | $1.50 | Half of the 3% protocol cut |
| Fulcrum | $1.50 | The other half |
| **Trader** | **$187** | $100 deposit back + $87 profit (87% of the win) |

Footnote: *A $100 deposit could only make $10 here. With Fulcrum it made $87.*

### Ending B: ETH −8%. The position is liquidated at about $919.

| Who | Gets | Why |
|---|---|---|
| Lenders (vault) | **$900** | Loan repaid in full, first |
| Keeper | $0.50 | Paid for closing the position on time |
| Insurance fund | ~$18.58 | Whatever is left goes to the reserve that covers future crashes |
| Trader | $0 | The $100 deposit absorbed the loss |

Footnote: *The trader can never lose more than their deposit, and the lenders are paid before anyone else.*

**Below both cards, one line:** In a crash too fast to liquidate in time, the insurance fund pays the gap before lenders do. [See all 7 crash replays →](/backtest)

> Numbers: the split uses the **Level 1** profit cut from PR #10 (LP 10%, treasury 3%, split 50/50) and the Base mainnet keeper bounty of $0.50. The sim's current `worked_example()` still uses the pre-#10 tiers (LP 12%, $5 keeper → trader $185, insurance $14.08). Once the PR #10 sim lands, bind these tables to `{arkiv.example}` instead of hardcoding them.

---

## 5. Earn your leverage *(because of that)*

**H2:** Start small. Prove it. Unlock 10x.
**Lead:** Every wallet starts as a Starter. Good trading moves you up automatically; big losses move you down. Nobody approves it but the contract.

| | Starter | Trader | Pro |
|---|---|---|---|
| Max leverage | 5x | 10x | 10x |
| Max deposit | $50 | $250 | $1,000 |
| You keep of each win | 80% | 87% | 91% |
| To move up | 5 trades, +$25 total | 10 trades, +$100 total | Top level |
| You drop a level at | Never | −$50 | −$200 |

**Footnote:** Lenders take a bigger cut from new traders, who are riskier, and a smaller one from proven ones.

> Display names for levels 0/1/2 are Starter/Trader/Pro. The section 4 example is a "Trader" (level 1) because Starter caps at 5x and $50. Say that in a footnote under section 4: *"Example uses the Trader level. New wallets start at 5x with up to $50."*

---

## 6. Proof *(until finally)*

**H2:** We replayed every crash since 2020.
**Lead:** Before asking anyone to lend, we ran the protocol minute by minute through 6.8 years of Binance prices and `{arkiv.meta.positions = 6,967}` real Hyperliquid trades. Every result is published on Arkiv and signed by our wallet, so you can check it without trusting this page.

Three stat tiles:
- **`{arkiv.lp_equilibrium.calibrated["0.055"].apy = 10.2%, vault ~$86k}`** average lender APY
- **`${arkiv.crash.base.lp_loss_total = 0}`** lender losses in COVID, LUNA, FTX and `{n}` more crashes
- **`${arkiv.headline.bad_debt = 0}`** bad debt

Then the vault-value line chart (the same `NavChart` as `/backtest`).

**Honest line, under the chart:** In our harshest stress test (thin liquidity, every trader at 10x, keepers offline for 30 minutes, and an empty insurance fund), lenders lost `{arkiv.crash.stress_outage_30m.max_usd = $0}` in every crash. We show that too.

**CTA:** `See the full backtest →` (/backtest) · `Verify on Arkiv →` (explorer link)

---

## 7. Pick a side *(ever since then)*: keep the existing two cards, new copy

**Traders, H2:** Trade bigger than your wallet.
- Up to 10x on real ETH and BTC, not a synthetic perp
- No funding fees; first week of borrowing free, then 8% a year
- Keep up to 91% of every win, paid the moment you close
- The most you can lose is your deposit

**Lenders, H2:** Earn from traders, without trading.
- Earn 7–15% of every winning trade, plus borrowing fees
- Traders' deposits and an insurance fund take losses before you
- `{arkiv.lp_equilibrium.calibrated["0.055"].apy = 10.2%, vault ~$86k}` APY in our 6.8-year backtest
- Withdraw any time, paid out within 30 days

Lender card small print: *Backtests aren't guarantees. Deposits can lose value.*

> Real-trader insight for later (pitch, not hero): swing traders fit best. Hyperliquid win rates rise from 25% on trades under 10 minutes to 56% on trades held over a week.

---

## 8. FAQ (replace the current five)

**Is this a perp?**
No. When you open a trade, the contract buys real ETH or BTC with your deposit plus the vault's loan, and holds it until you close. There's no funding rate.

**Can I lose more than I put in?**
No. Your deposit is the most you can lose. The contract closes your trade before losses pass it. In a very fast crash you can still lose all of it.

**Where does the loan come from?**
From lenders who deposit USDC into the vault. They're paid back first on every close, then take a share of the profit.

**What do lenders earn?**
7–15% of each winning trade, depending on the trader's level, plus 80% of borrowing fees. Our backtest averaged `{arkiv.lp_equilibrium.calibrated["0.055"].apy = 10.2%, vault ~$86k}` a year.

**Can lenders lose money?**
Yes, if a crash is fast enough that a trader's deposit and the insurance fund can't cover it. In our base backtest it never happened across 7 crashes; in a harsh stress test lenders lost `{arkiv.crash.stress_outage_30m.max_usd = $0}` in every crash. All results are public on Arkiv.

**How does Fulcrum make money?**
1.5% of profitable trades at the Trader level (half of a 3% cut; the other half funds insurance). It ranges from 1% to 2.5% by level.

**Who decides if I get paid, or my level?**
Nobody. The contract pays you when you close and updates your level automatically.

---

## Copy rules for the build
- Say "lenders" on the page, not "LPs" or "investors". "Investors" sounds like equity; "LPs" is jargon.
- Always use dollars ($100, $900), never percentages alone, in the first two sections.
- Every stat links to its source (`/backtest` or the Arkiv explorer).
- No "guaranteed", "risk-free" or "safe". Say "lenders are paid first" and show the stress number.

## Open questions for the team
1. **Chain:** *Resolved: Base mainnet. The page and app say Base.*
2. **Stress figure:** *Resolved in run `df74b20`: lender loss is $0 in all 7 crashes in every scenario, so the figure below no longer applies; kept for history.* The old `0.49%` was COVID's $4,933 loss on a $1M vault. That number was **after** insurance: the sim pays shortfalls from insurance first (`cover = min(shortfall, insurance)` in `model.py`), and only the rest is lender loss. But every crash replay starts with **insurance = $0** (`crash_job(..., insurance=0.0, ...)` in `export.py`), so in the replay there's nothing to cover it. That's a deliberate worst case, not what a running vault would see. The 6.8-year headline run builds insurance up to ~$64k, which would cover Oct-10 ($2,623) easily. COVID came 2.5 months after the run starts, so the fund would be small there. **Fix before quoting it:** in the PR #10 re-run, seed each crash replay with the insurance balance the headline run had on that date, and report both numbers (empty fund vs. realistic fund). Also check against the new Chainlink feed-outage stress.
3. **Position count:** the Arkiv docs say both 6,967 trades and 7,036 positions. Pick one (I think 7,036 is the full dataset and 6,967 is ETH/BTC closed). Then bind it to Arkiv.
4. **Free first week:** still true after PR #10? (Rollover is 8% APR; check whether the free period survived.)
