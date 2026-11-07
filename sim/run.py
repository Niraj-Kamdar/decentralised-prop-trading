# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""Fulcrum backtests on Binance 1m ETH/BTC history.

  uv run sim/run.py crash                          # replay historical crashes against a full book
  uv run sim/run.py yield                          # LP APY per calendar year, several demand seeds
  uv run sim/run.py crash --set pool_depth=1e6 p_10x=1 outage=30
  uv run sim/run.py yield --years 2022 --set per_day=8 idle_apr=0.045

--set k=v overrides any Params / Demand field, plus tvl, insurance, seeds and (crash only) outage = keeper-offline
minutes starting at the steepest hour of the crash.
"""

import argparse
import ast
from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace
from datetime import date, timedelta

import numpy as np

from data import NAMES, load
from model import DAY, Demand, Params, Sim

CRASHES = {  # UTC day of the crash
    "covid": "2020-03-12",
    "may-21": "2021-05-19",
    "luna": "2022-05-11",
    "ftx": "2022-11-08",
    "yen-carry": "2024-08-05",
    "tariffs": "2025-02-03",
    "oct-10": "2025-10-10",
}
# Book is built over the 14 days before the crash: long holds, mostly auto-roll, so it is at its caps when it hits.
CRASH_DEMAND = Demand(per_day=20, margin_median=500, hold_median_days=14, p_auto=0.9, p_tp=0.0)


def configure(sets, demand):
    p, extra = Params(), dict(tvl=1e6, insurance=0.0, outage=0, seeds=5)
    for kv in sets:
        k, v = kv.split("=", 1)
        v = ast.literal_eval(v)
        if hasattr(p, k):
            p = replace(p, **{k: v})
        elif hasattr(demand, k):
            demand = replace(demand, **{k: v})
        elif k in extra:
            extra[k] = v
        else:
            raise SystemExit(f"unknown parameter {k}")
    return p, demand, extra


def pct(x):
    return f"{100 * x:7.2f}%"


def crash_sim(name, p, d, tvl=1e6, insurance=0.0, outage=0, seed=0):
    """Replay one crash: 14 days of book-building, the crash day, 3 days after. Returns (Sim, steepest-hour minute)."""
    c = date.fromisoformat(CRASHES[name])
    px = load(str(c - timedelta(14)), str(c + timedelta(4)))
    worst = int((px[:, 60:] / px[:, :-60]).min(axis=0).argmin())  # start of the steepest hour across assets
    p = replace(p, outages=((worst, outage),) if outage else ())
    return Sim(px, p, d, tvl, insurance, seed=seed).run(), worst


def crash_job(spec):
    """Picklable crash run for process pools: (name, Params, Demand, tvl, insurance, outage) -> summary."""
    s, _ = crash_sim(*spec)
    return s.summary() | dict(book=s.hourly[14 * 24][3])  # open notional at 00:00 UTC on the crash day


def job(spec):
    """Picklable period run for process pools: (start, end, Params, Demand, tvl, insurance, seed) -> summary."""
    start, end, p, d, tvl, ins, seed = spec
    s = Sim(load(start, end), p, d, tvl, ins, seed=seed).run()
    return s.summary() | dict(win=float((s.trades()["roi"] > 0).mean()) if s.n else float("nan"))


def crash(args):
    p, d, x = configure(args.set, CRASH_DEMAND)
    print(f"tvl ${x['tvl']:,.0f}  insurance ${x['insurance']:,.0f}  pool depth ${p.pool_depth:,.0f}  "
          f"10x share {d.p_10x:.0%}  outage {x['outage']}m")
    print(f"{'event':<10} {'ETH 1h':>8} {'BTC 1h':>8} {'book':>10} {'liqs':>5} {'bad':>4} "
          f"{'blocked':>7} {'shortfall':>10} {'ins paid':>9} {'LP loss':>8} {'LP ret':>8}")
    for name in CRASHES:
        s, worst = crash_sim(name, p, d, x["tvl"], x["insurance"], x["outage"])
        h1 = s.S[:, 60:] / s.S[:, :-60] - 1
        r, book = s.summary(), s.hourly[14 * 24][3]
        print(f"{name:<10} {pct(h1[0].min())} {pct(h1[1].min())} {book:>10,.0f} {r['n_liq']:>5.0f} "
              f"{r['n_bad']:>4.0f} {r['blocked_liq']:>7.0f} {r['shortfall']:>10,.0f} {r['ins_cover']:>9,.0f} "
              f"{pct(r['bad_debt'] / x['tvl'])} {pct(r['ret'])}")


def _year(spec):
    year, seed, p, d, x = spec
    return year, job((f"{year}-01-01", f"{year + 1}-01-01", p, d, x["tvl"], x["insurance"], seed))


def yields(args):
    p, d, x = configure(args.set, Demand())
    print(f"tvl ${x['tvl']:,.0f}  {d.per_day}/day  margin~${d.margin_median:,.0f}  10x {d.p_10x:.0%}  "
          f"hold~{d.hold_median_days}d  idle apr {p.idle_apr:.1%}  seeds {x['seeds']}")
    for year in args.years:  # warm the cache once instead of from every worker
        load(f"{year}-01-01", f"{year + 1}-01-01")
    jobs = [(y, s, p, d, x) for y in args.years for s in range(x["seeds"])]
    with ProcessPoolExecutor() as ex:
        res = list(ex.map(_year, jobs))
    print(f"{'year':<5} {'APY med':>8} {'APY min':>8} {'APY max':>8} {'rollover':>8} {'profit':>8} {'idle':>8} "
          f"{'bad':>8} {'max dd':>8} {'util':>8} {'liqs':>6} {'trader ROI':>10}")
    for y in args.years:
        rs = [r for yy, r in res if yy == y]
        m = {k: float(np.median([r[k] for r in rs])) for k in rs[0]}
        apys = [r["apy"] for r in rs]
        print(f"{y:<5} {pct(m['apy'])} {pct(min(apys))} {pct(max(apys))} {pct(m['roll'])} {pct(m['profit'])} "
              f"{pct(m['idle'])} {pct(-m['bad'])} {pct(m['max_dd'])} {pct(m['util'])} {m['n_liq']:>6.0f} "
              f"{pct(m['trader_roi']):>10}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("crash", "yield"))
    ap.add_argument("--years", type=int, nargs="+", default=list(range(2020, 2026)))
    ap.add_argument("--set", nargs="*", default=[], metavar="K=V")
    a = ap.parse_args()
    crash(a) if a.cmd == "crash" else yields(a)
