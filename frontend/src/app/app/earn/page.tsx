"use client";

import { useState } from "react";
import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { vaultAbi } from "@/abi";
import { AmountInput, Empty, Notice, Row, Segmented, Stat, Toggle } from "@/components/ui";
import { useLP, type LPState } from "@/hooks/useLP";
import { useProtocol, type ProtocolState } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { approveIfNeeded, useUsdcBalance } from "@/hooks/useUsdc";
import { arc, CONTRACTS } from "@/lib/config";
import { dateTime, parseUsdc, pct, timeLeft, toUsdc, usd } from "@/lib/format";

export default function EarnPage() {
  const { data: proto } = useProtocol();
  const { data: lp } = useLP();
  const { isConnected } = useAccount();

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-[32px] leading-tight tracking-heading">Earn</h1>
        <p className="mt-1 text-sm text-muted">
          Deposit USDC into the vault that funds traders. You earn a share of their profits, weekly fees on what they borrow, and
          lending yield on idle cash.
        </p>
      </div>

      <VaultStats proto={proto} />

      <div className="grid gap-4 lg:grid-cols-[1fr_400px]">
        <div className="space-y-4">
          <YourPosition lp={lp} connected={isConnected} />
          <Requests lp={lp} proto={proto} />
          <Tickets lp={lp} />
        </div>
        <div className="space-y-4">
          <DepositWithdraw proto={proto} lp={lp} />
          <HowItWorks proto={proto} />
        </div>
      </div>
    </div>
  );
}

function VaultStats({ proto }: { proto?: ProtocolState }) {
  const v = proto?.vault;
  const util = v ? v.utilizationBps / 100 : 0;
  return (
    <div className="card p-5">
      <div className="grid grid-cols-2 gap-5 md:grid-cols-5">
        <Stat label="Vault size" value={v ? usd(v.totalAssets) : "—"} />
        <Stat label="Lent to traders" value={v ? usd(v.totalBorrowed) : "—"} />
        <Stat label="spUSDC price" value={v ? `$${(Number(v.sharePrice) / 1e6).toFixed(4)}` : "—"} sub="Rises as the vault earns" />
        <Stat label="Insurance pool" value={proto ? usd(proto.insurance) : "—"} sub="Absorbs losses before LPs" />
        <Stat label="Waiting to withdraw" value={v ? usd(v.pendingRedeemAssets) : "—"} />
      </div>
      <div className="mt-5">
        <div className="mb-1 flex justify-between text-xs text-muted">
          <span>
            Utilisation <span className={`num ${v?.isStressed ? "text-warn" : "text-fg"}`}>{v ? pct(v.utilizationBps) : "—"}</span>
            {v?.isStressed && <span className="ml-2 text-warn">Busy: bonus deposits open</span>}
          </span>
          <span>
            Busy at {v ? pct(v.stressUtilizationBps, 0) : "80%"} · cap {v ? pct(v.maxUtilizationBps, 0) : "85%"}
          </span>
        </div>
        <div className="relative h-2 rounded-full bg-line">
          <div className={`h-full rounded-full ${v?.isStressed ? "bg-warn" : "bg-accent"}`} style={{ width: `${Math.min(util, 100)}%` }} />
          {v && <div className="absolute top-[-3px] h-3.5 w-0.5 bg-warn" style={{ left: `${v.stressUtilizationBps / 100}%` }} />}
          {v && <div className="absolute top-[-3px] h-3.5 w-0.5 bg-down" style={{ left: `${v.maxUtilizationBps / 100}%` }} />}
        </div>
      </div>
    </div>
  );
}

