"""Fulcrum protocol model at 1-minute resolution.

Ports the economics of src/PositionManager.sol, LPVault.sol, InsuranceReserve.sol and UniV4TwapOracle.sol:
open caps, TWAP-marked liquidation threshold, exit/liquidation slippage gates (a swap reverts when the pool pays
less than mark * (1 - slip), so in a fast crash positions stay stuck until the TWAP catches up), 7-day epochs with
8% APR rollover debt (first epoch free), and the settlement / bad-debt waterfall.

ponytail: vault totalAssets ignores the 12h profit vesting and the redemption queue / bonus pot (no LP flows);
the pool is a constant-product curve reset to the CEX close every minute (arbs). Add LP flows when testing bank runs.
"""

import math
from dataclasses import dataclass, field

import numpy as np

DAY = 1440
EPOCH = 7 * DAY
YEAR = 365 * DAY
NEVER = 10**15


@dataclass
class Params:
    """Defaults = PositionManager/LPVault.initialize + ProtocolDeployer.setAsset."""

    tiers: dict = field(default_factory=lambda: {5: (0.04, 0.08, 0.02), 10: (0.02, 0.12, 0.03)})  # mu, lp, treasury
    rollover_apr: float = 0.08
    lp_rollover_share: float = 0.80
    min_notional: float = 500.0
    keeper_bounty: float = 5.0
    entry_slip: float = 0.01
    exit_slip: float = 0.01
    liq_slip: float = 0.02
    max_exposure: float = 0.35  # per-asset open notional cap, share of vault totalAssets
    max_util: float = 0.85
    idle_apr: float = 0.0  # Morpho yield on idle USDC; 0 = single-vault mode
    twap_min: int = 10
    pool_depth: float = 5e6  # USDC-side virtual reserve of each asset's v4 pool (liquidity near the price)
    pool_fee: float = 0.0005
    liq_ops_share: float = 0.0  # share of liquidation penalties sent to ops instead of insurance (contract: 0)
    outages: tuple = ()  # ((start_minute, minutes), ...) keeper offline -> TWAP stale, nothing can be priced


@dataclass
class Demand:
    """Trader population. Margin and holding time are lognormal around their medians."""

    per_day: float = 4.0
    margin_median: float = 2_000.0
    margin_sigma: float = 1.0
    p_10x: float = 0.4
    asset_w: tuple = (0.5, 0.5)
    hold_median_days: float = 3.0
    hold_sigma: float = 1.2
    p_auto: float = 0.7
    p_sl: float = 0.3
    sl_frac: float = 0.5  # stop-loss this far from entry towards the liquidation price
    p_tp: float = 0.2
    tp_gain: float = 0.15
    skill: float = 0.0  # share of arrivals who call direction: they skip entries that lose by exit time and retry later


def settle(p: Params, usdc_out, B, D, M, tier, forced, is_liq):
    """PositionManager._settle. Returns (keeper, principal_ret, lp_roll, lp_profit, to_insurance, ops, trader, shortfall)."""
    u = usdc_out
    k = min(p.keeper_bounty, u) if forced else 0.0
    u -= k
    if u < B:
        return k, u, 0.0, 0.0, 0.0, 0.0, 0.0, B - u
    u -= B
    roll = min(D, u)
    u -= roll
    lp_roll = roll * p.lp_rollover_share
    to_ins = roll - lp_roll
    lp_profit = treasury = trader = liq_ops = 0.0
    if is_liq:
        liq_ops = u * p.liq_ops_share
        to_ins += u - liq_ops
    elif u <= M:
        trader = u
    else:
        _, lp_bps, tr_bps = p.tiers[tier]
        lp_profit, treasury = (u - M) * lp_bps, (u - M) * tr_bps
        trader = u - lp_profit - treasury
    ops = treasury / 2  # InsuranceReserve.fund: treasury cut split 50/50 with the insurance pool
    return k, B, lp_roll, lp_profit, to_ins + treasury - ops, ops + liq_ops, trader, 0.0


