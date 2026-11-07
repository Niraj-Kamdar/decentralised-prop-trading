"""Self-checks for the protocol model: uv run --with numpy python sim/test_model.py"""

import numpy as np

from model import DAY, EPOCH, YEAR, Params, Sim, settle

p = Params()

# Worked example on PR #10 Base Level 0 defaults: 5x, $100 margin, +20% -> $600 out -> profit $100.
# L0 split: LP 15% ($15), treasury 5% ($5 -> insurance $2.50, ops $2.50), trader $180 ($100 margin + $80 profit).
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p, 600, 400, 0, 100, 5, False, False, level=0)
assert (k, ret, lp_profit, trader, short) == (0, 400, 15, 180, 0) and ins == ops == 2.5

# Liquidation: keeper bounty ($0.50) paid first, remainder after principal + rollover debt is penalty to insurance.
# $450 out -> keeper $0.50 -> $449.50. Principal $400 -> $49.50. Roll $10 (LP $8, ins $2) -> penalty $39.50.
# Total insurance = $2 + $39.50 = $41.50.
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p, 450, 400, 10, 100, 5, True, True, level=0)
assert k == 0.5 and ret == 400 and lp_roll == 8 and ins == 2 + 39.5 and ops == 0 and trader == 0

# Liquidation penalty split with ops (liq_ops_share=0.5): 39.50 penalty split 50/50 ($19.75 each).
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(Params(liq_ops_share=0.5), 450, 400, 10, 100, 5, True, True, level=0)
assert ins == 2 + 19.75 and ops == 19.75

# Bad debt: proceeds below principal -> shortfall, nothing else paid.
assert settle(p, 300, 400, 10, 100, 5, True, True, level=0)[-1] == 100.5

# Flat price, auto-roll, held 10 days: only the 2nd epoch is charged, 80% of it to LPs.
T = 12 * DAY
s = Sim(np.full((2, T), 2000.0), Params(pool_depth=1e12, pool_fee=0), tvl=1e6)
s.open_position(20, 0, 5, 10_000, auto=True, hold=10 * DAY)
s.run()
fee = 40_000 * 0.08 * EPOCH / YEAR
assert abs(s.L["lp_roll"] - 0.8 * fee) < 1e-6 and s.L["n_closed"] == 1 and s.L["bad_debt"] == 0

# Instant 30% gap on a 10x TWAP book: the TWAP lags, the 2% liq gate blocks exits until it catches up -> bad debt.
px = np.full((2, 200), 2000.0)
px[:, 100:] = 1400.0
s = Sim(px, Params(oracle="twap", pool_depth=1e12, pool_fee=0), tvl=1e6, insurance=1_000)
s.open_position(20, 0, 10, 5_000)
s.run()
assert s.L["n_liq"] == 1 and s.L["blocked_liq"] > 0
assert abs(s.L["shortfall"] - (45_000 - (50_000 * 0.7 - 0.5))) < 1 and s.L["ins_cover"] == 1_000
assert abs(s.ta() - (1e6 - s.L["bad_debt"])) < 1e-6

# -----------------------------------------------------------------------------
# Checks mirroring test/TraderLevels.t.sol and PR #10 specs
# -----------------------------------------------------------------------------

# 1. Level-0 trader can't open 10x or more than $50 margin.
s = Sim(np.full((2, 100), 2000.0), Params(pool_depth=1e12, pool_fee=0), tvl=1e6)
t0 = s.get_trader(0)
assert t0.level == 0
assert s.open_position(10, 0, 10, 50, trader=0) is None  # 10x exceeds Level 0 maxLeverage (5x)
assert s.open_position(10, 0, 5, 51, trader=0) is None   # $51 margin exceeds Level 0 maxMargin ($50)
id0 = s.open_position(10, 0, 5, 50, trader=0)
assert id0 is not None

# 2. Promotion after 5 trades and +$25.
# Trader 1 starts at Level 0.
t1 = s.get_trader(1)
for i in range(4):
    s._record_result(t1, 5.0, hold_m=100)
    assert t1.level == 0 and t1.trades == i + 1 and abs(t1.pnl - (i + 1) * 5.0) < 1e-6

# 5th trade pushes trades to 5 and cumulative pnl to +$25 -> promotes to Level 1, counters reset.
s._record_result(t1, 5.0, hold_m=100)
assert t1.level == 1 and t1.trades == 0 and t1.pnl == 0.0

# 3. Demotion and counter reset.
# Trader 1 is at Level 1 (demote_max_loss = $50). A loss of $50 demotes to Level 0, counters reset.
s._record_result(t1, -50.0, hold_m=100)
assert t1.level == 0 and t1.trades == 0 and t1.pnl == 0.0

# 4. L0 split on a +$100 profit = LP $15, treasury $5 (insurance $2.50, ops $2.50).
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p, 600, 400, 0, 100, 5, False, False, level=0)
assert lp_profit == 15.0 and ins == 2.5 and ops == 2.5 and trader == 180.0

# 5. Chainlink deviation update fires at threshold (0.5%) and not below it.
# Start at 2000.0:
# +0.495% (2009.9) is below 0.5% threshold -> no update, mark stays 2000.0.
# +0.505% (2010.1) is >= 0.5% threshold -> update fires, mark becomes 2010.1.
px_cl = np.array([[2000.0, 2009.9, 2010.1], [2000.0, 2000.0, 2000.0]])
s_cl = Sim(px_cl, Params(oracle="chainlink", chainlink_deviation=0.005, pool_depth=1e12, pool_fee=0), tvl=1e6)
assert s_cl.mark[0, 0] == 2000.0
assert s_cl.mark[0, 1] == 2000.0
assert s_cl.mark[0, 2] == 2010.1

# 6. Feed stale beyond 3600 s (60 min) blocks liquidation.
# Outage starts at minute 50 and lasts 70 minutes (through minute 119).
# Price crashes at minute 60.
# Between minutes 110 and 119, feed age exceeds 60 minutes -> ok[t] is False, liquidation is blocked.
# At minute 120, outage ends, feed recovers, and position is liquidated at minute 120.
px_stale = np.full((2, 200), 2000.0)
px_stale[:, 60:] = 1400.0
s_stale = Sim(px_stale, Params(oracle="chainlink", pool_depth=1e12, pool_fee=0, outages=((50, 70),)), tvl=1e6)
assert not s_stale.ok[115]  # stale at minute 115 (> 3600s since last update)
assert s_stale.ok[120]      # recovered at minute 120
s_stale.open_position(20, 0, 5, 50, auto=True, hold=200)
s_stale.run()
assert s_stale.L["n_liq"] == 1
assert s_stale.P["t_exit"][0] == 120  # liquidated precisely when feed recovered

# 7. Early-close fee charged inside the window and not outside it, and never on liquidation.
p_fee = Params(early_close_bps=10, early_close_h=24)  # 10 bps on N ($500 -> $0.50 fee)
# Held 2h (120 min < 24h): fee of $0.50 charged from trader payout to LP profit
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p_fee, 600, 400, 0, 100, 5, False, False, level=0, hold_m=120)
assert (lp_profit, trader) == (15.5, 179.5)

# Held 25h (1500 min >= 24h): no fee charged
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p_fee, 600, 400, 0, 100, 5, False, False, level=0, hold_m=1500)
assert (lp_profit, trader) == (15.0, 180.0)

# Liquidation within window: early-close fee never charged on liquidation
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p_fee, 450, 400, 10, 100, 5, True, True, level=0, hold_m=120)
assert trader == 0.0 and lp_profit == 0.0

print("ok")
