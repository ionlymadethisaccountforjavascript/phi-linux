#!/usr/bin/env bash
# Generate an Android boot image for a Phi Linux device port.
#
# This intentionally wraps a real mkbootimg instead of reimplementing the
# header format. Getting a boot header wrong means a device that hangs before
# it can print anything, and there is no upside to owning that code.
set -euo pipefail

DEVICE=""
KERNEL=iso-root/Image
DTB=""
INITRAMFS=""
OUT=""
HEADER_VERSION=""
CMDLINE=""
PAGESIZE=""
CMDLINE_EXTRA=""

usage() {
    cat <<'EOF'
usage: mkbootimg-device.sh --device <codename> [options]

  --device <codename>     device profile from config/devices/<codename>.conf
  --kernel <path>         kernel image (default iso-root/Image)
  --dtb <path>            device tree blob
  --initramfs <path>      initramfs cpio.gz
  --out <path>            output boot image
  --header-version <n>    0..4, overrides the device profile
  --cmdline <string>      overrides the device profile
  --pagesize <n>          overrides the device profile
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)   DEVICE="$2"; shift 2 ;;
        --kernel)   KERNEL="$2"; shift 2 ;;
        --dtb)      DTB="$2"; shift 2 ;;
        --initramfs) INITRAMFS="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --header-version) HEADER_VERSION="$2"; shift 2 ;;
        --cmdline)  CMDLINE="$2"; shift 2 ;;
        --pagesize) PAGESIZE="$2"; shift 2 ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$DEVICE" ]] || { echo "error: --device is required" >&2; exit 1; }

PROFILE="config/devices/${DEVICE}.conf"
if [[ ! -f "$PROFILE" ]]; then
    cat >&2 <<EOF
error: no device profile at $PROFILE

Copy config/devices/example.conf and fill in the values for your port.
Everything in there is device-specific and none of it transfers between SoCs:
  - header version (v2 appends the dtb to boot.img, v3/v4 puts it in vendor_boot)
  - the console the bootloader leaves usable for early debugging
  - page size and board id strings some bootloaders check
EOF
    exit 1
fi

# shellcheck disable=SC1090
source "$PROFILE"
HEADER_VERSION="${HEADER_VERSION:-${PHI_HEADER_VERSION:-2}}"
CMDLINE="${CMDLINE:-${PHI_CMDLINE:-}}"
PAGESIZE="${PAGESIZE:-${PHI_PAGESIZE:-2048}}"
DTB="${DTB:-${PHI_DTB:-}}"
ROOT_SPEC="${PHI_ROOT_SPEC:-}"
OUT="${OUT:-build/boot-${DEVICE}.img}"

# --- tools ------------------------------------------------------------------
if command -v mkbootimg >/dev/null 2>&1; then
    MKBOOTIMG=(mkbootimg)
elif command -v pmbootstrap >/dev/null 2>&1 && command -v mkbootimg.py >/dev/null 2>&1; then
    MKBOOTIMG=(python3 "$(command -v mkbootimg.py)")
else
    cat >&2 <<'EOF'
error: mkbootimg not found.

Install it from AOSP or from a distro package:
  pipx install   # not applicable; mkbootimg is AOSP python
  apt install android-sdk-libsparse-utils   # sometimes incomplete
  postmarketOS host: pmbootstrap init && pmbootstrap install  (brings mkbootimg.py)

Recommended for a phone port: use postmarketOS's boot-deploy instead, which
regenerates boot.img from /boot on the device after every kernel update:
  apk add boot-deploy && boot-deploy --flavor postmarketos
Phi's script exists for hosts that do not have a pmOS chroot.
EOF
    exit 1
fi

[[ -f "$KERNEL" ]] || { echo "error: kernel not found: $KERNEL" >&2; exit 1; }
[[ -n "$INITRAMFS" && -f "$INITRAMFS" ]] || { echo "error: initramfs not found: ${INITRAMFS:-<unset>}" >&2; exit 1; }

# Root spec has to reach the initramfs init via the cmdline, otherwise PID 1
# has no idea which partition holds the root filesystem.
if [[ -n "$ROOT_SPEC" ]] && [[ "$CMDLINE" != *"phi.root="* ]]; then
    CMDLINE="${CMDLINE} phi.root=${ROOT_SPEC}"
fi

ARGS=(--kernel "$KERNEL" --ramdisk "$INITRAMFS"
      --header_version "$HEADER_VERSION"
      --pagesize "$PAGESIZE"
      --cmdline "$CMDLINE"
      --output "$OUT")

case "$HEADER_VERSION" in
    0|1|2)
        # v0-v2: dtb is appended to the kernel blob space
        [[ -n "$DTB" ]] && [[ -f "$DTB" ]] && ARGS+=(--dtb "$DTB")
        [[ -n "${PHI_BOARD:-}" ]] && ARGS+=(--board "$PHI_BOARD")
        ;;
    3|4)
        # v3/v4: dtb lives in vendor_boot.img, not here
        if [[ -n "$DTB" ]]; then
            echo "warning: header v$HEADER_VERSION takes its dtb from vendor_boot.img;" >&2
            echo "         $DTB is not included in this boot image." >&2
        fi
        ;;
    *) echo "error: unsupported header version $HEADER_VERSION" >&2; exit 1 ;;
esac

echo "==> device      : $DEVICE"
echo "==> header      : v$HEADER_VERSION"
echo "==> kernel      : $KERNEL"
echo "==> initramfs   : $INITRAMFS"
echo "==> cmdline     : $CMDLINE"
echo "==> output      : $OUT"
mkdir -p "$(dirname "$OUT")"
"${MKBOOTIMG[@]}" "${ARGS[@]}"

echo
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"
cat <<EOF

Next steps, in order:
  1. back up the current boot partition (scripts/deploy-device.sh does this)
  2. make deploy DEVICE=$DEVICE      # dry run, prints the fastboot commands
  3. scripts/deploy-device.sh --device $DEVICE --bootimg $OUT --yes

If the device does not boot: hold the key combo for fastboot and reflash the
backup. Read docs/DEVICE-BRINGUP.md before the first attempt.
EOF