class Pools:
    """One constant-product pool per asset; arbitrage resets it to the market price every minute."""

    def __init__(self, n, depth, fee):
        self.depth, self.fee, self.t = depth, fee, -1
        self.x, self.y = np.zeros(n), np.zeros(n)

    def _sync(self, t, spot):
        if t != self.t:
            self.t = t
            self.x[:] = self.depth
            self.y[:] = self.depth / spot

    def quote_sell(self, t, spot, a, q):
        self._sync(t, spot)
        qi = q * (1 - self.fee)
        return self.x[a] * qi / (self.y[a] + qi)

    def quote_buy(self, t, spot, a, usd):
        self._sync(t, spot)
        ui = usd * (1 - self.fee)
        return self.y[a] * ui / (self.x[a] + ui)

    def apply(self, a, dx, dy):
        self.x[a] += dx
        self.y[a] += dy


FIELDS = dict(a=np.int64, tier=np.int64, N=float, M=float, B=float, D=float, Q=float,
              end=np.int64, close_t=np.int64, auto=bool, sl=float, tp=float, liq=float,
              t_open=np.int64, t_exit=np.int64, st=np.int64, paid=float)  # st: 1 open, 2 closed, 3 liquidated
LEDGER = ("margin_in", "trader_out", "keeper", "lp_roll", "lp_profit", "idle", "shortfall", "bad_debt", "ins_in",
          "ins_cover", "ops", "volume", "n_open", "n_closed", "n_liq", "n_bad", "blocked_liq", "blocked_exit",
          "rej_cap", "rej_entry")


