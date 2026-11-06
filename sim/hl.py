"""Real trader behaviour from Hyperliquid's free public API (no keys, no S3).

  uv run --with numpy python sim/hl.py 600        # sample 600 leaderboard accounts, cache fills, print stats

Leaderboard (stats-data) -> random accounts -> userFillsByTime (last DAYS) + clearinghouseState (live leverage).
Fills are rebuilt into long positions per (user, coin): flat -> long opens, back to <= 0 closes.
"""

import gzip
import json
import os
import random
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np

CACHE = Path(os.environ.get("SIM_DATA", Path(__file__).parent / "data")) / "hl"
API = "https://api.hyperliquid.xyz/info"
BOARD = "https://stats-data.hyperliquid.xyz/Mainnet/leaderboard"
DAYS = 180
PAGE = 2000  # max fills per response; a full page = heavy (bot/MM-like) account, kept but flagged
_spent = []  # (time, weight) for the 1200 weight/min limit


def _post(body, weight):
    now = time.time()
    _spent[:] = [(t, w) for t, w in _spent if now - t < 60]
    if sum(w for _, w in _spent) + weight > 1000:
        time.sleep(60 - (now - _spent[0][0]) + 0.5)
    for wait in (5, 30, 60, 120):
        try:
            req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
            out = json.load(urllib.request.urlopen(req, timeout=60))
            _spent.append((time.time(), weight + (len(out) // 20 if isinstance(out, list) else 0)))
            return out
        except Exception as e:  # 429 / transient
            print(f"  retry in {wait}s: {e}", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError("Hyperliquid API unreachable")


def board():
    f = CACHE / "leaderboard.json.gz"
    if not f.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        f.write_bytes(gzip.compress(urllib.request.urlopen(BOARD, timeout=120).read()))
    rows = json.loads(gzip.decompress(f.read_bytes()))["leaderboardRows"]
    return [dict(user=r["ethAddress"], value=float(r["accountValue"]),
                 **{f"{w}_{k}": float(v[k]) for w, v in r["windowPerformances"] for k in ("pnl", "roi", "vlm")})
            for r in rows]


def account(user, since):
    """Cached {fills, state} for one address."""
    f = CACHE / f"{user}.json.gz"
    if f.exists():
        return json.loads(gzip.decompress(f.read_bytes()))
    print(f"fetching {user}", file=sys.stderr)
    fills = _post({"type": "userFillsByTime", "user": user, "startTime": since, "aggregateByTime": True}, 20)
    state = _post({"type": "clearinghouseState", "user": user}, 2)
    out = dict(fills=fills, state=state, since=since)
    f.write_bytes(gzip.compress(json.dumps(out).encode()))
    return out


def sample(n, seed=0):
    """n random leaderboard accounts that traded in the last month (so they have fills in the window)."""
    rows = [r for r in board() if r["month_vlm"] > 0]
    random.Random(seed).shuffle(rows)
    return rows[:n]


def positions(user, fills):
    """Long positions rebuilt from fills (perps only). One dict per closed or still-open long."""
    out, cur = [], {}
    for x in sorted(fills, key=lambda x: x["time"]):
        c = x["coin"]
        if c.startswith("@") or "/" in c or ":" in c:  # spot / builder-deployed markets
            continue
        start, sz, px = float(x["startPosition"]), float(x["sz"]), float(x["px"])
        after = start + (sz if x["side"] == "B" else -sz)
        p = cur.get(c)
        if p is None and start <= 0 < after:  # flat/short -> long: open (short leg, if any, is ignored)
            p = cur[c] = dict(user=user, coin=c, t_open=x["time"], cost=0.0, peak=0.0, pnl=0.0, fees=0.0,
                              fills=0, liq=False)
            sz, start = after, 0.0  # only the long leg
        if p is None:
            continue
        p["fills"] += 1
        p["fees"] += float(x["fee"])
        p["pnl"] += float(x["closedPnl"])
        if x["side"] == "B":
            p["cost"] += sz * px
        p["peak"] = max(p["peak"], max(after, 0) * px)
        p["liq"] |= (x.get("liquidation") or {}).get("liquidatedUser", "").lower() == user.lower()
        if after <= 0:
            p["t_close"] = x["time"]
            out.append(cur.pop(c))
    out += [p | dict(t_close=None) for p in cur.values()]
    return out


def table(accts):
    """Flatten positions of many accounts into column arrays."""
    ps = [p for a in accts for p in positions(a["user"], a["fills"])]
    cols = {k: np.array([p[k] for p in ps]) for k in ("user", "coin", "t_open", "cost", "peak", "pnl", "fees",
                                                     "fills", "liq")}
    cols["closed"] = np.array([p["t_close"] is not None for p in ps])
    cols["hold_h"] = np.array([((p["t_close"] or 0) - p["t_open"]) / 3.6e6 for p in ps])
    cols["net"] = cols["pnl"] - cols["fees"]
    cols["ret"] = cols["net"] / np.maximum(cols["cost"], 1e-9)  # return on notional, leverage-free
    return cols


def leverage(accts):
    """Live leverage of every open position across accounts: (coin, leverage, type, notional)."""
    out = []
    for a in accts:
        for ap in (a.get("state") or {}).get("assetPositions", []):
            q = ap["position"]
            out.append((q["coin"], float(q["leverage"]["value"]), q["leverage"]["type"], abs(float(q["positionValue"])),
                        float(q["szi"]) > 0))
    return out


def load(n=600, seed=0):
    since = int((time.time() - DAYS * 86400) * 1000) // 86_400_000 * 86_400_000
    rows = sample(n, seed)
    accts = []
    for r in rows:
        a = account(r["user"], since)
        accts.append(r | a | dict(heavy=len(a["fills"]) >= PAGE))
    return accts


if __name__ == "__main__":
    accts = load(int(sys.argv[1]) if len(sys.argv) > 1 else 600)
    t = table(accts)
    m = t["closed"] & np.isin(t["coin"], ["ETH", "BTC"])
    print(f"accounts {len(accts)}  heavy {sum(a['heavy'] for a in accts)}  long positions {len(t['coin'])}  "
          f"closed ETH/BTC {m.sum()}")
    print(f"win rate {np.mean(t['net'][m] > 0):.1%}  liq {np.mean(t['liq'][m]):.1%}  "
          f"hold median {np.median(t['hold_h'][m]):.1f}h  notional median ${np.median(t['cost'][m]):,.0f}")


def replay(t, start, end, p, tvl=1e6, vol_x=50.0, p_10x=0.8, seed=0, insurance=0.0):
    """Replay real ETH/BTC long positions through a Fulcrum vault on Binance minutes [start, end).

    Each trade keeps its real entry minute, hold and asset. Sizes are scaled by one factor so the vault sees
    vol_x × TVL of notional per year (Hyperliquid accounts are far bigger than one $1M vault); tier is drawn
    with P(10x) = p_10x since fills don't carry leverage. Returns the finished Sim.
    """
    from data import load, minute
    from model import Sim

    m = t["closed"] & np.isin(t["coin"], ["ETH", "BTC"])
    i0 = (t["t_open"][m] // 60_000 - minute(start)).astype(int)  # data.minute is unix minutes
    hold = np.maximum((t["hold_h"][m] * 60).astype(int), 1)
    keep = (i0 >= 0) & (i0 < minute(end) - minute(start))
    i0, hold, cost, coin = i0[keep], hold[keep], t["cost"][m][keep], t["coin"][m][keep]
    s = Sim(load(start, end), p, None, tvl, insurance, seed=seed)
    years = s.T / (365 * 1440)
    k = vol_x * tvl * years / cost.sum()
    tier = np.where(np.random.default_rng(seed).random(len(cost)) < p_10x, 10, 5)
    for ti, a, tr, n, h in zip(i0, (coin == "BTC").astype(int), tier, cost * k, hold):
        s.book.setdefault(int(ti), []).append((int(a), int(tr), max(n, p.min_notional) / tr, int(h)))
    s.run()
    s.scale = k
    return s


def replay_job(spec):
    """Picklable: (min_hold_h, start, end, Params, target_vol_x) -> summary + win/liq rates of the replayed book.

    Volume is matched to target by rescaling twice (oversized trades fail Fulcrum's 1% entry check and drop out).
    """
    min_hold, start, end, p, target = spec
    t = table(load())
    t["closed"] = t["closed"] & (t["hold_h"] >= min_hold)
    vx = target
    for _ in range(3):
        s = replay(t, start, end, p, vol_x=vx)
        vx *= target / max(s.summary()["volume"], 1e-9)
    tr = s.trades()
    d = tr["st"] >= 2
    return s.summary() | dict(win=float((tr["roi"][d] > 0).mean()), liq_rate=float((tr["st"][d] == 3).mean()),
                              trades=int(s.L["n_open"]), rejected=int(s.L["rej_entry"] + s.L["rej_cap"]))


def dataset(accts):
    """The rebuilt ETH/BTC long positions as compact columns: the frozen sample published to Arkiv."""
    t = table(accts)
    m = np.isin(t["coin"], ["ETH", "BTC"])
    users = sorted(set(t["user"][m]))
    ix = {u: i for i, u in enumerate(users)}
    return dict(
        users=users,
        user=[ix[u] for u in t["user"][m]], btc=(t["coin"][m] == "BTC").astype(int).tolist(),
        t_open=t["t_open"][m].astype(int).tolist(), hold_h=t["hold_h"][m].round(4).tolist(),
        cost=t["cost"][m].round(2).tolist(), pnl=t["pnl"][m].round(2).tolist(), fees=t["fees"][m].round(2).tolist(),
        liq=t["liq"][m].astype(int).tolist(), closed=t["closed"][m].astype(int).tolist(),
        open_long_leverage=[x[1] for x in leverage(accts) if x[0] in ("ETH", "BTC") and x[4]])
