import { defineChain, getAddress, isAddress, zeroAddress, type Address } from "viem";

export const APP_NAME = "Fulcrum";

/**
 * - `mainnet`: Arc (5042).
 * - `fork`: a local anvil fork of Arc mainnet (also chain 5042) started by `npm run fork` in the repo root.
 * - `testnet`: Arc testnet (5042002). The Uniswap pools this app trades on exist on mainnet only.
 * - `base`: Base mainnet (8453).
 */
export type Network = "mainnet" | "fork" | "testnet" | "base";
const envNetwork = process.env.NEXT_PUBLIC_NETWORK;
export const NETWORK: Network =
  envNetwork === "base"
    ? "base"
    : envNetwork === "testnet"
    ? "testnet"
    : envNetwork === "fork"
    ? "fork"
    : "mainnet";

const DEFAULTS = {
  mainnet: { id: 5042, name: "Arc", rpc: "https://rpc.mainnet.arc.io", explorer: "https://explorer.arc.io" },
  fork: { id: 5042, name: "Arc (local fork)", rpc: "http://127.0.0.1:8545", explorer: "https://explorer.arc.io" },
  testnet: { id: 5042002, name: "Arc Testnet", rpc: "https://rpc.testnet.arc.io", explorer: "https://explorer.testnet.arc.io" },
  base: { id: 8453, name: "Base", rpc: "https://mainnet.base.org", explorer: "https://basescan.org" },
} as const;

const d = DEFAULTS[NETWORK];
export const NETWORK_LABEL = {
  mainnet: "Arc mainnet",
  fork: "Local Arc fork",
  testnet: "Arc testnet",
  base: "Base",
}[NETWORK];
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || d.rpc;
export const EXPLORER_URL = (process.env.NEXT_PUBLIC_EXPLORER_URL || d.explorer).replace(/\/$/, "");
/** Transactions on a local fork do not exist on the public explorer. */
export const HAS_EXPLORER = NETWORK !== "fork";

const nativeCurrency =
  NETWORK === "base"
    ? { name: "Ether", symbol: "ETH", decimals: 18 }
    : { name: "USDC", symbol: "USDC", decimals: 18 };

export const arc = defineChain({
  id: d.id as number,
  name: d.name,
  nativeCurrency,
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: `${d.name} Explorer`, url: EXPLORER_URL } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  testnet: NETWORK === "testnet",
});

function addr(v: string | undefined, fallback: Address = zeroAddress): Address {
  return v && isAddress(v) ? getAddress(v) : fallback;
}

const USDC_BY_NETWORK: Record<Network, Address> = {
  mainnet: "0x3600000000000000000000000000000000000000",
  fork: "0x3600000000000000000000000000000000000000",
  testnet: "0x3600000000000000000000000000000000000000",
  base: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
};
export const USDC: Address = USDC_BY_NETWORK[NETWORK];
export const USDC_DECIMALS = 6;

/** Uniswap v4 Quoter per network. */
const V4_QUOTER_BY_NETWORK: Record<Network, Address> = {
  mainnet: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
  fork: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
  testnet: zeroAddress,
  base: "0x0d5e0f971ed27fbff6c2837bf31316121532048d",
};
const V4_QUOTER: Address = V4_QUOTER_BY_NETWORK[NETWORK];

export const CONTRACTS = {
  positionManager: addr(process.env.NEXT_PUBLIC_POSITION_MANAGER),
  lpVault: addr(process.env.NEXT_PUBLIC_LP_VAULT),
  oracle: addr(process.env.NEXT_PUBLIC_ORACLE),
  insurance: addr(process.env.NEXT_PUBLIC_INSURANCE),
  quoter: addr(process.env.NEXT_PUBLIC_V4_QUOTER, V4_QUOTER),
};

export const PROTOCOL_CONFIGURED =
  CONTRACTS.positionManager !== zeroAddress && CONTRACTS.lpVault !== zeroAddress && CONTRACTS.oracle !== zeroAddress;
export const TRADING_CONFIGURED = PROTOCOL_CONFIGURED;

export const WALLETCONNECT_PROJECT_ID = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "";

/** Spot markets: ETH and BTC long only. Prices come from the protocol's Uniswap v4 TWAP oracle. */
export type Asset = {
  symbol: string;
  name: string;
  address: Address;
  decimals: number;
};

/** Spot tokens. The protocol trades them on their Uniswap v4 USDC pools. */
export const ASSETS: Asset[] = [
  {
    symbol: "ETH",
    name: "Ethereum",
    address: addr(
      process.env.NEXT_PUBLIC_WETH,
      NETWORK === "base" ? "0x4200000000000000000000000000000000000006" : "0x128cC466B61f542da60c70e3aA11c10e19B84EDB"
    ),
    decimals: 18,
  },
  {
    symbol: "BTC",
    name: "Bitcoin",
    address: addr(
      process.env.NEXT_PUBLIC_CIRBTC,
      NETWORK === "base" ? "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf" : "0x171A4217b86A807A64eB94757Db6849fb4bDbAA0"
    ),
    decimals: 8,
  },
];

export const assetByAddress = (a: string) => ASSETS.find((x) => x.address.toLowerCase() === a.toLowerCase());

export const TIERS = [5, 10] as const;
export type Tier = (typeof TIERS)[number];

export const txUrl = (hash: string) => `${EXPLORER_URL}/tx/${hash}`;
export const addressUrl = (a: string) => `${EXPLORER_URL}/address/${a}`;
