"""Fulcrum protocol model at 1-minute resolution.

Ports the economics of src/PositionManager.sol, LPVault.sol, InsuranceReserve.sol and ChainlinkOracle.sol:
open caps, trader levels (0, 1, 2) with auto promotion/demotion and level-based profit cuts, Chainlink oracle
(0.5% deviation threshold, 1200s heartbeat, 3600s max staleness) with selectable TWAP fallback, exit/liquidation
slippage gates (a swap reverts when the pool pays less than mark * (1 - slip)), 7-day epochs with 8% APR rollover
debt (first epoch free), and the settlement / bad-debt waterfall.

ponytail: vault totalAssets ignores the 12h profit vesting and the redemption queue / bonus pot (no LP flows);
the pool is a constant-product curve reset to the CEX close every minute (arbs).
"""

import math
from dataclasses import dataclass, field

import numpy as np

DAY = 1440
EPOCH = 7 * DAY
YEAR = 365 * DAY
NEVER = 10**15


@dataclass
class LevelConfig:
    """Trader level settings: matches PositionManager.LevelConfig."""

    enabled: bool = True
    max_leverage: int = 5
    max_margin: float = 50.0  # 6-dec USDC
    lp_profit_bps: int = 1500  # 15%
    treasury_profit_bps: int = 500  # 5%
    promote_min_trades: int = 5
    promote_min_pnl: float = 25.0  # 6-dec USDC
    demote_max_loss: float = 0.0  # 0 = never demote


# Base mainnet MVP defaults (script/lib/ProtocolDeployer.sol: deployBase)
DEFAULT_LEVELS = {
    0: LevelConfig(enabled=True, max_leverage=5, max_margin=50.0, lp_profit_bps=1500, treasury_profit_bps=500,
                   promote_min_trades=5, promote_min_pnl=25.0, demote_max_loss=0.0),
    1: LevelConfig(enabled=True, max_leverage=10, max_margin=250.0, lp_profit_bps=1000, treasury_profit_bps=300,
                   promote_min_trades=10, promote_min_pnl=100.0, demote_max_loss=50.0),
    2: LevelConfig(enabled=True, max_leverage=10, max_margin=1000.0, lp_profit_bps=700, treasury_profit_bps=200,
                   promote_min_trades=0, promote_min_pnl=0.0, demote_max_loss=200.0),
}


@dataclass
class Params:
    """Defaults = PositionManager/LPVault.initialize + ProtocolDeployer.deployBase."""

    # Maintenance margin per tier: 5x -> 4%, 10x -> 2% (PositionManager.initialize)
    tiers: dict = field(default_factory=lambda: {5: (0.04, 0.15, 0.05), 10: (0.02, 0.10, 0.03)})
    levels: dict = field(default_factory=lambda: {k: LevelConfig(**v.__dict__) for k, v in DEFAULT_LEVELS.items()})
    rollover_apr: float = 0.08
    lp_rollover_share: float = 0.80
    min_notional: float = 50.0  # PR #10: was 500.0
    keeper_bounty: float = 0.50  # PR #10: was 5.0
    entry_slip: float = 0.01
    exit_slip: float = 0.01
    liq_slip: float = 0.02
    max_exposure: float = 0.35  # per-asset open notional cap, share of vault totalAssets
    max_util: float = 0.85
    idle_apr: float = 0.0  # Morpho / Aave yield on idle USDC; 0 = single-vault mode
    oracle: str = "chainlink"  # "chainlink" (default) or "twap"
    twap_min: int = 10
    # Chainlink parameters on Base (BaseMainnet.sol: ETH_USD_FEED 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
    # BTC_USD_FEED 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F):
    # data.chain.link Base ETH/USD & BTC/USD trigger at 0.5% deviation threshold with a 1200s (20m) heartbeat.
    chainlink_deviation: float = 0.005
    chainlink_heartbeat_s: int = 1200
    pool_depth: float = 5e6  # USDC-side virtual reserve of each asset's v4 pool (liquidity near the price)
    pool_fee: float = 0.0005
    # Experiments (E1-E4)
    early_close_bps: int = 0  # E1: early-close fee in bps on notional paid to LPs (e.g. 5, 10, 20)
    early_close_h: int = 24  # E1: hours window inside which early-close fee applies
    promote_min_hold_h: int = 0  # E2: only positions held >= promote_min_hold_h count for promotion
    ins_cap: float = float("inf")  # E3: insurance reserve cap as fraction of TVL (e.g. 0.10, 0.15, 0.20)
    ins_surplus_lp: float = 0.70  # E3: share of surplus above cap distributed to LPs (rest to company)
    liq_ops_share: float = 0.0  # E4: share of liquidation penalties sent to ops instead of insurance
    outages: tuple = ()  # ((start_minute, minutes), ...) feed outage: no updates for N minutes


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
    skill: float = 0.0  # share of arrivals who call direction
    p_new: float = 0.3  # probability an arriving trade belongs to a new trader vs existing


