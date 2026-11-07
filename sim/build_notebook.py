"""Builds sim/fulcrum_backtest.ipynb (cells kept as plain strings so the notebook stays diffable).

  cd sim && uv run --with nbformat python build_notebook.py fulcrum_backtest.ipynb
  uv run --with jupyter,matplotlib,ipywidgets,numpy,nbformat jupyter nbconvert --to notebook --execute --inplace fulcrum_backtest.ipynb
"""

import sys

import nbformat as nbf

cells = []
md = lambda s: cells.append(nbf.v4.new_markdown_cell(s.strip()))  # noqa: E731
code = lambda s: cells.append(nbf.v4.new_code_cell(s.strip()))  # noqa: E731

md(r"""
# Fulcrum — backtesting LP risk & yield on 6.8 years of real ETH/BTC prices

**Fulcrum** lets traders go long spot ETH/BTC with money borrowed from an LP vault.
This backtest models the **Base mainnet MVP contracts (PR #10)**:
- **Chainlink Oracle**: 0.5% deviation threshold, 1200s (20m) heartbeat, 3600s staleness rejection (replaces 10-minute TWAP).
- **Trader Levels (0, 1, 2)**: Level 0 (5x max leverage, $50 max margin, 15% LP profit cut), Level 1 (10x, $250, 10%), Level 2 (10x, $1,000, 7%).
- **Automatic promotion/demotion**: promotion on trade count and cumulative PnL; demotion on drawdown.
- **Risk params**: $50 minimum notional, $0.50 keeper bounty, 8% APR rollover debt.
- **Vault sizing**: Pitch numbers use a scaled **$1M vault**; the MVP launches capped at **$10,000 TVL** ($100 per address).

The two critical questions every LP (and judge) asks:
1. **Will I lose money when the market crashes?** → we replay the 7 worst crashes since 2020 minute by minute.
2. **What do I actually earn?** → we run the vault through bull, bear, and chop regimes across 3.6M minutes.

> Everything below is computed from **3.6 million minutes of Binance ETH & BTC prices** (Jan 2020 → Oct 2026)
> fed through a minute-by-minute port of our Solidity contracts.
""")

code(r'''
%matplotlib inline
import time
from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace

import ipywidgets as W
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import LinearSegmentedColormap
from IPython.display import HTML, display

from data import NAMES, load, minute
from model import DAY, YEAR, Demand, Params, Sim, LevelConfig, DEFAULT_LEVELS
from run import CRASH_DEMAND, CRASHES, crash_job, crash_sim, job
import hl

# Palette: validated categorical order (blue, orange, aqua) + reserved status red; recessive greys for chrome.
BLUE, ORANGE, AQUA, YELLOW, RED = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e34948"
INK, INK2, MUTED, GRID, SURFACE = "#0b0b0b", "#52514e", "#8a8984", "#e6e5e0", "#fcfcfb"
SEQ = LinearSegmentedColormap.from_list("seq", [SURFACE, "#cde2fb", "#6da7ec", "#2a78d6", "#184f95", "#0d366b"])
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE, "figure.dpi": 110,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
    "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
    "lines.linewidth": 2, "font.size": 11, "axes.titlesize": 13, "axes.titleweight": "bold",
    "axes.titlelocation": "left", "legend.frameon": False,
})

POOL = ProcessPoolExecutor()
pmap = lambda fn, specs: list(POOL.map(fn, specs))
usd = lambda x: f"${x/1e6:,.2f}M" if abs(x) >= 1e6 else f"${x/1e3:,.1f}k" if abs(x) >= 1e4 else f"${x:,.0f}"
pct = lambda x, d=1: f"{100*x:.{d}f}%"

def kpis(items):
    """Row of stat tiles: (label, value[, note])."""
    tile = ('<div style="background:#fff;border:1px solid #e6e5e0;border-radius:10px;padding:10px 16px;min-width:150px">'
            '<div style="font-size:12px;color:#52514e">{}</div>'
            '<div style="font-size:22px;font-weight:700;color:#0b0b0b;margin-top:2px">{}</div>'
            '<div style="font-size:11px;color:#8a8984">{}</div></div>')
    body = "".join(tile.format(*(list(it) + [""])[:3]) for it in items)
    return HTML(f'<div style="display:flex;flex-wrap:wrap;gap:10px;margin:6px 0 14px">{body}</div>')

def table(header, rows):
    th = "".join(f'<th style="text-align:{"left" if i == 0 else "right"};padding:4px 10px;color:#52514e;'
                 f'border-bottom:1px solid #e6e5e0">{h}</th>' for i, h in enumerate(header))
    tr = "".join("<tr>" + "".join(f'<td style="text-align:{"left" if i == 0 else "right"};padding:4px 10px;'
                                  f'color:#0b0b0b">{c}</td>' for i, c in enumerate(r)) + "</tr>" for r in rows)
    return HTML(f'<table style="border-collapse:collapse;font-size:13px;background:#fff">'
                f'<thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table>')

def times(start, minutes):
    return np.datetime64(start) + np.asarray(minutes).astype("timedelta64[m]")

def heat(ax, M, xt, yt, fmt, title):
    ax.imshow(M, cmap=SEQ, aspect="auto", vmin=0, vmax=max(M.max(), 1e-9))
    ax.set_xticks(range(len(xt)), xt); ax.set_yticks(range(len(yt)), yt); ax.grid(False); ax.set_title(title)
    for (i, j), v in np.ndenumerate(M):
        ax.text(j, i, fmt(v), ha="center", va="center", fontsize=10,
                color="#fff" if v > 0.55 * M.max() and M.max() > 0 else INK)
''')

