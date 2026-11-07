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
