#!/usr/bin/env bash
# w6800-fan-control.sh - Multi-GPU 3-Zone Fan Controller for Radeon PRO W6800
#   Zone 1 (ZEROFAN): <= 45°C         -> 0 RPM (Hardware Zero-Fan)
#   Zone 2 (AUTO)   : 49°C .. 66°C    -> Stock SMU Curve (pwm1_enable=2, ~1150-1500 RPM)
#   Zone 3 (BOOST)  : >= 70°C         -> Bypass SMU Acoustic Limit, 2000+ RPM Linear P-Control
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

# --- 3-Zone Temperature Thresholds (°C, based on max of Edge, Hotspot, VRAM) ---
ZERO_FAN_TEMP=45       # Zone 1: Enter Zero-Fan (0 RPM) when <= 45°C
AUTO_FAN_TEMP=49       # Zone 2: Enter Stock SMU Curve from Zero-Fan when >= 49°C
BOOST_EXIT_TEMP=66     # Zone 2: Return to Stock SMU Curve from Boost when <= 66°C
BOOST_FAN_TEMP=70      # Zone 3: Enter High-Power Linear P-Control when >= 70°C

# --- Zone 3 (BOOST) P-Controller Parameters (PWM 0..255) ---
# On W6800, PWM 92 ≈ 2050-2100 RPM, PWM 100 ≈ 2264 RPM.
# Formula at T >= 70°C: PWM = BOOST_BASE_PWM + (MAX_TEMP - BOOST_FAN_TEMP) * BOOST_KP
#   70°C -> PWM  92 (~2,080 RPM)
#   75°C -> PWM 127 (~2,850 RPM)
#   80°C -> PWM 162 (~3,600 RPM)
#   85°C -> PWM 197 (~4,200 RPM)
#   90°C -> PWM 232 (~4,600+ RPM)
BOOST_BASE_PWM=92      # Starting PWM at 70°C (~2,080 RPM, above 2,000 RPM)
BOOST_KP=7             # Proportional gain: +7 PWM (~155 RPM) per 1°C above 70°C
BOOST_MAX_PWM=255      # Maximum PWM limit (100% fan speed)

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

# Wake THM PWM controller from 0-RPM sleep via brief manual PWM kick (Disable FAN_CONTROL ->
# Static Duty -> Enable FAN_CONTROL), guaranteeing the SMU resumes its stock curve cleanly.
wake_and_set_stock_curve() {
  local h="$1"
  echo 1 > "$h/pwm1_enable" 2>/dev/null || true
  echo 65 > "$h/pwm1" 2>/dev/null || true
  sleep 1
  echo 2 > "$h/pwm1_enable" 2>/dev/null || true
}

# Calculate Zone 3 P-control PWM duty (clamped between BOOST_BASE_PWM and BOOST_MAX_PWM)
calc_boost_pwm() {
  local temp="$1"
  local delta=$(( temp - BOOST_FAN_TEMP ))
  if [ "$delta" -lt 0 ]; then
    delta=0
  fi
  local pwm=$(( BOOST_BASE_PWM + delta * BOOST_KP ))
  if [ "$pwm" -gt "$BOOST_MAX_PWM" ]; then
    pwm="$BOOST_MAX_PWM"
  fi
  echo "$pwm"
}

restore_all_stock_curves() {
  local h d slot
  for h in $(find_all_w6800_hwmons); do
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    slot="$(basename "${d:-unknown}")"
    wake_and_set_stock_curve "$h"
    log "[$slot] Restored W6800 fan to stock SMU automatic curve (pwm1_enable=2)."
  done
}

stop_existing_daemon() {
  local skip_restore="${1:-0}"
  local pids=()
  if [ -f "$PID_FILE" ]; then
    local file_pid
    file_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$file_pid" ] && pids+=("$file_pid")
  fi
  for p in $(pgrep -f " --daemon" 2>/dev/null || true); do
    pids+=("$p")
  done

  for old_pid in "${pids[@]}"; do
    if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && [ "$old_pid" != "$PPID" ] && kill -0 "$old_pid" 2>/dev/null; then
      log "Stopping previous W6800 fan controller instance (PID $old_pid)..."
      if [ "$skip_restore" -eq 1 ]; then
        # When replacing with a new daemon, terminate old daemon without running its exit restore
        pkill -9 -P "$old_pid" 2>/dev/null || true
        kill -9 "$old_pid" 2>/dev/null || true
      else
        pkill -P "$old_pid" 2>/dev/null || true
        kill "$old_pid" 2>/dev/null || true
      fi
      for _ in $(seq 1 30); do
        kill -0 "$old_pid" 2>/dev/null || break
        sleep 0.2
      done
    fi
  done
  rm -f "$PID_FILE"
}

MODE="${1:-}"

# 1. Handle --stop flag (graceful stop + restore stock curve)
if [ "$MODE" = "--stop" ]; then
  stop_existing_daemon 0
  restore_all_stock_curves
  exit 0
fi