# --------------------------------------------------------------------------------------------- data
md(r"""
## 1 · The data

Binance spot 1-minute closes for ETH and BTC, every minute since 1 Jan 2020 — gap-free, forward-filled across
exchange maintenance. The dotted lines are the seven crashes replayed in section 4.
""")

code(r'''
START, END = "2020-01-01", "2026-11-01"
px = load(START, END)
T = px.shape[1]
h1 = px[:, 60:] / px[:, :-60] - 1
display(kpis([
    ("Minutes of history", f"{T:,}", "Jan 2020 → Oct 2026"),
    ("Price points", f"{px.size:,}", "ETH + BTC, 1-minute"),
    ("Worst 1h move — ETH", pct(h1[0].min()), "COVID, 12 Mar 2020"),
    ("Worst 1h move — BTC", pct(h1[1].min())),
    ("Crashes replayed", f"{len(CRASHES)}", "COVID → Oct-10 2025"),
]))

fig, ax = plt.subplots(figsize=(12, 4.2))
d = times(START, np.arange(0, T, DAY))
for k, c in enumerate((BLUE, ORANGE)):
    s = px[k, ::DAY] / px[k, 0] * 100
    ax.plot(d, s, color=c, label=NAMES[k])
    ax.annotate(f"{NAMES[k]} ×{s[-1]/100:.1f}", (d[-1], s[-1]), xytext=(6, 0), textcoords="offset points",
                color=INK2, va="center", fontsize=10)
ax.set_yscale("log"); ax.set_ylabel("price, indexed (Jan 2020 = 100, log)")
for name, day in CRASHES.items():
    ax.axvline(np.datetime64(day), color=MUTED, lw=1, ls=":")
    ax.text(np.datetime64(day), ax.get_ylim()[1], name, rotation=90, va="top", ha="right", fontsize=9, color=INK2)
ax.legend(loc="lower right"); ax.set_title("6.8 years of ETH & BTC — every minute is in the backtest")
plt.show()
''')

