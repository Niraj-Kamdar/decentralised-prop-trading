"use client";

import { useState } from "react";
import { Segmented } from "@/components/ui";
import { usd } from "@/lib/format";
import { simulate } from "@/lib/math";

const MARGINS = [5, 10, 100] as const;

export function Calculator() {
  const [margin, setMargin] = useState<(typeof MARGINS)[number]>(10);
  const [tier, setTier] = useState<5 | 10>(5);
  const [move, setMove] = useState(10);
  const o = simulate(margin, tier, move / 100);
  const liqPct = (o.liqMove * 100).toFixed(1);

  return (
    <div className="card grid gap-6 p-6 md:grid-cols-2">
      <div className="space-y-5">
        <div>
          <div className="label mb-2">You put in</div>
          <Segmented options={MARGINS} value={margin} onChange={setMargin} render={(m) => `$${m}`} />
        </div>
        <div>
          <div className="label mb-2">Buying power</div>
          <Segmented options={[5, 10] as const} value={tier} onChange={setTier} render={(t) => `${t}x → $${margin * t}`} />
        </div>
        <div>
          <div className="mb-2 flex items-center justify-between">
            <span className="label">If BTC moves</span>
            <span className={`num text-lg font-semibold ${move >= 0 ? "text-up" : "text-down"}`}>
              {move > 0 ? "+" : ""}
              {move}%
            </span>
          </div>
          <input type="range" min={-30} max={30} step={1} value={move} onChange={(e) => setMove(Number(e.target.value))} className="w-full" />
          <div className="mt-1 flex justify-between text-xs text-muted">
            <span>-30%</span>
            <span>0</span>
            <span>+30%</span>
          </div>
        </div>
        <p className="text-xs text-muted">
          At {tier}x, the trade closes automatically if the price falls about {liqPct.replace("-", "")}%. That protects the LPs who
          lent you the rest, and it means you can never lose more than your ${margin}.
        </p>
      </div>

      <div className="flex flex-col justify-between gap-4 rounded-lg bg-bg p-5">
        <div>
          <div className="label">You get back</div>
          <div className={`num mt-1 text-4xl font-bold ${o.traderPnl >= 0 ? "text-up" : "text-down"}`}>{usd(o.traderGets)}</div>
          <div className={`num mt-1 text-sm ${o.traderPnl >= 0 ? "text-up" : "text-down"}`}>
            {usd(o.traderPnl, { sign: true })} ({((o.traderPnl / margin) * 100).toFixed(0)}% on your ${margin})
          </div>
          {o.liquidated && (
            <p className="mt-3 rounded-md border border-down/40 bg-down/10 px-3 py-2 text-sm text-down">
              Liquidated. You lose your ${margin} and nothing more. LPs get their money back first.
            </p>
          )}
        </div>
        <div className="space-y-1 border-t border-line pt-4 text-sm">
          <div className="flex justify-between">
            <span className="text-muted">Trade size</span>
            <span className="num">{usd(o.notional)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted">Borrowed from LPs</span>
            <span className="num">{usd(o.borrowed)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted">LPs earn from your profit</span>
            <span className="num text-up">{usd(o.lpEarns)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted">Fees to open or close</span>
            <span className="num">$0.00</span>
          </div>
        </div>
      </div>
    </div>
  );
}
