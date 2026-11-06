/**
 * Keeper for the protocol:
 * Liquidates underwater positions, closes expired epochs, executes take-profit / stop-loss orders and pays
 * out matured LP withdrawals.
 *
 *   KEEPER_PRIVATE_KEY=0x... npm run keeper
 *
 * Reads the same NEXT_PUBLIC_* configuration as the app (.env.local / .env). It earns the keeper
 * bounty on liquidations, expiries and triggers.
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

const INTERVAL_MS = Number(process.env.KEEPER_INTERVAL_MS || 5000);

async function main() {
  const { createPublicClient, createWalletClient, http, formatUnits } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { pmAbi, vaultAbi } = await import("../src/abi");
  const { arc, ASSETS, CONTRACTS, RPC_URL, assetByAddress, PROTOCOL_CONFIGURED } = await import("../src/lib/config");
  const { readOraclePrices, priceOf } = await import("../src/lib/oracle");
  const { valueInUsdc } = await import("../src/lib/trade");

  const pk = process.env.KEEPER_PRIVATE_KEY as `0x${string}` | undefined;
  if (!pk) throw new Error("KEEPER_PRIVATE_KEY is not set");
  if (!PROTOCOL_CONFIGURED) throw new Error("Contract addresses are not configured (NEXT_PUBLIC_*)");

  const account = privateKeyToAccount(pk);
  const pc = createPublicClient({ chain: arc, transport: http(RPC_URL) });
  const wc = createWalletClient({ chain: arc, transport: http(RPC_URL), account });
  const pm = { address: CONTRACTS.positionManager, abi: pmAbi } as const;
  const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);
  const short = (e: unknown) => (e instanceof Error ? e.message.split("\n")[0] : String(e));
  log(`keeper ${account.address} on ${arc.name} (${arc.id}) via ${RPC_URL}`);

  // ------------------------------------------------------------------ Positions and LP queue
  const open = new Set<bigint>();
  let scanned = 0n;
  let lastQueueCheck = 0;

  async function positions() {
    const count = await pc.readContract({ ...pm, functionName: "positionCount" });
    for (let id = scanned + 1n; id <= count; id++) open.add(id);
    scanned = count;
    if (open.size === 0) return;

    const ids = [...open];
    const all = await pc.multicall({
      contracts: ids.map((id) => ({ ...pm, functionName: "getPosition", args: [id] }) as const),
      allowFailure: false,
    });
    const live = ids
      .map((id, i) => ({ id, p: all[i] }))
      .filter(({ id, p }) => {
        if (p.status !== 1) open.delete(id);
        return p.status === 1;
      });
    if (live.length === 0) return;

    const [thresholds, prices] = await Promise.all([
      pc.multicall({
        contracts: live.map(({ id }) => ({ ...pm, functionName: "liquidationThreshold", args: [id] }) as const),
        allowFailure: false,
      }),
      readOraclePrices(pc),
    ]);
    const now = Number((await pc.getBlock()).timestamp);

    for (const [i, { id, p }] of live.entries()) {
      const asset = assetByAddress(p.spotToken);
      const px = asset && priceOf(prices, asset.address);
      if (!asset || !px?.twap18) continue; // oracle warming up or stale: nothing can execute anyway
      const mark = valueInUsdc(p.spotAmount, px.twap18, asset.decimals);
      const liquidatable = mark <= (thresholds[i] as bigint);
      const expired = now >= Number(p.epochEndTime);
      const triggered =
        (p.stopLossPrice > 0n && px.twap18 <= p.stopLossPrice) ||
        (p.takeProfitPrice > 0n && px.twap18 >= p.takeProfitPrice) ||
        (p.trailingStopPrice > 0n && px.twap18 <= p.trailingStopPrice);

      let fn: "liquidate" | "processEpoch" | "executeTrigger" | null = null;
      if (liquidatable) fn = "liquidate";
      else if (expired && !p.autoRollover) fn = "processEpoch"; // healthy auto-rolls accrue lazily
      else if (triggered) fn = "executeTrigger";
      if (!fn) continue;

      try {
        // minAmountOut = 0: the contract still enforces its floor (TWAP mark minus the allowed slippage). If the
        // pool is below that floor the simulation reverts and we retry on the next tick.
        const { request } = await pc.simulateContract({ ...pm, functionName: fn, args: [id, 0n], account });
        const hash = await wc.writeContract(request);
        const r = await pc.waitForTransactionReceipt({ hash });
        log(`${fn} #${id} (${asset.symbol}, mark $${formatUnits(mark, 6)}): ${r.status} ${hash}`);
      } catch (e) {
        log(`${fn} #${id} not executable yet:`, short(e));
      }
    }
  }

  async function lpQueue() {
    if (Date.now() - lastQueueCheck < 10 * 60_000) return;
    lastQueueCheck = Date.now();
    const v = { address: CONTRACTS.lpVault, abi: vaultAbi } as const;
    const [head, len, budget] = await pc.multicall({
      contracts: [
        { ...v, functionName: "queueHead" },
        { ...v, functionName: "queueLength" },
        { ...v, functionName: "fulfilmentBudget" },
      ],
      allowFailure: false,
    });
    if (head < len && budget > 0n) {
      try {
        const { request } = await pc.simulateContract({ ...v, functionName: "processRedemptions", args: [20n], account });
        const hash = await wc.writeContract(request);
        log(`processRedemptions: ${hash}`);
      } catch (e) {
        log("processRedemptions skipped:", short(e));
      }
    }
  }

  for (;;) {
    for (const job of [positions, lpQueue]) {
      try {
        await job();
      } catch (e) {
        log(`${job.name} error:`, short(e));
      }
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
