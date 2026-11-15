#!/usr/bin/env bash
# w6800-fan-control.sh - Zero-Fan (0 RPM <= 45°C) + Stock SMU Curve (>= 49°C) controller for Radeon PRO W6800
#
# Requires:
#   amdgpu.ko built with patches/w6800-zerofan-unlock.patch (Method A)
#
# Usage:
#   Can be triggered by Unraid "User Scripts" plugin ("At Startup of Array" -> Run in Background)
#   or run directly:
#     ./w6800-fan-control.sh          # Run foreground daemon loop
#     ./w6800-fan-control.sh --stop   # Stop running daemon and restore stock SMU fan curve

set -euo pipefail

ZERO_FAN_TEMP=45       # Enter Zero-Fan (0 RPM) when max(Edge, Hotspot, VRAM) <= 45°C
AUTO_FAN_TEMP=49       # Return to Stock SMU Curve (pwm1_enable=2) when max(Edge, Hotspot, VRAM) >= 49°C
POLL_INTERVAL=2        # Temperature polling interval in seconds
TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3" # Radeon PRO W6800 strictly
PID_FILE="/var/run/w6800-fan-control.pid"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [W6800-FanCtrl] $*"
}

find_w6800_hwmon() {
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
      return 0
    fi
  done
  return 1
}

restore_stock_curve() {
  local hwmon="${1:-}"
  if [ -z "$hwmon" ] || [ ! -d "$hwmon" ]; then
    hwmon="$(find_w6800_hwmon || true)"
  fi
  if [ -n "$hwmon" ] && [ -w "$hwmon/pwm1_enable" ]; then
    echo 2 > "$hwmon/pwm1_enable" 2>/dev/null || true
    log "Restored W6800 fan to stock SMU automatic curve (pwm1_enable=2)."
  fi
}

# Handle --stop flag
if [ "${1:-}" = "--stop" ]; then
  if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      log "Stopping running W6800 fan controller (PID $OLD_PID)..."
      kill "$OLD_PID" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi
  restore_stock_curve ""
  exit 0
fi

# Stop any previous instance before starting
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    log "Terminating previous W6800 fan controller instance (PID $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
fi
echo "$$" > "$PID_FILE"

HWMON_DIR=""
cleanup() {
  rm -f "$PID_FILE"
  restore_stock_curve "$HWMON_DIR"
  exit 0
}
trap cleanup EXIT INT TERM

log "Starting W6800 Zero-Fan controller (Zero-Fan <= ${ZERO_FAN_TEMP}°C, Stock SMU Curve >= ${AUTO_FAN_TEMP}°C)..."

# Wait up to 30s for W6800 hwmon node (allows time for amdgpu.ko hot-swap on boot)
for i in $(seq 1 30); do
  HWMON_DIR="$(find_w6800_hwmon || true)"
  [ -n "$HWMON_DIR" ] && break
  sleep 1
done

if [ -z "$HWMON_DIR" ]; then
  log "ERROR: Could not find writable W6800 hwmon node within 30 seconds!" >&2
  exit 1
fi

PCI_SLOT="$(basename "$(readlink -f "$HWMON_DIR/device")")"
log "Monitoring W6800 at PCI slot $PCI_SLOT ($HWMON_DIR)"

CURRENT_MODE=""

while true; do
  # Re-acquire hwmon directory if driver was reloaded
  if [ ! -d "$HWMON_DIR" ]; then
    HWMON_DIR="$(find_w6800_hwmon || true)"
    CURRENT_MODE=""
    if [ -z "$HWMON_DIR" ]; then
      sleep "$POLL_INTERVAL"
      continue
    fi
  fi

  T_EDGE=$(( $(cat "$HWMON_DIR/temp1_input" 2>/dev/null || echo 50000) / 1000 ))
  T_JUNC=$(( $(cat "$HWMON_DIR/temp2_input" 2>/dev/null || echo 50000) / 1000 ))
  T_MEM=$((  $(cat "$HWMON_DIR/temp3_input" 2>/dev/null || echo 50000) / 1000 ))

  MAX_TEMP=$T_EDGE
  [ "$T_JUNC" -gt "$MAX_TEMP" ] && MAX_TEMP=$T_JUNC
  [ "$T_MEM"  -gt "$MAX_TEMP" ] && MAX_TEMP=$T_MEM

  if [ "$MAX_TEMP" -le "$ZERO_FAN_TEMP" ] && [ "$CURRENT_MODE" != "ZEROFAN" ]; then
    echo 1 > "$HWMON_DIR/pwm1_enable"
    echo 0 > "$HWMON_DIR/pwm1"
    CURRENT_MODE="ZEROFAN"
    log "State -> ZEROFAN (0 RPM) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
  elif [ "$MAX_TEMP" -ge "$AUTO_FAN_TEMP" ] && [ "$CURRENT_MODE" != "AUTO" ]; then
    echo 2 > "$HWMON_DIR/pwm1_enable"
    CURRENT_MODE="AUTO"
    log "State -> AUTO (SMU Stock Curve) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
  fi

  sleep "$POLL_INTERVAL"
done
