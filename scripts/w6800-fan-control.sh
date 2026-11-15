#!/usr/bin/env bash
# w6800-fan-control.sh - Multi-GPU Zero-Fan (0 RPM <= 45°C) + Stock SMU Curve (>= 49°C) daemon for Radeon PRO W6800
#
# Requires:
#   amdgpu.ko built with patches/w6800-zerofan-unlock.patch (Method A)
#
# Usage:
#   Safe to set to "At Startup of Array" or click "Run Script" in Unraid User Scripts plugin!
#   The script automatically detaches into a new session (setsid, closing stdout/stderr pipes)
#   so it never blocks Unraid Array Start or gets killed when closing the User Scripts popup.
#
#   ./w6800-fan-control.sh              # Self-daemonize in background and exit 0 immediately
#   ./w6800-fan-control.sh --stop       # Stop running daemon and restore stock SMU fan curve on all W6800s
#   ./w6800-fan-control.sh --foreground # Run in foreground (for manual debugging)

set -euo pipefail

ZERO_FAN_TEMP=45       # Enter Zero-Fan (0 RPM) when max(Edge, Hotspot, VRAM) <= 45°C
AUTO_FAN_TEMP=49       # Return to Stock SMU Curve (pwm1_enable=2) when max(Edge, Hotspot, VRAM) >= 49°C
POLL_INTERVAL=2        # Temperature polling interval in seconds
TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3" # Radeon PRO W6800 strictly
PID_FILE="/var/run/w6800-fan-control.pid"
LOG_FILE="/var/log/w6800-fan-control.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [W6800-FanCtrl] $*"
  logger -t "W6800-FanCtrl" "$*" 2>/dev/null || true
}

find_all_w6800_hwmons() {
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] || continue
    grep -qi "amdgpu" "$h/name" || continue
    local d
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    [ -n "$d" ] || continue

    [ "$(cat "$d/vendor" 2>/dev/null || true)" = "$TARGET_VENDOR" ] || continue
    [ "$(cat "$d/device" 2>/dev/null || true)" = "$TARGET_DEVICE" ] || continue

    if [ -w "$h/pwm1_enable" ] && [ -w "$h/pwm1" ]; then
      echo "$h"
    fi
  done
}

restore_all_stock_curves() {
  local h d slot
  for h in $(find_all_w6800_hwmons); do
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    slot="$(basename "${d:-unknown}")"
    echo 2 > "$h/pwm1_enable" 2>/dev/null || true
    log "[$slot] Restored W6800 fan to stock SMU automatic curve (pwm1_enable=2)."
  done
}

stop_existing_daemon() {
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
      log "Stopping previous W6800 fan controller instance (PID $old_pid)..."
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi
}

MODE="${1:-}"

# 1. Handle --stop flag
if [ "$MODE" = "--stop" ]; then
  stop_existing_daemon
  restore_all_stock_curves
  exit 0
fi

# 2. Default invocation (from Unraid User Scripts / Array Start):
#    Stop any old instance, spawn detached background daemon in a new session (setsid),
#    and exit 0 immediately so User Scripts never kills the process group on close.
if [ "$MODE" != "--daemon" ] && [ "$MODE" != "--foreground" ]; then
  stop_existing_daemon
  SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  setsid bash "$SCRIPT_PATH" --daemon </dev/null >>"$LOG_FILE" 2>&1 &
  DAEMON_PID=$!
  log "W6800 Zero-Fan background daemon started (PID $DAEMON_PID, Log: $LOG_FILE)."
  exit 0
fi

# 3. Daemon / Foreground main loop
if [ "$MODE" = "--foreground" ]; then
  stop_existing_daemon
fi
echo "$$" > "$PID_FILE"

cleanup() {
  trap - EXIT INT TERM
  rm -f "$PID_FILE"
  restore_all_stock_curves
  exit 0
}
trap cleanup EXIT INT TERM

log "Daemon loop active (Zero-Fan <= ${ZERO_FAN_TEMP}°C, Stock SMU Curve >= ${AUTO_FAN_TEMP}°C)."

# Wait up to 30s for at least one W6800 hwmon node
FOUND_INIT=0
for i in $(seq 1 30); do
  if [ -n "$(find_all_w6800_hwmons)" ]; then
    FOUND_INIT=1
    break
  fi
  sleep 1
done

if [ "$FOUND_INIT" -eq 0 ]; then
  log "ERROR: Could not find writable W6800 hwmon node within 30 seconds!" >&2
  exit 1
fi

declare -A CURRENT_MODE

for h in $(find_all_w6800_hwmons); do
  slot="$(basename "$(readlink -f "$h/device")")"
  log "Monitoring W6800 at PCI slot $slot ($h)."
done

while true; do
  for h in $(find_all_w6800_hwmons); do
    [ -d "$h" ] || continue
    slot="$(basename "$(readlink -f "$h/device")")"
    prev_mode="${CURRENT_MODE[$slot]:-}"

    T_EDGE=$(( $(cat "$h/temp1_input" 2>/dev/null || echo 50000) / 1000 ))
    T_JUNC=$(( $(cat "$h/temp2_input" 2>/dev/null || echo 50000) / 1000 ))
    T_MEM=$((  $(cat "$h/temp3_input" 2>/dev/null || echo 50000) / 1000 ))

    MAX_TEMP=$T_EDGE
    [ "$T_JUNC" -gt "$MAX_TEMP" ] && MAX_TEMP=$T_JUNC
    [ "$T_MEM"  -gt "$MAX_TEMP" ] && MAX_TEMP=$T_MEM

    if [ "$MAX_TEMP" -le "$ZERO_FAN_TEMP" ] && [ "$prev_mode" != "ZEROFAN" ]; then
      echo 1 > "$h/pwm1_enable"
      echo 0 > "$h/pwm1"
      CURRENT_MODE["$slot"]="ZEROFAN"
      log "[$slot] State -> ZEROFAN (0 RPM) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
    elif [ "$MAX_TEMP" -ge "$AUTO_FAN_TEMP" ] && [ "$prev_mode" != "AUTO" ]; then
      echo 2 > "$h/pwm1_enable"
      CURRENT_MODE["$slot"]="AUTO"
      log "[$slot] State -> AUTO (SMU Stock Curve) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
    fi
  done

  sleep "$POLL_INTERVAL"
done
