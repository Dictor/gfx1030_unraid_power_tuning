# gfx1030 (Radeon PRO W6800) Powercap & Zero-Fan Unlock for Unraid

> **Reference / Original Source**:  
> [gfx1030 Wiki - Power Tuning & Floor Unlock](https://blivioniag.github.io/gfx1030-wiki/tuning/power.html)

Unlocks two hardware-level features locked by the factory VBIOS on **AMD Radeon PRO W6800** (Navi 21 / `0x1002:0x73a3`) running on **Unraid OS (Linux 6.18.x-Unraid)**:
1. **120W Minimum Power Cap Unlock (`patches/w6800-powercap-min-120W.patch`)**: Lowers the minimum PPT limit down to **120W** (factory locked at 200W/250W).
2. **Zero-Fan (0 RPM) + Stock SMU Curve Unlock (`patches/w6800-zerofan-unlock.patch`)**: Unlocks SMU Zero-RPM (`0 RPM` complete fan stop) when `pwm1=0` is written in manual mode, while preserving a **60°C hardware fail-safe** and restoring the **100% stock VBIOS SMU fan curve (1,200 RPM+)** whenever `pwm1_enable=2` (auto) is selected.

---

## Key Concepts

1. **120W Minimum Powercap Patch (`patches/w6800-powercap-min-120W.patch`)**:
   Modifies `sienna_cichlid_ppt.c` so `sienna_cichlid_get_power_limit()` reports a `min_power_limit` of **120W** exclusively for W6800 (`0x1002:0x73a3`). Other GPUs (e.g. RX 6900 XT / 6950 XT) remain untouched.
2. **Zero-Fan (0 RPM) Method A Patch (`patches/w6800-zerofan-unlock.patch`)**:
   On Navi 21, writing `pwm1=0` in standard Linux manual PWM mode clamps the fan at **777 RPM** inside SMU firmware. This patch hooks W6800 (`0x1002:0x73a3`) fan control in `sienna_cichlid_ppt.c`:
   - `echo 1 > pwm1_enable && echo 0 > pwm1`: Enables SMU `FanZeroRpmEnable = 1` (`FanStopTemp = 55°C`, hardware fail-safe `FanStartTemp = 60°C`) in `PPTable_t` / `OverDriveTable_t` and hands control to the SMU Zero-RPM state machine so the fan physically stops (**0 RPM**).
   - `echo 1 > pwm1_enable && echo N > pwm1` (`N > 0`): Disables `FanZeroRpmEnable` and sets standard manual PWM speed (`>= 777 RPM`).
   - `echo 2 > pwm1_enable`: Restores `FanZeroRpmEnable = 0` and enables SMU automatic fan control, returning 100% to the **stock W6800 VBIOS fan curve (1,200 RPM+)**.
3. **Hot-Swap Persistence**:
   Unraid loads modules from RAM. We replace `/lib/modules/.../amdgpu.ko` at runtime and configure `/boot/config/go` (or `/boot/bzmodules`) to persist across reboots.

---

## Quick Start (How-To)

### 1. Build `amdgpu.ko` on WSL (Ubuntu)

Run the interactive build script in WSL. It prompts you in English to choose which patch(es) to include (`[1] Powercap only`, `[2] Zero-Fan only`, or `[3] Both [Default]`), fetches the matching Unraid kernel source, applies the selected patch(es), and verifies the compiled ELF symbols.

```bash
cd /path/to/gfx1030_unraid_amdgpu_patch
chmod +x build_wsl.sh
./build_wsl.sh 6.18.58-Unraid
```

Non-interactive CLI flags are also supported:
```bash
./build_wsl.sh 6.18.58-Unraid --both
./build_wsl.sh 6.18.58-Unraid --powercap-only
./build_wsl.sh 6.18.58-Unraid --zerofan-only
```
Output binary: `build/output/amdgpu.ko` (plus `.ko.xz` and `.ko.zst`).

---

### 2. Copy Module to Unraid

```bash
scp build/output/amdgpu.ko root@<UNRAID_IP>:~/amdgpu.ko
```

---

### 3. Hot-Swap & Verify on Unraid

In the Unraid terminal (`root@unraid:~#`):

```bash
# 1. Replace running module in tmpfs
cp -f ~/amdgpu.ko /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
rm -f /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.xz
rm -f /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst

# 2. Update dependencies and reload
depmod -a
modprobe -r amdgpu 2>/dev/null || true
modprobe amdgpu

# 3. Verify patches in dmesg
dmesg | grep -i "W6800"
```

Expected output (when built with Both patches):
```text
amdgpu 0000:07:00.0: amdgpu: W6800 zerofan: unlocked SMU Zero-RPM capability (fail-safe 60 C) on 0000:07:00.0
amdgpu 0000:07:00.0: amdgpu: W6800 powerfix: allowing PPT limit down to 120 W on 0000:07:00.0
```

---

### 4. Usage: Power Cap & Zero-Fan Control

#### A. Set Target Power Cap (e.g. 180W)
```bash
# Verify minimum floor is unlocked to 120W (120000000 uW)
cat /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap_min

# Set power cap to 180W (180000000 uW)
echo 180000000 > /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap
```

#### B. Toggle Zero-Fan (0 RPM) & Stock SMU Curve
```bash
HWMON=$(ls -d /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*)

# Enter Zero-Fan mode (0 RPM, with 60°C SMU hardware fail-safe)
echo 1 > "$HWMON/pwm1_enable"
echo 0 > "$HWMON/pwm1"
cat "$HWMON/fan1_input"   # -> 0

# Return to 100% Stock W6800 SMU Automatic Fan Curve (1,200 RPM+)
echo 2 > "$HWMON/pwm1_enable"
cat "$HWMON/fan1_input"   # -> ~1200+
```

---

### 5. Make Persistent Across Reboots

Store the module on your flash drive and register a hook in `/boot/config/go` (or repack `/boot/bzmodules` via `scripts/repack_bzmodules.sh`):

```bash
# 1. Store module on flash drive
mkdir -p /boot/config/custom/w6800
cp -f ~/amdgpu.ko /boot/config/custom/w6800/amdgpu.ko

# 2. Add startup hook to /boot/config/go
cat << 'EOF' >> /boot/config/go

# --- W6800 GFX1030 UNLOCK & POWERCAP HOOK ---
(
  if [ -f /boot/config/custom/w6800/amdgpu.ko ]; then
    TARGET_DIR="/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu"
    cp -f /boot/config/custom/w6800/amdgpu.ko "$TARGET_DIR/amdgpu.ko"
    rm -f "$TARGET_DIR/amdgpu.ko.xz" "$TARGET_DIR/amdgpu.ko.zst"
    depmod -a
    modprobe -r amdgpu 2>/dev/null || true
    modprobe amdgpu 2>/dev/null || true
  fi

  for i in $(seq 1 30); do
    if [ -f /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap ]; then
      echo 180000000 > /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap 2>/dev/null && break
    fi
    sleep 1
  done
) >/var/log/w6800-powercap-boot.log 2>&1 &
# --- END W6800 HOOK ---
EOF
```

---

## Repository Files

| File | Description |
|---|---|
| `build_wsl.sh` | Interactive WSL Ubuntu `amdgpu.ko` builder (supports choosing Powercap, Zero-Fan, or Both). |
| `patches/w6800-powercap-min-120W.patch` | Kernel patch lowering W6800 minimum powercap floor to 120W. |
| `patches/w6800-zerofan-unlock.patch` | Kernel patch (Method A) unlocking W6800 0 RPM Zero-Fan on `pwm1=0` and restoring stock SMU curve on `pwm1_enable=2`. |
| `scripts/w6800-array-start.sh` | Unraid Array startup script to hot-swap `amdgpu.ko` and set 140W power limit on all W6800 GPUs (`0x1002:0x73a3`). |
| `scripts/w6800-fan-control.sh` | Unraid 3-Zone multi-GPU fan controller (`<= 45°C` [exit `>= 49°C`] -> 0 RPM Zero-Fan, Stock SMU Curve, `>= 70°C` [exit `<= 65°C`] -> 1,700+ RPM High-Power P-Control). |
| `AGENTS.md` | Project agent rules (including mandatory auto-commit & push on file changes). |
| `zero_fan_plan.md` | Technical architecture and usage guide for the W6800 Zero-Fan (0 RPM) + Stock SMU curve implementation. |
| `KERNEL_INDEPENDENCE_PLAN.md` | Self-sufficient Unraid kernel `.config` extraction and zero-dependency maintenance guide. |
