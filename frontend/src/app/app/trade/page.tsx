"use client";

import { useMemo, useState } from "react";
import { OrderPanel } from "@/components/trade/OrderPanel";
import { PositionsTable } from "@/components/trade/PositionsTable";
import { PriceChart } from "@/components/trade/PriceChart";
import { usePositions } from "@/hooks/usePositions";
import { usePrices } from "@/hooks/usePrices";
import { borrowCapacity, exposureHeadroom, useProtocol } from "@/hooks/useProtocol";
import { ASSETS } from "@/lib/config";
import { price, usd } from "@/lib/format";

export default function TradePage() {
  const [symbol, setSymbol] = useState(ASSETS[0]?.symbol);
  const asset = ASSETS.find((a) => a.symbol === symbol) ?? ASSETS[0];
  const { get, error: priceError } = usePrices();
  const { data: proto } = useProtocol();
  const { data: positions, isLoading } = usePositions();
  const live = get(asset.address);

  const liqPrices = useMemo(
    () =>
      (positions ?? [])
        .filter((p) => p.status === "OPEN" && p.spotToken.toLowerCase() === asset.address.toLowerCase() && p.spotAmount > 0n)
        .map((p) => Number(p.liqThreshold) / 1e6 / (Number(p.spotAmount) / 10 ** asset.decimals)),
    [positions, asset],
  );

  return (
    <div className="space-y-4">
      <div className="card flex flex-wrap items-center gap-x-8 gap-y-3 px-4 py-3">
        <div className="flex gap-1">
          {ASSETS.map((a) => (
            <button
              key={a.symbol}
              onClick={() => setSymbol(a.symbol)}
              className={`rounded-md px-3 py-1.5 text-sm font-semibold ${a.symbol === asset.symbol ? "bg-panel2" : "text-muted hover:text-fg"}`}
            >
              {a.symbol}/USD
            </button>
          ))}
        </div>
        <div>
          <div className="text-xs text-muted">Chainlink price</div>
          <div className="num text-lg font-semibold">{live?.ready ? price(live.twap) : "warming up"}</div>
        </div>
        <div>
          <div className="text-xs text-muted">Pool price</div>
          <div className="num text-sm">
            {price(live?.spot)}
            {live?.spot && live.twap ? (
              <span className="ml-1 text-muted">({(((live.spot - live.twap) / live.twap) * 100).toFixed(2)}% vs Chainlink)</span>
            ) : null}
          </div>
        </div>
        <div>
          <div className="text-xs text-muted">Vault can lend</div>
          <div className="num text-sm">{proto ? usd(borrowCapacity(proto)) : "—"}</div>
        </div>
        <div>
          <div className="text-xs text-muted">{asset.symbol} capacity</div>
          <div className="num text-sm">{proto ? usd(exposureHeadroom(proto, asset.address)) : "—"}</div>
        </div>
        <div>
          <div className="text-xs text-muted">Venue</div>
          <div className="text-sm">Uniswap v4 · spot</div>
        </div>
      </div>

      {priceError && (
        <div className="rounded-lg border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">
          Live prices unavailable: {priceError.message}. Trading needs the on-chain price oracle.
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
        <div className="card h-[340px] overflow-hidden sm:h-[460px] lg:h-auto">
          <PriceChart asset={asset} spot={live?.spot} twap={live?.twap} liqPrices={liqPrices} />
        </div>
        <div className="card">
          <OrderPanel asset={asset} price18={live?.twap18} />
        </div>
      </div>

      <div className="card">
        <PositionsTable positions={positions} loading={isLoading} />
      </div>
    </div>
  );
}
