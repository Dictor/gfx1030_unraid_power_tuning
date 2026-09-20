# gfx1030 (Radeon PRO W6800 & etc...) powercap unlock for Unraid

> **Reference / Original Source**:  
> [gfx1030 Wiki - Power Tuning & Floor Unlock](https://blivioniag.github.io/gfx1030-wiki/tuning/power.html)

Enables lowering the power cap down to **120W** (factory locked at 200W/250W by VBIOS) on **AMD Radeon PRO W6800** (Navi 21 / `0x1002:0x73a3`) running on **Unraid OS (Linux 6.18.x-Unraid)**. (It works any other gfx1030 and RDNA2 not only w6800, but not tested.)

---

## Key Concept

1. **Kernel Patch (`patches/w6800-powercap-min-120W.patch`)**:
   Modifies `sienna_cichlid_ppt.c` so `sienna_cichlid_get_power_limit()` reports a `min_power_limit` of **120W** exclusively for W6800 (`0x73a3`). Other GPUs (e.g. RX 6900 XT / 6950 XT) remain untouched.
2. **Hot-Swap Persistence**:
   Unraid loads modules from RAM. We replace `/lib/modules/.../amdgpu.ko` at runtime and configure `/boot/config/go` to re-apply the module and desired powercap (e.g. 180W) automatically on every boot.

---

## Quick Start (How-To)

### 1. Build `amdgpu.ko` on WSL (Ubuntu)

Run the one-click build script in WSL. It automatically fetches the matching official Unraid kernel source (`ich777/unraid_kernel`), applies the patch, and compiles a clean module.

```bash
cd /path/to/gfx1030_unraid_amdgpu_patch
chmod +x build_wsl.sh
./build_wsl.sh --clean
```
Output binary: `build/output/amdgpu.ko`

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

# 2. Update dependencies and reload
depmod -a
modprobe -r amdgpu 2>/dev/null || true
modprobe amdgpu

# 3. Verify patch in dmesg
dmesg | grep -i "W6800"
```

Expected output:
```text
amdgpu 0000:07:00.0: amdgpu: W6800 powerfix: allowing PPT limit down to 120 W on 0000:07:00.0
```

---

### 4. Apply Target Power Cap (e.g. 180W)

```bash
# Verify minimum floor is unlocked to 120W (120000000 uW)
cat /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap_min

# Set power cap to 180W (180000000 uW)
echo 180000000 > /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap

# Verify active power cap
cat /sys/bus/pci/devices/0000:07:00.0/hwmon/hwmon*/power1_cap
```

---

### 5. Make Persistent Across Reboots

Store the module on your flash drive and register a hook in `/boot/config/go` (or use UserScript plugin):

```bash
# 1. Store module on flash drive
mkdir -p /boot/config/custom/w6800
cp -f ~/amdgpu.ko /boot/config/custom/w6800/amdgpu.ko

# 2. Add startup hook to /boot/config/go
cat << 'EOF' >> /boot/config/go

# --- W6800 GFX1030 120W UNLOCK & 180W POWERCAP HOOK ---
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
| `build_wsl.sh` | One-click kernel module builder for WSL Ubuntu (`--clean` supported). |
| `patches/w6800-powercap-min-120W.patch` | Kernel patch lowering W6800 floor to 120W. |
| `scripts/w6800-probe.sh` | Diagnostic probe for GPU detection and HWMON power status. |
| `scripts/w6800-powercap-apply.sh` | Script to apply wattage limits (e.g. `./scripts/w6800-powercap-apply.sh 180`). |
| `scripts/w6800-array-start.sh` | Array startup script to ensure module swap and set 180W limit. |
| `scripts/install_unraid_persistence.sh` | Automated installer for `/boot/config/custom/w6800` and `/boot/config/go`. |