# --------------------------------------------------------------------------------------------- engine
md(r"""
## 2 · The engine — our Base MVP contracts, ported minute by minute

| Contract mechanic | How the sim models it |
|---|---|
| `openPosition` caps | per-asset exposure ≤ 35% of vault, utilisation ≤ 85%, min notional $50, trader level limits (L0: 5x & $50 margin; L1: 10x & $250; L2: 10x & $1,000) |
| `ChainlinkOracle` | 0.5% deviation threshold or 1200s (20m) heartbeat; stale beyond 3600s (reverts); feed outage stress tests |
| Liquidation line | `Chainlink mark value ≤ borrowed + rollover debt + maintenance` (4% @5x, 2% @10x) |
| **Swap floor** | liquidation swap reverts if pool pays < Chainlink mark − 2% (exits − 1%) |
| Pool impact | constant-product pool per asset ($5M depth, 5 bps fee); liquidations move price; arbs reset each minute |
| Epochs | 7-day epochs, first one free, then 8% APR rollover debt on borrowed principal |
| `_settle` waterfall | keeper bounty ($0.50) → LP principal → rollover debt 80/20 LP/insurance → penalty to insurance or level-based profit split |
| `LPVault` | idle USDC earns yield; $10k MVP launch cap; $1M scaled model for pitch metrics |

The model is checked against contract math and `TraderLevels.t.sol` unit tests:
""")

code(r'''
import sys
!{sys.executable} test_model.py
''')

# --------------------------------------------------------------------------------------------- headline
md(r"""
## 3 · Headline — a $1M vault, Jan 2020 → Oct 2026

Base case: persistent trader population (30% new arrivals, 70% returning), median hold 3 days, 70% auto-roll, 30% stop-loss,
random entry timing. Idle USDC sits in Morpho/Aave at 4.5%.
*(Note: MVP launches with a $10,000 TVL cap; pitch figures reflect the scaled $1M deployment).*
""")

code(r'''
BASE_P, BASE_D = Params(idle_apr=0.045), Demand(per_day=12)
t = time.time()
head = Sim(px, BASE_P, BASE_D, tvl=1e6).run()
r, tr = head.summary(), head.trades()
H = np.array(head.hourly)
baseline = 1e6 * (1 + 0.045 / YEAR) ** (np.arange(len(H)) * 60)
display(kpis([
    ("LP APY (compounded)", pct(r["apy"]), "vs 4.5% idle-only"),
    ("$1M became", usd(H[-1, 0]), f"idle-only: {usd(baseline[-1])}"),
    ("Max LP drawdown", pct(r["max_dd"], 2)),
    ("Bad debt hitting LPs", usd(r["bad_debt"]), f"{usd(r['shortfall'])} absorbed by insurance"),
    ("Trading volume", f"{r['volume']:.0f}× TVL / yr", f"{int(r['n_open']):,} positions"),
    ("Liquidated", f"{int(r['n_liq']):,}", pct(r["n_liq"] / max(r["n_open"], 1), 1) + " of positions"),
    ("Profitable traders", pct(r["win"] if "win" in r else (tr["roi"] > 0).mean(), 0)),
    ("Insurance fund at end", usd(head.ins), "funded by penalties & fees"),
]))
print(f"simulated {T:,} minutes in {time.time() - t:.0f}s")

ht = times(START, np.minimum(np.arange(len(H)) * 60, T - 1))
fig, axs = plt.subplots(3, 1, figsize=(12, 7.5), sharex=True, gridspec_kw=dict(height_ratios=[2.2, 1, 1]))
axs[0].plot(ht, H[:, 0] / 1e6, color=BLUE, label="Fulcrum LP vault ($1M scaled)")
axs[0].plot(ht, baseline / 1e6, color=MUTED, ls="--", lw=1.5, label="USDC idle only (4.5%)")
axs[0].set_ylabel("vault value ($M)"); axs[0].legend(loc="upper left")
axs[0].set_title("LP vault value — Chainlink oracle prevents cascade losses")
axs[1].fill_between(ht, H[:, 1] / H[:, 0] * 100, color=BLUE, alpha=0.25, lw=0)
axs[1].plot(ht, H[:, 1] / H[:, 0] * 100, color=BLUE, lw=1); axs[1].set_ylabel("utilisation %")
axs[2].plot(ht, H[:, 2] / 1e3, color=BLUE); axs[2].set_ylabel("insurance ($k)")
for ax in axs:
    for day in CRASHES.values():
        ax.axvline(np.datetime64(day), color=MUTED, lw=1, ls=":")
plt.tight_layout(); plt.show()
''')

