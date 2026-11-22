#!/usr/bin/env bash
# w6800-fan-control.sh - Always-Manual MMIO Fan Controller for Radeon PRO W6800
#   Sets pwm1_enable=1 ONCE at startup and never toggles auto(2)<->manual(1) during runtime,
#   eliminating SMU mailbox contention during ROCm workloads while preserving 0 RPM idle.
#   Requires amdgpu.ko with Option A state guard in patches/w6800-zerofan-unlock.patch.
#
#   Zone 1 (IDLE)  : <= 45°C for 3 ticks (15s, exit >= 49°C) -> PWM 0 (0 RPM) or IDLE_MANUAL_PWM
#   Zone 2 (LOW)   : 49°C .. 69°C                            -> Linear Manual PWM 52..68 (~1150-1530 RPM)
#   Zone 3 (BOOST) : >= 70°C                                 -> P-Control PWM 75+ (~1700+ RPM)
#   All active speeds pass through Asymmetric Smoother (Instant Attack / Slow Decay + Deadband).
#
# Usage:
#   ./w6800-fan-control.sh              # Self-daemonize in background (Unraid User Scripts / Array Start)
#   ./w6800-fan-control.sh --stop       # Stop daemon and restore stock SMU fan curve
#   ./w6800-fan-control.sh --foreground # Run in foreground for debugging

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Idle / Zero-Fan settings (°C, based on max of Hotspot & VRAM)
ENABLE_ZERO_FAN=1        # 1 = 0 RPM when idle <= 45°C, 0 = always stay at IDLE_MANUAL_PWM (~777 RPM)
ZERO_FAN_TEMP=45         # Enter Idle/Zero-Fan when <= 45°C
ZERO_FAN_HOLD_TICKS=3    # Require 3 consecutive <=45°C ticks (15s) before stopping fan from active
ACTIVE_FAN_TEMP=49       # Wake from Idle/Zero-Fan when >= 49°C (4°C hysteresis)
IDLE_MANUAL_PWM=35       # Fallback manual PWM (~777 RPM) when ENABLE_ZERO_FAN=0

# Continuous Manual PWM Curve (PWM 0..255; PWM 52 ≈ 1,150 RPM, 75 ≈ 1,700 RPM, 100 ≈ 2,264 RPM)
LOW_BASE_TEMP=49         # Low-noise zone base temperature
LOW_BASE_PWM=52          # Starting PWM at 49°C (~1,150 RPM)
LOW_MAX_PWM=68           # Target PWM at 69°C (~1,530 RPM)
BOOST_TEMP=70            # Boost threshold temperature
BOOST_BASE_PWM=75        # Starting PWM at 70°C (~1,700 RPM)
BOOST_KP=7               # Proportional gain above 70°C: +7 PWM (~158 RPM) per 1°C
MAX_PWM=255              # Max PWM ceiling (100%)

# Asymmetric Smoother (Instant Attack on rise, 5s-calibrated Slow Decay on drop + Deadband)
DECAY_KEEP=65            # Keep 65% of current PWM + 35% of target PWM per 5s tick when cooling
PWM_DEADBAND=4           # Skip pwm1 writes when |RAW_PWM - CUR_PWM| < 4 (~90 RPM)

# System & device identifiers
POLL_INTERVAL=5          # 5s polling minimizes SMU metrics table mailbox queries
TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3"   # Radeon PRO W6800
PID_FILE="/var/run/w6800-fan-control.pid"
LOG_FILE="/var/log/w6800-fan-control.log"

# ==============================================================================
# CORE FUNCTIONS
# ==============================================================================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [W6800-FanCtrl] $*"
  logger -t "W6800-FanCtrl" "$*" 2>/dev/null || true
}

find_all_w6800_hwmons() {
  local h d vendor device
  for h in /sys/class/hwmon/hwmon*; do
    [ -f "$h/name" ] && grep -qi "amdgpu" "$h/name" || continue
    d="$(readlink -f "$h/device" 2>/dev/null || true)"
    [ -n "$d" ] && [ -w "$h/pwm1_enable" ] && [ -w "$h/pwm1" ] || continue
    read -r vendor < "$d/vendor" 2>/dev/null || continue
    read -r device < "$d/device" 2>/dev/null || continue
    [ "$vendor" = "$TARGET_VENDOR" ] && [ "$device" = "$TARGET_DEVICE" ] && echo "$h"
  done
}

