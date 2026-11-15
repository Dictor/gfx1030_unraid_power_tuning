#!/usr/bin/env bash
# build_wsl.sh - One-click amdgpu.ko builder for Radeon PRO W6800 on WSL Ubuntu
#
# Usage (inside WSL):
#   chmod +x build_wsl.sh
#   ./build_wsl.sh [KERNEL_VERSION] [--clean|-c] [--powercap-only|--zerofan-only|--both]
#
# Example:
#   ./build_wsl.sh 6.18.33-Unraid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWERCAP_PATCH="$SCRIPT_DIR/patches/w6800-powercap-min-120W.patch"
ZEROFAN_PATCH="$SCRIPT_DIR/patches/w6800-zerofan-unlock.patch"

TARGET_KREL="6.18.33-Unraid"
CLEAN_MODE=0
PATCH_CHOICE=""

for arg in "$@"; do
  case "$arg" in
    --clean|-c)
      CLEAN_MODE=1
      ;;
    --powercap-only)
      PATCH_CHOICE="1"
      ;;
    --zerofan-only)
      PATCH_CHOICE="2"
      ;;
    --both)
      PATCH_CHOICE="3"
      ;;
    *)
      if [[ "$arg" != -* ]]; then
        TARGET_KREL="$arg"
      fi
      ;;
  esac
done

BASE_KVER="${TARGET_KREL%%-*}" # 6.18.33
MAJOR_VER="${BASE_KVER%%.*}"   # 6

if [[ "$TARGET_KREL" == *-* ]]; then
  LOCALVERSION="-${TARGET_KREL#*-}"
else
  LOCALVERSION=""
fi

WORK_DIR="/tmp/amdgpu-build-${TARGET_KREL}"
OUT_DIR="$SCRIPT_DIR/build/output"

echo "================================================================="
echo "   Radeon PRO W6800 amdgpu.ko Builder (WSL / Linux Environment)  "
echo "================================================================="
echo "Target Kernel Version  : $TARGET_KREL (Base: $BASE_KVER)"
echo "Build Scratch Directory: $WORK_DIR"
echo "Output Directory       : $OUT_DIR"
echo "================================================================="
echo ""

# Interactive patch selection if not specified via CLI flags
if [ -z "$PATCH_CHOICE" ]; then
  echo "Select which W6800 patch(es) to include in amdgpu.ko:"
  echo "  [1] 120W Minimum Powercap Unlock only (w6800-powercap-min-120W.patch)"
  echo "  [2] Zero-Fan (0 RPM) Unlock only      (w6800-zerofan-unlock.patch)"
  echo "  [3] Both Patches (120W Powercap + Zero-Fan Unlock) [Default]"
  echo ""
  while true; do
    read -r -p "Enter selection [1-3] (default: 3): " USER_INPUT
    USER_INPUT="${USER_INPUT:-3}"
    case "$USER_INPUT" in
      1|2|3)
        PATCH_CHOICE="$USER_INPUT"
        break
        ;;
      *)
        echo "Invalid selection '$USER_INPUT'. Please enter 1, 2, or 3."
        ;;
    esac
  done
  echo ""
fi

APPLY_POWERCAP=0
APPLY_ZEROFAN=0
PATCH_DESC=""

case "$PATCH_CHOICE" in
  1)
    APPLY_POWERCAP=1
    PATCH_DESC="120W Minimum Powercap Unlock only"
    ;;
  2)
    APPLY_ZEROFAN=1
    PATCH_DESC="Zero-Fan (0 RPM) Unlock only"
    ;;
  3)
    APPLY_POWERCAP=1
    APPLY_ZEROFAN=1
    PATCH_DESC="Both (120W Minimum Powercap + Zero-Fan Unlock)"
    ;;
esac

echo "[*] Selected Patch Configuration: $PATCH_DESC"
if [ "$APPLY_POWERCAP" -eq 1 ]; then
  [ -f "$POWERCAP_PATCH" ] || { echo "[-] ERROR: Patch file missing at $POWERCAP_PATCH" >&2; exit 1; }
  echo "    - Powercap Patch : $POWERCAP_PATCH"
