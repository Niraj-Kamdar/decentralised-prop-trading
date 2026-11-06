"use client";

import { useState } from "react";
import { Segmented } from "@/components/ui";
import { usd } from "@/lib/format";
import { simulate } from "@/lib/math";

const DEPOSITS = [10, 50, 100] as const;
const RANGE = 20; // slider spans -RANGE% … +RANGE%

export function Calculator() {
  const [deposit, setDeposit] = useState<(typeof DEPOSITS)[number]>(10);
  const [tier, setTier] = useState<5 | 10>(5);
  const [move, setMove] = useState(5);
  const o = simulate(deposit, tier, move / 100);
  const liqPct = Math.round(o.liqMove * 1000) / 10; // e.g. -16, -8
  // Share of the track (from the left) that is in the auto-close zone.
  const liqZone = ((liqPct + RANGE) / (2 * RANGE)) * 100;
  const tone = o.liquidated || o.traderPnl < 0 ? "text-down" : "text-up";

  return (
    <div className="card-raised p-6 sm:p-7">
      <div className="space-y-5">
        <div>
          <div className="label mb-2">You deposit</div>
          <Segmented options={DEPOSITS} value={deposit} onChange={setDeposit} render={(m) => `$${m}`} />
        </div>
        <div>
          <div className="label mb-2">You trade with</div>
          <Segmented options={[5, 10] as const} value={tier} onChange={setTier} render={(t) => `$${deposit * t} · ${t}x`} />
        </div>
        <div>
          <div className="mb-2 flex items-center justify-between">
            <label htmlFor="calc-move" className="label">
              If BTC moves
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
            <>You lose your ${deposit} deposit. Never more.</>
          ) : (
            <span className="num">
              {usd(o.traderPnl, { sign: true })} ({o.traderPnl >= 0 ? "+" : ""}
              {((o.traderPnl / deposit) * 100).toFixed(0)}%)
            </span>
          )}
        </div>
        {!o.liquidated && o.traderPnl > 0 && (
          <p className="mt-3 text-xs text-muted">
            A plain ${deposit} trade would make {usd((deposit * move) / 100)}. The vault earns {usd(o.lpEarns)} for lending you the rest.
          </p>
        )}
      </div>
    </div>
  );
}