wake_and_set_stock_curve() {
  local h="$1"
  echo 1  > "$h/pwm1_enable" 2>/dev/null || true
  echo 65 > "$h/pwm1"        2>/dev/null || true
  sleep 1
  echo 2  > "$h/pwm1_enable" 2>/dev/null || true
}

restore_all_stock_curves() {
  local h slot
  for h in $(find_all_w6800_hwmons); do
    slot="$(basename "$(readlink -f "$h/device" 2>/dev/null || echo unknown)")"
    wake_and_set_stock_curve "$h"
    log "[$slot] Restored W6800 fan to stock SMU automatic curve (pwm1_enable=2)."
  done
}

stop_existing_daemon() {
  local skip_restore="${1:-0}" sig="-TERM" p
  [ "$skip_restore" -eq 1 ] && sig="-9"

  local -A seen=()
  local pids=()
  [ -f "$PID_FILE" ] && pids+=("$(cat "$PID_FILE" 2>/dev/null || true)")
  for p in $(pgrep -f " --daemon" 2>/dev/null || true); do pids+=("$p"); done

  for p in "${pids[@]}"; do
    [ -n "$p" ] && [ -z "${seen[$p]:-}" ] || continue
    seen["$p"]=1
    if [ "$p" != "$$" ] && [ "$p" != "$PPID" ] && kill -0 "$p" 2>/dev/null; then
      log "Stopping previous W6800 fan controller instance (PID $p)..."
      pkill "$sig" -P "$p" 2>/dev/null || true
      kill "$sig" "$p" 2>/dev/null || true
      for _ in $(seq 1 25); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.2
      done
    fi
  done
  rm -f "$PID_FILE"
}

# ==============================================================================
# CLI ENTRYPOINT & DAEMONIZATION
# ==============================================================================
MODE="${1:-}"

if [ "$MODE" = "--stop" ]; then
  stop_existing_daemon 0
  restore_all_stock_curves
  exit 0
fi

if [ "$MODE" != "--daemon" ] && [ "$MODE" != "--foreground" ]; then
  stop_existing_daemon 1
  SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  setsid bash "$SCRIPT_PATH" --daemon </dev/null >>"$LOG_FILE" 2>&1 &
  log "W6800 Always-Manual Fan Controller daemon started (PID $!, Log: $LOG_FILE)."
  exit 0
fi

[ "$MODE" = "--foreground" ] && stop_existing_daemon 1
echo "$$" > "$PID_FILE"
trap 'trap - EXIT INT TERM; rm -f "$PID_FILE"; restore_all_stock_curves; exit 0' EXIT INT TERM

# ==============================================================================
# INITIALIZATION & DEVICE DISCOVERY (Logged Once; pwm1_enable=1 Set Once)
# ==============================================================================
HWMONS=()
for _ in $(seq 1 30); do
  mapfile -t HWMONS < <(find_all_w6800_hwmons)
  [ "${#HWMONS[@]}" -gt 0 ] && break
  sleep 1
done

if [ "${#HWMONS[@]}" -eq 0 ]; then
  log "ERROR: Could not find writable W6800 hwmon node within 30 seconds!" >&2
  exit 1
fi

log "Daemon active (Always-Manual | ZeroFan=${ENABLE_ZERO_FAN} <=${ZERO_FAN_TEMP}°C/${ZERO_FAN_HOLD_TICKS}ticks [exit >=${ACTIVE_FAN_TEMP}°C] | Curve ${LOW_BASE_TEMP}°C->${LOW_BASE_PWM}, ${BOOST_TEMP}°C->${BOOST_BASE_PWM}+ | Poll=${POLL_INTERVAL}s)."
for h in "${HWMONS[@]}"; do
  echo 1 > "$h/pwm1_enable" 2>/dev/null || true
  slot="$(basename "$(readlink -f "$h/device")")"
  log "Monitoring W6800 at PCI slot $slot ($h) [Always-Manual mode]."
done

# ==============================================================================
# MAIN CONTROL LOOP (Silent, Zero-Fork, MMIO Direct Polling)
# ==============================================================================
declare -A CURRENT_MODE CURRENT_PWM IDLE_TICKS LAST_TEMP

