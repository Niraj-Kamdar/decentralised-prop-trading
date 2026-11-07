"""Every number the app, landing page and Arkiv need, in one results.json (+ positions.json.gz: the trader sample).

  uv run --with numpy python sim/export.py [out.json]        # ~1-2 min on 8 cores, needs the cached data
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
from model import DAY, Demand, LpFlow, Params, Sim, settle
from run import CRASH_DEMAND, CRASHES, crash_job, job

START, END = "2020-01-01", "2026-11-01"
BASE_P, BASE_D = Params(idle_apr=0.045), Demand(per_day=12)
STRESS_P, STRESS_D = replace(BASE_P, pool_depth=1e6), replace(CRASH_DEMAND, p_10x=1.0)
YEARS = {str(y): (f"{y}-01-01", f"{y + 1}-01-01") for y in range(2020, 2026)} | {"2026 YTD": ("2026-01-01", END)}
SEEDS = range(3)
VOL, SKILL = (1 / 3, 2 / 3, 1.0, 2.0, 3.0), (0.0, 0.25, 0.5, 0.75, 1.0)
HOLDS = (0, 1, 6, 24)
RS, RE = "2026-05-11", "2026-11-01"


def finite(o):
    """JSON has no Infinity/NaN: write them as null."""
    if isinstance(o, dict): return {k: finite(v) for k, v in o.items()}
    if isinstance(o, list): return [finite(v) for v in o]
    return None if isinstance(o, float) and not np.isfinite(o) else o


def headline(_):
    s = Sim(load(START, END), BASE_P, BASE_D, 1e6).run()
    tr, h = s.trades(), np.array(s.hourly)
    done = tr["st"] >= 2
    nav = h[::24, :3]  # daily (totalAssets, borrowed, insurance)

    # Synthetic trader level progression stats
    traders = s.traders
    n_tr = max(len(traders), 1)
    l0 = sum(1 for t in traders if t.level == 0)
    l1 = sum(1 for t in traders if t.level == 1)
    l2 = sum(1 for t in traders if t.level == 2)
    p_l1 = [t.promoted_l1_t / DAY for t in traders if t.promoted_l1_t >= 0]
    p_l2 = [t.promoted_l2_t / DAY for t in traders if t.promoted_l2_t >= 0]

    level_stats = dict(
        total_traders=len(traders),
        distribution=dict(L0=l0, L1=l1, L2=l2),
        distribution_pct=dict(L0=round(l0 / n_tr, 4), L1=round(l1 / n_tr, 4), L2=round(l2 / n_tr, 4)),
        promoted_l1_share=round(len(p_l1) / n_tr, 4),
        promoted_l2_share=round(len(p_l2) / n_tr, 4),
        time_to_l1_days_median=round(float(np.median(p_l1)), 1) if p_l1 else None,
        time_to_l2_days_median=round(float(np.median(p_l2)), 1) if p_l2 else None,
    )

    return s.summary() | dict(
        positions=int(done.sum()), liq_rate=float((tr["st"][done] == 3).mean()),
        win=float((tr["roi"][done] > 0).mean()), daily_nav=nav[:, 0].round(0).tolist(),
        daily_util=(nav[:, 1] / nav[:, 0]).round(4).tolist(), daily_insurance=nav[:, 2].round(0).tolist(),
        level_stats=level_stats)


def crash_drop(name):
    c = date.fromisoformat(CRASHES[name])
    px = load(str(c - timedelta(14)), str(c + timedelta(4)))
    return (px[:, 60:] / px[:, :-60] - 1).min(axis=1).tolist()  # worst 1h move, ETH and BTC


def worked_example():
    """10x, $100 margin, ETH +10% / ETH -8% (liquidated), straight from the settlement waterfall on Base Level 1."""
    p = Params()
    # Level 1: 10% LP profit cut, 3% treasury (half to insurance, half to ops)
    k, ret, _, lp, ins, ops, trader, _ = settle(p, 1100, 900, 0, 100, 10, False, False, level=1)
    win = dict(position=1100, lp_principal=ret, lp_profit=lp, insurance=ins, company=ops, trader=trader)
    # Liquidation: keeper bounty ($0.50) paid first, principal ($900), remainder to insurance
    k, ret, _, lp, ins, ops, trader, short = settle(p, 920 * 0.999, 900, 0, 100, 10, True, True, level=1)
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


EXPERIMENT_CONFIGS = [
    ("baseline", "Baseline (PR #10)", BASE_P),
    ("e1_5bps_24h", "E1: 5 bps fee < 24h", replace(BASE_P, early_close_bps=5, early_close_h=24)),
    ("e1_10bps_24h", "E1: 10 bps fee < 24h", replace(BASE_P, early_close_bps=10, early_close_h=24)),
    ("e1_20bps_24h", "E1: 20 bps fee < 24h", replace(BASE_P, early_close_bps=20, early_close_h=24)),
    ("e1_10bps_1h", "E1: 10 bps fee < 1h", replace(BASE_P, early_close_bps=10, early_close_h=1)),
    ("e1_10bps_6h", "E1: 10 bps fee < 6h", replace(BASE_P, early_close_bps=10, early_close_h=6)),
    ("e2_24h_hold", "E2: Hold >= 24h for promotion", replace(BASE_P, promote_min_hold_h=24)),
    ("e3_cap10_surp70", "E3: 10% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.10, ins_surplus_lp=0.70)),
    ("e3_cap15_surp70", "E3: 15% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.15, ins_surplus_lp=0.70)),
    ("e3_cap20_surp70", "E3: 20% ins cap, 70% to LP", replace(BASE_P, ins_cap=0.20, ins_surplus_lp=0.70)),
    ("e3_cap15_surp50", "E3: 15% ins cap, 50% to LP", replace(BASE_P, ins_cap=0.15, ins_surplus_lp=0.50)),
    ("e3_cap15_surp100", "E3: 15% ins cap, 100% to LP", replace(BASE_P, ins_cap=0.15, ins_surplus_lp=1.00)),
    ("e4_liq_ops_50", "E4: 50% liq penalty to company", replace(BASE_P, liq_ops_share=0.50)),
]


def run_single_experiment(spec):
    """Run one experiment config across HL replay, 2025 synthetic, and 7 crashes."""
    cid, label, p = spec
    t = hl.table(hl.load(600))
    # 1. Hyperliquid replay
    s_hl = hl.replay(t, RS, RE, p, vol_x=47.0)
    sum_hl = s_hl.summary()
    traders = s_hl.traders
    n_tr = max(len(traders), 1)
    l1_share = sum(1 for tr in traders if tr.promoted_l1_t >= 0) / n_tr
    l2_share = sum(1 for tr in traders if tr.promoted_l2_t >= 0) / n_tr
    p_l1 = [tr.promoted_l1_t / DAY for tr in traders if tr.promoted_l1_t >= 0]
    time_to_l1 = float(np.median(p_l1)) if p_l1 else None

    # 2. 2025 synthetic swing traders
    s_syn = Sim(load("2025-01-01", "2026-01-01"), p, BASE_D, 1e6, seed=0).run()
    sum_syn = s_syn.summary()

    # 3. Crash replays with stress + 30m outage
    st_p = replace(p, pool_depth=1e6)
    st_d = replace(CRASH_DEMAND, p_10x=1.0)
    crash_bad_debt = 0.0
    crash_shortfall = 0.0
    crash_ins_paid = 0.0
    for name in CRASHES:
        res = crash_job((name, st_p, st_d, 1e6, 0.0, 30))
        crash_bad_debt += res["bad_debt"]
        crash_shortfall += res["shortfall"]
        crash_ins_paid += res["ins_cover"]

    return dict(
        id=cid, label=label,
        hl_replay=dict(
            lp_apy=float(sum_hl["apy"]),
            roll_apy=float(sum_hl["roll"]),
            profit_apy=float(sum_hl["profit"]),
            early_fee_apy=float(sum_hl["early"]),
            idle_apy=float(sum_hl["idle"]),
            company_rev_per_m=float(sum_hl["ops"] * 1e6),
            ins_end=float(sum_hl["ins_end"]),
            ins_cover=float(sum_hl["ins_cover"]),
            bad_debt=float(sum_hl["bad_debt"]),
            volume=float(sum_hl["volume"]),
            promoted_l1_share=round(l1_share, 4),
            promoted_l2_share=round(l2_share, 4),
            time_to_l1_days=round(time_to_l1, 1) if time_to_l1 is not None else None,
        ),
        syn_2025=dict(
            lp_apy=float(sum_syn["apy"]),
            company_rev_per_m=float(sum_syn["ops"] * 1e6),
            bad_debt=float(sum_syn["bad_debt"]),
        ),
        crashes_stress_30m=dict(
            total_bad_debt=float(crash_bad_debt),
            total_shortfall=float(crash_shortfall),
            total_ins_paid=float(crash_ins_paid),
        )
    )


def with_levels(p, l0=(5, 25.0, 0.0), l1=(10, 100.0, 0.0), hold_h=0):
    """Promotion thresholds per level as (min trades, min pnl $, min roi on margin); demotion is untouched."""
    lv = {k: replace(v) for k, v in p.levels.items()}
    for k, (n, usd, roi) in ((0, l0), (1, l1)):
        lv[k] = replace(lv[k], promote_min_trades=n, promote_min_pnl=usd, promote_min_roi=roi)
    return replace(p, levels=lv, promote_min_hold_h=hold_h)


LEVEL_SWEEP = [
    ("current", "Current: 5 trades/+$25, 10/+$100", BASE_P),
    ("n3_5", "3/5 trades, same $", with_levels(BASE_P, (3, 25., 0), (5, 100., 0))),
    ("n0", "No trade count, same $", with_levels(BASE_P, (0, 25., 0), (0, 100., 0))),
    ("n3_5_usd10_50", "3/5 trades, +$10/+$50", with_levels(BASE_P, (3, 10., 0), (5, 50., 0))),
    ("n0_usd10_50", "No count, +$10/+$50", with_levels(BASE_P, (0, 10., 0), (0, 50., 0))),
    ("n3_5_roi20", "3/5 trades, +20% of margin", with_levels(BASE_P, (3, 0, .2), (5, 0, .2))),
    ("n0_roi10", "No count, +10% of margin", with_levels(BASE_P, (0, 0, .1), (0, 0, .1))),
    ("n3_5_usd10_50_h24", "3/5, +$10/+$50, hold >= 24h", with_levels(BASE_P, (3, 10., 0), (5, 50., 0), 24)),
    ("n3_5_roi20_h24", "3/5, +20% of margin, hold >= 24h", with_levels(BASE_P, (3, 0, .2), (5, 0, .2), 24)),
]


def level_metrics(s):
    """APY, utilisation, level mix, median days to L1/L2, and the share of promoted traders still profitable."""
    tr, r = s.traders, s.summary()
    n = max(len(tr), 1)
    med = lambda ts: round(float(np.median(ts)) / DAY, 1) if ts else None  # noqa: E731
    after = [t.pnl_after > 0 for t in tr if t.promoted_l1_t >= 0 and t.n_after > 0]
    return dict(
        apy=float(r["apy"]), util=float(r["util"]), traders=len(tr),
        pct={f"L{i}": round(sum(t.level == i for t in tr) / n, 4) for i in range(3)},
        days_to_l1=med([t.promoted_l1_t for t in tr if t.promoted_l1_t >= 0]),
        days_to_l2=med([t.promoted_l2_t for t in tr if t.promoted_l2_t >= 0]),
        promoted=sum(t.promoted_l1_t >= 0 for t in tr), promoted_profitable=round(float(np.mean(after)), 4) if after else None)


def level_sweep_job(spec):
    """One (config, kind) run: synthetic headline demand, Hyperliquid replay, or the 7 crashes (base + stress)."""
    (cid, _, p), kind = spec
    if kind == "syn":
        return level_metrics(Sim(load(START, END), p, BASE_D, 1e6).run())
    if kind == "hl":
        return level_metrics(hl.replay(hl.table(hl.load(600)), RS, RE, p, vol_x=47.0))
    loss = {}
    for sc, (cp, cd) in {"base": (p, CRASH_DEMAND), "stress": (replace(p, pool_depth=1e6), replace(CRASH_DEMAND, p_10x=1.0))}.items():
        loss[sc] = float(sum(crash_job((n, cp, cd, 1e6, 0.0, 0))["bad_debt"] for n in CRASHES))
    return loss


CAL_TVLS = (10e3, 100e3, 1e6)


def split(r):
    """Fee / profit-cut / idle contributions that sum to APY: each part's share of total income times APY.
    (summary()'s parts are compounded income over starting TVL, so they do not add up to the share-price APY.)"""
    tot = r["roll"] + r["profit"] + r["idle"]
    return {k: float(r[k] / tot * r["apy"]) for k in ("roll", "profit", "idle")} if tot > 0 else dict(roll=0.0, profit=0.0, idle=0.0)


def mean_spread(xs):
    return dict(mean=float(np.mean(xs)), min=float(np.min(xs)), max=float(np.max(xs)), std=float(np.std(xs)))


LP_PREMIUMS = (0.01, 0.03, 0.055)


def bursts(day):
    """Distribution of the 30-day trailing share-price APY, its best/worst windows, and TVL re-settling after the
    largest one-day share-price drop (ponytail: settled = TVL within 10% of its median 180-270 days later, for 30 days)."""
    px, tv, t0 = day[:, 5], day[:, 0], date.fromisoformat(START)
    a = (px[30:] / px[:-30]) ** (365 / 30) - 1
    dt = lambda i: str(t0 + timedelta(int(i)))  # noqa: E731
    lo, hi = int(a.argmin()), int(a.argmax())
    shock = int((px[1:] / px[:-1]).argmin()) + 1
    ref_w = tv[shock + 180: shock + 270] if shock + 180 < len(tv) else tv[-90:]
    ok = np.abs(tv / np.median(ref_w) - 1) < 0.10
    settle = next((i - shock for i in range(shock, len(tv) - 30) if ok[i: i + 30].all()), None)
    return dict(p10=float(np.percentile(a, 10)), p50=float(np.percentile(a, 50)), p90=float(np.percentile(a, 90)),
                share_above_10pct=float((a > 0.10).mean()), share_below_idle=float((a < BASE_P.idle_apr).mean()),
                worst=dict(apy=float(a[lo]), start=dt(lo), end=dt(lo + 30)),
                best=dict(apy=float(a[hi]), start=dt(hi), end=dt(hi + 30)),
                shock=dict(date=dt(shock), drop=float(px[shock] / px[shock - 1] - 1), tvl_resettle_days=settle))


def lp_job(spec):
    """Elastic-TVL run: equilibrium = last year of the daily series; also yearly APY and TVL on each crash date."""
    d, premium, seed, tvl0, cap = spec
    s = Sim(load(START, END), BASE_P, d, tvl0, seed=seed, lp=LpFlow(premium=premium, max_rate=cap)).run()
    r = s.lp_report(years=1)
    day = np.array(s.daily)
    r["tvl_median"] = float(np.median(day[-365:, 0]))
    r.pop("tvl_daily")
    t0 = date.fromisoformat(START)
    ix = lambda iso: min(max((date.fromisoformat(iso) - t0).days, 0), len(day) - 1)  # noqa: E731
    r["apy_by_year"] = {n: float(day[ix(b), 5] / day[ix(a), 5] - 1) for n, (a, b) in YEARS.items()}
    r["tvl_weekly"] = day[::7, 0].round(0).tolist()
    r["bursts"] = bursts(day)
    r["tvl_at_crash"] = {n: float(day[ix(c), 0]) for n, c in CRASHES.items()}
    return r


def lp_crash(args):
    """Crash losses at the elastic TVL on the crash date."""
    d, tvls = args
    out = {}
    for n, v in tvls.items():
        for sc, (p, cd) in {"base": (BASE_P, CRASH_DEMAND), "stress": (STRESS_P, STRESS_D)}.items():
            cd = replace(cd, emp=d.emp) if d.emp is not None else cd
            if sc == "stress" and d.emp is not None:
                cd = replace(cd, emp=d.emp | dict(p_10x=1.0))
            r = crash_job((n, p, cd, v, 0.0, 0))
            out.setdefault(n, dict(tvl=v))[sc] = dict(usd=float(r["bad_debt"]), pct_tvl=float(r["bad_debt"] / v))
    return out


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

        # TWAP vs Chainlink crash comparison
        twap_p = replace(STRESS_P, oracle="twap")
        cl_p = replace(STRESS_P, oracle="chainlink")
        f_twap_crash = ex.map(crash_job, [(n, twap_p, STRESS_D, 1e6, 0.0, 0) for n in CRASHES])
        f_cl_crash = ex.map(crash_job, [(n, cl_p, STRESS_D, 1e6, 0.0, 0) for n in CRASHES])

        # Experiments E1-E4
        f_exp = ex.map(run_single_experiment, EXPERIMENT_CONFIGS)
        sweep = [[ex.submit(level_sweep_job, (c, k)) for k in ("syn", "hl", "crash")] for c in LEVEL_SWEEP]

        emp = hl.empirical(accts)
        cal_d = replace(BASE_D, per_day=emp["per_day"], p_new=emp["p_new"], emp=emp)  # real arrival rate, new-trader share
        cal_crash = {"base": (BASE_P, replace(CRASH_DEMAND, emp=emp)),
                     "stress": (STRESS_P, replace(CRASH_DEMAND, emp=emp | dict(p_10x=1.0)))}
        f_cal_full = [ex.submit(job, (START, END, BASE_P, cal_d, v, 0.0, 0)) for v in CAL_TVLS]
        lp_runs = {(k, pr): [ex.submit(lp_job, (d, pr, sd, 1e5, 0.02)) for sd in SEEDS]
                   for k, d in (("calibrated", cal_d), ("synthetic", BASE_D)) for pr in LP_PREMIUMS}
        conv_runs = {(k, v): ex.submit(lp_job, (d, 0.03, 0, v, 0.02))
                     for k, d in (("calibrated", cal_d), ("synthetic", BASE_D)) for v in (1e4, 1e6)}
        cap_runs = {(k, c): ex.submit(lp_job, (d, 0.03, 0, 1e5, c))
                    for k, d in (("calibrated", cal_d), ("synthetic", BASE_D)) for c in (0.005, 0.05)}
        lp_res = {k: [f.result() for f in fs] for k, fs in lp_runs.items()}
        f_lp_crash = {k: ex.submit(lp_crash, (cal_d if k[0] == "calibrated" else BASE_D, rs[0]["tvl_at_crash"]))
                      for k, rs in lp_res.items()}

        years, crash, drops, grid, rep = list(f_years), list(f_crash), list(f_drop), list(f_map), list(f_rep)
        twap_crash, cl_crash = list(f_twap_crash), list(f_cl_crash)
        exp_results = list(f_exp)
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

    oracle_comparison = {}
    for i, name in enumerate(CRASHES):
        rt, rc = twap_crash[i], cl_crash[i]
        oracle_comparison[name] = dict(
            date=CRASHES[name], eth_1h=drops[i][0], btc_1h=drops[i][1],
            twap=dict(liquidations=int(rt["n_liq"]), blocked_liq=int(rt["blocked_liq"]),
                      shortfall=float(rt["shortfall"]), lp_loss=float(rt["bad_debt"]),
                      lp_loss_pct=float(rt["bad_debt"] / 1e6), insurance_paid=float(rt["ins_cover"])),
            chainlink=dict(liquidations=int(rc["n_liq"]), blocked_liq=int(rc["blocked_liq"]),
                           shortfall=float(rc["shortfall"]), lp_loss=float(rc["bad_debt"]),
                           lp_loss_pct=float(rc["bad_debt"] / 1e6), insurance_paid=float(rc["ins_cover"]))
        )

    g = np.array(grid, dtype=object).reshape(len(SKILL), len(VOL), 2)
    cell = lambda k: [[float(np.mean([r[k] for r in c])) for c in row] for row in g]  # noqa: E731

    # Extract real trader replay levels
    t = hl.table(accts)
    s_baseline_rep = hl.replay(t, RS, RE, BASE_P, vol_x=47.0)
    real_traders_list = s_baseline_rep.traders
    n_rt = max(len(real_traders_list), 1)
    r_l0 = sum(1 for tr in real_traders_list if tr.level == 0)
    r_l1 = sum(1 for tr in real_traders_list if tr.level == 1)
    r_l2 = sum(1 for tr in real_traders_list if tr.level == 2)
    r_p1 = [tr.promoted_l1_t / DAY for tr in real_traders_list if tr.promoted_l1_t >= 0]
    r_p2 = [tr.promoted_l2_t / DAY for tr in real_traders_list if tr.promoted_l2_t >= 0]

    real_level_stats = dict(
        total_traders=len(real_traders_list),
        distribution=dict(L0=r_l0, L1=r_l1, L2=r_l2),
        distribution_pct=dict(L0=round(r_l0 / n_rt, 4), L1=round(r_l1 / n_rt, 4), L2=round(r_l2 / n_rt, 4)),
        promoted_l1_share=round(len(r_p1) / n_rt, 4),
        promoted_l2_share=round(len(r_p2) / n_rt, 4),
        time_to_l1_days_median=round(float(np.median(r_p1)), 1) if r_p1 else None,
        time_to_l2_days_median=round(float(np.median(r_p2)), 1) if r_p2 else None,
    )

    demand_calibrated = {}
    for v, f in zip(CAL_TVLS, f_cal_full):
        r = f.result()
        demand_calibrated[f"{int(v)}"] = dict(tvl=v, apy=float(r["apy"]), util=float(r["util"]), seeds=1, split_apy=split(r))
    ms = lambda rs, k: mean_spread([r[k] for r in rs])  # noqa: E731
    lp_equilibrium = {k: {} for k in ("synthetic", "calibrated")}
    for (k, pr), rs in lp_res.items():
        lp_equilibrium[k][f"{pr}"] = dict(
            seed_tvl=1e5, premium=pr, hurdle=BASE_P.idle_apr + pr, idle_apr=BASE_P.idle_apr, max_rate=0.02,
            tvl_median_last_year=ms(rs, "tvl_median"), apy=ms(rs, "apy"), util=ms(rs, "util"),
            premium_per_lent=ms(rs, "premium_per_lent"), split_apy={q: float(np.mean([split(r)[q] for r in rs])) for q in ("roll", "profit", "idle")},
            apy_by_year={y: float(np.mean([r["apy_by_year"][y] for r in rs])) for y in YEARS},
            tvl_weekly=rs[0]["tvl_weekly"], bursts=rs[0]["bursts"], seeds=len(rs), crash_lp_loss=f_lp_crash[(k, pr)].result())
    for (k, c), f in cap_runs.items():
        r = f.result()
        lp_equilibrium[k].setdefault("flow_cap_p3", {})[f"{c}"] = dict(
            max_rate=c, tvl_median_last_year=r["tvl_median"], apy=r["apy"], util=r["util"], bursts=r["bursts"],
            tvl_weekly=r["tvl_weekly"])
    for (k, v), f in conv_runs.items():
        r = f.result()
        lp_equilibrium[k].setdefault("convergence_p3", {})[f"{int(v)}"] = dict(
            seed_tvl=v, tvl_median_last_year=r["tvl_median"], apy=r["apy"], util=r["util"], tvl_weekly=r["tvl_weekly"])

    syn_level_stats = head.pop("level_stats")

    res = dict(
        meta=dict(generated=datetime.now(timezone.utc).isoformat(timespec="seconds"), prices=[START, END],
                  commit=commit(),
                  vault_tvl=1e6, vault_mvp=10_000, params=asdict(BASE_P), demand=asdict(BASE_D)),
        example=worked_example(),
        headline={k: v for k, v in head.items() if not k.startswith("daily_")} | dict(
            start=START, end=END, daily=dict(nav=head["daily_nav"], util=head["daily_util"],
                                             insurance=head["daily_insurance"])),
        crashes=crashes,
        oracle_comparison=oracle_comparison,
        years=yrs,
        money_map=dict(volume_x=list(VOL), skill=list(SKILL), apy=cell("apy"), win=cell("win"),
                       volume=cell("volume"), insurance=cell("ins"), util=cell("util")),
        real_traders=real_traders(accts) | dict(replay=dict(window=[RS, RE], rows=[
            dict(min_hold_h=h) | pick(r, *YIELD_KEYS, "liq_rate") for h, r in zip(HOLDS, rep)] + [
            dict(min_hold_h=None, synthetic=True) | pick(syn.result(), *YIELD_KEYS)])),
        levels=dict(synthetic=syn_level_stats, real=real_level_stats),
        experiments={exp["id"]: exp for exp in exp_results},
        demand_calibrated=demand_calibrated, lp_equilibrium=lp_equilibrium,
        levels_sweep={c[0]: dict(label=c[1], synthetic=f[0].result(), hyperliquid=f[1].result(),
                                 crash_lp_loss=f[2].result()) for c, f in zip(LEVEL_SWEEP, sweep)},
    )
    with open(out, "w") as f:  # round-trip so numpy floats become floats, then inf (an uncapped param) -> null
        json.dump(finite(json.loads(json.dumps(res, default=float))), f, separators=(",", ":"), allow_nan=False)
    pos = os.path.join(os.path.dirname(out) or ".", "positions.json.gz")
    with open(pos, "wb") as f:
        f.write(gzip.compress(json.dumps(hl.dataset(accts), separators=(",", ":")).encode(), mtime=0))
    for p in (out, pos):
        print(f"wrote {p}: {os.path.getsize(p) / 1024:.0f} KiB", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "results.json")
