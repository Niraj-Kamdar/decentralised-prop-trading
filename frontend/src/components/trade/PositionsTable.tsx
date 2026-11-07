"use client";

import { useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { pmAbi } from "@/abi";
import { AmountInput, Empty, Modal, Notice, Row, Segmented } from "@/components/ui";
import type { Position } from "@/hooks/usePositions";
import { usePrices } from "@/hooks/usePrices";
import { tierParams, useProtocol, useTraderStats } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { approveIfNeeded } from "@/hooks/useUsdc";
import { addressUrl, chain, assetByAddress, CONTRACTS, type Asset } from "@/lib/config";
import { dateTime, parseUsdc, price, timeLeft, toUsdc, usd } from "@/lib/format";
import { positionView } from "@/lib/positionView";
import { prepareExit } from "@/lib/trade";

type Tab = "open" | "history";

export function PositionsTable({ positions, loading }: { positions: Position[] | undefined; loading: boolean }) {
  const [tab, setTab] = useState<Tab>("open");
  const open = positions?.filter((p) => p.status === "OPEN") ?? [];
  const closed = positions?.filter((p) => p.status !== "OPEN") ?? [];

  return (
    <div>
      <div className="flex items-center gap-1 border-b border-line px-3 py-2">
        <TabBtn active={tab === "open"} onClick={() => setTab("open")}>
          Open positions {open.length > 0 && <span className="num ml-1 text-muted">{open.length}</span>}
        </TabBtn>
        <TabBtn active={tab === "history"} onClick={() => setTab("history")}>
          History
        </TabBtn>
      </div>
      {tab === "open" ? <OpenTable rows={open} loading={loading} /> : <HistoryTable rows={closed} />}
    </div>
  );
}

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button onClick={onClick} aria-pressed={active} className={`relative px-3 py-2 text-sm transition-colors duration-150 ${active ? "text-fg after:absolute after:inset-x-3 after:-bottom-2 after:h-0.5 after:bg-accent" : "text-muted hover:text-fg"}`}>
      {children}
    </button>
  );
}