while true; do
  for h in "${HWMONS[@]}"; do
    [ -d "$h" ] || continue

    prev_t="${LAST_TEMP[$h]:-55}"
    fallback_mt=$(( prev_t * 1000 ))
    read -r t2 < "$h/temp2_input" 2>/dev/null || t2="$fallback_mt"
    read -r t3 < "$h/temp3_input" 2>/dev/null || t3="$fallback_mt"
    [ -n "$t2" ] || t2="$fallback_mt"
    [ -n "$t3" ] || t3="$fallback_mt"

    max_t=$(( (t2 > t3 ? t2 : t3) / 1000 ))
    LAST_TEMP["$h"]="$max_t"
    prev_mode="${CURRENT_MODE[$h]:-}"

    # 1. Idle / Zero-Fan state machine (no-op unless state enters IDLE)
    if [ "$max_t" -le "$ZERO_FAN_TEMP" ]; then
      IDLE_TICKS["$h"]=$(( ${IDLE_TICKS[$h]:-0} + 1 ))
      if [ "$prev_mode" = "IDLE" ]; then
        continue
      elif [ -z "$prev_mode" ] || [ "${IDLE_TICKS[$h]}" -ge "$ZERO_FAN_HOLD_TICKS" ]; then
        idle_pwm=$(( ENABLE_ZERO_FAN ? 0 : IDLE_MANUAL_PWM ))
        echo "$idle_pwm" > "$h/pwm1" 2>/dev/null || true
        CURRENT_MODE["$h"]="IDLE"
        CURRENT_PWM["$h"]="$idle_pwm"
        continue
      fi
    else
      IDLE_TICKS["$h"]=0
      if [ "$prev_mode" = "IDLE" ] && [ "$max_t" -lt "$ACTIVE_FAN_TEMP" ]; then
        continue
      fi
    fi

    # 2. Continuous Manual PWM Curve (49..69°C Low-Noise, >=70°C Boost)
    if [ "$max_t" -ge "$BOOST_TEMP" ]; then
      raw_pwm=$(( BOOST_BASE_PWM + (max_t - BOOST_TEMP) * BOOST_KP ))
    elif [ "$max_t" -le "$LOW_BASE_TEMP" ]; then
      raw_pwm="$LOW_BASE_PWM"
    else
      raw_pwm=$(( LOW_BASE_PWM + (max_t - LOW_BASE_TEMP) * (LOW_MAX_PWM - LOW_BASE_PWM) / (BOOST_TEMP - 1 - LOW_BASE_TEMP) ))
    fi
    [ "$raw_pwm" -lt "$LOW_BASE_PWM" ] && raw_pwm="$LOW_BASE_PWM"
    [ "$raw_pwm" -gt "$MAX_PWM" ] && raw_pwm="$MAX_PWM"

    # 3. Asymmetric Smoother (Instant Attack / Slow Decay) + Deadband
    cur_pwm="${CURRENT_PWM[$h]:-0}"
    diff=$(( raw_pwm > cur_pwm ? raw_pwm - cur_pwm : cur_pwm - raw_pwm ))

    if [ "$prev_mode" != "ACTIVE" ]; then
      target_pwm="$raw_pwm"
    elif [ "$diff" -lt "$PWM_DEADBAND" ]; then
      target_pwm="$cur_pwm"
    elif [ "$raw_pwm" -gt "$cur_pwm" ]; then
      target_pwm="$raw_pwm"
    else
      target_pwm=$(( (cur_pwm * DECAY_KEEP + raw_pwm * (100 - DECAY_KEEP)) / 100 ))
      [ "$target_pwm" -ge "$cur_pwm" ] && target_pwm=$(( cur_pwm - 1 ))
    fi

    # 4. Write pwm1 ONLY when waking from IDLE or PWM actually changes
    if [ "$prev_mode" != "ACTIVE" ] || [ "$target_pwm" != "$cur_pwm" ]; then
      echo "$target_pwm" > "$h/pwm1" 2>/dev/null || true
      CURRENT_PWM["$h"]="$target_pwm"
    fi
    CURRENT_MODE["$h"]="ACTIVE"
  done

  sleep "$POLL_INTERVAL"
done