function YourPosition({ lp, connected }: { lp?: LPState; connected: boolean }) {
  const { run, busy, walletClient } = useTx();
  const { address } = useAccount();
  if (!connected) return <div className="card"><Empty>Connect a wallet to see your liquidity.</Empty></div>;
  const earned = lp ? toUsdc(lp.value) - toUsdc(lp.costBasis) : null;
  return (
    <div className="card p-5">
      <h2 className="text-lg">Your liquidity</h2>
      <div className="mt-4 grid grid-cols-2 gap-5 md:grid-cols-4">
        <Stat label="Current value" value={lp ? usd(lp.value) : "—"} />
        <Stat label="Deposited" value={lp ? usd(lp.costBasis) : "—"} sub="Cost basis" />
        <Stat label="Earned" value={earned === null ? "—" : usd(earned, { sign: true })} tone={earned === null ? undefined : earned >= 0 ? "up" : "down"} />
        <Stat label="spUSDC" value={lp ? Number(formatUnits(lp.shares, 12)).toLocaleString("en-US", { maximumFractionDigits: 4 }) : "—"} />
      </div>
      {lp && lp.claimableAssets > 0n && (
        <div className="mt-4 flex items-center justify-between gap-4 rounded-lg border border-up/30 bg-up/5 p-3">
          <div className="text-sm">
            <div className="font-medium text-up">{usd(lp.claimableAssets)} ready to withdraw</div>
            <div className="text-muted">Your withdrawal request has been paid out.</div>
          </div>
          <button
            className="btn-up"
            disabled={busy}
            onClick={() =>
              run("Withdrawal claimed", [
                {
                  title: "Claim USDC",
                  send: () =>
                    walletClient!.writeContract({
                      address: CONTRACTS.lpVault,
                      abi: vaultAbi,
                      functionName: "withdraw",
                      args: [lp.claimableAssets, address!, address!],
                      account: walletClient!.account!,
                      chain: arc,
                    }),
                },
              ])
            }
          >
            Claim
          </button>
        </div>
      )}
    </div>
  );
}

function DepositWithdraw({ proto, lp }: { proto?: ProtocolState; lp?: LPState }) {
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const [bonus, setBonus] = useState(false);
  const { address, isConnected } = useAccount();
  const { data: balance } = useUsdcBalance();
  const { run, busy, walletClient, publicClient } = useTx();
  const value = parseUsdc(amount);
  const v = proto?.vault;

  const stressed = !!v?.isStressed;
  const useBonus = tab === "deposit" && stressed && bonus;

  let problem: string | null = null;
  if (value === 0n) problem = "Enter an amount";
  else if (tab === "deposit" && balance !== undefined && value > balance) problem = "Not enough USDC";
  else if (useBonus && v && value < v.minBonusDeposit) problem = `Bonus deposits start at ${usd(v.minBonusDeposit)}`;
  else if (tab === "withdraw" && lp && value > lp.value) problem = "More than your balance";

  async function submit() {
    if (!walletClient || !publicClient || !address) return;
    if (tab === "deposit") {
      const ok = await run(useBonus ? "Bonus deposit locked" : "Deposited", [
        { title: "Approve USDC", send: () => approveIfNeeded(publicClient, walletClient, CONTRACTS.lpVault, value) },
        {
          title: useBonus ? "Deposit with bonus" : "Deposit",
          send: () =>
            walletClient.writeContract({
              address: CONTRACTS.lpVault,
              abi: vaultAbi,
              functionName: useBonus ? "depositWithBonus" : "deposit",
              args: [value, address],
              account: walletClient.account!,
              chain: arc,
            }),
        },
      ]);
      if (ok) setAmount("");
    } else {
      // Convert the USDC amount to shares pro rata to the wallet's own balance; MAX requests every share.
      const shares = !lp || lp.value === 0n ? 0n : value >= lp.value ? lp.shares : (lp.shares * value) / lp.value;
      const ok = await run("Withdrawal requested", [
        {
          title: "Request withdrawal",
          send: () =>
            walletClient.writeContract({
              address: CONTRACTS.lpVault,
              abi: vaultAbi,
              functionName: "requestRedeem",
              args: [shares, address, address],
              account: walletClient.account!,
              chain: arc,
            }),
        },
      ]);
      if (ok) setAmount("");
    }
  }

  const cooldownDays = v ? Math.round(v.redeemCooldown / 86400) : 30;
  const bonusDays = v ? Math.round(v.bonusDuration / 86400) : 90;

  return (
    <div className="card p-4">
      <Segmented options={["deposit", "withdraw"] as const} value={tab} onChange={(t) => (setTab(t), setAmount(""))} render={(t) => (t === "deposit" ? "Deposit" : "Withdraw")} />
      <div className="mt-4 space-y-4">
        <div>
          <div className="mb-2 flex justify-between text-xs text-muted">
            <span>Amount</span>
            <span>
              {tab === "deposit" ? "Wallet" : "Your liquidity"}: {tab === "deposit" ? (balance !== undefined ? usd(balance) : "—") : lp ? usd(lp.value) : "—"}
            </span>
          </div>
          <AmountInput
            value={amount}
            onChange={setAmount}
            max={tab === "deposit" ? (balance !== undefined ? formatUnits(balance, 6) : undefined) : lp ? formatUnits(lp.value, 6) : undefined}
          />
        </div>

        {tab === "deposit" && stressed && (
          <div className="rounded-lg border border-warn/40 bg-warn/5 p-3">
            <Toggle checked={bonus} onChange={setBonus} label={<span className="font-medium text-fg">Lock for {bonusDays} days and earn a bonus</span>} />
            <p className="mt-2 text-xs text-muted">
              The vault is busy, so it needs liquidity now. Locked deposits share the bonus pot ({v ? usd(v.bonusPot) : "—"}), up to{" "}
              {v ? pct(v.maxBonusAprBps, 0) : "20%"} APR, on top of normal earnings. Unlocking early forfeits the bonus.
            </p>
          </div>
        )}

        {tab === "withdraw" && (
          <div className="space-y-2">
            <Notice>
              Withdrawals are paid after a {cooldownDays}-day queue. From the moment you request, those funds stop earning but can
              still absorb losses. You can cancel any time before payout.
            </Notice>
            {stressed && (
              <Notice tone="warn">
                The vault is busy ({v ? pct(v.utilizationBps) : ""} lent out). Requesting now forfeits{" "}
                {v ? pct(v.exitPenaltyBps, 0) : "25%"} of the yield you've earned, never your principal.
              </Notice>
            )}
          </div>
        )}

        {!isConnected ? (
          <p className="rounded-lg border border-line p-3 text-center text-sm text-muted">Connect a wallet to continue.</p>
        ) : (
          <button className="btn-primary w-full py-3" disabled={!!problem || busy} onClick={submit}>
            {busy ? "Working…" : problem && value > 0n ? problem : tab === "deposit" ? (useBonus ? "Deposit & lock" : "Deposit") : "Request withdrawal"}
          </button>
        )}
      </div>
    </div>
  );
}

