// End-to-end smoke test of the trading UI against the local Arc mainnet fork.
//
//   1. npm run fork                      (repo root; leaves anvil + keeper running)
//   2. cd frontend && npm run dev        (uses .env.development.local written by step 1)
//   3. node e2e/fork-smoke.mjs           (needs `playwright` with Chromium: npm i -D playwright && npx playwright install chromium)
//
// A tiny EIP-1193 provider is injected as `window.ethereum`. It forwards every request to anvil, which signs for
// its unlocked test accounts, so the real wagmi "Browser wallet" flow runs without an extension. Screenshots go
// to e2e/screenshots/.
import { execSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const APP = process.env.APP_URL || "http://localhost:3000";
const RPC = process.env.FORK_RPC || "http://127.0.0.1:8545";
const TRADER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // anvil #2
const shots = path.join(here, "screenshots");
mkdirSync(shots, { recursive: true });

const sh = (cmd) => execSync(cmd, { cwd: root, stdio: ["ignore", "pipe", "inherit"] }).toString().trim();
const rpc = async (method, params = []) => {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
};
const usdcOf = async (a) =>
  Number(BigInt(await rpc("eth_call", [{ to: "0x3600000000000000000000000000000000000000", data: "0x70a08231" + a.slice(2).toLowerCase().padStart(64, "0") }, "latest"]))) / 1e6;

function injectWallet({ rpcUrl, account }) {
  const listeners = {};
  window.ethereum = {
    isMetaMask: false,
    on: (e, f) => ((listeners[e] ||= []).push(f), window.ethereum),
    removeListener: (e, f) => ((listeners[e] = (listeners[e] || []).filter((x) => x !== f)), window.ethereum),
    async request({ method, params }) {
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [account];
      if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
      if (method === "wallet_requestPermissions" || method === "wallet_getPermissions") return [{ parentCapability: "eth_accounts" }];
      const r = await fetch(rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }) });
      const j = await r.json();
      if (j.error) throw Object.assign(new Error(j.error.message), { code: j.error.code, data: j.error.data });
      return j.result;
    },
  };
}

const step = (m) => console.log(`\n▶ ${m}`);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 });
page.on("pageerror", (e) => console.log("  [pageerror]", e.message));
await page.addInitScript(injectWallet, { rpcUrl: RPC, account: TRADER });

async function toast(text, timeout = 60_000) {
  await page.getByText(text).first().waitFor({ timeout });
}

async function openPosition(symbol, margin, tier) {
  await page.getByRole("button", { name: `${symbol}/USD` }).click();
  await page.locator("input").first().fill(String(margin));
  await page.getByRole("button", { name: `${tier}x`, exact: true }).click();
  const buy = page.getByRole("button", { name: `Buy ${symbol} with ${tier}x` });
  await buy.waitFor();
  await page.waitForFunction((n) => {
    const b = [...document.querySelectorAll("button")].find((x) => x.textContent === n);
    return b && !b.disabled;
  }, `Buy ${symbol} with ${tier}x`, { timeout: 30_000 });
  await buy.click();
  await toast(`${tier}x ${symbol} position opened`);
}

try {
  step("Trade page loads with TWAP prices from the fork");
  await page.goto(`${APP}/app/trade`);
  await page.getByText("10-min TWAP").first().waitFor();
  await page.waitForFunction(() => /\$2,?\d{3}/.test(document.body.innerText), null, { timeout: 30_000 });

  step("Connect the injected wallet");
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await page.getByRole("button", { name: "Browser wallet" }).click();
  await page.getByText(/0x3C44/i).first().waitFor({ timeout: 20_000 });
  await page.screenshot({ path: path.join(shots, "1-connected.png") });

  // The MVP vault holds $100 and lends at most 85% of it, so a $10 x 10x trade ($90 borrowed) is refused by the
  // order panel; $8 x 10x borrows $72.
  step("Open ETH 10x with $8");
  const before = await usdcOf(TRADER);
  await openPosition("ETH", 8, 10);
  await page.getByRole("button", { name: "Close", exact: true }).first().waitFor({ timeout: 30_000 });
  console.log(`  trader USDC ${before} -> ${await usdcOf(TRADER)}`);
  await page.screenshot({ path: path.join(shots, "2-eth-open.png") });

  step("ETH pool +5%, TWAP catches up, close in profit");
  console.log("  " + sh("bash script/fork/move-price.sh ETH 5").split("\n")[0]);
  sh("bash script/fork/warp.sh 610");
  await page.waitForTimeout(6_000);
  await page.screenshot({ path: path.join(shots, "3-eth-rally.png") });
  const preClose = await usdcOf(TRADER);
  await page.getByRole("button", { name: "Close", exact: true }).first().click();
  await page.getByRole("button", { name: "Close position" }).click();
  await toast("ETH position closed");
  const payout = (await usdcOf(TRADER)) - preClose;
  console.log(`  payout $${payout.toFixed(4)} on $8 margin`);
  // 10x on +5% less pool fees, minus the 15% LP/treasury profit share: roughly $8 + $3.
  if (!(payout > 9.5 && payout < 13)) throw new Error(`unexpected payout ${payout}`);

  step("Open ETH 10x again, crash the pool 9%, keeper liquidates");
  await openPosition("ETH", 8, 10);
  console.log("  " + sh("bash script/fork/move-price.sh ETH -9").split("\n")[0]);
  sh("bash script/fork/warp.sh 610");
  await page.getByText("No open positions").first().waitFor({ timeout: 90_000 }).catch(async () => {
    await page.screenshot({ path: path.join(shots, "x-liquidation-timeout.png") });
    throw new Error("position was not liquidated by the keeper");
  });
  await page.getByRole("button", { name: /History/ }).click();
  await page.waitForTimeout(1_000);
  await page.screenshot({ path: path.join(shots, "4-liquidated-history.png") });

  step("Open BTC 5x with $10");
  await page.getByRole("button", { name: /^Open/ }).first().click().catch(() => {});
  await openPosition("BTC", 10, 5);
  await page.waitForTimeout(3_000);
  await page.screenshot({ path: path.join(shots, "5-btc-open.png") });

  console.log("\n✔ fork UI smoke test passed");
} catch (e) {
  await page.screenshot({ path: path.join(shots, "x-failure.png") }).catch(() => {});
  console.error("\n✘", e.message);
  process.exitCode = 1;
} finally {
  await browser.close();
}
