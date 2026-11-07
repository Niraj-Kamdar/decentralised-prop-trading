import { defineChain, getAddress, isAddress, zeroAddress, type Address } from "viem";

export const APP_NAME = "Fulcrum";
export const TAGLINE = "Capital for traders. Returns for investors.";
export const SITE_DESCRIPTION =
  "Decentralised prop trading on-chain. Traders get up to 10x buying power on crypto with losses capped at their deposit. Investors fund the vault and earn a share of every winning trade, like copy trading without picking a trader.";
/** Canonical origin for metadata, sitemap and OG URLs. */
export const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL || "https://fulcrum-trade.vercel.app").replace(/\/$/, "");

/** Base mainnet (8453). NEXT_PUBLIC_RPC_URL / NEXT_PUBLIC_EXPLORER_URL override the defaults. */
export const NETWORK_LABEL = "Base";
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || "https://mainnet.base.org";
export const EXPLORER_URL = (process.env.NEXT_PUBLIC_EXPLORER_URL || "https://basescan.org").replace(/\/$/, "");

export const chain = defineChain({
  id: 8453,
  name: "Base",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "Basescan", url: EXPLORER_URL } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

function addr(v: string | undefined, fallback: Address = zeroAddress): Address {
  return v && isAddress(v) ? getAddress(v) : fallback;
}

export const USDC: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
export const USDC_DECIMALS = 6;

/** Uniswap v4 Quoter on Base. */
const V4_QUOTER: Address = "0x0d5e0f971ed27fbff6c2837bf31316121532048d";

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

/** Spot markets: ETH and BTC long only. Marks come from Chainlink; trades fill on Uniswap v4. */
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
    address: addr(process.env.NEXT_PUBLIC_WETH, "0x4200000000000000000000000000000000000006"),
    decimals: 18,
  },
  {
    symbol: "BTC",
    name: "Bitcoin",
    address: addr(process.env.NEXT_PUBLIC_CBBTC, "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf"),
    decimals: 8,
  },
];

export const assetByAddress = (a: string) => ASSETS.find((x) => x.address.toLowerCase() === a.toLowerCase());

export const TIERS = [5, 10] as const;
export type Tier = (typeof TIERS)[number];

export const txUrl = (hash: string) => `${EXPLORER_URL}/tx/${hash}`;
export const addressUrl = (a: string) => `${EXPLORER_URL}/address/${a}`;
