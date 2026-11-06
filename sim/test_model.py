"""Self-checks for the protocol model: uv run --with numpy python sim/test_model.py"""

import numpy as np

from model import DAY, EPOCH, YEAR, Params, Sim, settle

p = Params()

# README worked example: 5x, $100 margin, +20% -> $600 out -> trader $190, LPs $8, treasury $2 (half to insurance).
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p, 600, 400, 0, 100, 5, False, False)
assert (k, ret, lp_profit, trader, short) == (0, 400, 8, 190, 0) and ins == ops == 1

# Liquidation: remainder after principal + rollover debt is a penalty to insurance; keeper paid first.
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(p, 450, 400, 10, 100, 5, True, True)
assert k == 5 and ret == 400 and lp_roll == 8 and ins == 2 + 35 and trader == 0

# Liquidation penalty split with ops: 35 penalty, half each way; rollover's 2 stays with insurance.
k, ret, lp_roll, lp_profit, ins, ops, trader, short = settle(Params(liq_ops_share=0.5), 450, 400, 10, 100, 5, True, True)
assert ins == 2 + 17.5 and ops == 17.5

# Bad debt: proceeds below principal -> shortfall, nothing else paid.
assert settle(p, 300, 400, 10, 100, 5, True, True)[-1] == 105

# Flat price, auto-roll, held 10 days: only the 2nd epoch is charged, 80% of it to LPs.
T = 12 * DAY
s = Sim(np.full((2, T), 2000.0), Params(pool_depth=1e12, pool_fee=0), tvl=1e6)
s.open_position(20, 0, 5, 10_000, auto=True, hold=10 * DAY)
s.run()
fee = 40_000 * 0.08 * EPOCH / YEAR
assert abs(s.L["lp_roll"] - 0.8 * fee) < 1e-6 and s.L["n_closed"] == 1 and s.L["bad_debt"] == 0

# Instant 30% gap on a 10x book: the TWAP lags, the 2% liq gate blocks exits until it catches up -> bad debt.
px = np.full((2, 200), 2000.0)
px[:, 100:] = 1400.0
s = Sim(px, Params(pool_depth=1e12, pool_fee=0), tvl=1e6, insurance=1_000)
s.open_position(20, 0, 10, 5_000)
s.run()
assert s.L["n_liq"] == 1 and s.L["blocked_liq"] > 0
assert abs(s.L["shortfall"] - (45_000 - (50_000 * 0.7 - 5))) < 1 and s.L["ins_cover"] == 1_000
assert abs(s.ta() - (1e6 - s.L["bad_debt"])) < 1e-6

# Keeper outage: nothing can be liquidated while the oracle is stale.
s = Sim(px, Params(pool_depth=1e12, pool_fee=0, outages=((95, 60),)), tvl=1e6)
s.open_position(20, 0, 10, 5_000)
s.run()
assert s.L["n_liq"] == 1 and s.L["blocked_liq"] == 0  # TWAP had fully converged when the keeper came back

# Replay book: a scheduled real trade opens at its minute and closes after its hold.
s = Sim(np.full((2, 400), 2000.0), Params(pool_depth=1e12, pool_fee=0), tvl=1e6)
s.book = {50: [(1, 5, 1_000, 120)]}
s.run()
assert s.L["n_open"] == s.L["n_closed"] == 1 and s.P["t_exit"][0] == 170 and s.P["a"][0] == 1

print("ok")
