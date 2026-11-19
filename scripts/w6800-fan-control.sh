#!/usr/bin/env bash
# w6800-fan-control.sh - Multi-GPU 3-Zone Fan Controller for Radeon PRO W6800
#   Zone 1 (ZEROFAN): <= 45°C (exits >= 49°C) -> 0 RPM
#   Zone 2 (AUTO)   : Stock SMU Curve (pwm1_enable=2, ~1150-1500 RPM)
#   Zone 3 (BOOST)  : >= 70°C (exits <= 65°C) -> 1700+ RPM P-Control + Asymmetric Smoother
#
# Usage:
#   ./w6800-fan-control.sh              # Self-daemonize in background (Unraid User Scripts / Array Start)
#   ./w6800-fan-control.sh --stop       # Stop daemon and restore stock SMU fan curve
#   ./w6800-fan-control.sh --foreground # Run in foreground for debugging

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Zone temperature thresholds (°C, based on max of Edge, Hotspot, VRAM)
ZERO_FAN_TEMP=45         # Zone 1 entry (<= 45°C -> 0 RPM)
AUTO_FAN_TEMP=49         # Zone 1 exit / Zone 2 entry (>= 49°C -> Stock SMU)
BOOST_EXIT_TEMP=65       # Zone 3 exit / Zone 2 return (<= 65°C -> Stock SMU)
BOOST_FAN_TEMP=70        # Zone 3 entry (>= 70°C -> High-Power P-Control)

# Zone 3 P-Controller parameters (PWM 0..255; PWM 75 ≈ 1,700 RPM, PWM 100 ≈ 2,264 RPM)
BOOST_BASE_PWM=75        # Starting PWM at 70°C (~1,700 RPM)
BOOST_KP=7               # Gain above 70°C: +7 PWM (~158 RPM) per 1°C
BOOST_HYST_KP=4          # Cooldown slope in 66..69°C hysteresis band (4 PWM per 1°C)
BOOST_MIN_PWM=58         # Floor PWM in 66..69°C hysteresis band (~1,300 RPM)
BOOST_MAX_PWM=255        # Max PWM ceiling (100%)

# Zone 3 Asymmetric Smoother (Instant Attack on rise, Slow EMA Decay on drop + Deadband)
BOOST_DECAY_KEEP=80      # Keep 80% of current PWM + 20% of target PWM per 2s tick when cooling
BOOST_PWM_DEADBAND=3     # Hold PWM steady when |RAW_PWM - CUR_PWM| < 3 (~65 RPM)

# System & device identifiers
POLL_INTERVAL=2
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
  log "W6800 3-Zone Fan Controller daemon started (PID $!, Log: $LOG_FILE)."
  exit 0
fi

[ "$MODE" = "--foreground" ] && stop_existing_daemon 1
echo "$$" > "$PID_FILE"
trap 'trap - EXIT INT TERM; rm -f "$PID_FILE"; restore_all_stock_curves; exit 0' EXIT INT TERM

# ==============================================================================
# INITIALIZATION & DEVICE DISCOVERY (Logged Once)
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

log "Daemon active (Zone1 <=${ZERO_FAN_TEMP}°C [exit >=${AUTO_FAN_TEMP}°C] | Zone2 Stock SMU | Zone3 >=${BOOST_FAN_TEMP}°C [exit <=${BOOST_EXIT_TEMP}°C])."
for h in "${HWMONS[@]}"; do
  slot="$(basename "$(readlink -f "$h/device")")"
  log "Monitoring W6800 at PCI slot $slot ($h)."
done

# ==============================================================================
# MAIN CONTROL LOOP (Silent, Zero-Fork Polling)
# ==============================================================================
declare -A CURRENT_MODE CURRENT_BOOST_PWM

