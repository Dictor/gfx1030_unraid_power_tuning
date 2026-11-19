#!/usr/bin/env bash
# w6800-array-start.sh - Hot-swap patched amdgpu.ko & set powercap for Radeon PRO W6800 on Unraid Array Start

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
TARGET_WATTS=140
TARGET_UW=$(( TARGET_WATTS * 1000000 ))
TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3"   # Radeon PRO W6800
PATCHED_KO="/boot/config/custom/w6800/amdgpu.ko"
CURRENT_MOD_DIR="/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu"

# ==============================================================================
# CORE LOGIC
# ==============================================================================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [W6800-Powercap] $*"
  logger -t "W6800-Powercap" "$*" 2>/dev/null || true
}

log "Unraid Array started. Ensuring W6800 driver unlock and applying ${TARGET_WATTS}W power cap..."

# 1. Hot-swap driver if patched module is not loaded yet or if PATCHED_KO was updated
if [ -f "$PATCHED_KO" ]; then
  if ! lsmod | grep -E "^amdgpu " >/dev/null 2>&1 ||
     ! cmp -s "$PATCHED_KO" "$CURRENT_MOD_DIR/amdgpu.ko" 2>/dev/null ||
     ! dmesg 2>/dev/null | grep "W6800 powerfix" >/dev/null 2>&1 ||
     ! dmesg 2>/dev/null | grep "W6800 zerofan" >/dev/null 2>&1; then
    log "Updating and hot-swapping patched amdgpu.ko..."
    cp -f "$PATCHED_KO" "$CURRENT_MOD_DIR/amdgpu.ko"
    rm -f "$CURRENT_MOD_DIR/amdgpu.ko.xz" "$CURRENT_MOD_DIR/amdgpu.ko.zst"
    depmod -a
    echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
    modprobe -r amdgpu 2>/dev/null || true
    if ! lsmod | grep -E "^amdgpu " >/dev/null 2>&1; then
      modprobe amdgpu
      sleep 2
      log "Hot-swap completed successfully."
    else
      log "WARNING: Could not unload running amdgpu module (GPU is in use)."
    fi
  fi
fi

# 2. Wait up to 30s for hwmon device nodes to appear and apply target wattage
APPLIED=0
for _ in $(seq 1 30); do
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] && grep -qi "amdgpu" "$h/name" || continue
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    [ -n "$d" ] && [ -w "$h/power1_cap" ] || continue
    read -r vendor < "$d/vendor" 2>/dev/null || continue
    read -r device < "$d/device" 2>/dev/null || continue
    [ "$vendor" = "$TARGET_VENDOR" ] && [ "$device" = "$TARGET_DEVICE" ] || continue

    echo "$TARGET_UW" > "$h/power1_cap"
    read -r current_cap < "$h/power1_cap"
    log "SUCCESS: Slot $(basename "$d") power cap configured to $(( current_cap / 1000000 )) W."
    APPLIED=1
  done
  [ "$APPLIED" -eq 1 ] && break
  sleep 1
done

if [ "$APPLIED" -eq 0 ]; then
  log "ERROR: Could not find writable W6800 hwmon node within 30 seconds!" >&2
  exit 1
fi
