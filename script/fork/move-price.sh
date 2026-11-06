#!/usr/bin/env bash
# Move a real Uniswap v4 pool on the local fork by trading against its liquidity:  npm run fork:move -- ETH -8
#   $1  ETH | BTC
#   $2  percent move of the USD price (e.g. -8, 5, 2.5)
# The TWAP follows over the next 10 minutes of recorded observations (npm run fork:warp -- 600 to fast-forward).
source "$(dirname "$0")/lib.sh"
need_deployment

[[ $# -eq 2 ]] || die "usage: npm run fork:move -- <ETH|BTC> <percent>"
ASSET=$(asset_addr "$1")
BPS=$(node -p "Math.round(Number('$2') * 100)")
[[ "$BPS" =~ ^-?[0-9]+$ ]] || die "percent must be a number"

ORACLE=$(json oracle)
MOVER=$(json poolMover)
DEPLOYER_PK=$(pk 0)

TICK=$(spot_tick "$ASSET")
# tick = ln(ratio) / ln(1.0001), with ln(1 + x) ~ x / (1 + x/2) (within 0.1% for moves up to 30%).
TARGET=$((TICK + (BPS * 10000) / (10000 + BPS / 2)))

# Fund the mover: USDC from the shim faucet (to buy), the asset by writing its balance slot (to sell).
"${CAST[@]}" send -q -r "$RPC" --private-key "$DEPLOYER_PK" "$USDC" "mint(address,uint256)" "$MOVER" 5000000000000 >/dev/null
SLOT=$("${FORGE[@]}" script script/fork/ForkCtl.s.sol --sig 'balanceSlot(address,address)' "$ASSET" "$MOVER" \
  --rpc-url "$RPC" 2>/dev/null | awk '/SLOT/ {print $2}')
[[ -n "$SLOT" ]] || die "could not find the balance slot of $ASSET"
"${CAST[@]}" rpc -r "$RPC" anvil_setStorageAt "$ASSET" "$SLOT" \
  "$("${CAST[@]}" abi-encode "f(uint256)" 1000000000000000000000000)" >/dev/null

KEY=$("${CAST[@]}" call -r "$RPC" "$ORACLE" "poolKey(address)((address,address,uint24,int24,address))" "$ASSET")
BEFORE=$("${CAST[@]}" call -r "$RPC" "$ORACLE" "spotPrice(address)(uint256)" "$ASSET" | awk '{print $1}')
"${CAST[@]}" send -q -r "$RPC" --private-key "$DEPLOYER_PK" "$MOVER" \
  "moveTo((address,address,uint24,int24,address),int24)" "$KEY" "$TARGET" >/dev/null
AFTER=$("${CAST[@]}" call -r "$RPC" "$ORACLE" "spotPrice(address)(uint256)" "$ASSET" | awk '{print $1}')

node -e "
const b = Number(BigInt('$BEFORE')) / 1e18, a = Number(BigInt('$AFTER')) / 1e18;
console.log('$(echo "$1" | tr '[:lower:]' '[:upper:]') pool price: \$' + b.toFixed(2) + ' -> \$' + a.toFixed(2) + ' (' + ((a / b - 1) * 100).toFixed(2) + '%)');
console.log('The 10-minute TWAP follows as observations are recorded. Fast-forward with: npm run fork:warp -- 600');
"