@dataclass
class Trader:
    id: int
    level: int = 0
    trades: int = 0
    pnl: float = 0.0
    promoted_l1_t: int = -1
    promoted_l2_t: int = -1


def settle(p: Params, usdc_out, B, D, M, tier, forced, is_liq, level=0, hold_m=NEVER):
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
        l = p.levels.get(level, DEFAULT_LEVELS[0])
        profit = u - M
        lp_profit = profit * (l.lp_profit_bps / 10000.0)
        treasury = profit * (l.treasury_profit_bps / 10000.0)
        trader = u - lp_profit - treasury

    # E1: early close fee paid to LPs (not on liquidation)
    if not is_liq and p.early_close_bps > 0 and hold_m < p.early_close_h * 60:
        notional = M * tier
        fee = min(notional * (p.early_close_bps / 10000.0), trader)
        trader -= fee
        lp_profit += fee

    ops = treasury / 2.0  # InsuranceReserve.fund: treasury cut split 50/50 with insurance
    return k, B, lp_roll, lp_profit, to_ins + treasury - ops, ops + liq_ops, trader, 0.0


def make_chainlink(prices, dev=0.005, heartbeat_min=20, outages=(), max_staleness_min=60):
    """Simulate Chainlink price feeds with deviation threshold, heartbeat and staleness check."""
    A, T = prices.shape
    cl = np.zeros((A, T), dtype=float)
    ok = np.ones(T, dtype=bool)
    outage_mask = np.zeros(T, dtype=bool)
    for s, d in outages:
        outage_mask[s:s + d] = True

    for a in range(A):
        answer = prices[a, 0]
        last_t = 0
        p = prices[a]
        c = cl[a]
        for t in range(T):
            if not outage_mask[t]:
                if abs(p[t] / answer - 1.0) >= dev or (t - last_t) >= heartbeat_min:
                    answer = p[t]
                    last_t = t
            c[t] = answer
            if (t - last_t) > max_staleness_min:
                ok[t] = False
    return cl, ok


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
              t_open=np.int64, t_exit=np.int64, st=np.int64, paid=float, trader=np.int64)  # st: 1 open, 2 closed, 3 liquidated
LEDGER = ("margin_in", "trader_out", "keeper", "lp_roll", "lp_profit", "early_close", "idle", "shortfall", "bad_debt", "ins_in",
          "ins_cover", "ops", "volume", "n_open", "n_closed", "n_liq", "n_bad", "blocked_liq", "blocked_exit",
          "rej_cap", "rej_entry")


