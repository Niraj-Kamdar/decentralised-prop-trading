import { erc20Abi } from "viem";
import { insuranceReserveAbi } from "./InsuranceReserve";
import { lPVaultAbi } from "./LPVault";
import { positionManagerAbi } from "./PositionManager";
import { traderProxyAbi } from "./TraderProxy";
import { chainlinkOracleAbi } from "./ChainlinkOracle";
import { v4SwapRouterAbi } from "./V4SwapRouter";

const errorsOf = <T extends readonly { type: string }[]>(abi: T) =>
  abi.filter((x): x is Extract<T[number], { type: "error" }> => x.type === "error");

/**
 * Calls into PositionManager can revert inside the oracle, vault, proxy, router or USDC. Appending their error
 * fragments lets viem decode those nested reverts into readable names.
 */
const nestedErrors = [
  ...errorsOf(chainlinkOracleAbi),
  ...errorsOf(lPVaultAbi),
  ...errorsOf(traderProxyAbi),
  ...errorsOf(v4SwapRouterAbi),
  ...errorsOf(insuranceReserveAbi),
];

export const pmAbi = [
  ...positionManagerAbi,
  ...nestedErrors.filter(
    (e, i) =>
      !positionManagerAbi.some((p) => p.type === "error" && p.name === e.name) &&
      nestedErrors.findIndex((x) => x.name === e.name) === i,
  ),
] as const;
export const vaultAbi = lPVaultAbi;
export const oracleAbi = chainlinkOracleAbi;
export const insuranceAbi = insuranceReserveAbi;
export { erc20Abi };
