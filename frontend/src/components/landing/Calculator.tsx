"use client";

import { useState } from "react";
import { Segmented } from "@/components/ui";
import { usd } from "@/lib/format";
import { simulate } from "@/lib/math";

/** Trader levels as configured on Base (ProtocolDeployer.deployBase); maintenance is the tier's (5x: 4%, 10x: 2%). */
const LEVELS = {
  Starter: { lev: 5, deposits: [10, 25, 50], maintenanceBps: 400, lpProfitBps: 1500, treasuryProfitBps: 500 },
  Trader: { lev: 10, deposits: [50, 100, 250], maintenanceBps: 200, lpProfitBps: 1000, treasuryProfitBps: 300 },
  Pro: { lev: 10, deposits: [100, 500, 1000], maintenanceBps: 200, lpProfitBps: 700, treasuryProfitBps: 200 },
} as const;
type Level = keyof typeof LEVELS;
const RANGE = 20; // slider spans -RANGE% … +RANGE%

export function Calculator() {
  const [level, setLevel] = useState<Level>("Trader");
  const [deposit, setDeposit] = useState<number>(100);
  const [move, setMove] = useState(5);
  const l = LEVELS[level];
  const o = simulate(deposit, l.lev, move / 100, l);
  const liqPct = Math.round(o.liqMove * 1000) / 10; // e.g. -16, -8
  // Share of the track (from the left) that is in the auto-close zone.
  const liqZone = ((liqPct + RANGE) / (2 * RANGE)) * 100;
  const tone = o.liquidated || o.traderPnl < 0 ? "text-down" : "text-up";

  const pickLevel = (n: Level) => {
    setLevel(n);
    setDeposit(LEVELS[n].deposits[1]);
  };

  return (
    <div className="card-raised p-6 sm:p-7">
      <div className="space-y-5">
        <div>
          <div className="label mb-2">Your level</div>
          <Segmented options={Object.keys(LEVELS) as Level[]} value={level} onChange={pickLevel} render={(n) => `${n} · ${LEVELS[n].lev}x`} />
        </div>
        <div>
          <div className="label mb-2">You deposit</div>
          <Segmented
            options={l.deposits as readonly number[]}
            value={deposit}
            onChange={setDeposit}
            render={(m) => `$${m.toLocaleString()}`}
          />
          <p className="mt-2 text-xs text-muted">
            You trade {usd(o.notional)} of ETH. The vault lends you {usd(o.borrowed)}.
          </p>
        </div>
        <div>
          <div className="mb-2 flex items-center justify-between">
            <label htmlFor="calc-move" className="label">
              If ETH moves
            </label>
            <span className={`num text-lg ${move >= 0 ? "text-up" : "text-down"}`}>
              {move > 0 ? "+" : ""}
              {move}%
            </span>
          </div>
          <input
            id="calc-move"
            type="range"
            min={-RANGE}
            max={RANGE}
            step={1}
            value={move}
            onChange={(e) => setMove(Number(e.target.value))}
            className="range"
            style={{
              background: `linear-gradient(to right, rgb(var(--down) / 0.35) 0 ${liqZone}%, rgb(var(--line)) ${liqZone}% 100%)`,
            }}
          />
          <div className="mt-2 flex justify-between text-xs text-muted">
            <span>−{RANGE}%</span>
            <span className="text-down">Auto-closes at {liqPct}%</span>
            <span>+{RANGE}%</span>
          </div>
        </div>
      </div>

      <div className="mt-6 border-t border-line pt-5">
        <div className="label">{o.liquidated ? "Trade auto-closed" : "You get back"}</div>
        <div className={`num mt-1 text-[40px] font-light leading-none tracking-heading ${tone}`}>{usd(o.traderGets)}</div>
        <div className={`mt-2 text-sm ${tone}`}>
          {o.liquidated ? (
            <>You lose your {usd(deposit)} deposit. Never more.</>
          ) : (
            <span className="num">
              {usd(o.traderPnl, { sign: true })} ({o.traderPnl >= 0 ? "+" : ""}
              {((o.traderPnl / deposit) * 100).toFixed(0)}%)
            </span>
          )}
        </div>
        {!o.liquidated && o.traderPnl > 0 && (
          <p className="mt-3 text-xs text-muted">
            The same {usd(deposit)} without leverage would make {usd((deposit * move) / 100)}. Lenders earn {usd(o.lpEarns)} for
            funding the rest.
          </p>
        )}
      </div>
    </div>
  );
}
