#!/usr/bin/env bash
# Build the Phi Linux initramfs (cpio.gz).
#
# Deliberately tiny: busybox + our init + the kernel's module tree if it exists.
# Everything else lives in the root filesystem, which makes the initramfs small
# enough to keep in a boot image on a phone with a 64 MB boot partition.
set -euo pipefail

ARCH=arm64
OUT=build/initramfs-arm64.cpio.gz
ROOTFS=build/rootfs
KVER=""
BUSYBOX=""

usage() {
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'
options:
  --arch <arm64|amd64>     target architecture (default arm64)
  --out <path>             output cpio.gz
  --rootfs <dir>           root filesystem to pull kernel modules from
  --kver <version>         kernel version for the module subtree (default: derive)
  --busybox <path>         busybox binary (default: search PATH)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)    ARCH="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --rootfs)  ROOTFS="$2"; shift 2 ;;
        --kver)    KVER="$2"; shift 2 ;;
        --busybox) BUSYBOX="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

# --- locate a busybox of the right architecture -----------------------------
find_static_busybox() {
    local candidates=()
    [[ -n "$BUSYBOX" ]] && candidates+=("$BUSYBOX")
    candidates+=(/usr/bin/busybox /bin/busybox /usr/lib/initramfs-tools/bin/busybox)

    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] || continue
        local m
        m="$(python3 -c '
import struct,sys
d=open(sys.argv[1],"rb").read(64)
if d[:4]!=b"\x7fELF": print("?"); raise SystemExit
print({62:"x86-64",183:"arm64",40:"arm32"}.get(struct.unpack("<H",d[18:20])[0],"?"))' "$c")"
        if [[ "$ARCH" == arm64 && "$m" != arm64 ]]; then
            echo "  skipping $c ($m, need arm64)" >&2
            continue
        fi
        if [[ "$ARCH" == amd64 && "$m" != x86-64 ]]; then
            echo "  skipping $c ($m, need x86-64)" >&2
            continue
        fi
        echo "$c"
        return 0
    done
    return 1
}

BB="$(find_static_busybox)" || {
    cat >&2 <<'EOF'
error: no static busybox for this architecture.

  Any host, arm64 target -- easiest path:
    make rootfs && make initramfs
    # the rootfs contains an arm64 busybox, which this script reuses

  Host packages, if you want one directly:
    Debian/Ubuntu   sudo apt install busybox-static
    Arch            sudo pacman -S busybox
    Fedora          sudo dnf install busybox
    Alpine          sudo apk add busybox-static
    (all of the above are x86-64 builds; they only work for --arch amd64)

  The build container has an arm64 busybox and needs no host packages:
    scripts/phi-container.sh initramfs
EOF
    exit 1
}

# --- assemble ---------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging in $STAGE"
mkdir -p "$STAGE"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,run,tmp,newroot,etc,lib,lib64,usr/lib}

cp "$BB" "$STAGE/bin/busybox"
chmod 755 "$STAGE/bin/busybox"
# balloon out every applet so /bin/sh, mount, switch_root, etc. resolve
for applet in $(busybox --list 2>/dev/null || true); do
    ln -sf busybox "$STAGE/bin/$applet" 2>/dev/null || true
done
[[ -e "$STAGE/bin/sh" ]] || ln -sf busybox "$STAGE/bin/sh"

install -m 755 initramfs/init "$STAGE/init"
mkdir -p "$STAGE/conf"
cp -r initramfs/conf/. "$STAGE/conf/" 2>/dev/null || true

# --- kernel modules ---------------------------------------------------------
if [[ -z "$KVER" ]]; then
    if [[ -d "$ROOTFS/lib/modules" ]]; then
        KVER="$(ls "$ROOTFS/lib/modules" | sort -V | tail -1)"
    fi
    if [[ -z "$KVER" && -f iso-root/Image ]]; then
        KVER="$(grep -a -o -m1 -E 'Linux version [0-9][^ ]*' iso-root/Image | sed 's/Linux version //' || true)"
    fi
fi

if [[ -n "$KVER" && -d "$ROOTFS/lib/modules/$KVER" ]]; then
    echo "==> including modules for $KVER"
    mkdir -p "$STAGE/lib/modules/$KVER"
    # kernel/ + the module list only: keeps the initramfs from ballooning
    cp -a "$ROOTFS/lib/modules/$KVER/kernel" "$STAGE/lib/modules/$KVER/" 2>/dev/null || true
    cp -a "$ROOTFS/lib/modules/$KVER/modules."*.{dep,alias,builtin,order} \
          "$STAGE/lib/modules/$KVER/" 2>/dev/null || true
    if [[ -x "$ROOTFS/sbin/depmod" ]]; then
        "$ROOTFS/sbin/depmod" -b "$STAGE" "$KVER" 2>/dev/null || true
    elif command -v depmod >/dev/null 2>&1; then
        depmod -b "$STAGE" "$KVER" 2>/dev/null || true
    fi
else
    echo "==> no module tree found (kernel must be built-in only: normal for pmOS)"
fi

# --- pack -------------------------------------------------------------------
# GNU cpio when present, otherwise the applet in the busybox we already found.
if command -v cpio >/dev/null 2>&1; then
    CPIO=(cpio --null --create --format=newc --quiet)
    CPIO_LIST=(cpio -it)
else
    CPIO=("$BB" cpio -0 -o -H newc -F /dev/stdout)
    CPIO_LIST=("$BB" cpio -it)
fi

mkdir -p "$(dirname "$OUT")"
(
    cd "$STAGE"
    find . -print0 | "${CPIO[@]}" 2>/dev/null | gzip -9 > "$OLDPWD/$OUT"
)

SIZE="$(du -h "$OUT" | cut -f1)"
echo "==> $(basename "$OUT")  $SIZE"
zcat "$OUT" | "${CPIO_LIST[@]}" 2>/dev/null | wc -l | xargs printf '    %s entries\n'