fi
if [ "$APPLY_ZEROFAN" -eq 1 ]; then
  [ -f "$ZEROFAN_PATCH" ] || { echo "[-] ERROR: Patch file missing at $ZEROFAN_PATCH" >&2; exit 1; }
  echo "    - Zero-Fan Patch : $ZEROFAN_PATCH"
fi
echo ""

if [ "$CLEAN_MODE" -eq 1 ] && [ -d "$WORK_DIR" ]; then
  echo "[*] Clean flag specified: Purging previous scratch directory $WORK_DIR..."
  rm -rf "$WORK_DIR"
fi

# 1. Check dependencies
echo "[*] Step 1/6: Checking required build tools..."
MISSING_PKGS=()
for cmd in gcc make bc bison flex wget tar xz nm patch; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_PKGS+=("$cmd")
  fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "[-] Missing tools: ${MISSING_PKGS[*]}"
  echo "    Please run: sudo apt-get update && sudo apt-get install -y build-essential bc bison flex libelf-dev libssl-dev wget xz-utils patch"
  exit 1
fi
echo "    All required build tools found."

# 2. Download Kernel Source
mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

UNRAID_TARBALL="linux-${TARGET_KREL}.tar.xz"
UNRAID_RELEASE_URL="https://github.com/ich777/unraid_kernel/releases/download/${TARGET_KREL}/${UNRAID_TARBALL}"
VANILLA_TARBALL="linux-${BASE_KVER}.tar.xz"
VANILLA_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/${VANILLA_TARBALL}"

echo ""
echo "[*] Step 2/6: Acquiring kernel source tree for $TARGET_KREL..."
IS_UNRAID_TREE=0

if [ -f "$UNRAID_TARBALL" ]; then
  echo "    Found cached official Unraid kernel archive: $UNRAID_TARBALL"
  TARBALL_NAME="$UNRAID_TARBALL"
  IS_UNRAID_TREE=1
elif wget --spider -q "$UNRAID_RELEASE_URL" 2>/dev/null; then
  echo "    [+] Detected official pre-configured Unraid kernel release on GitHub!"
  echo "        URL: $UNRAID_RELEASE_URL"
  echo "        Downloading $UNRAID_TARBALL ..."
  wget --show-progress -q "$UNRAID_RELEASE_URL" -O "$UNRAID_TARBALL"
  TARBALL_NAME="$UNRAID_TARBALL"
  IS_UNRAID_TREE=1
else
  echo "    Official Unraid tarball not available online. Falling back to kernel.org vanilla..."
  TARBALL_NAME="$VANILLA_TARBALL"
  if [ ! -f "$TARBALL_NAME" ]; then
    echo "    Downloading $TARBALL_NAME from kernel.org ..."
    wget --show-progress -q "$VANILLA_URL" || {
      echo "    Retrying with historic archive path..."
      wget --show-progress -q "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/historic/${TARBALL_NAME}"
    }
  else
    echo "    Found cached $TARBALL_NAME, skipping download."
  fi
fi

# 3. Extract source tree
echo ""
echo "[*] Step 3/6: Extracting kernel source tree to fast WSL scratch..."
# Check for existing extraction
if [ "$IS_UNRAID_TREE" -eq 1 ]; then
  CANDIDATE_DIR="$WORK_DIR/linux-${TARGET_KREL}"
else
  CANDIDATE_DIR="$WORK_DIR/linux-${BASE_KVER}"
fi

if [ ! -d "$CANDIDATE_DIR" ] || [ ! -f "$CANDIDATE_DIR/Makefile" ]; then
  echo "    Extracting $TARBALL_NAME (this may take a minute)..."
  tar -xf "$TARBALL_NAME"
fi

if [ -d "$WORK_DIR/linux-${TARGET_KREL}" ]; then
  SRC_DIR="$WORK_DIR/linux-${TARGET_KREL}"
elif [ -d "$WORK_DIR/linux-${BASE_KVER}" ]; then
  SRC_DIR="$WORK_DIR/linux-${BASE_KVER}"
