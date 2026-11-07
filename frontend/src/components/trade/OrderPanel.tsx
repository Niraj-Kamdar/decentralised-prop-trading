"use client";

import { useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { formatUnits } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { pmAbi } from "@/abi";
import { AmountInput, Notice, Row, Segmented, Toggle } from "@/components/ui";
import { borrowCapacity, exposureHeadroom, tierParams, useProtocol } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { approveIfNeeded, useUsdcBalance } from "@/hooks/useUsdc";
import { chain, CONTRACTS, TIERS, TRADING_CONFIGURED, USDC, type Asset } from "@/lib/config";
import { parseUsdc, pct, price, toUsdc, usd } from "@/lib/format";
import { epochFee } from "@/lib/math";
import { prepareOpen, tokensForUsdc } from "@/lib/trade";
import { quoteExactIn } from "@/lib/uniswap";

const SLIPPAGES = [30, 50, 100] as const;
const PRESETS = ["5", "10"];

/** `price18` is the Chainlink price (null while the oracle warms up); entries are checked against it on-chain. */
export function OrderPanel({ asset, price18 }: { asset: Asset; price18?: bigint | null }) {
  const { isConnected } = useAccount();
  const client = usePublicClient();
  const { data: proto } = useProtocol();
  const { data: balance } = useUsdcBalance();
  const { run, busy, walletClient, publicClient } = useTx();

  const [amount, setAmount] = useState("5");
  const [tier, setTier] = useState<number>(5);
  const [autoRoll, setAutoRoll] = useState(false);
  const [slippage, setSlippage] = useState<number>(50);
  const [debounced, setDebounced] = useState(amount);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(amount), 400);
    return () => clearTimeout(t);
  }, [amount]);

  const margin = parseUsdc(amount);
  const notional = margin * BigInt(tier);
  const borrowed = notional - margin;
  const t = tierParams(proto, tier);
  const px = price18 ? Number(formatUnits(price18, 18)) : undefined;

  const oracleTokens = price18 && notional > 0n ? tokensForUsdc(notional, price18, asset.decimals) : 0n;
  const debouncedNotional = parseUsdc(debounced) * BigInt(tier);
  const { data: quote } = useQuery({
    queryKey: ["quote-open", asset.address, debouncedNotional.toString()],
    enabled: !!client && debouncedNotional > 0n && TRADING_CONFIGURED,
    queryFn: () => quoteExactIn(client!, { tokenIn: USDC, tokenOut: asset.address, spot: asset.address, amountIn: debouncedNotional }),
    refetchInterval: 15_000,
  });
  const tokensOut = quote ?? oracleTokens;
  const tokens = Number(formatUnits(tokensOut, asset.decimals));
  const impactBps =
    quote && oracleTokens > 0n && debouncedNotional === notional ? Number(((oracleTokens - quote) * 10_000n) / oracleTokens) : null;

  const threshold = toUsdc(borrowed) + (toUsdc(notional) * t.maintenanceBps) / 10_000;
  const liqPrice = tokens > 0 ? threshold / tokens : null;
  const liqDrop = px && liqPrice ? (1 - liqPrice / px) * 100 : null;
  const weekly = epochFee(toUsdc(borrowed), proto?.pm.rolloverAprBps ?? 800);
  const keepPct = 100 - (t.lpProfitBps + t.treasuryProfitBps) / 100;

  // Pre-flight checks mirroring the contract's revert conditions.
  let problem: string | null = null;
  if (!TRADING_CONFIGURED) problem = "Trading is not configured.";
  else if (!price18) problem = "The price oracle is warming up (it needs 10 minutes of pool history). Try again shortly.";
  else if (proto?.pm.paused) problem = "New positions are paused.";
  else if (proto && !proto.pm.assets[asset.address.toLowerCase()]?.enabled) problem = "This market is not enabled yet.";
  else if (proto && !proto.pm.tiers[tier]?.enabled) problem = `${tier}x is disabled.`;
  else if (margin === 0n) problem = "Enter an amount.";
  else if (proto && notional < proto.pm.minNotional)
    problem = `Minimum position size is ${usd(proto.pm.minNotional)}: at ${tier}x, put in at least ${usd(toUsdc(proto.pm.minNotional) / tier)}.`;
  else if (proto && borrowed > borrowCapacity(proto))
    problem = `The vault can lend at most ${usd(borrowCapacity(proto))} right now. Try a smaller amount or lower leverage.`;
  else if (proto && notional > exposureHeadroom(proto, asset.address))
    problem = `${asset.symbol} is near its open-interest cap: max size ${usd(exposureHeadroom(proto, asset.address))} right now.`;
  else if (balance !== undefined && margin > balance) problem = "Not enough USDC in your wallet.";
  else if (impactBps !== null && proto && impactBps > proto.pm.maxEntrySlippageBps)
    problem = `The pool would fill ${pct(impactBps, 2)} worse than the 10-minute average price (max ${pct(proto.pm.maxEntrySlippageBps)}). Try a smaller size or wait for the pool to settle.`;

  async function submit() {
    if (!walletClient || !publicClient) return;
    await run(`${tier}x ${asset.symbol} position opened`, [
      {
        title: "Approve USDC",
        send: () => approveIfNeeded(publicClient, walletClient, CONTRACTS.positionManager, margin),
      },
      {
        title: `Open ${tier}x ${asset.symbol}`,
        send: async () => {
          const prep = await prepareOpen(publicClient, {
            asset,
            tier,
            margin,
            autoRollover: autoRoll,
            slippageBps: slippage,
            twap18: price18 ?? null,
          });
          return walletClient.writeContract({
            address: CONTRACTS.positionManager,
            abi: pmAbi,
            functionName: "openPosition",
            args: [prep.args],
            account: walletClient.account!,
            chain,
          });
        },
      },
    ]);
  }

  const maxMargin = balance !== undefined ? formatUnits(balance, 6) : undefined;

  return (
    <div className="space-y-4 p-4">
      <div>
        <div className="mb-2 flex items-center justify-between">
          <span className="label">You put in</span>
          <span className="text-xs text-muted">Wallet: {balance !== undefined ? usd(balance) : "—"}</span>
        </div>
        <AmountInput value={amount} onChange={setAmount} max={maxMargin} />
        <div className="mt-2 flex gap-2">
          {PRESETS.map((p) => (
            <button key={p} onClick={() => setAmount(p)} className="btn-secondary flex-1 py-1 text-xs">
              ${p}
            </button>
          ))}
        </div>
      </div>

      <div>
        <div className="label mb-2">Leverage</div>
        <Segmented options={TIERS} value={tier as (typeof TIERS)[number]} onChange={setTier} render={(x) => `${x}x`} />
      </div>

      <div className="rounded-lg bg-panel2 p-3">
        <Row label="Position size" value={usd(notional)} />
        <Row label="Borrowed from LPs" value={usd(borrowed)} />
        <Row label={`You receive (est.)`} value={tokens > 0 ? `${tokens.toLocaleString("en-US", { maximumFractionDigits: 8 })} ${asset.symbol}` : "—"} />
        <Row label="Entry price (est.)" value={tokens > 0 ? price(toUsdc(notional) / tokens) : "—"} />
        <Row
          label="Liquidation price"
          value={liqPrice ? `${price(liqPrice)}${liqDrop !== null ? ` (−${liqDrop.toFixed(1)}%)` : ""}` : "—"}
          tone="down"
        />
        <Row label="Max loss" value={usd(margin)} />
        <Row label="Fees" value="None for the first 7 days" tone="up" />
        <Row label="You keep of profits" value={`${keepPct}%`} />
      </div>

      <Toggle
        checked={autoRoll}
        onChange={setAutoRoll}
        label={
          <span>
            Keep open after 7 days
            <span className="block text-xs text-muted/80">
              {autoRoll ? `Rolls weekly for ≈${usd(weekly)}/week` : "Otherwise it is closed automatically after 7 days"}
            </span>
          </span>
        }
      />

      <div className="flex items-center justify-between text-sm">
        <span className="text-muted">Slippage tolerance</span>
        <div className="flex gap-1">
          {SLIPPAGES.map((s) => (
            <button
              key={s}
              onClick={() => setSlippage(s)}
              className={`rounded px-2 py-0.5 text-xs ${slippage === s ? "bg-panel2 text-fg" : "text-muted hover:text-fg"}`}
            >
              {s / 100}%
            </button>
          ))}
        </div>
      </div>

      {isConnected && problem && margin > 0n && <Notice tone="warn">{problem}</Notice>}

      {!isConnected ? (
        <p className="rounded-lg border border-line p-3 text-center text-sm text-muted">Connect a wallet to trade.</p>
      ) : (
        <button className="btn-primary w-full py-3 text-base" disabled={!!problem || busy} onClick={submit}>
          {busy ? "Working…" : `Buy ${asset.symbol} with ${tier}x`}
        </button>
      )}
      <p className="text-center text-xs text-muted">
        Two wallet confirmations: approve USDC, then open. Your fill is checked against the 10-minute Uniswap average price.
      </p>
    </div>
  );
}
