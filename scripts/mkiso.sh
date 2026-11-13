#!/usr/bin/env bash
# Build a bootable ARM64 ISO for the VM track.
#
# The ISO is a development convenience, not a shipping artifact: phones boot
# from a boot partition, so the real device path is 'make bootimg'.
set -euo pipefail

TREE=iso-root
INITRAMFS=build/initramfs-arm64.cpio.gz
OUT=build/phi-linux-arm64.iso
VOLID=PHI_LINUX

usage() {
    cat <<'EOF'
usage: mkiso.sh [options]

  --tree <dir>         iso staging tree (default iso-root)
  --initramfs <path>   initramfs to embed (default build/initramfs-arm64.cpio.gz)
  --out <path>         output ISO
  --volid <id>         volume id (max 32 chars, default PHI_LINUX)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tree)      TREE="$2"; shift 2 ;;
        --initramfs) INITRAMFS="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        --volid)     VOLID="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -f "$TREE/Image" ]] || { echo "error: no kernel at $TREE/Image" >&2; exit 1; }
[[ -f "$TREE/boot/grub/grub.cfg" ]] || { echo "error: no $TREE/boot/grub/grub.cfg" >&2; exit 1; }

if [[ ! -f "$INITRAMFS" ]]; then
    cat >&2 <<EOF
error: initramfs not found: $INITRAMFS

grub.cfg references /initramfs-arm64.cpio.gz. Without it the kernel panics
with "VFS: Unable to mount root fs" because there is no initrd to run.
Build it first:
    make initramfs
EOF
    exit 1
fi

command -v grub-mkrescue >/dev/null 2>&1 || {
    cat >&2 <<'EOF'
error: grub-mkrescue not found.

On Debian/Ubuntu (host builds arm64 EFI images):
  sudo apt install grub-efi-arm64-bin grub-pc-bin xorriso mtools

Or use the VM track without an ISO at all, which needs no extra tooling:
  make run
EOF
    exit 1
}
command -v xorriso >/dev/null 2>&1 || { echo "error: xorriso not found (apt install xorriso mtools)" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$TREE/." "$STAGE/"
mkdir -p "$STAGE/boot/grub"
install -m 644 "$INITRAMFS" "$STAGE/$(basename "$INITRAMFS")"
# grub.cfg points at /initramfs-arm64.cpio.gz; keep the name it expects
if [[ "$(basename "$INITRAMFS")" != "initramfs-arm64.cpio.gz" ]]; then
    cp "$INITRAMFS" "$STAGE/initramfs-arm64.cpio.gz"
fi

GRUB_DIR=/usr/lib/grub/arm64-efi
[[ -d "$GRUB_DIR" ]] || GRUB_DIR="$(dirname "$(find /usr/lib/grub -name 'efi.mod' -path '*arm64*' 2>/dev/null | head -1)" 2>/dev/null)/"
if [[ ! -d "$GRUB_DIR" || "$GRUB_DIR" == "/" ]]; then
    echo "error: no arm64-efi GRUB platform modules found (apt install grub-efi-arm64-bin)" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "==> grub-mkrescue ($(basename "$GRUB_DIR")) -> $OUT"
grub-mkrescue --directory="$GRUB_DIR" \
    --output="$OUT" \
    --volid="$VOLID" \
    "$STAGE" 2>&1 | sed 's/^/    /'

echo "==> $(du -h "$OUT" | cut -f1)  $OUT"
echo "    boot it with: qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G \\"
echo "                    -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \\"
echo "                    -cdrom $OUT -nographic"
