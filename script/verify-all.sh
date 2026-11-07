#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="$ROOT/deployments/base-mainnet.json"

if [ ! -f "$JSON" ]; then
  echo "Error: $JSON not found. Run deployment script first."
  exit 1
fi

ETHERSCAN_KEY="${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}"

ORACLE=$(node -pe "require('$JSON').chainlinkOracle")
ROUTER=$(node -pe "require('$JSON').v4SwapRouter")
VAULT_PROXY=$(node -pe "require('$JSON').lpVault")
INSURANCE=$(node -pe "require('$JSON').insuranceReserve")
PM_PROXY=$(node -pe "require('$JSON').positionManager")
PROXY_IMPL=$(node -pe "require('$JSON').traderProxyImpl")

echo "=== Verifying on Blockscout ==="
for item in \
  "$ORACLE:src/ChainlinkOracle.sol:ChainlinkOracle" \
  "$ROUTER:src/V4SwapRouter.sol:V4SwapRouter" \
  "$INSURANCE:src/InsuranceReserve.sol:InsuranceReserve" \
  "$PROXY_IMPL:src/TraderProxy.sol:TraderProxy"; do
  ADDR="${item%%:*}"
  CONTRACT="${item#*:}"
  echo "Verifying $CONTRACT at $ADDR on Blockscout..."
  forge verify-contract "$ADDR" "$CONTRACT" \
    --chain 8453 \
    --verifier blockscout \
    --verifier-url "https://base.blockscout.com/api/" || true
done

echo "=== Verifying on Etherscan / Basescan ==="
for item in \
  "$ORACLE:src/ChainlinkOracle.sol:ChainlinkOracle" \
  "$ROUTER:src/V4SwapRouter.sol:V4SwapRouter" \
  "$INSURANCE:src/InsuranceReserve.sol:InsuranceReserve" \
  "$PROXY_IMPL:src/TraderProxy.sol:TraderProxy"; do
  ADDR="${item%%:*}"
  CONTRACT="${item#*:}"
  echo "Verifying $CONTRACT at $ADDR on Etherscan..."
  forge verify-contract "$ADDR" "$CONTRACT" \
    --chain 8453 \
    --verifier etherscan \
    --verifier-url "https://api.etherscan.io/v2/api?chainid=8453" \
    --etherscan-api-key "$ETHERSCAN_KEY" || true
done

echo "All verification tasks dispatched."
