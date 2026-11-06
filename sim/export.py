"""Every number the app, landing page and Arkiv need, in one results.json (+ positions.json.gz: the trader sample).

  uv run --with numpy python sim/export.py [out.json]        # ~5 min on 8 cores, needs the cached data
"""

import gzip
import json
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, replace
from datetime import date, datetime, timedelta, timezone

import numpy as np

import hl
from data import load
from model import DAY, Demand, Params, Sim, settle
from run import CRASH_DEMAND, CRASHES, crash_job, job

START, END = "2020-01-01", "2026-11-01"
BASE_P, BASE_D = Params(idle_apr=0.045), Demand(per_day=12)
STRESS_P, STRESS_D = replace(BASE_P, pool_depth=1e6), replace(CRASH_DEMAND, p_10x=1.0)
YEARS = {str(y): (f"{y}-01-01", f"{y + 1}-01-01") for y in range(2020, 2026)} | {"2026 YTD": ("2026-01-01", END)}
SEEDS = range(3)
VOL, SKILL = (1 / 3, 2 / 3, 1.0, 2.0, 3.0), (0.0, 0.25, 0.5, 0.75, 1.0)
HOLDS = (0, 1, 6, 24)
RS, RE = "2026-05-11", "2026-11-01"


def headline(_):
    s = Sim(load(START, END), BASE_P, BASE_D, 1e6).run()
    tr, h = s.trades(), np.array(s.hourly)
    done = tr["st"] >= 2
    nav = h[::24, :3]  # daily (totalAssets, borrowed, insurance)
    return s.summary() | dict(
        positions=int(done.sum()), liq_rate=float((tr["st"][done] == 3).mean()),
        win=float((tr["roi"][done] > 0).mean()), daily_nav=nav[:, 0].round(0).tolist(),
        daily_util=(nav[:, 1] / nav[:, 0]).round(4).tolist(), daily_insurance=nav[:, 2].round(0).tolist())


def crash_drop(name):
    c = date.fromisoformat(CRASHES[name])
    px = load(str(c - timedelta(14)), str(c + timedelta(4)))
    return (px[:, 60:] / px[:, :-60] - 1).min(axis=1).tolist()  # worst 1h move, ETH and BTC


def worked_example():
    """10x, $100 margin, ETH +10% / ETH -8% (liquidated), straight from the settlement waterfall."""
    p = Params()
    k, ret, _, lp, ins, ops, trader, _ = settle(p, 1100, 900, 0, 100, 10, False, False)
    win = dict(position=1100, lp_principal=ret, lp_profit=lp, insurance=ins, company=ops, trader=trader)
    k, ret, _, lp, ins, ops, trader, short = settle(p, 920 * 0.999, 900, 0, 100, 10, True, True)
    liq = dict(position=920, keeper=k, lp_principal=ret, insurance=round(ins, 2), company=ops, trader=trader,
               shortfall=short)
    return dict(margin=100, leverage=10, borrowed=900, win_10pct=win, liquidated_at_minus_8pct=liq)


