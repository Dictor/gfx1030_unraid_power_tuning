#!/usr/bin/env bash
# w6800-powercap-apply.sh [WATTS] - Apply power cap to Radeon PRO W6800 GPU(s) on Unraid
#
# Matches W6800 strictly by PCI Vendor (0x1002) and Device (0x73a3).
# Other GPUs (such as RX 6950 XT: 0x73a5) are completely ignored.
#
# Designed to run at boot (via /boot/config/go):
# Waits up to 60s for hwmon nodes to appear and stabilize, applies the cap,
# and exits. Idempotent.
#
# Usage:
#   sudo ./scripts/w6800-powercap-apply.sh [WATTS]  (default: 180)
# Exit:
#   0 = cap applied to >=1 card
#   1 = no W6800 found or write failed

set -euo pipefail

W="${1:-180}"
if ! [[ "$W" =~ ^[0-9]+$ ]]; then
  echo "w6800-powercap-apply: wattage must be an integer, got '$W'" >&2
  exit 2
fi

UW=$((W * 1000000))
DEADLINE=$((SECONDS + 60))

TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] w6800-powercap-apply: $*"
}

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)" >&2; exit 1; }

log "Initiating power cap target: ${W} W (${UW} uW)"

last=-1
applied=0

while [ $SECONDS -lt $DEADLINE ]; do
  n=0
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    grep -qi "amdgpu" "$h/name" || continue
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    [ -n "$d" ] || continue

    # Strict check for W6800 PCI ID
    [ "$(cat "$d/vendor" 2>/dev/null || true)" = "$TARGET_VENDOR" ] || continue
    [ "$(cat "$d/device" 2>/dev/null || true)" = "$TARGET_DEVICE" ] || continue

    slot="$(basename "$d")"

    if [ ! -w "$h/power1_cap" ]; then
      log "FAIL: $h/power1_cap not writable on $slot"
      continue
    fi

    # Check minimum cap floor
    if [ -f "$h/power1_cap_min" ]; then
      min_uw="$(cat "$h/power1_cap_min" 2>/dev/null || echo 0)"
      if [ "$UW" -lt "$min_uw" ]; then
        log "WARNING: requested ${W} W is lower than reported floor $((min_uw / 1000000)) W on $slot."
        log "         If write fails, verify w6800-powercap-min kernel patch is active."
      fi
    fi

    cur="$(cat "$h/power1_cap" 2>/dev/null || echo 0)"
    if [ "$cur" != "$UW" ]; then
      if echo "$UW" > "$h/power1_cap" 2>/dev/null; then
        log "Success on $slot: power cap -> ${W} W (was $((cur / 1000000)) W)"
        applied=$((applied + 1))
      else
        log "FAIL: write rejected on $slot! (Current: $((cur / 1000000)) W, Target: ${W} W)"
        log "      Make sure patched amdgpu module is loaded and power1_cap_min allows <=180W."
      fi
    else
      # Already at target
      applied=$((applied + 1))
    fi
    n=$((n + 1))
  done

  # Settle check: cards found and stable across two consecutive iterations
  if [ "$n" -gt 0 ] && [ "$n" -eq "$last" ]; then
    log "Done: ${W} W cap active on $applied of $n W6800 card(s)."
    exit 0
  fi

  last=$n
  sleep 2
done

if [ "$last" -gt 0 ] && [ "$applied" -gt 0 ]; then
  log "Done (timeout reached): ${W} W cap active on $applied of $last W6800 card(s)."
  exit 0
fi

log "FAIL: no Radeon PRO W6800 cards configured within 60s timeout."
exit 1
