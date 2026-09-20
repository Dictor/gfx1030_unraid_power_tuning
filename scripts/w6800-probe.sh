#!/usr/bin/env bash
# w6800-probe.sh - Hardware & Powercap diagnostic probe for Radeon PRO W6800 on Unraid
#
# Usage:
#   sudo ./scripts/w6800-probe.sh

set -euo pipefail

TARGET_VENDOR="0x1002"
TARGET_DEVICE="0x73a3" # Radeon PRO W6800

echo "================================================================="
echo "       Radeon PRO W6800 Unraid Hardware & Powercap Probe         "
echo "================================================================="

# 1. System & Kernel information
KREL="$(uname -r)"
echo "[*] System Information:"
echo "    - Kernel Release : $KREL"
if [ -f /etc/unraid-version ]; then
  # shellcheck source=/dev/null
  . /etc/unraid-version
  echo "    - Unraid Version : ${version:-Unknown}"
fi
echo ""

# 2. PCI Device Detection
echo "[*] PCI Bus Scan for AMD GPUs (Vendor 0x1002):"
W6800_COUNT=0
OTHER_AMD_COUNT=0

for dev_path in /sys/bus/pci/devices/*; do
  [ -f "$dev_path/vendor" ] || continue
  ven="$(cat "$dev_path/vendor" 2>/dev/null || true)"
  [ "$ven" = "$TARGET_VENDOR" ] || continue
  dev="$(cat "$dev_path/device" 2>/dev/null || true)"
  sven="$(cat "$dev_path/subsystem_vendor" 2>/dev/null || true)"
  sdev="$(cat "$dev_path/subsystem_device" 2>/dev/null || true)"
  slot="$(basename "$dev_path")"

  if [ "$dev" = "$TARGET_DEVICE" ]; then
    W6800_COUNT=$((W6800_COUNT + 1))
    echo "    [+] Target GPU Found: Slot $slot"
    echo "        Vendor:Device      : $ven:$dev (Radeon PRO W6800)"
    echo "        Subsystem ID       : $sven:$sdev"
    [ -d "$dev_path/driver" ] && drv="$(basename "$(readlink -f "$dev_path/driver")")" || drv="unbound"
    echo "        Active Driver      : $drv"
  else
    # Distinguish other AMD GPUs (e.g. RX 6950 XT: 73a5, RX 6800/6900 XT: 73bf, V620: 73a1)
    OTHER_AMD_COUNT=$((OTHER_AMD_COUNT + 1))
    echo "    [-] Other AMD Device : Slot $slot ($ven:$dev, Subsys: $sven:$sdev)"
    echo "        Status             : Kept 100% stock / Untouched"
  fi
done

if [ "$W6800_COUNT" -eq 0 ]; then
  echo ""
  echo "[-] ERROR: No Radeon PRO W6800 (Device ID 0x73a3) found on PCI bus!"
  exit 1
fi
echo ""

# 3. Kernel Log (dmesg) Powerfix Verification
echo "[*] Kernel Driver Patch (dmesg) Status:"
if dmesg | grep -qi "W6800 powerfix"; then
  echo "    [+] PATCH DETECTED: 'W6800 powerfix' marker present in dmesg!"
  dmesg | grep -i "W6800 powerfix" | tail -n 2 | sed 's/^/        /'
else
  echo "    [-] Patch marker NOT found in dmesg."
  echo "        (Stock amdgpu driver active, or powerfix patch not loaded yet)"
fi
echo ""

# 4. HWMON Power & Sensor Analysis
echo "[*] HWMON Power Analysis for W6800:"
for h in /sys/class/hwmon/hwmon*; do
  [ -f "$h/name" ] || continue
  grep -qi "amdgpu" "$h/name" || continue
  d="$(readlink -f "$h/device" 2>/dev/null || true)"
  [ -n "$d" ] || continue
  [ "$(cat "$d/vendor" 2>/dev/null || true)" = "$TARGET_VENDOR" ] || continue
  [ "$(cat "$d/device" 2>/dev/null || true)" = "$TARGET_DEVICE" ] || continue

  slot="$(basename "$d")"
  echo "    ---------------------------------------------------------"
  echo "    Device Slot: $slot  (HWMON: $(basename "$h"))"

  # Power Limits
  cur_pwr="N/A"
  min_pwr="N/A"
  max_pwr="N/A"
  input_pwr="N/A"
  [ -f "$h/power1_cap" ] && cur_pwr="$(( $(cat "$h/power1_cap") / 1000000 )) W"
  [ -f "$h/power1_cap_min" ] && min_pwr="$(( $(cat "$h/power1_cap_min") / 1000000 )) W"
  [ -f "$h/power1_cap_max" ] && max_pwr="$(( $(cat "$h/power1_cap_max") / 1000000 )) W"
  if [ -f "$h/power1_average" ]; then
    input_pwr="$(( $(cat "$h/power1_average") / 1000000 )) W"
  elif [ -f "$h/power1_input" ]; then
    input_pwr="$(( $(cat "$h/power1_input") / 1000000 )) W"
  fi

  echo "    Power Limits:"
  echo "        Current Cap       : $cur_pwr"
  echo "        Minimum Floor     : $min_pwr"
  echo "        Maximum Cap       : $max_pwr"
  echo "        Realtime Draw     : $input_pwr"

  if [ "$min_pwr" = "120 W" ]; then
    echo "        Floor Status      : [UNLOCKED 120W] (Ready for low-power caps down to 120W)"
  else
    echo "        Floor Status      : [STOCK LOCKED] (Minimum is $min_pwr; patch required for <=180W)"
  fi

  # Temperatures
  edge_temp="N/A"
  junc_temp="N/A"
  mem_temp="N/A"
  [ -f "$h/temp1_input" ] && edge_temp="$(( $(cat "$h/temp1_input") / 1000 )) °C"
  [ -f "$h/temp2_input" ] && junc_temp="$(( $(cat "$h/temp2_input") / 1000 )) °C"
  [ -f "$h/temp3_input" ] && mem_temp="$(( $(cat "$h/temp3_input") / 1000 )) °C"
  echo "    Temperatures:"
  echo "        Edge / Junction   : $edge_temp / $junc_temp"
  echo "        VRAM Memory       : $mem_temp"
done

echo "================================================================="
echo "[*] Probe complete."