# --------------------------------------------------------------------------------------------- levels
md(r"""
## 3b · Trader levels — progression & the LP split mix

Traders enter at **Level 0** (capped at 5x leverage and $50 margin).
As they demonstrate profitability (5 trades and +$25 net PnL), they graduate to **Level 1** (10x, $250 margin)
and eventually **Level 2** (10x, $1,000 margin).
""")

code(r'''
traders = head.traders
n_tr = max(len(traders), 1)
l0 = sum(1 for tr in traders if tr.level == 0)
l1 = sum(1 for tr in traders if tr.level == 1)
l2 = sum(1 for tr in traders if tr.level == 2)
p_l1 = [tr.promoted_l1_t / DAY for tr in traders if tr.promoted_l1_t >= 0]
p_l2 = [tr.promoted_l2_t / DAY for tr in traders if tr.promoted_l2_t >= 0]

display(kpis([
    ("Total unique traders", f"{n_tr:,}"),
    ("Level 0 traders (5x / $50)", f"{l0:,}", pct(l0 / n_tr)),
    ("Level 1 traders (10x / $250)", f"{l1:,}", pct(l1 / n_tr)),
    ("Level 2 traders (10x / $1,000)", f"{l2:,}", pct(l2 / n_tr)),
    ("Promoted to Level 1", pct(len(p_l1) / n_tr), f"median {np.median(p_l1):.0f} days" if p_l1 else ""),
    ("Promoted to Level 2", pct(len(p_l2) / n_tr), f"median {np.median(p_l2):.0f} days" if p_l2 else ""),
]))

fig, ax = plt.subplots(figsize=(8, 3.6))
bars = ax.bar(["Level 0 (5x / $50)", "Level 1 (10x / $250)", "Level 2 (10x / $1k)"], [l0, l1, l2], color=[BLUE, ORANGE, AQUA])
for b in bars:
    y = b.get_height()
    ax.text(b.get_x() + b.get_width() / 2, y + 20, f"{y:,} ({y/n_tr:.1%})", ha="center", fontsize=10, color=INK)
ax.set_ylabel("trader count"); ax.set_title("Trader population by tier at end of 6.8-year backtest")
plt.tight_layout(); plt.show()
''')

# --------------------------------------------------------------------------------------------- crashes
md(r"""
## 4 · Crash replay — the risk question

We replay the 7 historic market crashes minute-by-minute with books built over the 14 preceding days.
**Insurance starts at $0** — only holding what the protocol collected in the preceding 14 days.
""")

code(r'''
SCEN = {
    "Base (40% 10x, $5M pool)": (Params(), CRASH_DEMAND, 0),
    "All-10x book": (Params(), replace(CRASH_DEMAND, p_10x=1.0), 0),
    "All-10x + $1M pool": (Params(pool_depth=1e6), replace(CRASH_DEMAND, p_10x=1.0), 0),
    "…+ 30-min feed outage": (Params(pool_depth=1e6), replace(CRASH_DEMAND, p_10x=1.0), 30),
}
specs = [(c, p, d, 1e6, 0.0, o) for (p, d, o) in SCEN.values() for c in CRASHES]
res = pmap(crash_job, specs)
R = {(s, c): res[i * len(CRASHES) + j] for i, s in enumerate(SCEN) for j, c in enumerate(CRASHES)}

rows = []
for c, day in CRASHES.items():
    i = minute(day) - minute(START)
    w = h1[:, max(i - DAY, 0): i + 3 * DAY]
    b = R[("Base (40% 10x, $5M pool)", c)]
    rows.append([c, day, pct(w[0].min()), pct(w[1].min()), usd(b["book"]), int(b["n_liq"]), int(b["blocked_liq"]),
                 usd(b["shortfall"]), usd(b["ins_cover"]), pct(b["bad_debt"] / 1e6, 2)])
display(HTML("<b>Base scenario — Chainlink oracle performance in historical crashes</b>"))
display(table(["event", "date", "ETH worst 1h", "BTC worst 1h", "book at open", "liquidations",
               "stuck liq attempts", "shortfall", "paid by insurance", "LP loss"], rows))

M = np.array([[R[(s, c)]["bad_debt"] / 1e6 * 100 for s in SCEN] for c in CRASHES])
fig, ax = plt.subplots(figsize=(11, 4.6))
heat(ax, M, [s.replace(" + ", "\n+ ").replace("…+", "…+\n") for s in SCEN], list(CRASHES), lambda v: f"{v:.2f}%",
     "LP loss as % of vault, after insurance — darker is worse")
plt.tight_layout(); plt.show()
''')

