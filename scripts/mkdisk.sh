#!/usr/bin/env bash
# Turn a root filesystem directory into a bootable ext4 disk image.
#
# `make run` needs this to get past the initramfs: without a root filesystem
# there is nothing for switch_root to switch to, and the VM parks in a rescue
# shell by design.
#
# Uses mke2fs -d, which populates an image from a directory without root and
# without loop devices -- so this works in an unprivileged container.
set -euo pipefail

ROOTFS=build/rootfs
OUT=build/rootfs.ext4
SIZE=""
LABEL=phi-root

usage() {
    cat <<'EOF'
usage: mkdisk.sh [options]

  --rootfs <dir>    root filesystem directory (default build/rootfs)
  --out <path>      output image (default build/rootfs.ext4)
  --size <n>        image size, e.g. 4G (default: rootfs + 40%, min 1G)
  --label <name>    filesystem label (default phi-root)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --out)    OUT="$2"; shift 2 ;;
        --size)   SIZE="$2"; shift 2 ;;
        --label)  LABEL="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -d "$ROOTFS" ]] || {
    echo "error: no root filesystem at $ROOTFS" >&2
    echo "       run 'make rootfs' first (or 'scripts/phi-container.sh rootfs')" >&2
    exit 1
}
[[ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ]] || { echo "error: $ROOTFS is empty" >&2; exit 1; }
command -v mke2fs >/dev/null 2>&1 || { echo "error: mke2fs not found (apt install e2fsprogs)" >&2; exit 1; }

if [[ -z "$SIZE" ]]; then
    # 40% headroom over the used size: Plasma Mobile writes a lot to /var, and
    # a full filesystem in the VM looks exactly like a broken boot.
    used_mb="$(du -sm "$ROOTFS" | cut -f1)"
    want_mb=$(( used_mb * 140 / 100 ))
    (( want_mb < 1024 )) && want_mb=1024
    SIZE="${want_mb}M"
fi

mkdir -p "$(dirname "$OUT")"
echo "==> $ROOTFS -> $OUT ($SIZE, ext4, label=$LABEL)"
rm -f "$OUT"
# Sparse file: apparent size is SIZE, real usage only what is written.
truncate -s "$SIZE" "$OUT"
mke2fs -q -t ext4 -L "$LABEL" -d "$ROOTFS" -F "$OUT"
# Reserve less for root than a server default would: this is a phone image.
tune2fs -m 1 -L "$LABEL" "$OUT" >/dev/null

files="$(du -sh "$ROOTFS" | cut -f1)"
echo "==> done: $OUT ($(du -h --apparent-size "$OUT" | cut -f1) apparent, $files of content)"
echo
echo "    boot it:"
echo "      make run                      # mounts it as /dev/vda"
echo "      # or by hand:"
echo "      scripts/run-qemu.sh --disk $OUT"
