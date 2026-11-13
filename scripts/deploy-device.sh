#!/usr/bin/env bash
# Flash a Phi Linux boot image to an Android phone.
#
# Dry run by default. Nothing is written unless --yes is passed, every
# destructive step is preceded by a backup attempt, and the script refuses to
# continue if the connected device does not match the profile.
set -euo pipefail

DEVICE=""
BOOTIMG=""
CONFIRM=0
SLOT=""

usage() {
    cat <<'EOF'
usage: deploy-device.sh --device <codename> --bootimg <path> [--yes]

  --device <codename>    device profile in config/devices/
  --bootimg <path>       boot image to flash
  --slot <a|b|auto>      target slot (default auto: follow current slot)
  --yes                  actually flash; without it this is a dry run
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)  DEVICE="$2"; shift 2 ;;
        --bootimg) BOOTIMG="$2"; shift 2 ;;
        --slot)    SLOT="$2"; shift 2 ;;
        --yes)     CONFIRM=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$DEVICE" && -n "$BOOTIMG" ]] || { echo "error: --device and --bootimg are required" >&2; exit 1; }
[[ -f "$BOOTIMG" ]] || { echo "error: boot image not found: $BOOTIMG" >&2; exit 1; }
PROFILE="config/devices/${DEVICE}.conf"
[[ -f "$PROFILE" ]] || { echo "error: no profile at $PROFILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$PROFILE"

run() {
    if [[ $CONFIRM -eq 1 ]]; then
        echo "+ $*"
        "$@"
    else
        echo "DRY RUN: $*"
    fi
}

command -v fastboot >/dev/null 2>&1 || { echo "error: fastboot not found" >&2; exit 1; }

echo "==> fastboot devices"
fastboot devices || true
echo

echo "==> verifying the connected device matches '$DEVICE'"
PRODUCT="$(fastboot getvar product 2>&1 | sed -n 's/^product: //p' | head -1)"
UNLOCKED="$(fastboot getvar unlocked 2>&1 | sed -n 's/^unlocked: //p' | head -1)"
CUR_SLOT="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p' | head -1)"
echo "    product    : ${PRODUCT:-<none>}"
echo "    unlocked   : ${UNLOCKED:-<unknown>}"
echo "    current slot: ${CUR_SLOT:-<none>}"

if [[ -z "$PRODUCT" ]]; then
    echo
    echo "error: no device in fastboot mode. Hold the documented key combo while" >&2
    echo "       plugging in USB, or run 'adb reboot bootloader' from a booted device." >&2
    exit 1
fi

EXPECTED="${PHI_FASTBOOT_PRODUCT:-$DEVICE}"
if [[ "$PRODUCT" != "$EXPECTED" ]] && [[ "$PRODUCT" != *"$DEVICE"* ]]; then
    echo
    echo "error: connected product '$PRODUCT' does not match profile '$DEVICE'." >&2
    echo "       Refusing to flash a boot image built for a different board." >&2
    exit 1
fi

if [[ "$UNLOCKED" == "no" ]]; then
    echo
    echo "error: bootloader is locked. Unlock it first (this wipes the device):" >&2
    echo "         fastboot flashing unlock     # or: fastboot oem unlock" >&2
    exit 1
fi

# --- pick a slot ------------------------------------------------------------
case "${SLOT:-auto}" in
    auto)  TARGET="${CUR_SLOT:-a}" ;;
    a|b)   TARGET="$SLOT" ;;
    *) echo "error: --slot must be a, b or auto" >&2; exit 1 ;;
esac
BOOT_PART="boot_${TARGET}"
echo "    flashing to: $BOOT_PART"

if [[ -n "${PHI_VERITY:-}" && "${PHI_VERITY}" == "disabled" ]]; then
    echo
    echo "    note: this profile disables verity/verification on first flash."
    echo "          Skipping this on a locked-AVB device causes a boot loop."
fi

# --- back up ----------------------------------------------------------------
BACKUP="build/backup-${DEVICE}-boot_${TARGET}-$(date +%Y%m%d-%H%M%S).img"
mkdir -p build
echo
echo "==> backing up $BOOT_PART to $BACKUP"
if ! run fastboot fetch "$BOOT_PART" "$BACKUP" 2>/dev/null; then
    echo "    'fastboot fetch' unavailable on this fastboot version."
    echo "    >>> BACK UP MANUALLY BEFORE CONTINUING <<<"
    echo "        Boot a working OS, then:  adb shell su -c 'dd if=/dev/block/by-name/${BOOT_PART} of=/sdcard/boot.img'"
    if [[ $CONFIRM -eq 1 && "${PHI_ALLOW_NO_BACKUP:-0}" != "1" ]]; then
        echo "error: refusing to flash without a backup (set PHI_ALLOW_NO_BACKUP=1 to override)" >&2
        exit 1
    fi
fi

# --- flash ------------------------------------------------------------------
echo
echo "==> flashing"
run fastboot flash "$BOOT_PART" "$BOOTIMG"
run fastboot reboot

cat <<EOF

==> done
If it boots:  ssh into the device and check dmesg for panel/typec errors.
If it hangs:  hold the fastboot combo, then reflash the backup:
              fastboot flash $BOOT_PART $BACKUP
If it hangs before fastboot is reachable: this is a vendor-bootloader device
              with no recovery entry; do not flash experiments to vendor_boot
              or super until you have a serial or pstore working (see docs).
EOF