# 2. Default invocation (from Unraid User Scripts / Array Start):
#    Stop any old instance immediately, spawn detached background daemon in a new session (setsid),
#    and exit 0 immediately so User Scripts never kills the process group on close.
if [ "$MODE" != "--daemon" ] && [ "$MODE" != "--foreground" ]; then
  stop_existing_daemon 1
  SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  setsid bash "$SCRIPT_PATH" --daemon </dev/null >>"$LOG_FILE" 2>&1 &
  DAEMON_PID=$!
  log "W6800 3-Zone Fan Controller daemon started (PID $DAEMON_PID, Log: $LOG_FILE)."
  exit 0
fi

# 3. Daemon / Foreground main loop
if [ "$MODE" = "--foreground" ]; then
  stop_existing_daemon 1
fi
echo "$$" > "$PID_FILE"

cleanup() {
  trap - EXIT INT TERM
  rm -f "$PID_FILE"
  restore_all_stock_curves
  exit 0
}
trap cleanup EXIT INT TERM

log "Daemon loop active (Zone1 Zero-Fan <= ${ZERO_FAN_TEMP}°C | Zone2 Stock SMU ${AUTO_FAN_TEMP}..${BOOST_EXIT_TEMP}°C | Zone3 P-Boost >= ${BOOST_FAN_TEMP}°C)."

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
declare -A LAST_LOGGED_PWM

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
    FAN_RPM=$(cat "$h/fan1_input" 2>/dev/null || echo 0)

    MAX_TEMP=$T_EDGE
    [ "$T_JUNC" -gt "$MAX_TEMP" ] && MAX_TEMP=$T_JUNC
    [ "$T_MEM"  -gt "$MAX_TEMP" ] && MAX_TEMP=$T_MEM

    # --- Zone 1: Zero-Fan (<= 45°C) ---
    if [ "$MAX_TEMP" -le "$ZERO_FAN_TEMP" ]; then
      if [ "$prev_mode" != "ZEROFAN" ] || [ "$FAN_RPM" -gt 500 ]; then
        echo 1 > "$h/pwm1_enable"
        echo 0 > "$h/pwm1"
        CURRENT_MODE["$slot"]="ZEROFAN"
        LAST_LOGGED_PWM["$slot"]=0
        log "[$slot] Zone 1 -> ZEROFAN (0 RPM) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
      fi

    # --- Zone 3: High-Power P-Control Boost (>= 70°C, or staying in BOOST until <= 66°C) ---
    elif [ "$MAX_TEMP" -ge "$BOOST_FAN_TEMP" ] || { [ "$prev_mode" = "BOOST" ] && [ "$MAX_TEMP" -gt "$BOOST_EXIT_TEMP" ]; }; then
      TARGET_PWM="$(calc_boost_pwm "$MAX_TEMP")"
      echo 1 > "$h/pwm1_enable"
      echo "$TARGET_PWM" > "$h/pwm1"

      prev_pwm="${LAST_LOGGED_PWM[$slot]:-0}"
      pwm_diff=$(( TARGET_PWM - prev_pwm ))
      [ "$pwm_diff" -lt 0 ] && pwm_diff=$(( -pwm_diff ))

      if [ "$prev_mode" != "BOOST" ] || [ "$pwm_diff" -ge 10 ] || [ "$FAN_RPM" -lt 1500 ]; then
        CURRENT_MODE["$slot"]="BOOST"
        LAST_LOGGED_PWM["$slot"]="$TARGET_PWM"
        sleep 1
        NEW_RPM=$(cat "$h/fan1_input" 2>/dev/null || echo 0)
        log "[$slot] Zone 3 -> BOOST P-Ctrl (PWM=${TARGET_PWM}/255, ${NEW_RPM} RPM) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
      else
        CURRENT_MODE["$slot"]="BOOST"
      fi

    # --- Zone 2: Stock SMU Automatic Curve (49°C .. 66°C) ---
    elif [ "$MAX_TEMP" -ge "$AUTO_FAN_TEMP" ]; then
      if [ "$prev_mode" != "AUTO" ] || [ "$FAN_RPM" -lt 500 ]; then
        if [ "$prev_mode" = "BOOST" ] && [ "$FAN_RPM" -ge 500 ]; then
          # Coming down from manual BOOST: fan is already spinning, switch smoothly to SMU curve
          echo 2 > "$h/pwm1_enable"
        else
          # Coming up from ZEROFAN or cold start: wake THM PWM block first
          wake_and_set_stock_curve "$h"
        fi
        CURRENT_MODE["$slot"]="AUTO"
        LAST_LOGGED_PWM["$slot"]=0
        sleep 1
        NEW_RPM=$(cat "$h/fan1_input" 2>/dev/null || echo 0)
        log "[$slot] Zone 2 -> AUTO (SMU Stock Curve, ${NEW_RPM} RPM) | Max=${MAX_TEMP}°C (Edge=${T_EDGE}°C, Hotspot=${T_JUNC}°C, VRAM=${T_MEM}°C)"
      fi
    fi
  done

  sleep "$POLL_INTERVAL"
done
