import { defineChain, getAddress, isAddress, zeroAddress, type Address, type Hex } from "viem";

export const APP_NAME = "Fulcrum";

export type Network = "mainnet" | "testnet";
export const NETWORK: Network = process.env.NEXT_PUBLIC_NETWORK === "testnet" ? "testnet" : "mainnet";

const DEFAULTS = {
  mainnet: { id: 5042, name: "Arc", rpc: "https://rpc.arc.network", explorer: "https://arcscan.app" },
  testnet: {
    id: 5042002,
    name: "Arc Testnet",
    rpc: "https://rpc.testnet.arc.network",
    explorer: "https://testnet.arcscan.app",
  },
} as const;

const d = DEFAULTS[NETWORK];
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || d.rpc;
export const EXPLORER_URL = (process.env.NEXT_PUBLIC_EXPLORER_URL || d.explorer).replace(/\/$/, "");

/** USDC is Arc's gas token: 18 decimals natively, 6 decimals through the ERC-20 precompile at 0x3600..00. */
export const arc = defineChain({
  id: d.id as number,
  name: d.name,
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "Arcscan", url: EXPLORER_URL } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  testnet: NETWORK === "testnet",
});

function addr(v: string | undefined): Address {
  return v && isAddress(v) ? getAddress(v) : zeroAddress;
}

export const USDC: Address = "0x3600000000000000000000000000000000000000";
export const USDC_DECIMALS = 6;

export const CONTRACTS = {
  positionManager: addr(process.env.NEXT_PUBLIC_POSITION_MANAGER),
  lpVault: addr(process.env.NEXT_PUBLIC_LP_VAULT),
  oracle: addr(process.env.NEXT_PUBLIC_ORACLE),
  insurance: addr(process.env.NEXT_PUBLIC_INSURANCE),
  swapRouter: addr(process.env.NEXT_PUBLIC_SWAP_ROUTER),
  quoter: addr(process.env.NEXT_PUBLIC_QUOTER),
};

export const SWAP_ROUTER_KIND: "router02" | "router" =
  process.env.NEXT_PUBLIC_SWAP_ROUTER_KIND === "router" ? "router" : "router02";

export const PROTOCOL_CONFIGURED =
  CONTRACTS.positionManager !== zeroAddress && CONTRACTS.lpVault !== zeroAddress && CONTRACTS.oracle !== zeroAddress;
export const TRADING_CONFIGURED = PROTOCOL_CONFIGURED && CONTRACTS.swapRouter !== zeroAddress;

/** Hermes base URL used by the browser. Defaults to this app's server-side proxy, which holds PYTH_API_KEY. */
export const HERMES_URL = (process.env.NEXT_PUBLIC_HERMES_URL || "/api/pyth").replace(/\/$/, "");
export const WALLETCONNECT_PROJECT_ID = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

export type Asset = {
  symbol: string;
  name: string;
  address: Address;
  decimals: number;
  pythId: Hex;
  fee: number;
  chartSymbol: string;
};

const DEFAULT_ASSETS: Asset[] = [
  {
    symbol: "BTC",
    name: "Bitcoin",
    address: zeroAddress,
    decimals: 8,
    pythId: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
    fee: 3000,
    chartSymbol: "Crypto.BTC/USD",
  },
  {
    symbol: "ETH",
    name: "Ethereum",
    address: zeroAddress,
    decimals: 18,
    pythId: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
    fee: 3000,
    chartSymbol: "Crypto.ETH/USD",
  },
];

function parseAssets(): Asset[] {
  const raw = process.env.NEXT_PUBLIC_ASSETS;
  if (!raw) return DEFAULT_ASSETS;
  try {
    const list = JSON.parse(raw) as Array<Partial<Asset>>;
    return list.map((a) => ({
      symbol: String(a.symbol),
      name: String(a.name ?? a.symbol),
      address: addr(a.address),
      decimals: Number(a.decimals ?? 18),
      pythId: (a.pythId?.startsWith("0x") ? a.pythId : `0x${a.pythId}`) as Hex,
      fee: Number(a.fee ?? 3000),
      chartSymbol: String(a.chartSymbol ?? `Crypto.${a.symbol}/USD`),
    }));
  } catch {
    console.error("NEXT_PUBLIC_ASSETS is not valid JSON; using defaults");
    return DEFAULT_ASSETS;
  }
}

export const ASSETS: Asset[] = parseAssets();
export const assetByAddress = (a: string) => ASSETS.find((x) => x.address.toLowerCase() === a.toLowerCase());

export const TIERS = [5, 10] as const;
export type Tier = (typeof TIERS)[number];

export const txUrl = (hash: string) => `${EXPLORER_URL}/tx/${hash}`;
export const addressUrl = (a: string) => `${EXPLORER_URL}/address/${a}`;