class Sim:
    def __init__(self, prices, p=None, demand=None, tvl=1e6, insurance=0.0, seed=0, capacity=64):
        self.p = p = p or Params()
        self.S = np.asarray(prices, float)
        A, self.T = self.S.shape

        if p.oracle == "chainlink":
            self.cl, self.ok = make_chainlink(self.S, dev=p.chainlink_deviation,
                                              heartbeat_min=p.chainlink_heartbeat_s // 60,
                                              outages=p.outages, max_staleness_min=3600 // 60)
            self.mark = self.cl
            self.tw = self.cl  # alias for backward compatibility
        else:
            w = p.twap_min
            c = np.concatenate([np.zeros((A, 1)), np.cumsum(self.S, axis=1)], axis=1)
            self.tw = np.full((A, self.T), np.nan)
            self.tw[:, w - 1:] = (c[:, w:] - c[:, :-w]) / w
            self.ok = np.ones(self.T, bool)
            self.ok[: w - 1] = False
            for s, d in p.outages:  # stale after 90s; a gap > 300s restarts the series and needs a full warm-up
                self.ok[s: s + d + (w if d > 5 else 0)] = False
            self.mark = self.tw

        self.mu = np.zeros(256)
        for k, v in p.tiers.items():
            self.mu[k] = v[0] if isinstance(v, (tuple, list)) else v
        self.rng = np.random.default_rng(seed)
        self.demand = demand
        self.arrivals = self.rng.poisson(demand.per_day / DAY, self.T) if demand else np.zeros(self.T, int)
        self.retry = np.zeros(self.T, int)
        self.book = {}  # minute -> [(asset, tier, margin, hold[, trader])]: scheduled trades
        cap = int(self.arrivals.sum()) + capacity
        self.P = {k: np.zeros(cap, dt) for k, dt in FIELDS.items()}
        self.n, self.open, self.dirty = 0, [], True
        self.pools = Pools(A, p.pool_depth, p.pool_fee)
        self.tvl0, self.cash, self.borrowed, self.ins = tvl, tvl, 0.0, insurance
        self.expo = np.zeros(A)
        self.L = dict.fromkeys(LEDGER, 0.0)
        self.hourly = []  # (totalAssets, borrowed, insurance, open notional)
        self.log = []
        self.traders = []
        self.trader_map = {}

    def ta(self):
        return self.cash + self.borrowed

    def get_trader(self, key):
        """Lookup or create a Trader by key (int or account string)."""
        if isinstance(key, int) and 0 <= key < len(self.traders):
            return self.traders[key]
        if key in self.trader_map:
            return self.trader_map[key]
        tr = Trader(id=len(self.traders))
        self.traders.append(tr)
        self.trader_map[key] = tr
        return tr

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
                for item in self.book.get(t, ()):
                    if len(item) == 5:
                        a, req_tier, req_M, hold, tr = item
                        if tr is not None:
                            tr_obj = self.get_trader(tr)
                            cfg = self.p.levels.get(tr_obj.level, DEFAULT_LEVELS[0])
                            tier = min(req_tier, cfg.max_leverage)
                            M = min(req_M, cfg.max_margin)
                            if M * tier < self.p.min_notional:
                                continue
                        else:
                            tier, M = req_tier, req_M
                    else:
                        a, tier, M, hold = item
                        tr = None
                    self.open_position(t, a, tier, M, auto=True, hold=hold, trader=tr)
            if t % 60 == 0:
                self._snap()
        for i in list(self.open):  # mark leftover book to market
            self.pools.t = -1
            self._exit(i, self.T - 1, self.S[:, -1], 1.0, False, False)
        self._snap()
        return self

    def _snap(self):
        self.hourly.append((self.ta(), self.borrowed, self.ins, self.expo.sum()))

    # ------------------------------------------------------------------ positions

    def open_position(self, t, a, tier, M, auto=True, hold=NEVER, sl_frac=0.0, tp_gain=0.0, trader=None):
        p = self.p
        tr_obj = None
        if trader is not None:
            tr_obj = self.get_trader(trader)
            cfg = p.levels.get(tr_obj.level, DEFAULT_LEVELS[0])
            if not cfg.enabled or tier > cfg.max_leverage or M > cfg.max_margin + 1e-6:
                return None

        N = M * tier
        B = N - M
        if N < p.min_notional:
            return None
        ta = self.ta()
        if self.expo[a] + N > p.max_exposure * ta or self.borrowed + B > p.max_util * ta:
            self.L["rej_cap"] += 1
            return None
        q = self.pools.quote_buy(t, self.S[:, t], a, N)
        mark, thr = q * self.mark[a, t], B + N * self.mu[tier]
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
                   liq=liq, t_open=t, st=1, trader=tr_obj.id if tr_obj is not None else -1)
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
        if not self.traders or r.random() < d.p_new:
            tr_obj = Trader(id=len(self.traders))
            self.traders.append(tr_obj)
        else:
            tr_obj = self.traders[int(r.integers(len(self.traders)))]

        cfg = self.p.levels.get(tr_obj.level, DEFAULT_LEVELS[0])
        req_tier = 10 if r.random() < d.p_10x else 5
        tier = min(req_tier, cfg.max_leverage)
        a = int(r.choice(len(d.asset_w), p=d.asset_w))
        M = max(d.margin_median * math.exp(d.margin_sigma * r.standard_normal()), self.p.min_notional / tier)
        M = min(M, cfg.max_margin)
        if M * tier < self.p.min_notional:
            return

        hold = max(int(d.hold_median_days * DAY * math.exp(d.hold_sigma * r.standard_normal())), 1)
        auto = r.random() < d.p_auto
        sl = d.sl_frac if r.random() < d.p_sl else 0.0
        tp = d.tp_gain if r.random() < d.p_tp else 0.0
        if d.skill and r.random() < d.skill:
            exit_t = min(t + (hold if auto else min(hold, EPOCH)), self.T - 1)
            if self.S[a, exit_t] <= self.S[a, t]:
                back = t + int(r.integers(60, DAY))
                if back < self.T:
                    self.retry[back] += 1
                return
        self.open_position(t, a, tier, M, auto=auto, hold=hold, sl_frac=sl, tp_gain=tp, trader=tr_obj.id)

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
        mk = self.mark[:, t]
        if self.dirty:
            self._agg()
        if t < self.next_t and (mk > self.low).all() and (mk < self.high).all():
            return
        p, P, ids = self.p, self.P, np.array(self.open)
        due = P["auto"][ids] & (P["end"][ids] <= t)
        if due.any():
            r = ids[due]
            P["D"][r] += P["B"][r] * p.rollover_apr * EPOCH / YEAR
            P["end"][r] += EPOCH
            P["liq"][r] = (P["B"][r] + P["D"][r] + P["N"][r] * self.mu[P["tier"][r]]) / P["Q"][r]
            self.dirty = True
        mkp, sl, tp = mk[P["a"][ids]], P["sl"][ids], P["tp"][ids]
        liq = mkp <= P["liq"][ids]
        trig = ~liq & (((sl > 0) & (mkp <= sl)) | ((tp > 0) & (mkp >= tp)))
        exp = ~liq & ~trig & ~P["auto"][ids] & (P["end"][ids] <= t)
        man = ~liq & ~trig & ~exp & (P["close_t"][ids] <= t)
        for i in ids[liq]:
            self._exit(i, t, mk, p.liq_slip, True, True)
        for i in ids[trig | exp]:
            self._exit(i, t, mk, p.exit_slip, True, False)
        for i in ids[man]:
            self._exit(i, t, mk, p.exit_slip, False, False)

    def _exit(self, i, t, px, slip, forced, is_liq):
        P, L = self.P, self.L
        a, q = P["a"][i], P["Q"][i]
        out = self.pools.quote_sell(t, self.S[:, t], a, q)
        if out < q * px[a] * (1 - slip):  # swap minOut floor at the oracle mark -> revert, retry next minute
            L["blocked_liq" if is_liq else "blocked_exit"] += 1
            if is_liq:
                self.log.append((t, a, "blocked"))
            return
        self.pools.apply(a, -out, q)
        B = P["B"][i]
        hold_m = t - P["t_open"][i]
        trader_idx = int(P["trader"][i])
        level = self.traders[trader_idx].level if 0 <= trader_idx < len(self.traders) else 0

        k, ret, lp_roll, lp_profit, to_ins, ops, trader, short = settle(
            self.p, out, B, P["D"][i], P["M"][i], int(P["tier"][i]), forced, is_liq, level=level, hold_m=hold_m)

        # Track early-close fee in ledger
        if not is_liq and self.p.early_close_bps > 0 and hold_m < self.p.early_close_h * 60:
            notional = P["M"][i] * P["tier"][i]
            fee = notional * (self.p.early_close_bps / 10000.0)
            L["early_close"] += min(fee, out)

        # E3: insurance cap & surplus distribution
        if self.p.ins_cap < float("inf"):
            max_ins = self.p.ins_cap * self.ta()
            room = max(0.0, max_ins - self.ins)
            fill = min(to_ins, room)
            surplus = to_ins - fill
            to_ins = fill
            surplus_lp = surplus * self.p.ins_surplus_lp
            surplus_ops = surplus * (1.0 - self.p.ins_surplus_lp)
            lp_profit += surplus_lp
            ops += surplus_ops

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

        # Update trader stats and level progression
        if 0 <= trader_idx < len(self.traders):
            tr_obj = self.traders[trader_idx]
            trade_pnl = trader - P["M"][i]
            self._record_result(tr_obj, trade_pnl, hold_m, t)

        self.open.remove(i)
        self.dirty = True

    def _record_result(self, trader, pnl, hold_m, t=0):
        """Update trader stats and promote or demote according to PositionManager._recordResult."""
        p = self.p
        lvl = trader.level
        l = p.levels.get(lvl, DEFAULT_LEVELS[0])

        counts_for_promotion = True
        if p.promote_min_hold_h > 0 and hold_m < p.promote_min_hold_h * 60:
            counts_for_promotion = False

        if counts_for_promotion:
            trader.trades += 1
            trader.pnl += pnl
        elif pnl < 0:
            trader.pnl += pnl  # losses still count towards demotion

        new_lvl = lvl
        if lvl > 0 and l.demote_max_loss > 0 and trader.pnl <= -l.demote_max_loss:
            new_lvl = lvl - 1
        elif (lvl + 1 in p.levels and p.levels[lvl + 1].enabled
              and trader.trades >= l.promote_min_trades
              and trader.pnl >= l.promote_min_pnl):
            new_lvl = lvl + 1

        if new_lvl != lvl:
            trader.level = new_lvl
            trader.trades = 0
            trader.pnl = 0.0
            if new_lvl == 1 and trader.promoted_l1_t < 0:
                trader.promoted_l1_t = t
            elif new_lvl == 2 and trader.promoted_l2_t < 0:
                trader.promoted_l2_t = t

    def trades(self):
        """Closed positions as a dict of arrays, with trader ROI on margin."""
        P, n = self.P, self.n
        out = {k: v[:n] for k, v in P.items()}
        out["roi"] = (out["paid"] - out["M"]) / np.maximum(out["M"], 1e-9)
        return out

    # ------------------------------------------------------------------ results

    def summary(self):
        h = np.array(self.hourly)
        ta, L, years = h[:, 0], self.L, self.T / YEAR
        ann = lambda x: x / self.tvl0 / years  # noqa: E731
        return dict(
            apy=(ta[-1] / ta[0]) ** (1 / years) - 1, ret=ta[-1] / ta[0] - 1,
            max_dd=(ta / np.maximum.accumulate(ta) - 1).min(), util=(h[:, 1] / ta).mean(),
            roll=ann(L["lp_roll"]), profit=ann(L["lp_profit"]), early=ann(L["early_close"]),
            idle=ann(L["idle"]), bad=ann(L["bad_debt"]), ops=ann(L["ops"]),
            volume=ann(L["volume"]), ins=ann(L["ins_in"]), bad_debt=L["bad_debt"], shortfall=L["shortfall"],
            ins_cover=L["ins_cover"], ins_end=self.ins,
            n_open=L["n_open"], n_liq=L["n_liq"], n_bad=L["n_bad"], blocked_liq=L["blocked_liq"],
            trader_roi=(L["trader_out"] - L["margin_in"]) / max(L["margin_in"], 1), rej_cap=L["rej_cap"],
        )