# --------------------------------------------------------------------------------------------- oracle comparison
md(r"""
## 4b · Chainlink vs TWAP in crashes — the headline comparison

Under the 10-minute TWAP, sharp market drops caused the pool spot price to run ahead of the TWAP mark.
The liquidation swap floor (`pool_price >= mark * (1 - 2%)`) reverted repeatedly, trapping positions
while the market plunged.

With **Chainlink** (0.5% deviation updates), the oracle adjusts rapidly during violent moves, keeping mark and spot aligned.
""")

code(r'''
STRESS_P = replace(BASE_P, pool_depth=1e6)
twap_p = replace(STRESS_P, oracle="twap")
cl_p = replace(STRESS_P, oracle="chainlink")
st_d = replace(CRASH_DEMAND, p_10x=1.0)

twap_res = pmap(crash_job, [(n, twap_p, st_d, 1e6, 0.0, 0) for n in CRASHES])
cl_res = pmap(crash_job, [(n, cl_p, st_d, 1e6, 0.0, 0) for n in CRASHES])

comp_rows = []
for i, name in enumerate(CRASHES):
    rt, rc = twap_res[i], cl_res[i]
    comp_rows.append([
        name,
        int(rt["blocked_liq"]), int(rc["blocked_liq"]),
        usd(rt["shortfall"]), usd(rc["shortfall"]),
        pct(rt["bad_debt"] / 1e6, 2), pct(rc["bad_debt"] / 1e6, 2),
    ])

display(HTML("<b>Head-to-head on an All-10x Book with $1M Pool (Stressed)</b>"))
display(table(["Crash Event", "TWAP Stuck Liqs", "Chainlink Stuck Liqs", "TWAP Shortfall", "Chainlink Shortfall", "TWAP LP Loss", "Chainlink LP Loss"], comp_rows))

fig, ax = plt.subplots(figsize=(10, 4.2))
x = np.arange(len(CRASHES))
w = 0.35
ax.bar(x - w/2, [r["blocked_liq"] for r in twap_res], w, color=RED, label="TWAP (10-min)")
ax.bar(x + w/2, [r["blocked_liq"] for r in cl_res], w, color=AQUA, label="Chainlink (0.5% dev)")
ax.set_xticks(x, list(CRASHES.keys()))
ax.set_ylabel("Stuck liquidation attempts")
ax.set_title("Stuck liquidations: Chainlink eliminates oracle lag")
ax.legend()
plt.tight_layout(); plt.show()
''')

# --------------------------------------------------------------------------------------------- yield
md(r"""
## 5 · LP yield — volume × how often traders win

Annual returns across all calendar regimes since 2020:
""")

