#!/usr/bin/env bash
# w6800-array-start.sh - Hot-swap patched amdgpu.ko & set 140W powercap for Radeon PRO W6800 on Unraid Array Start
#
# Usage:
#   Can be triggered by Unraid "User Scripts" plugin set to "At Startup of Array"
#   or called directly from /boot/config/custom/w6800/w6800-array-start.sh

set -euo pipefail

TARGET_WATTS=140
TARGET_UW=$((TARGET_WATTS * 1000000))
TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3" # Radeon PRO W6800 strictly

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [W6800-Powercap] $*"
}

log "Unraid Array started. Ensuring W6800 120W unlock and applying ${TARGET_WATTS}W power cap..."

# 1. Hot-swap driver if patched module is not loaded yet (e.g. fresh reboot)
PATCHED_KO="/boot/config/custom/w6800/amdgpu.ko"
if [ -f "$PATCHED_KO" ]; then
  CURRENT_MOD_DIR="/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu"
  # Avoid 'grep -q' on a pipe with 'set -o pipefail': grep -q closes the pipe early
  # upon first match, causing 'dmesg: write error: Broken pipe' and non-zero pipefail.
  if ! dmesg 2>/dev/null | grep -E "W6800 (powerfix|zerofan)" >/dev/null 2>&1; then
    log "Patched driver marker not found in dmesg. Performing hot-swap..."
    cp -f "$PATCHED_KO" "$CURRENT_MOD_DIR/amdgpu.ko"
    rm -f "$CURRENT_MOD_DIR/amdgpu.ko.xz" "$CURRENT_MOD_DIR/amdgpu.ko.zst"
    depmod -a
    modprobe -r amdgpu 2>/dev/null || true
    modprobe amdgpu
    sleep 2
  fi
fi

# 2. Wait up to 30s for hwmon device node to appear and apply target wattage
APPLIED=0
for i in $(seq 1 30); do
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    grep -qi "amdgpu" "$h/name" || continue
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    [ -n "$d" ] || continue

    # Strict check for W6800 PCI ID (0x1002:0x73a3). Ignores other GPUs (e.g. RX 6950 XT)
    [ "$(cat "$d/vendor" 2>/dev/null || true)" = "$TARGET_VENDOR" ] || continue
    [ "$(cat "$d/device" 2>/dev/null || true)" = "$TARGET_DEVICE" ] || continue

    slot="$(basename "$d")"
    if [ -w "$h/power1_cap" ]; then
      echo "$TARGET_UW" > "$h/power1_cap"
      CURRENT_CAP="$(cat "$h/power1_cap")"
      log "SUCCESS: Slot $slot power cap configured to $((CURRENT_CAP / 1000000)) W!"
      APPLIED=1
    fi
  done

  [ "$APPLIED" -eq 1 ] && break
  sleep 1
done

if [ "$APPLIED" -eq 0 ]; then
  log "ERROR: Could not find writable W6800 hwmon node within 30 seconds!" >&2
  exit 1
fi