function OpenTable({ rows, loading }: { rows: Position[]; loading: boolean }) {
  const { get } = usePrices();
  const { data: proto } = useProtocol();
  const level = useTraderStats().data?.level ?? 0;
  const [action, setAction] = useState<{ kind: "close" | "margin" | "orders"; pos: Position } | null>(null);

  if (loading) return <Empty>Loading positions…</Empty>;
  if (rows.length === 0) return <Empty>No open positions. Open one above to get started.</Empty>;

  return (
    <>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[960px] text-sm">
          <thead className="bg-panel2 text-left text-xs text-muted">
            <tr className="border-b border-line">
              {["Market", "Size", "Margin", "Entry", "Mark", "Liq. price", "PnL (if closed now)", "Epoch", ""].map((h) => (
                <th key={h} className="px-3 py-2.5 font-normal">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((pos) => {
              const asset = assetByAddress(pos.spotToken);
              const v = positionView(pos, asset?.decimals ?? 18, asset ? get(asset.address)?.twap18 ?? undefined : undefined, tierParams(proto, pos.tier, level));
              const atRisk = v.health !== null && v.health < 0.25;
              return (
                <tr key={pos.id.toString()} className="border-b border-line last:border-0 transition-colors hover:bg-panel2/60">
                  <td className="px-3 py-3">
                    <div className="font-medium">
                      {asset?.symbol ?? "?"} <span className="pill ml-1 border border-accent/20 bg-accent/5 text-accent">{pos.tier}x</span>
                    </div>
                    <a href={addressUrl(pos.proxy)} target="_blank" rel="noreferrer" className="text-xs text-muted hover:text-fg">
                      #{pos.id.toString()} ↗
                    </a>
                  </td>
                  <td className="num px-3 py-3">
                    {usd(pos.notional)}
                    <div className="text-xs text-muted">
                      {v.tokens.toLocaleString("en-US", { maximumFractionDigits: 6 })} {asset?.symbol}
                    </div>
                  </td>
                  <td className="num px-3 py-3">{usd(pos.userMargin)}</td>
                  <td className="num px-3 py-3">{price(v.entryPrice)}</td>
                  <td className="num px-3 py-3">{price(v.markPrice)}</td>
                  <td className={`num px-3 py-3 ${atRisk ? "text-down" : ""}`}>
                    {price(v.liqPrice)}
                    {v.health !== null && (
                      <div className="mt-1 h-1 w-20 overflow-hidden rounded bg-line">
                        <div className={`h-full ${atRisk ? "bg-down" : v.health < 0.5 ? "bg-warn" : "bg-up"}`} style={{ width: `${v.health * 100}%` }} />
                      </div>
                    )}
                  </td>
                  <td className={`num px-3 py-3 ${v.pnl === null ? "" : v.pnl >= 0 ? "text-up" : "text-down"}`}>
                    {usd(v.pnl, { sign: true })}
                    {v.pnlPct !== null && <div className="text-xs">{(v.pnlPct * 100).toFixed(1)}%</div>}
                  </td>
                  <td className="px-3 py-3 text-xs">
                    <div>{pos.autoRollover ? "Auto-roll" : "Closes"} in {timeLeft(pos.epochEndTime)}</div>
                    {v.rolloverDebt > 0 && <div className="num text-muted">fees {usd(v.rolloverDebt)}</div>}
                    <AutoRollToggle pos={pos} />
                  </td>
                  <td className="px-3 py-3">
                    <div className="flex justify-end gap-1">
                      <button className="btn-ghost px-2 py-1 text-xs" onClick={() => setAction({ kind: "orders", pos })}>
                        TP/SL
                      </button>
                      <button className="btn-ghost px-2 py-1 text-xs" onClick={() => setAction({ kind: "margin", pos })}>
                        Add margin
                      </button>
                      <button className="btn-secondary px-3 py-1 text-xs" onClick={() => setAction({ kind: "close", pos })}>
                        Close
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {action && assetByAddress(action.pos.spotToken) && (
        <>
          {action.kind === "close" && <CloseModal pos={action.pos} asset={assetByAddress(action.pos.spotToken)!} onClose={() => setAction(null)} />}
          {action.kind === "margin" && <MarginModal pos={action.pos} asset={assetByAddress(action.pos.spotToken)!} onClose={() => setAction(null)} />}
          {action.kind === "orders" && <OrdersModal pos={action.pos} asset={assetByAddress(action.pos.spotToken)!} onClose={() => setAction(null)} />}
        </>
      )}
    </>
  );
}

function AutoRollToggle({ pos }: { pos: Position }) {
  const { run, busy, walletClient } = useTx();
  return (
    <button
      disabled={busy}
      className="mt-1 text-xs text-accent hover:underline disabled:opacity-50"
      onClick={() =>
        run(pos.autoRollover ? "Auto-roll turned off" : "Auto-roll turned on", [
          {
            title: pos.autoRollover ? "Turn off auto-roll" : "Turn on auto-roll",
            send: () =>
              walletClient!.writeContract({
                address: CONTRACTS.positionManager,
                abi: pmAbi,
                functionName: "setAutoRollover",
                args: [pos.id, !pos.autoRollover],
                account: walletClient!.account!,
                chain,
              }),
          },
        ])
      }
    >
      {pos.autoRollover ? "Turn off auto-roll" : "Turn on auto-roll"}
    </button>
  );
}

function CloseModal({ pos, asset, onClose }: { pos: Position; asset: Asset; onClose: () => void }) {
  const { get } = usePrices();
  const { data: proto } = useProtocol();
  const level = useTraderStats().data?.level ?? 0;
  const { run, busy, walletClient, publicClient } = useTx();
  const [slippage, setSlippage] = useState<number>(50);
  const v = positionView(pos, asset.decimals, get(asset.address)?.twap18 ?? undefined, tierParams(proto, pos.tier, level));

  async function submit() {
    if (!walletClient || !publicClient) return;
    const ok = await run(`${asset.symbol} position closed`, [
      {
        title: `Close ${asset.symbol} position`,
        send: async () => {
          const prep = await prepareExit(publicClient, {
            asset,
            spotAmount: pos.spotAmount,
            slippageBps: slippage,
            maxSlippageBps: proto?.pm.maxExitSlippageBps ?? 100,
            twap18: get(asset.address)?.twap18 ?? null,
          });
          if (prep.mark === null) throw new Error("The Chainlink price is unavailable right now. Try again in a few minutes.");
          if (prep.poolBelowOracle) {
            throw new Error(
              "The Uniswap pool is trading too far below the Chainlink price to close safely right now. Try again when the pool recovers.",
            );
          }
          return walletClient.writeContract({
            address: CONTRACTS.positionManager,
            abi: pmAbi,
            functionName: "closePosition",
            args: [pos.id, prep.minAmountOut],
            account: walletClient.account!,
            chain,
          });
        },
      },
    ]);
    if (ok) onClose();
  }

  return (
    <Modal open onClose={onClose} title={`Close ${asset.symbol} ${pos.tier}x`}>
      <div className="rounded-lg bg-panel2 p-3">
        <Row label="Sell" value={`${v.tokens.toLocaleString("en-US", { maximumFractionDigits: 8 })} ${asset.symbol}`} />
        <Row label="Value at 10-min avg price" value={usd(v.markValue)} />
        <Row label="Repay LPs" value={usd(toUsdc(pos.borrowedPrincipal) + v.rolloverDebt)} />
        <Row label="You receive (est.)" value={usd(v.receive)} tone={v.pnl !== null && v.pnl >= 0 ? "up" : "down"} />
        <Row label="PnL" value={usd(v.pnl, { sign: true })} tone={v.pnl !== null && v.pnl >= 0 ? "up" : "down"} />
      </div>
      <div className="mt-4 flex items-center justify-between text-sm">
        <span className="text-muted">Slippage tolerance</span>
        <Segmented options={[30, 50, 100] as const} value={slippage as 30 | 50 | 100} onChange={setSlippage} render={(s) => `${s / 100}%`} />
      </div>
      <p className="mt-3 text-xs text-muted">
        Profit share is taken only from gains above your margin. The actual amount depends on the Uniswap fill.
      </p>
      <button className="btn-down mt-4 w-full py-3" disabled={busy} onClick={submit}>
        {busy ? "Working…" : "Close position"}
      </button>
    </Modal>
  );
}

function MarginModal({ pos, asset, onClose }: { pos: Position; asset: Asset; onClose: () => void }) {
  const { run, busy, walletClient, publicClient } = useTx();
  const [amount, setAmount] = useState("");
  const value = parseUsdc(amount);
  const tooMuch = value > pos.borrowedPrincipal;

  async function submit() {
    if (!walletClient || !publicClient) return;
    const ok = await run("Margin added", [
      { title: "Approve USDC", send: () => approveIfNeeded(publicClient, walletClient, CONTRACTS.positionManager, value) },
      {
        title: "Add margin",
        send: () =>
          walletClient.writeContract({
            address: CONTRACTS.positionManager,
            abi: pmAbi,
            functionName: "addMargin",
            args: [pos.id, value],
            account: walletClient.account!,
            chain,
          }),
      },
    ]);
    if (ok) onClose();
  }

  return (
    <Modal open onClose={onClose} title={`Add margin to ${asset.symbol} ${pos.tier}x`}>
      <p className="mb-3 text-sm text-muted">
        Extra margin pays down what you borrowed. That lowers your liquidation price and your weekly fees. You get it back when
        you close, before any profit is split.
      </p>
      <AmountInput value={amount} onChange={setAmount} max={formatUnits(pos.borrowedPrincipal, 6)} />
      <div className="mt-3 rounded-lg bg-panel2 p-3">
        <Row label="Borrowed now" value={usd(pos.borrowedPrincipal)} />
        <Row label="Borrowed after" value={usd(toUsdc(pos.borrowedPrincipal) - toUsdc(value))} />
      </div>
      {tooMuch && <div className="mt-3"><Notice tone="warn">You can add at most the borrowed amount.</Notice></div>}
      <button className="btn-primary mt-4 w-full py-3" disabled={busy || value === 0n || tooMuch} onClick={submit}>
        {busy ? "Working…" : "Add margin"}
      </button>
    </Modal>
  );
}

function OrdersModal({ pos, asset, onClose }: { pos: Position; asset: Asset; onClose: () => void }) {
  const { run, busy, walletClient } = useTx();
  const fmt = (v: bigint) => (v === 0n ? "" : formatUnits(v, 18));
  const [tp, setTp] = useState(fmt(pos.takeProfitPrice));
  const [sl, setSl] = useState(fmt(pos.stopLossPrice));
  const [trail, setTrail] = useState(fmt(pos.trailingStopPrice));
  const parse = (s: string) => {
    try {
      return s.trim() ? parseUnits(s.trim(), 18) : 0n;
    } catch {
      return 0n;
    }
  };

  async function submit() {
    if (!walletClient) return;
    const ok = await run("Orders updated", [
      {
        title: "Set take-profit / stop-loss",
        send: () =>
          walletClient.writeContract({
            address: CONTRACTS.positionManager,
            abi: pmAbi,
            functionName: "setOrders",
            args: [pos.id, parse(sl), parse(tp), parse(trail)],
            account: walletClient.account!,
            chain,
          }),
      },
    ]);
    if (ok) onClose();
  }

  const field = (label: string, value: string, set: (v: string) => void, hint: string) => (
    <label className="block">
      <span className="label">{label}</span>
      <AmountInput value={value} onChange={set} suffix="USD" placeholder="Not set" />
      <span className="mt-1 block text-xs text-muted">{hint}</span>
    </label>
  );

  return (
    <Modal open onClose={onClose} title={`Orders for ${asset.symbol} ${pos.tier}x`}>
      <div className="space-y-4">
        {field("Take profit", tp, setTp, `Close when ${asset.symbol} reaches or exceeds this price.`)}
        {field("Stop loss", sl, setSl, `Close when ${asset.symbol} falls to this price or lower.`)}
        {field("Trailing floor", trail, setTrail, "A stop you can raise as price moves up.")}
        <p className="text-xs text-muted">Orders are executed by keeper bots when the Chainlink price crosses them. Leave a field empty to clear it.</p>
        <button className="btn-primary w-full py-3" disabled={busy} onClick={submit}>
          {busy ? "Working…" : "Save orders"}
        </button>
      </div>
    </Modal>
  );
}

function HistoryTable({ rows }: { rows: Position[] }) {
  if (rows.length === 0) return <Empty>No closed positions yet.</Empty>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[640px] text-sm">
        <thead className="bg-panel2 text-left text-xs text-muted">
          <tr className="border-b border-line">
            {["Market", "Size", "Margin", "Opened", "Outcome", ""].map((h) => (
              <th key={h} className="px-3 py-2.5 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((pos) => {
            const asset = assetByAddress(pos.spotToken);
            return (
              <tr key={pos.id.toString()} className="border-b border-line last:border-0 transition-colors hover:bg-panel2/60">
                <td className="px-3 py-3 font-medium">
                  {asset?.symbol ?? "?"} <span className="pill ml-1 border border-line bg-panel2 text-muted">{pos.tier}x</span>
                </td>
                <td className="num px-3 py-3">{usd(pos.notional)}</td>
                <td className="num px-3 py-3">{usd(pos.userMargin)}</td>
                <td className="px-3 py-3 text-muted">{dateTime(pos.openedAt)}</td>
                <td className="px-3 py-3">
                  <span className={`pill ${pos.status === "LIQUIDATED" ? "border border-down/30 bg-down/5 text-down" : "border border-line bg-panel2 text-muted"}`}>
                    {pos.status === "LIQUIDATED" ? "Liquidated" : "Closed"}
                  </span>
                </td>
                <td className="px-3 py-3 text-right">
                  <a href={addressUrl(pos.proxy)} target="_blank" rel="noreferrer" className="text-xs text-accent hover:underline">
                    #{pos.id.toString()} ↗
                  </a>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