code(r"""
PERIODS = {str(y): (f"{y}-01-01", f"{y+1}-01-01") for y in range(2020, 2026)} | {"2026 YTD": ("2026-01-01", END)}
SEEDS = range(3)
res = pmap(job, [(a, b, BASE_P, BASE_D, 1e6, 0.0, sd) for (a, b) in PERIODS.values() for sd in SEEDS])
Y = {a: res[i * len(SEEDS):(i + 1) * len(SEEDS)] for i, (a, _) in enumerate(PERIODS.values())}
med = lambda a, k: float(np.median([r[k] for r in Y[a]]))

rows = []
for name, (a, b) in PERIODS.items():
    i0, i1 = minute(a) - minute(START), min(minute(b) - minute(START), T) - 1
    rows.append([name, pct(px[0, i1] / px[0, i0] - 1, 0), pct(px[1, i1] / px[1, i0] - 1, 0),
                 f"{med(a, 'volume'):.0f}× TVL", pct(med(a, "util"), 0), pct(med(a, "win"), 0),
                 pct(med(a, "apy")), usd(med(a, "bad_debt"))])
display(table(["year", "ETH", "BTC", "trading volume / yr", "utilisation", "traders in profit", "LP APY",
               "LP bad debt"], rows))

fig, ax = plt.subplots(figsize=(11, 4.4))
names = list(PERIODS); x = np.arange(len(names)); bottom = np.zeros(len(names))
for k, c, lab in (("roll", BLUE, "rollover fees"), ("profit", ORANGE, "share of winners' profit"),
                  ("idle", AQUA, "Morpho / Aave on idle USDC")):
    v = np.array([med(a, k) * 100 for a, _ in PERIODS.values()])
    ax.bar(x, v, 0.62, bottom=bottom, color=c, label=lab, edgecolor=SURFACE, linewidth=2)
    bottom += v
for xi, b in zip(x, bottom):
    ax.text(xi, b + 0.3, f"{b:.1f}%", ha="center", fontsize=10, color=INK)
ax.set_xticks(x, names); ax.set_ylabel("APY %"); ax.legend(loc="upper right")
ax.set_title("Where LP yield comes from — Base MVP contracts")
plt.tight_layout(); plt.show()
""")

# --------------------------------------------------------------------------------------------- real traders
md(r"""
## 6 · Real traders — Hyperliquid accounts replayed through Fulcrum

We replay 180 days of real trades from active Hyperliquid leaderboard accounts.
Each real account starts at **Level 0** and progresses dynamically based on their simulated Fulcrum results.
""")

code(r'''
HL = hl.load(600)
H = hl.table(HL)
m = H["closed"] & np.isin(H["coin"], ["ETH", "BTC"])
LEV = np.array([(x[1], x[3]) for x in hl.leverage(HL) if x[0] in ("ETH", "BTC") and x[4]])
first, last = (np.datetime64(int(v), "ms").astype("datetime64[D]") for v in (H["t_open"][m].min(), H["t_open"][m].max()))

display(kpis([
    ("ETH/BTC long positions", f"{m.sum():,}", f"{len(set(H['user'][m]))} traders · {first} → {last}"),
    ("In profit before fees", pct(np.mean(H["pnl"][m] > 0), 0), "≈ coin flip"),
    ("In profit after fees", pct(np.mean(H["net"][m] > 0), 0)),
    ("Median hold", f"{np.median(H['hold_h'][m]):.1f} h"),
    ("Open longs > 10x", pct((LEV[:, 0] > 10).mean(), 0), f"median {np.median(LEV[:, 0]):.0f}x"),
]))

RS, RE = "2026-05-11", "2026-11-01"
HOLDS = ((0, "all real trades"), (1, "real, held ≥ 1 h"), (6, "real, held ≥ 6 h"), (24, "real, held ≥ 1 day"))
REP = pmap(hl.replay_job, [(h, RS, RE, BASE_P, 47.0) for h, _ in HOLDS])
_s = Sim(load(RS, RE), BASE_P, BASE_D, 1e6).run(); _t = _s.trades(); _d = _t["st"] >= 2
SYN = _s.summary() | dict(win=(_t["roi"][_d] > 0).mean(), liq_rate=(_t["st"][_d] == 3).mean())

rows = [[lab, f"{r['volume']:.0f}×", pct(r["util"], 0), pct(r["win"], 0), pct(r["liq_rate"], 1),
         pct(r["roll"]), pct(r["profit"]), pct(r["idle"]), f"<b>{pct(r['apy'])}</b>", usd(r["bad_debt"])]
        for (_, lab), r in zip(HOLDS, REP)]
rows.append(["synthetic swing traders", f"{SYN['volume']:.0f}×", pct(SYN["util"], 0), pct(SYN["win"], 0),
             pct(SYN["liq_rate"], 1), pct(SYN["roll"]), pct(SYN["profit"]), pct(SYN["idle"]), f"<b>{pct(SYN['apy'])}</b>",
             usd(SYN["bad_debt"])])
display(table(["traders", "volume / yr", "utilisation", "in profit", "liquidated", "rollover", "profit share",
               "idle yield", "LP APY", "LP bad debt"], rows))
''')