else
  SRC_DIR="$(find "$WORK_DIR" -maxdepth 2 -name "Makefile" -exec grep -l "SUBLEVEL" {} + 2>/dev/null | head -n 1 | xargs -r dirname)"
fi

[ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/Makefile" ] || { echo "[-] ERROR: Kernel source root not found!" >&2; exit 1; }
echo "    Kernel source located at: $SRC_DIR"

# 3.1 Enforce clean build of amdgpu objects to prevent invalid relocation errors
echo "    Cleaning any previous amdgpu build objects to prevent relocation corruption..."
make -C "$SRC_DIR" M=drivers/gpu/drm/amd clean >/dev/null 2>&1 || true
find "$SRC_DIR/drivers/gpu/drm/amd" -type f \( -name "*.o" -o -name "*.ko" -o -name "*.cmd" -o -name "*.mod*" \) -delete 2>/dev/null || true

# 4. Apply selected W6800 patch(es)
echo ""
echo "[*] Step 4/6: Applying selected W6800 patch(es) to sienna_cichlid_ppt.c..."
PPT_FILE="$SRC_DIR/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c"
PPT_ORIG="${PPT_FILE}.orig"

# Keep or restore a pristine backup of sienna_cichlid_ppt.c so switching patch
# combinations across runs always starts from a clean unpatched file.
if [ ! -f "$PPT_ORIG" ]; then
  if grep -qE "sienna_cichlid_w6800_min_powercap_fix|sienna_cichlid_w6800_zerofan_unlock" "$PPT_FILE" 2>/dev/null; then
    tar -xf "$WORK_DIR/$TARBALL_NAME" --wildcards "*sienna_cichlid_ppt.c" -O > "$PPT_ORIG"
  else
    cp "$PPT_FILE" "$PPT_ORIG"
  fi
fi
cp "$PPT_ORIG" "$PPT_FILE"

if [ "$APPLY_POWERCAP" -eq 1 ]; then
  echo "    Applying 120W minimum powercap patch (w6800-powercap-min-120W.patch)..."
  (cd "$SRC_DIR" && patch -p1 < "$POWERCAP_PATCH")
  echo "    [+] 120W minimum powercap patch applied!"
fi

if [ "$APPLY_ZEROFAN" -eq 1 ]; then
  echo "    Applying Zero-Fan (0 RPM) unlock patch (w6800-zerofan-unlock.patch)..."
  (cd "$SRC_DIR" && patch -p1 < "$ZEROFAN_PATCH")
  echo "    [+] Zero-Fan (0 RPM) unlock patch applied!"
fi

# 5. Prepare Kernel Headers & Kbuild
echo ""
echo "[*] Step 5/6: Configuring kernel headers and build environment..."
cd "$SRC_DIR"

if [ -f "$SCRIPT_DIR/unraid-kernel.config" ]; then
  echo "    [+] Found custom user config (unraid-kernel.config)!"
  cp "$SCRIPT_DIR/unraid-kernel.config" .config
elif [ -f "$SCRIPT_DIR/config.gz" ]; then
  echo "    [+] Found custom config.gz! Decompressing..."
  zcat "$SCRIPT_DIR/config.gz" > .config
elif [ "$IS_UNRAID_TREE" -eq 1 ] && [ -f .config ]; then
  echo "    [+] Using official Unraid pre-configured .config!"
else
  echo "    Generating base kernel defconfig..."
  make defconfig >/dev/null
fi

# Strip certificate requirements that halt standalone out-of-tree compiles
if [ -f scripts/config ]; then
  scripts/config --set-str SYSTEM_TRUSTED_KEYS "" || true
  scripts/config --set-str SYSTEM_REVOCATION_KEYS "" || true
  scripts/config --set-str MODULE_SIG_KEY "" || true
  scripts/config --disable MODULE_SIG_ALL || true

  # Ensure vermagic matches target (e.g. -Unraid)
  if [ -n "$LOCALVERSION" ]; then
    scripts/config --set-str CONFIG_LOCALVERSION "$LOCALVERSION" || true
  fi

  # In vanilla builds, hibernation causes unresolved symbol pm_hibernation_mode_is_suspend
  if [ "$IS_UNRAID_TREE" -eq 0 ]; then
    scripts/config --disable CONFIG_HIBERNATION || true
  fi

  # Ensure DRM and AMDGPU drivers are selected as modules
  scripts/config --enable CONFIG_DRM || true
  scripts/config --module CONFIG_DRM_AMDGPU || true
  scripts/config --enable CONFIG_DRM_AMDGPU_SI || true
  scripts/config --enable CONFIG_DRM_AMDGPU_CIK || true
  scripts/config --enable CONFIG_DRM_AMDGPU_USERPTR || true
  scripts/config --enable CONFIG_DRM_AMD_DC || true
  scripts/config --enable CONFIG_DRM_AMD_DC_FP || true
  scripts/config --enable CONFIG_HSA_AMD || true
  scripts/config --enable CONFIG_HSA_AMD_SVM || true
  scripts/config --module CONFIG_DRM_SCHED || true
  make olddefconfig >/dev/null
fi

echo "    Preparing module headers..."
make prepare >/dev/null
make modules_prepare >/dev/null

# 6. Compile amdgpu.ko
NCPU="$(nproc)"
echo ""
echo "[*] Step 6/6: Compiling amdgpu.ko using $NCPU CPU threads..."
make -j"$NCPU" KBUILD_MODPOST_WARN=1 M=drivers/gpu/drm/amd/amdgpu modules

BUILT_KO="$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
if [ ! -f "$BUILT_KO" ]; then
  echo "[-] ERROR: Compilation failed! amdgpu.ko was not generated." >&2
  exit 1
fi

# Verify exported patch symbols
echo ""
echo "[*] Verifying compiled binary ($PATCH_DESC)..."
if [ "$APPLY_POWERCAP" -eq 1 ]; then
  POWERCAP_SYMBOL=$(nm "$BUILT_KO" 2>/dev/null | grep "sienna_cichlid_w6800_min_powercap_fix" || true)
  if [ -n "$POWERCAP_SYMBOL" ]; then
    echo "    [+] Powercap patch symbol verified:"
    echo "        $POWERCAP_SYMBOL"
  else
    echo "[-] ERROR: Powercap patch function (sienna_cichlid_w6800_min_powercap_fix) missing in built module binary!" >&2
    exit 1
  fi
fi

if [ "$APPLY_ZEROFAN" -eq 1 ]; then
  ZEROFAN_SYMBOL=$(nm "$BUILT_KO" 2>/dev/null | grep "sienna_cichlid_w6800_zerofan_unlock" || true)
  if [ -n "$ZEROFAN_SYMBOL" ]; then
    echo "    [+] Zero-Fan patch symbol verified:"
    echo "        $ZEROFAN_SYMBOL"
  else
    echo "[-] ERROR: Zero-Fan patch function (sienna_cichlid_w6800_zerofan_unlock) missing in built module binary!" >&2
    exit 1
  fi
fi

# Package and copy artifacts to project output directory
cp "$BUILT_KO" "$OUT_DIR/amdgpu.ko"
echo "    Compressing XZ version..."
xz -c -9 "$BUILT_KO" > "$OUT_DIR/amdgpu.ko.xz"

if command -v zstd >/dev/null 2>&1; then
  echo "    Compressing Zstandard version..."
  zstd -q -19 -f -c "$BUILT_KO" > "$OUT_DIR/amdgpu.ko.zst"
fi

echo ""
echo "================================================================="
echo "[+] BUILD SUCCESSFUL!"
echo "================================================================="
echo "Patch Configuration: $PATCH_DESC"
echo "Artifacts generated in: $OUT_DIR"
ls -lh "$OUT_DIR"/amdgpu.ko*
echo ""
echo "Next Steps for Unraid Server:"
echo "1. Copy '$OUT_DIR/amdgpu.ko' to '/boot/config/custom/w6800/amdgpu.ko' on Unraid."
echo "2. Run 'scripts/w6800-array-start.sh' (for hot-swap & 140W powercap)"
echo "   and 'scripts/w6800-fan-control.sh' (for <=45C Zero-Fan + SMU stock curve)."
echo "================================================================="
