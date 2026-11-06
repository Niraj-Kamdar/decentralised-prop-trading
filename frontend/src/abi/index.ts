import { erc20Abi } from "viem";
import { insuranceReserveAbi } from "./InsuranceReserve";
import { lPVaultAbi } from "./LPVault";
import { oracleVerifierAbi } from "./OracleVerifier";
import { positionManagerAbi } from "./PositionManager";
import { traderProxyAbi } from "./TraderProxy";

const errorsOf = <T extends readonly { type: string }[]>(abi: T) =>
  abi.filter((x): x is Extract<T[number], { type: "error" }> => x.type === "error");

/**
 * Calls into PositionManager can revert inside the oracle, vault, proxy or USDC. Appending their error
 * fragments lets viem decode those nested reverts into readable names.
 */
const nestedErrors = [
  ...errorsOf(oracleVerifierAbi),
  ...errorsOf(lPVaultAbi),
  ...errorsOf(traderProxyAbi),
  ...errorsOf(insuranceReserveAbi),
];

export const pmAbi = [...positionManagerAbi, ...nestedErrors.filter((e) => !positionManagerAbi.some((p) => p.type === "error" && p.name === e.name))] as const;
export const vaultAbi = lPVaultAbi;
export const oracleAbi = oracleVerifierAbi;
export const insuranceAbi = insuranceReserveAbi;
export { erc20Abi };
