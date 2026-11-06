# Shared helpers for the local Arc mainnet fork scripts. Sourced, not executed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

# Native binaries from the pinned @foundry-rs packages (their bin.mjs launchers swallow exit codes).
FORGE=("$(node "$ROOT/script/foundry.mjs" --path forge)")
CAST=("$(node "$ROOT/script/foundry.mjs" --path cast)")
ANVIL=("$(node "$ROOT/script/foundry.mjs" --path anvil)")

PORT=${FORK_PORT:-8545}
RPC="http://127.0.0.1:$PORT"
DEPLOYMENT="$ROOT/deployments/fork.json"

# Anvil's well-known test mnemonic: #0 deployer, #1 keeper, #2 trader, #3 LP. Never use these keys on a real chain.
MNEMONIC="test test test test test test test test test test test junk"
pk() { "${CAST[@]}" wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }
addr() { "${CAST[@]}" wallet address --private-key "$1"; }

USDC=0x3600000000000000000000000000000000000000
WETH=0x128cC466B61f542da60c70e3aA11c10e19B84EDB
CIRBTC=0x171A4217b86A807A64eB94757Db6849fb4bDbAA0

die() { echo "error: $*" >&2; exit 1; }

need_deployment() {
  [[ -f "$DEPLOYMENT" ]] || die "no fork deployment found; start the fork first with: npm run fork"
  "${CAST[@]}" chain-id -r "$RPC" >/dev/null 2>&1 || die "no anvil fork is answering on $RPC; start it with: npm run fork"
}

json() { node -p "require('$DEPLOYMENT').$1"; }

asset_addr() {
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    ETH | WETH) echo "$WETH" ;;
    BTC | CIRBTC) echo "$CIRBTC" ;;
    *) die "unknown asset '$1' (use ETH or BTC)" ;;
  esac
}

# Current pool tick of an asset (cast prints "123 [1.23e2]"; keep the number).
spot_tick() { "${CAST[@]}" call -r "$RPC" "$(json oracle)" "spotTick(address)(int24)" "$1" | awk '{print $1}'; }

# Record one TWAP observation for both markets from the deployer key (a recorder on the fork).
record_twap() {
  local oracle t1 t2
  oracle=$(json oracle)
  t1=$(spot_tick "$WETH")
  t2=$(spot_tick "$CIRBTC")
  "${CAST[@]}" send -q -r "$RPC" --private-key "$(pk 0)" "$oracle" \
    "record(address[],int24[])" "[$WETH,$CIRBTC]" "[$t1,$t2]" >/dev/null
}

# Advance chain time by $1 seconds in 10s steps, recording the TWAP at each step (a jump longer than the oracle's
# maxObservationGap would restart its series and make prices unavailable for 10 minutes).
warp() {
  local secs=$1 step=10 t=0
  while ((t < secs)); do
    "${CAST[@]}" rpc -r "$RPC" evm_increaseTime "$step" >/dev/null
    record_twap
    t=$((t + step))
  done
}
