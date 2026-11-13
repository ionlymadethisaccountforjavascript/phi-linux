#!/usr/bin/env bash
# Boot the VM track in QEMU.
#
# Direct kernel boot beats an ISO here: no grub, no xorriso, and a rebuild is
# an instant restart. QEMU virt has no GPU, so this validates the boot chain,
# initramfs, systemd and D-Bus -- not KWin's rendering path.
set -euo pipefail

KERNEL=iso-root/Image
INITRAMFS=build/initramfs-arm64.cpio.gz
DISK=""
MEM=2G
CPUS=2
GRAPHICAL=0
ACCEL=auto
EXTRA=""

usage() {
    cat <<'EOF'
usage: run-qemu.sh [options]

  --kernel <path>       kernel image
  --initramfs <path>    initramfs
  --disk <path>         root filesystem image (raw); mounted as /dev/vda
  --mem <size>          memory (default 2G)
  --cpus <n>            vCPUs (default 2)
  --accel <auto|kvm|hvf|tcg>   hardware acceleration (default auto)
  --graphical           open a window instead of -nographic
  --append <string>     extra kernel cmdline
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel)    KERNEL="$2"; shift 2 ;;
        --initramfs) INITRAMFS="$2"; shift 2 ;;
        --disk)      DISK="$2"; shift 2 ;;
        --mem)       MEM="$2"; shift 2 ;;
        --cpus)      CPUS="$2"; shift 2 ;;
        --accel)     ACCEL="$2"; shift 2 ;;
        --graphical) GRAPHICAL=1; shift ;;
        --append)    EXTRA="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

command -v qemu-system-aarch64 >/dev/null 2>&1 || {
    echo "error: qemu-system-aarch64 not found (apt install qemu-system-arm)" >&2
    exit 1
}
[[ -f "$KERNEL" ]] || { echo "error: no kernel at $KERNEL" >&2; exit 1; }

CMDLINE="console=ttyAMA0 rdinit=/init panic=10 phi.debug=0"
if [[ -n "$DISK" ]]; then
    CMDLINE+=" phi.root=/dev/vda phi.rootfstype=ext4"
else
    CMDLINE+=" phi.rescue=1"   # no disk: land in the initramfs shell on purpose
fi
[[ -n "$EXTRA" ]] && CMDLINE+=" $EXTRA"

# Emulation choice decides whether this is usable or a slideshow:
#   kvm  - arm64 host with /dev/kvm (and inside a container: --device /dev/kvm)
#   hvf  - Apple Silicon, arm64 guest on the Hypervisor framework
#   tcg  - pure emulation, 5-20x slower; fine for a serial console, painful
#          for Plasma
if [[ "$ACCEL" == "auto" ]]; then
    if [[ -w /dev/kvm ]]; then
        ACCEL=kvm
    elif [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
        ACCEL=hvf
    else
        ACCEL=tcg
    fi
fi

case "$ACCEL" in
    kvm|hvf) CPU_ARGS=(-accel "$ACCEL" -cpu host) ;;
    tcg)     CPU_ARGS=(-accel tcg -cpu cortex-a72) ;;
    *)       echo "error: --accel must be auto, kvm, hvf or tcg" >&2; exit 1 ;;
esac

ARGS=(-M virt "${CPU_ARGS[@]}" -smp "$CPUS" -m "$MEM"
      -kernel "$KERNEL" -append "$CMDLINE")

[[ -f "$INITRAMFS" ]] && ARGS+=(-initrd "$INITRAMFS")
[[ -n "$DISK" ]] && ARGS+=(-drive "file=$DISK,if=virtio,format=raw")

if [[ $GRAPHICAL -eq 1 ]]; then
    ARGS+=(-device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet)
else
    ARGS+=(-nographic)
fi

echo "==> qemu-system-aarch64 (accel=$ACCEL) ${ARGS[*]}"
echo "    cmdline: $CMDLINE"
echo "    exit QEMU with ctrl-a x"
exec qemu-system-aarch64 "${ARGS[@]}"
