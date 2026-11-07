import { createConfig, http } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { APP_NAME, chain, RPC_URL, WALLETCONNECT_PROJECT_ID } from "./config";

export const wagmiConfig = createConfig({
  chains: [chain],
  ssr: true,
  connectors: [
    injected({ shimDisconnect: true }),
    ...(WALLETCONNECT_PROJECT_ID
      ? [walletConnect({ projectId: WALLETCONNECT_PROJECT_ID, showQrModal: true, metadata: { name: APP_NAME, description: "Leveraged spot trading on Base", url: "https://localhost", icons: [] } })]
      : []),
  ],
  transports: { [chain.id]: http(RPC_URL, { batch: true }) },
  batch: { multicall: true },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
