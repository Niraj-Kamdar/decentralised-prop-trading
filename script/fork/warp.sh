#!/usr/bin/env bash
# Fast-forward the local fork's clock by N seconds while recording the TWAP every 10s:  npm run fork:warp -- 600
# Use it after fork:move to let the TWAP catch up (the keeper then liquidates or triggers), or to reach epoch ends.
# For long jumps (e.g. 7 days) the oracle restarts its series and needs 10 more minutes; pass the jump and then 610.
source "$(dirname "$0")/lib.sh"
need_deployment

SECS=${1:-610}
[[ "$SECS" =~ ^[0-9]+$ ]] || die "usage: npm run fork:warp -- <seconds>"

if ((SECS > 3600)); then
  # Long jump: one step, then re-warm the TWAP.
  "${CAST[@]}" rpc -r "$RPC" evm_increaseTime "$SECS" >/dev/null
  echo "Jumped $SECS s; re-warming the TWAP (610 s of observations)..."
  record_twap
  warp 610
else
  warp "$SECS"
fi
"${CAST[@]}" rpc -r "$RPC" evm_mine >/dev/null
echo "Chain time is now $("${CAST[@]}" block -r "$RPC" latest -f timestamp)."