while true; do
  for h in "${HWMONS[@]}"; do
    [ -d "$h" ] || continue

    read -r t1  < "$h/temp1_input" 2>/dev/null || t1=50000
    read -r t2  < "$h/temp2_input" 2>/dev/null || t2=50000
    read -r t3  < "$h/temp3_input" 2>/dev/null || t3=50000
    read -r rpm < "$h/fan1_input"  2>/dev/null || rpm=0

    max_t=$(( t1 > t2 ? t1 : t2 ))
    max_t=$(( (max_t > t3 ? max_t : t3) / 1000 ))

    prev_mode="${CURRENT_MODE[$h]:-}"
    target_zone="$prev_mode"

    # 1. Zone selection with hysteresis
    if [ "$max_t" -le "$ZERO_FAN_TEMP" ]; then
      target_zone="ZEROFAN"
    elif [ "$max_t" -ge "$BOOST_FAN_TEMP" ]; then
      target_zone="BOOST"
    elif [ "$prev_mode" = "ZEROFAN" ]; then
      [ "$max_t" -ge "$AUTO_FAN_TEMP" ] && target_zone="AUTO"
    elif [ "$prev_mode" = "BOOST" ]; then
      [ "$max_t" -le "$BOOST_EXIT_TEMP" ] && target_zone="AUTO"
    else
      target_zone="AUTO"
    fi

    # 2. Zone execution
    case "$target_zone" in
      ZEROFAN)
        if [ "$prev_mode" != "ZEROFAN" ] || [ "$rpm" -gt 500 ]; then
          echo 1 > "$h/pwm1_enable"
          echo 0 > "$h/pwm1"
          CURRENT_MODE["$h"]="ZEROFAN"
          CURRENT_BOOST_PWM["$h"]=0
        fi
        ;;

      BOOST)
        delta=$(( max_t - BOOST_FAN_TEMP ))
        if [ "$delta" -ge 0 ]; then
          raw_pwm=$(( BOOST_BASE_PWM + delta * BOOST_KP ))
        else
          raw_pwm=$(( BOOST_BASE_PWM + delta * BOOST_HYST_KP ))
        fi
        [ "$raw_pwm" -lt "$BOOST_MIN_PWM" ] && raw_pwm="$BOOST_MIN_PWM"
        [ "$raw_pwm" -gt "$BOOST_MAX_PWM" ] && raw_pwm="$BOOST_MAX_PWM"

        cur_pwm="${CURRENT_BOOST_PWM[$h]:-0}"
        diff=$(( raw_pwm > cur_pwm ? raw_pwm - cur_pwm : cur_pwm - raw_pwm ))

        if [ "$prev_mode" != "BOOST" ] || [ "$raw_pwm" -gt "$cur_pwm" ]; then
          target_pwm="$raw_pwm"
        elif [ "$diff" -lt "$BOOST_PWM_DEADBAND" ]; then
          target_pwm="$cur_pwm"
        else
          target_pwm=$(( (cur_pwm * BOOST_DECAY_KEEP + raw_pwm * (100 - BOOST_DECAY_KEEP)) / 100 ))
          [ "$target_pwm" -ge "$cur_pwm" ] && target_pwm=$(( cur_pwm - 1 ))
        fi

        if [ "$prev_mode" != "BOOST" ] || [ "$target_pwm" != "$cur_pwm" ] || [ "$rpm" -lt 1200 ]; then
          echo 1 > "$h/pwm1_enable"
          echo "$target_pwm" > "$h/pwm1"
          CURRENT_BOOST_PWM["$h"]="$target_pwm"
        fi
        CURRENT_MODE["$h"]="BOOST"
        ;;

      AUTO)
        if [ "$prev_mode" != "AUTO" ] || [ "$rpm" -lt 500 ]; then
          if [ "$prev_mode" = "BOOST" ] && [ "$rpm" -ge 500 ]; then
            echo 2 > "$h/pwm1_enable"
          else
            wake_and_set_stock_curve "$h"
          fi
          CURRENT_MODE["$h"]="AUTO"
          CURRENT_BOOST_PWM["$h"]=0
        fi
        ;;
    esac
  done

  sleep "$POLL_INTERVAL"
done
