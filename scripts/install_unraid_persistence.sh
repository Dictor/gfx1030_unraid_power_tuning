#!/usr/bin/env bash
# install_unraid_persistence.sh - Install W6800 powercap persistence to Unraid USB flash drive
#
# Sets up /boot/config/custom/w6800, configures boot parameters in syslinux.cfg,
# and integrates startup hooks into /boot/config/go.
#
# Usage:
#   sudo ./scripts/install_unraid_persistence.sh [--watts 180]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_WATTS="180"
while [ $# -gt 0 ]; do
  case "$1" in
    --watts) TARGET_WATTS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

BOOT_DIR="/boot"
CUSTOM_DIR="/boot/config/custom/w6800"
GO_FILE="/boot/config/go"
SYSLINUX_FILE="/boot/syslinux/syslinux.cfg"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)" >&2; exit 1; }

echo "================================================================="
echo "      Radeon PRO W6800 Unraid Powercap Persistence Installer     "
echo "================================================================="

if [ ! -d "$BOOT_DIR/config" ]; then
  echo "[-] ERROR: /boot/config directory not found. Is this an Unraid host?" >&2
  exit 1
fi

# 1. Prepare persistence directory on flash drive
echo "[*] Step 1/3: Installing scripts to $CUSTOM_DIR ..."
mkdir -p "$CUSTOM_DIR"
cp "$SCRIPT_DIR/w6800-probe.sh" "$CUSTOM_DIR/"
cp "$SCRIPT_DIR/w6800-powercap-apply.sh" "$CUSTOM_DIR/"
[ -f "$REPO_ROOT/patches/w6800-powercap-min-120W.patch" ] && cp "$REPO_ROOT/patches/w6800-powercap-min-120W.patch" "$CUSTOM_DIR/"

# Copy patched amdgpu.ko if found in search paths
if [ -f "$REPO_ROOT/build/output/amdgpu.ko" ]; then
  cp -f "$REPO_ROOT/build/output/amdgpu.ko" "$CUSTOM_DIR/amdgpu.ko"
  echo "    [+] Installed built amdgpu.ko to $CUSTOM_DIR/amdgpu.ko"
elif [ -f "$SCRIPT_DIR/amdgpu.ko" ]; then
  cp -f "$SCRIPT_DIR/amdgpu.ko" "$CUSTOM_DIR/amdgpu.ko"
  echo "    [+] Installed amdgpu.ko to $CUSTOM_DIR/amdgpu.ko"
elif [ -f "/root/amdgpu.ko" ]; then
  cp -f "/root/amdgpu.ko" "$CUSTOM_DIR/amdgpu.ko"
  echo "    [+] Installed /root/amdgpu.ko to $CUSTOM_DIR/amdgpu.ko"
fi

chmod +x "$CUSTOM_DIR"/*.sh
echo "    [+] Scripts copied and marked executable."

# 2. Configure amdgpu.ppfeaturemask in syslinux.cfg
echo "[*] Step 2/3: Checking boot parameters in $SYSLINUX_FILE ..."
if [ -f "$SYSLINUX_FILE" ]; then
  if grep -q "amdgpu.ppfeaturemask=0xffffffff" "$SYSLINUX_FILE"; then
    echo "    [+] amdgpu.ppfeaturemask=0xffffffff already present in syslinux.cfg."
  else
    echo "    Backing up syslinux.cfg to syslinux.cfg.bak ..."
    cp "$SYSLINUX_FILE" "$SYSLINUX_FILE.bak.$(date +%Y%m%d_%H%M%S)"
    # Append parameter to kernel append line
    sed -i '/append initrd=\/bzroot/ s/$/ amdgpu.ppfeaturemask=0xffffffff/' "$SYSLINUX_FILE"
    echo "    [+] Appended amdgpu.ppfeaturemask=0xffffffff to syslinux.cfg."
  fi
else
  echo "    [!] Notice: syslinux.cfg not found at default path (UEFI or custom bootloader in use)."
fi

# 3. Configure boot script /boot/config/go
echo "[*] Step 3/3: Configuring startup hooks in $GO_FILE ..."
MARKER_START="# --- W6800 GFX1030 UNRAID POWERCAP HOOK (START) ---"
MARKER_END="# --- W6800 GFX1030 UNRAID POWERCAP HOOK (END) ---"

if grep -q "$MARKER_START" "$GO_FILE"; then
  echo "    Existing W6800 startup hook detected. Updating parameters..."
  sed -i "/$MARKER_START/,/$MARKER_END/d" "$GO_FILE"
fi

cat <<'EOF' >> "$GO_FILE"
# --- W6800 GFX1030 UNRAID POWERCAP HOOK (START) ---
# 1. Hot-swap patched amdgpu.ko driver if available
if [ -f /boot/config/custom/w6800/amdgpu.ko ]; then
  TARGET_MOD_DIR="/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu"
  if [ -d "$TARGET_MOD_DIR" ]; then
    cp -f /boot/config/custom/w6800/amdgpu.ko "$TARGET_MOD_DIR/amdgpu.ko"
    rm -f "$TARGET_MOD_DIR/amdgpu.ko.xz" "$TARGET_MOD_DIR/amdgpu.ko.zst"
    depmod -a
    modprobe -r amdgpu 2>/dev/null || true
    modprobe amdgpu 2>/dev/null || true
  fi
fi

# 2. Apply target power cap to Radeon PRO W6800 in background
EOF

cat <<EOF >> "$GO_FILE"
/bin/bash /boot/config/custom/w6800/w6800-powercap-apply.sh ${TARGET_WATTS} >/var/log/w6800-powercap-boot.log 2>&1 &
$MARKER_END
EOF

echo "    [+] Hook successfully installed into $GO_FILE."
echo ""
echo "================================================================="
echo "[+] W6800 powercap persistence installation complete!"
echo "    - Target Power Cap : ${TARGET_WATTS} W"
echo "    - Installed Tools  : $CUSTOM_DIR"
echo "================================================================="