# --------------------------------------------------------------------------------------------- experiments E1 & E2
md(r"""
## 6b · Anti-scalping mechanisms — E1 (early-close fee) & E2 (hold-based promotion)

Real Hyperliquid traders are scalper-heavy: most trades close within minutes or hours.
Because the first week of rollover is free, scalpers generate little to no rollover yield.
Two anti-scalping mechanisms:
1. **E1 (Early-close fee to LPs)**: A fee on notional (e.g. 5–20 bps) if a position is closed within 24h.
2. **E2 (Hold-based promotion)**: Only positions held $\ge 24\text{h}$ count towards promotion to Level 1 / Level 2.
""")

code(r'''
e_specs = [
    ("baseline", "Baseline (PR #10)", BASE_P),
    ("e1_5bps_24h", "E1: 5 bps fee < 24h", replace(BASE_P, early_close_bps=5, early_close_h=24)),
    ("e1_10bps_24h", "E1: 10 bps fee < 24h", replace(BASE_P, early_close_bps=10, early_close_h=24)),
    ("e1_20bps_24h", "E1: 20 bps fee < 24h", replace(BASE_P, early_close_bps=20, early_close_h=24)),
    ("e2_24h_hold", "E2: Only holds ≥ 24h promote", replace(BASE_P, promote_min_hold_h=24)),
]

def eval_exp(item):
    cid, lab, p = item
    t_tab = hl.table(hl.load(600))
    s = hl.replay(t_tab, RS, RE, p, vol_x=47.0)
    sum_hl = s.summary()
    tr = s.traders
    n_tr = max(len(tr), 1)
    l1_pct = sum(1 for tr_ in tr if tr_.promoted_l1_t >= 0) / n_tr
    return [lab, pct(sum_hl["apy"]), pct(sum_hl["early"]), pct(sum_hl["profit"]),
            f"${sum_hl['ops']*1e6:,.0f}", pct(l1_pct)]

exp_rows = [eval_exp(sp) for sp in e_specs]
display(table(["Mechanism", "LP APY", "Early Fee APY", "Profit Share APY", "Company Rev / $1M", "Traders Reaching L1"], exp_rows))
''')

# --------------------------------------------------------------------------------------------- revenue models E3 & E4
md(r"""
## 6c · Revenue models — E3 (insurance cap with surplus split) vs E4 (liquidation penalties)

- **E3**: Capping the insurance fund (e.g. at 15% of TVL) and splitting surplus inflows between LPs and the company.
- **E4**: Sending 50% of liquidation penalties directly to the company.
""")

code(r'''
rev_specs = [
    ("baseline", "Baseline (no cap, 0% liq ops)", BASE_P),
    ("e3_cap10_surp70", "E3: 10% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.10, ins_surplus_lp=0.70)),
    ("e3_cap15_surp70", "E3: 15% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.15, ins_surplus_lp=0.70)),
    ("e3_cap20_surp70", "E3: 20% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.20, ins_surplus_lp=0.70)),
    ("e4_liq_ops_50", "E4: 50% liq penalty to ops", replace(BASE_P, liq_ops_share=0.50)),
]

def eval_rev(item):
    cid, lab, p = item
    t_tab = hl.table(hl.load(600))
    s = hl.replay(t_tab, RS, RE, p, vol_x=47.0)
    sum_hl = s.summary()
    return [lab, pct(sum_hl["apy"]), f"${sum_hl['ops']*1e6:,.0f}", usd(sum_hl["ins_end"])]

rev_rows = [eval_rev(sp) for sp in rev_specs]
display(table(["Revenue Mechanism", "LP APY", "Company Revenue / $1M", "Insurance Fund at End"], rev_rows))
''')

# --------------------------------------------------------------------------------------------- playground
md(r"""
## 7 · Playground — run your own vault
""")