def real_traders(accts):
    board = hl.board()
    share = {w: float(np.mean([r[f"{w}_pnl"] > 0 for r in board if r[f"{w}_vlm"] > 0]))
             for w in ("day", "week", "month", "allTime")}
    pnl = np.sort([r["allTime_pnl"] for r in board])[::-1]
    t = hl.table(accts)
    m = t["closed"] & np.isin(t["coin"], ["ETH", "BTC"])
    buckets = []
    for lo, hi, lab in ((0, 1 / 6, "< 10 min"), (1 / 6, 1, "10 min-1 h"), (1, 6, "1-6 h"), (6, 24, "6-24 h"),
                        (24, 168, "1-7 days"), (168, 1e9, "> 1 week")):
        k = m & (t["hold_h"] >= lo) & (t["hold_h"] < hi)
        buckets.append(dict(hold=lab, share=float(k.sum() / m.sum()), win_gross=float(np.mean(t["pnl"][k] > 0)),
                            win_net=float(np.mean(t["net"][k] > 0)), liq=float(t["liq"][k].mean())))
    lev = [x[1] for x in hl.leverage(accts) if x[0] in ("ETH", "BTC") and x[4]]
    return dict(
        leaderboard=dict(accounts=len(board), in_profit=share, top1pct_profit_share=float(
            pnl[: len(pnl) // 100].sum() / pnl[pnl > 0].sum())),
        sample=dict(accounts=len(accts), traders=len(set(t["user"][m])), positions=int(m.sum()),
                    win_gross=float(np.mean(t["pnl"][m] > 0)), win_net=float(np.mean(t["net"][m] > 0)),
                    liq=float(t["liq"][m].mean()), hold_median_h=float(np.median(t["hold_h"][m])),
                    notional_median=float(np.median(t["cost"][m]))),
        by_hold=buckets, open_long_leverage=lev)


def commit():
    """GIT_SHA is baked into the docker image; locally ask git."""
    try:
        return os.environ.get("GIT_SHA") or subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                                                           capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        return "unknown"


def pick(r, *keys):
    return {k: float(r[k]) for k in keys}


YIELD_KEYS = ("apy", "roll", "profit", "idle", "util", "volume", "win", "bad_debt", "ins")


def main(out):
    accts = hl.load(600)
    with ProcessPoolExecutor() as ex:
        f_head = ex.submit(headline, None)
        f_years = ex.map(job, [(a, b, BASE_P, BASE_D, 1e6, 0.0, sd) for a, b in YEARS.values() for sd in SEEDS])
        scen = {"base": (BASE_P, CRASH_DEMAND, 0), "stress": (STRESS_P, STRESS_D, 0),
                "stress_outage_30m": (STRESS_P, STRESS_D, 30)}
        f_crash = ex.map(crash_job, [(n, p, d, 1e6, 0.0, o) for p, d, o in scen.values() for n in CRASHES])
        f_drop = ex.map(crash_drop, list(CRASHES))
        f_map = ex.map(job, [("2025-01-01", "2026-01-01", BASE_P, replace(BASE_D, per_day=BASE_D.per_day * v, skill=k),
                              1e6, 0.0, sd) for k in SKILL for v in VOL for sd in (0, 1)])
        f_rep = ex.map(hl.replay_job, [(h, RS, RE, BASE_P, 47.0) for h in HOLDS])
        syn = ex.submit(job, (RS, RE, BASE_P, BASE_D, 1e6, 0.0, 0))
        years, crash, drops, grid, rep = list(f_years), list(f_crash), list(f_drop), list(f_map), list(f_rep)
        head = f_head.result()

    n = len(SEEDS)
    yrs = {name: {k: float(np.median([r[k] for r in years[i * n:(i + 1) * n]])) for k in YIELD_KEYS}
           for i, name in enumerate(YEARS)}
    crashes = {}
    for j, sc in enumerate(scen):
        for i, name in enumerate(CRASHES):
            r = crash[j * len(CRASHES) + i]
            crashes.setdefault(name, dict(date=CRASHES[name], eth_1h=drops[i][0], btc_1h=drops[i][1]))[sc] = dict(
                book=float(r["book"]), liquidations=int(r["n_liq"]), lp_loss=float(r["bad_debt"]),
                lp_loss_pct=float(r["bad_debt"] / 1e6), insurance_paid=float(r["ins_cover"]))
    g = np.array(grid, dtype=object).reshape(len(SKILL), len(VOL), 2)
    cell = lambda k: [[float(np.mean([r[k] for r in c])) for c in row] for row in g]  # noqa: E731

    res = dict(
        meta=dict(generated=datetime.now(timezone.utc).isoformat(timespec="seconds"), prices=[START, END],
                  commit=commit(),
                  vault_tvl=1e6, params=asdict(BASE_P), demand=asdict(BASE_D)),
        example=worked_example(),
        headline={k: v for k, v in head.items() if not k.startswith("daily_")} | dict(
            start=START, end=END, daily=dict(nav=head["daily_nav"], util=head["daily_util"],
                                             insurance=head["daily_insurance"])),
        crashes=crashes,
        years=yrs,
        money_map=dict(volume_x=list(VOL), skill=list(SKILL), apy=cell("apy"), win=cell("win"),
                       volume=cell("volume"), insurance=cell("ins"), util=cell("util")),
        real_traders=real_traders(accts) | dict(replay=dict(window=[RS, RE], rows=[
            dict(min_hold_h=h) | pick(r, *YIELD_KEYS, "liq_rate") for h, r in zip(HOLDS, rep)] + [
            dict(min_hold_h=None, synthetic=True) | pick(syn.result(), *YIELD_KEYS)])),
    )
    with open(out, "w") as f:
        json.dump(res, f, default=float, separators=(",", ":"))
    pos = os.path.join(os.path.dirname(out) or ".", "positions.json.gz")
    with open(pos, "wb") as f:
        f.write(gzip.compress(json.dumps(hl.dataset(accts), separators=(",", ":")).encode(), mtime=0))
    for p in (out, pos):
        print(f"wrote {p}: {os.path.getsize(p) / 1024:.0f} KiB", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "results.json")