function Requests({ lp, proto }: { lp?: LPState; proto?: ProtocolState }) {
  const { run, busy, walletClient } = useTx();
  const reqs = lp?.requests.filter((r) => r.status === "PENDING" || r.filledShares > 0n) ?? [];
  if (!lp || reqs.length === 0) return null;
  const now = Date.now() / 1000;

  const write = (functionName: "cancelRedeemRequest" | "processRedemptions", arg: bigint) =>
    walletClient!.writeContract({
      address: CONTRACTS.lpVault,
      abi: vaultAbi,
      functionName,
      args: [arg],
      account: walletClient!.account!,
      chain: arc,
    });

  return (
    <div className="card">
      <div className="border-b border-line px-5 py-3">
        <h2 className="text-lg">Withdrawal requests</h2>
      </div>
      <div className="divide-y divide-line/60">
        {reqs.map((r) => {
          const total = r.requestedAt && r.maturesAt > r.requestedAt ? r.maturesAt - r.requestedAt : 1;
          const progress = Math.min(1, Math.max(0, (now - r.requestedAt) / total));
          const matured = now >= r.maturesAt;
          const pending = r.status === "PENDING";
          return (
            <div key={r.id.toString()} className="flex flex-wrap items-center justify-between gap-4 px-5 py-4">
              <div className="min-w-[220px] flex-1">
                <div className="flex items-center gap-2 text-sm">
                  <span className="num font-medium">{usd(r.assetsAtRequest)}</span>
                  <span className={`pill ${pending ? "border border-accent/20 bg-accent/5 text-accent" : "border border-up/30 bg-up/5 text-up"}`}>
                    {pending ? (matured ? "In queue for payout" : "Waiting") : r.status === "FULFILLED" ? "Paid out" : r.status.toLowerCase()}
                  </span>
                  {r.stressedAtRequest && <span className="pill border border-warn/30 bg-warn/5 text-warn">busy-exit</span>}
                </div>
                <div className="mt-2 h-1.5 overflow-hidden rounded bg-line">
                  <div className="h-full bg-accent" style={{ width: `${progress * 100}%` }} />
                </div>
                <div className="mt-1 text-xs text-muted">
                  Requested {dateTime(r.requestedAt)} · {matured ? "matured" : `matures in ${timeLeft(r.maturesAt)}`}
                </div>
              </div>
              {pending && (
                <div className="flex gap-2">
                  {matured && (
                    <button
                      className="btn-secondary text-xs"
                      disabled={busy || proto?.vault.fulfilmentBudget === 0n}
                      title={proto?.vault.fulfilmentBudget === 0n ? "Not enough free liquidity right now" : "Pay out matured requests in queue order"}
                      onClick={() => run("Queue processed", [{ title: "Process withdrawal queue", send: () => write("processRedemptions", 20n) }])}
                    >
                      Process queue
                    </button>
                  )}
                  <button
                    className="btn-ghost text-xs"
                    disabled={busy}
                    onClick={() => run("Request cancelled", [{ title: "Cancel withdrawal", send: () => write("cancelRedeemRequest", r.id) }])}
                  >
                    Cancel
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>
      {proto && proto.vault.fulfilmentBudget === 0n && reqs.some((r) => r.status === "PENDING" && now >= r.maturesAt) && (
        <div className="border-t border-line px-5 py-3 text-xs text-muted">
          Matured requests are paid once enough cash is free beyond what open trades could lose in a crash.
        </div>
      )}
    </div>
  );
}

function Tickets({ lp }: { lp?: LPState }) {
  const { run, busy, walletClient } = useTx();
  const tickets = lp?.tickets.filter((t) => t.active) ?? [];
  if (tickets.length === 0) return null;
  const now = Date.now() / 1000;
  return (
    <div className="card">
      <div className="border-b border-line px-5 py-3">
        <h2 className="text-lg">Bonus deposits</h2>
      </div>
      <div className="divide-y divide-line/60">
        {tickets.map((t) => {
          const matured = now >= t.maturesAt;
          return (
            <div key={t.id.toString()} className="flex flex-wrap items-center justify-between gap-4 px-5 py-4">
              <div>
                <div className="num font-medium">{usd(t.weight)} locked</div>
                <div className="text-xs text-muted">
                  Bonus so far <span className="num text-up">{usd(t.pendingBonus)}</span> · {matured ? "unlocked" : `unlocks in ${timeLeft(t.maturesAt)}`}
                </div>
              </div>
              <button
                className={matured ? "btn-up text-xs" : "btn-ghost text-xs"}
                disabled={busy}
                onClick={() =>
                  run(matured ? "Bonus claimed" : "Unlocked early", [
                    {
                      title: matured ? "Claim deposit + bonus" : "Unlock early (forfeit bonus)",
                      send: () =>
                        walletClient!.writeContract({
                          address: CONTRACTS.lpVault,
                          abi: vaultAbi,
                          functionName: matured ? "claimTicket" : "breakTicket",
                          args: [t.id],
                          account: walletClient!.account!,
                          chain: arc,
                        }),
                    },
                  ])
                }
              >
                {matured ? "Claim" : "Unlock early"}
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function HowItWorks({ proto }: { proto?: ProtocolState }) {
  const t5 = proto?.pm.tiers[5];
  const t10 = proto?.pm.tiers[10];
  return (
    <div className="card p-4 text-sm">
      <h3 className="text-lg">How LPs earn</h3>
      <div className="mt-3 rounded-lg bg-panel2 p-3">
        <Row label="Share of 5x profits" value={t5 ? pct(t5.lpProfitBps, 0) : "8%"} tone="up" />
        <Row label="Share of 10x profits" value={t10 ? pct(t10.lpProfitBps, 0) : "12%"} tone="up" />
        <Row label="Weekly fees (after week 1)" value={`80% of ${proto ? pct(proto.pm.rolloverAprBps, 0) : "8%"} APR`} tone="up" />
        <Row label="Idle cash" value="Lending yield" tone="up" />
      </div>
      <h3 className="mt-4 text-lg">What protects you</h3>
      <ul className="mt-2 list-disc space-y-1 pl-5 text-muted">
        <li>Trades are liquidated before they can lose more than the trader's margin.</li>
        <li>Liquidation penalties and fees fund an insurance pool that covers bad debt first.</li>
        <li>Each asset has an open-interest cap, and at most 85% of the vault can be lent out.</li>
      </ul>
    </div>
  );
}
