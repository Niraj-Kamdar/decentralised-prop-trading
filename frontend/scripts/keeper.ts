/**
 * Minimal keeper for the MVP. Without a keeper, nobody liquidates underwater positions, closes expired
 * epochs or executes take-profit / stop-loss orders, and LP principal is at risk.
 *
 *   KEEPER_PRIVATE_KEY=0x... PYTH_API_KEY=... npm run keeper
 *
 * Reads the same NEXT_PUBLIC_* configuration as the app (.env.local / .env). The keeper wallet needs a little
 * USDC for gas and Pyth fees; it earns the keeper bounty on liquidations, expiries and triggers.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

// Load .env.local / .env the way Next does, before the app config module reads process.env.
for (const f of [".env.local", ".env"]) {
  try {
    for (const line of readFileSync(path.join(process.cwd(), f), "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {
    /* file absent */
  }
}
// The browser default (/api/pyth) is a relative proxy URL; the keeper talks to Hermes directly.
process.env.NEXT_PUBLIC_HERMES_URL ||= process.env.PYTH_HERMES_URL || "https://hermes.pyth.network";

const INTERVAL_MS = Number(process.env.KEEPER_INTERVAL_MS || 5000);

async function main() {
  const { createPublicClient, createWalletClient, http, maxUint256, zeroAddress, formatUnits } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { pmAbi, vaultAbi, erc20Abi } = await import("../src/abi");
  const { arc, ASSETS, CONTRACTS, RPC_URL, USDC, assetByAddress, PROTOCOL_CONFIGURED } = await import("../src/lib/config");
  const { fetchPriceUpdate, priceFor } = await import("../src/lib/pyth");
  const { prepareExit, valueInUsdc } = await import("../src/lib/trade");

  const pk = process.env.KEEPER_PRIVATE_KEY as `0x${string}` | undefined;
  if (!pk) throw new Error("KEEPER_PRIVATE_KEY is not set");
  if (!PROTOCOL_CONFIGURED) throw new Error("Contract addresses are not configured (NEXT_PUBLIC_*)");

  const account = privateKeyToAccount(pk);
  const pc = createPublicClient({ chain: arc, transport: http(RPC_URL) });
  const wc = createWalletClient({ chain: arc, transport: http(RPC_URL), account });
  const pm = { address: CONTRACTS.positionManager, abi: pmAbi } as const;
  const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);
  log(`keeper ${account.address} on ${arc.name} (${arc.id})`);

  // PositionManager pulls Pyth fees from the caller in ERC-20 USDC.
  const allowance = await pc.readContract({ address: USDC, abi: erc20Abi, functionName: "allowance", args: [account.address, CONTRACTS.positionManager] });
  if (allowance < 10n ** 12n) {
    const hash = await wc.writeContract({ address: USDC, abi: erc20Abi, functionName: "approve", args: [CONTRACTS.positionManager, maxUint256] });
    await pc.waitForTransactionReceipt({ hash });
    log("approved USDC for Pyth fees");
  }

  const open = new Set<bigint>();
  let scanned = 0n;
  let lastQueueCheck = 0;

  async function tick() {
    // 1. Discover new positions.
    const count = await pc.readContract({ ...pm, functionName: "positionCount" });
    for (let id = scanned + 1n; id <= count; id++) open.add(id);
    scanned = count;
    if (open.size === 0) return;

    const ids = [...open];
    const positions = await pc.multicall({ contracts: ids.map((id) => ({ ...pm, functionName: "getPosition", args: [id] }) as const), allowFailure: false });
    const live = ids.map((id, i) => ({ id, p: positions[i] })).filter(({ id, p }) => {
      if (p.status !== 1) open.delete(id);
      return p.status === 1;
    });
    if (live.length === 0) return;

    const [thresholds, liqSlip, exitSlip] = await Promise.all([
      pc.multicall({ contracts: live.map(({ id }) => ({ ...pm, functionName: "liquidationThreshold", args: [id] }) as const), allowFailure: false }),
      pc.readContract({ ...pm, functionName: "maxLiqSlippageBps" }),
      pc.readContract({ ...pm, functionName: "maxExitSlippageBps" }),
    ]);
    const { prices } = await fetchPriceUpdate(ASSETS.filter((a) => a.address !== zeroAddress).map((a) => a.pythId));
    const now = Math.floor(Date.now() / 1000);

    // 2. Decide what each position needs.
    for (const [i, { id, p }] of live.entries()) {
      const asset = assetByAddress(p.spotToken);
      const px = asset && priceFor(prices, asset.pythId);
      if (!asset || !px) continue;
      const mark = valueInUsdc(p.spotAmount, px.price18, asset.decimals);
      const liquidatable = mark <= (thresholds[i] as bigint);
      const expired = now >= Number(p.epochEndTime);
      const triggered =
        (p.stopLossPrice > 0n && px.price18 <= p.stopLossPrice) ||
        (p.takeProfitPrice > 0n && px.price18 >= p.takeProfitPrice) ||
        (p.trailingStopPrice > 0n && px.price18 <= p.trailingStopPrice);

      let fn: "liquidate" | "processEpoch" | "executeTrigger" | null = null;
      if (liquidatable) fn = "liquidate";
      else if (expired && !p.autoRollover) fn = "processEpoch"; // healthy auto-rolls accrue lazily
      else if (triggered) fn = "executeTrigger";
      if (!fn) continue;

      try {
        const prep = await prepareExit(pc, {
          asset,
          proxy: p.proxy,
          spotAmount: p.spotAmount,
          slippageBps: Number(liquidatable ? liqSlip : exitSlip),
          maxSlippageBps: Number(liquidatable ? liqSlip : exitSlip),
        });
        const { request } = await pc.simulateContract({ ...pm, functionName: fn, args: [id, prep.swap, prep.priceUpdateData], account });
        const hash = await wc.writeContract(request);
        const r = await pc.waitForTransactionReceipt({ hash });
        log(`${fn} #${id} (${asset.symbol}, mark $${formatUnits(mark, 6)}): ${r.status} ${hash}`);
      } catch (e) {
        log(`${fn} #${id} failed:`, e instanceof Error ? e.message.split("\n")[0] : e);
      }
    }

    // 3. Every 10 minutes, pay out matured LP withdrawal requests if liquidity allows.
    if (Date.now() - lastQueueCheck > 10 * 60_000) {
      lastQueueCheck = Date.now();
      const v = { address: CONTRACTS.lpVault, abi: vaultAbi } as const;
      const [head, len, budget] = await pc.multicall({
        contracts: [{ ...v, functionName: "queueHead" }, { ...v, functionName: "queueLength" }, { ...v, functionName: "fulfilmentBudget" }],
        allowFailure: false,
      });
      if (head < len && budget > 0n) {
        try {
          const { request } = await pc.simulateContract({ ...v, functionName: "processRedemptions", args: [20n], account });
          const hash = await wc.writeContract(request);
          log(`processRedemptions: ${hash}`);
        } catch (e) {
          log("processRedemptions skipped:", e instanceof Error ? e.message.split("\n")[0] : e);
        }
      }
    }
  }

  for (;;) {
    try {
      await tick();
    } catch (e) {
      log("tick error:", e instanceof Error ? e.message.split("\n")[0] : e);
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