class Sim:
    def __init__(self, prices, p=None, demand=None, tvl=1e6, insurance=0.0, seed=0, capacity=64):
        self.p = p = p or Params()
        self.S = np.asarray(prices, float)
        A, self.T = self.S.shape
        w = p.twap_min
        c = np.concatenate([np.zeros((A, 1)), np.cumsum(self.S, axis=1)], axis=1)
        self.tw = np.full((A, self.T), np.nan)
        self.tw[:, w - 1:] = (c[:, w:] - c[:, :-w]) / w
        self.ok = np.ones(self.T, bool)
        self.ok[: w - 1] = False
        for s, d in p.outages:  # stale after 90s; a gap > 300s restarts the series and needs a full warm-up
            self.ok[s: s + d + (w if d > 5 else 0)] = False

        self.mu = np.zeros(256)
        for k, (m, _, _) in p.tiers.items():
            self.mu[k] = m
        self.rng = np.random.default_rng(seed)
        self.demand = demand
        self.arrivals = self.rng.poisson(demand.per_day / DAY, self.T) if demand else np.zeros(self.T, int)
        self.retry = np.zeros(self.T, int)  # skilled traders who passed on a losing entry come back later
        self.book = {}  # minute -> [(asset, tier, margin, hold)]: scheduled real trades to replay
        cap = int(self.arrivals.sum()) + capacity
        self.P = {k: np.zeros(cap, dt) for k, dt in FIELDS.items()}
        self.n, self.open, self.dirty = 0, [], True
        self.pools = Pools(A, p.pool_depth, p.pool_fee)
        self.tvl0, self.cash, self.borrowed, self.ins = tvl, tvl, 0.0, insurance
        self.expo = np.zeros(A)
        self.L = dict.fromkeys(LEDGER, 0.0)
        self.hourly = []  # (totalAssets, borrowed, insurance, open notional)
        self.log = []  # (minute, asset, kind) kind: "liq" | "bad" (liq with shortfall) | "blocked" (liq swap reverted)

    def ta(self):
        return self.cash + self.borrowed

    def run(self):
        idle = self.p.idle_apr / YEAR
        for t in range(self.T):
            y = self.cash * idle
            self.cash += y
            self.L["idle"] += y
            if self.ok[t]:
                if self.open:
                    self._events(t)
                for _ in range(self.arrivals[t] + self.retry[t]):
                    self._arrive(t)
                for a, tier, M, hold in self.book.get(t, ()):
                    self.open_position(t, a, tier, M, auto=True, hold=hold)
            if t % 60 == 0:
                self._snap()
        for i in list(self.open):  # mark the leftover book to market: fresh pool per position, not one fire sale
            self.pools.t = -1
            self._exit(i, self.T - 1, self.S[:, -1], 1.0, False, False)
        self._snap()
        return self

    def _snap(self):
        self.hourly.append((self.ta(), self.borrowed, self.ins, self.expo.sum()))

    # ------------------------------------------------------------------ positions

    def open_position(self, t, a, tier, M, auto=True, hold=NEVER, sl_frac=0.0, tp_gain=0.0):
        p, N = self.p, M * tier
        B = N - M
        if N < p.min_notional:
            return None
        ta = self.ta()
        if self.expo[a] + N > p.max_exposure * ta or self.borrowed + B > p.max_util * ta:
            self.L["rej_cap"] += 1
            return None
        q = self.pools.quote_buy(t, self.S[:, t], a, N)
        mark, thr = q * self.tw[a, t], B + N * self.mu[tier]
        if not mark >= N * (1 - p.entry_slip) or mark <= thr:  # EntryPriceDeviation / UnhealthyAtOpen
            self.L["rej_entry"] += 1
            return None
        self.pools.apply(a, N, -q)
        entry, liq = N / q, thr / q
        i, P = self.n, self.P
        if i == len(P["a"]):
            for k in P:
                P[k] = np.resize(P[k], 2 * i)
        self.n += 1
        row = dict(a=a, tier=tier, N=N, M=M, B=B, D=0.0, Q=q, end=t + EPOCH, close_t=min(t + hold, NEVER), auto=auto,
                   sl=entry - sl_frac * (entry - liq) if sl_frac else 0.0, tp=entry * (1 + tp_gain) if tp_gain else 0.0,
                   liq=liq, t_open=t, st=1)
        for k, v in row.items():
            P[k][i] = v
        self.cash -= B
        self.borrowed += B
        self.expo[a] += N
        self.L["margin_in"] += M
        self.L["volume"] += N
        self.L["n_open"] += 1
        self.open.append(i)
        self.dirty = True
        return i

    def _arrive(self, t):
        d, r = self.demand, self.rng
        tier = 10 if r.random() < d.p_10x else 5
        a = int(r.choice(len(d.asset_w), p=d.asset_w))
        M = max(d.margin_median * math.exp(d.margin_sigma * r.standard_normal()), self.p.min_notional / tier)
        hold = max(int(d.hold_median_days * DAY * math.exp(d.hold_sigma * r.standard_normal())), 1)
        auto = r.random() < d.p_auto
        sl = d.sl_frac if r.random() < d.p_sl else 0.0
        tp = d.tp_gain if r.random() < d.p_tp else 0.0
        if d.skill and r.random() < d.skill:
            exit_t = min(t + (hold if auto else min(hold, EPOCH)), self.T - 1)
            if self.S[a, exit_t] <= self.S[a, t]:  # ponytail: perfect foresight on direction; noisy skill if needed
                back = t + int(r.integers(60, DAY))
                if back < self.T:
                    self.retry[back] += 1
                return
        self.open_position(t, a, tier, M, auto=auto, hold=hold, sl_frac=sl, tp_gain=tp)

    def _agg(self):
        """Per-asset trigger bands so quiet minutes skip the per-position scan."""
        A = len(self.expo)
        self.low, self.high, self.next_t = np.full(A, -np.inf), np.full(A, np.inf), NEVER
        if self.open:
            P, ids = self.P, np.array(self.open)
            a = P["a"][ids]
            np.maximum.at(self.low, a, np.maximum(P["liq"][ids], P["sl"][ids]))
            np.minimum.at(self.high, a, np.where(P["tp"][ids] > 0, P["tp"][ids], np.inf))
            self.next_t = min(P["end"][ids].min(), P["close_t"][ids].min())
        self.dirty = False

    def _events(self, t):
        tw = self.tw[:, t]
        if self.dirty:
            self._agg()
        if t < self.next_t and (tw > self.low).all() and (tw < self.high).all():
            return
        p, P, ids = self.p, self.P, np.array(self.open)
        due = P["auto"][ids] & (P["end"][ids] <= t)
        if due.any():  # roll: accrue one epoch of debt on B (same result as the contract's lazy catch-up)
            r = ids[due]
            P["D"][r] += P["B"][r] * p.rollover_apr * EPOCH / YEAR
            P["end"][r] += EPOCH
            P["liq"][r] = (P["B"][r] + P["D"][r] + P["N"][r] * self.mu[P["tier"][r]]) / P["Q"][r]
            self.dirty = True
        twp, sl, tp = tw[P["a"][ids]], P["sl"][ids], P["tp"][ids]
        liq = twp <= P["liq"][ids]
        trig = ~liq & (((sl > 0) & (twp <= sl)) | ((tp > 0) & (twp >= tp)))
        exp = ~liq & ~trig & ~P["auto"][ids] & (P["end"][ids] <= t)
        man = ~liq & ~trig & ~exp & (P["close_t"][ids] <= t)
        for i in ids[liq]:
            self._exit(i, t, tw, p.liq_slip, True, True)
        for i in ids[trig | exp]:
            self._exit(i, t, tw, p.exit_slip, True, False)
        for i in ids[man]:
            self._exit(i, t, tw, p.exit_slip, False, False)

    def _exit(self, i, t, px, slip, forced, is_liq):
        P, L = self.P, self.L
        a, q = P["a"][i], P["Q"][i]
        out = self.pools.quote_sell(t, self.S[:, t], a, q)
        if out < q * px[a] * (1 - slip):  # swap minOut floor at the TWAP mark -> revert, retry next minute
            L["blocked_liq" if is_liq else "blocked_exit"] += 1
            if is_liq:
                self.log.append((t, a, "blocked"))
            return
        self.pools.apply(a, -out, q)
        B = P["B"][i]
        k, ret, lp_roll, lp_profit, to_ins, ops, trader, short = settle(
            self.p, out, B, P["D"][i], P["M"][i], int(P["tier"][i]), forced, is_liq)
        cover = min(short, self.ins)
        self.ins += to_ins - cover
        ret += cover
        self.cash += ret + lp_roll + lp_profit
        self.borrowed -= B
        self.expo[a] -= P["N"][i]
        for key, v in (("keeper", k), ("lp_roll", lp_roll), ("lp_profit", lp_profit), ("ins_in", to_ins),
                       ("ins_cover", cover), ("ops", ops), ("trader_out", trader), ("shortfall", short),
                       ("bad_debt", B - ret), ("n_closed", 1), ("n_liq", is_liq), ("n_bad", short > 0)):
            L[key] += v
        P["st"][i], P["t_exit"][i], P["paid"][i] = 3 if is_liq else 2, t, trader
        if is_liq:
            self.log.append((t, a, "bad" if short > 0 else "liq"))
        self.open.remove(i)
        self.dirty = True

    def trades(self):
        """Closed positions as a dict of arrays, with trader ROI on margin."""
        P, n = self.P, self.n
        out = {k: v[:n] for k, v in P.items()}
        out["roi"] = (out["paid"] - out["M"]) / out["M"]
        return out

    # ------------------------------------------------------------------ results

    def summary(self):
        h = np.array(self.hourly)
        ta, L, years = h[:, 0], self.L, self.T / YEAR
        ann = lambda x: x / self.tvl0 / years  # noqa: E731
        return dict(
            apy=(ta[-1] / ta[0]) ** (1 / years) - 1, ret=ta[-1] / ta[0] - 1,
            max_dd=(ta / np.maximum.accumulate(ta) - 1).min(), util=(h[:, 1] / ta).mean(),
            roll=ann(L["lp_roll"]), profit=ann(L["lp_profit"]), idle=ann(L["idle"]), bad=ann(L["bad_debt"]),
            volume=ann(L["volume"]), ins=ann(L["ins_in"]), bad_debt=L["bad_debt"], shortfall=L["shortfall"], ins_cover=L["ins_cover"], ins_end=self.ins,
            n_open=L["n_open"], n_liq=L["n_liq"], n_bad=L["n_bad"], blocked_liq=L["blocked_liq"],
            trader_roi=(L["trader_out"] - L["margin_in"]) / max(L["margin_in"], 1), rej_cap=L["rej_cap"],
        )