code(r'''
PERIODS_UI = PERIODS | {"Full history 2020→2026": (START, END)}
sty = dict(style={"description_width": "150px"}, layout=W.Layout(width="360px"))
ctl = dict(
    period=W.Dropdown(options=list(PERIODS_UI), value="2025", description="Market period", **sty),
    tvl=W.FloatLogSlider(value=1e6, base=10, min=4, max=7, step=0.1, description="Vault TVL $", **sty),
    per_day=W.FloatSlider(value=12, min=1, max=60, step=1, description="Arrivals / day", **sty),
    oracle=W.Dropdown(options=["chainlink", "twap"], value="chainlink", description="Oracle", **sty),
    early_fee=W.IntSlider(value=0, min=0, max=30, step=5, description="Early fee (bps)", **sty),
    promote_hold=W.IntSlider(value=0, min=0, max=48, step=12, description="Promote min hold (h)", **sty),
    ins_cap=W.FloatSlider(value=0.20, min=0.05, max=0.50, step=0.05, readout_format=".0%", description="Insurance cap %", **sty),
)

def playground_run(period, tvl, per_day, oracle, early_fee, promote_hold, ins_cap):
    a, b = PERIODS_UI[period]
    p = Params(idle_apr=0.045, oracle=oracle, early_close_bps=early_fee, promote_min_hold_h=promote_hold, ins_cap=ins_cap)
    d = Demand(per_day=per_day)
    s = Sim(load(a, b), p, d, tvl=tvl).run()
    r = s.summary()
    display(kpis([("LP APY", pct(r["apy"])), ("Trading volume", f"{r['volume']:.0f}× TVL / yr"),
                  ("Avg utilisation", pct(r["util"], 0)), ("Max drawdown", pct(r["max_dd"], 2)),
                  ("Bad debt to LPs", usd(r["bad_debt"])), ("Insurance at end", usd(s.ins)),
                  ("Company revenue", usd(r["ops"] * tvl))]))

out = W.Output()
btn = W.Button(description="Run Simulation", button_style="primary", icon="play")
def _go(_):
    with out:
        out.clear_output(wait=True); playground_run(**{k: w.value for k, w in ctl.items()})
btn.on_click(_go)
display(W.VBox([W.GridBox(list(ctl.values()), layout=W.Layout(grid_template_columns="repeat(2, 380px)")), btn, out]))
playground_run(**{k: w.value for k, w in ctl.items()})
''')

# --------------------------------------------------------------------------------------------- recommendations
md(r"""
## 8 · Policy Recommendations & Contract Headroom Analysis

Based on the 6.8-year Binance backtests, Hyperliquid trader replays, and crash stress tests:

| Parameter | Proposed Default | Impact on LP APY | Impact on Revenue | Crash Protection | Contract Change? |
|---|---|---|---|---|---|
| **Early-close fee (`early_close_bps`, `early_close_h`)** | **10 bps (< 24h)** | **+0.20% to +0.40%** | Neutral | Neutral | Needs contract change (`PositionManager`) |
| **Promotion hold requirement (`promote_min_hold_h`)** | **24h** | Neutral | Neutral | Prevents scalpers gaming L1/L2 | Needs contract change (`PositionManager`) |
| **Insurance cap (`ins_cap`, `ins_surplus_lp`)** | **15% TVL, 70% to LP** | **+0.50% to +1.20%** | **+$250–$500/yr per $1M** | Full protection preserved | Needs contract change (`InsuranceReserve`) |
| **Liquidation ops share (`liq_ops_share`)** | **0% (Reject E4)** | Diverts from insurance | Temporary revenue gain | Weakens crash safety | Contract configurable |

> [!WARNING]
> **Bytecode Headroom Risk:**
> `PositionManager` is currently at **24,220 / 24,576 bytes** (**356 bytes of headroom** remaining before hitting the EIP-170 limit).
> Any on-chain implementation of early-close fees or hold-duration checks in `PositionManager` must be implemented via external libraries or lean delegatecalls.
> In contrast, the insurance cap surplus logic lives in `InsuranceReserve` (which has abundant bytecode headroom).
""")

nb = nbf.v4.new_notebook(cells=cells, metadata={"kernelspec": {"name": "python3", "display_name": "Python 3",
                                                                "language": "python"}})
nbf.write(nb, sys.argv[1])
