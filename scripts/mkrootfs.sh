#!/usr/bin/env bash
# Build an arm64 Debian root filesystem for Phi Linux.
#
# Cross-build notes:
#   * an x86-64 host needs qemu-user-static + binfmt to run the arm64 postinst
#     scripts, otherwise debootstrap --second-stage fails half way through
#   * the resulting tree is what the initramfs packs modules from and what
#     boot.img eventually mounts, so keep it in build/ and out of git
set -euo pipefail

ARCH=arm64
SUITE=trixie
MIRROR=http://deb.debian.org/debian
OUT=build/rootfs
PKG_LIST=config/rootfs-packages.txt
COMPONENTS="main,contrib,non-free-firmware"
SKIP_PACKAGES=0

usage() {
    cat <<'EOF'
usage: mkrootfs.sh [options]

  --arch <arm64|amd64>   target arch (default arm64)
  --suite <codename>     Debian suite (default trixie)
  --mirror <url>         Debian mirror
  --out <dir>            output directory (default build/rootfs)
  --packages <file>      package list (default config/rootfs-packages.txt)
  --minimal              skip the Phi package list entirely
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)     ARCH="$2"; shift 2 ;;
        --suite)    SUITE="$2"; shift 2 ;;
        --mirror)   MIRROR="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --packages) PKG_LIST="$2"; shift 2 ;;
        --minimal)  SKIP_PACKAGES=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "error: mkrootfs needs root (debootstrap + mounts)" >&2; exit 1; }
command -v debootstrap >/dev/null 2>&1 || { echo "error: debootstrap not installed (apt install debootstrap)" >&2; exit 1; }

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
CROSS=0
[[ "$HOST_ARCH" != "$ARCH" && "$HOST_ARCH" != "arm64" ]] && CROSS=1

if [[ $CROSS -eq 1 ]]; then
    command -v qemu-aarch64-static >/dev/null 2>&1 || {
        echo "error: cross-building $ARCH on $HOST_ARCH needs qemu-user-static" >&2
        echo "       apt install qemu-user-static binfmt-support" >&2
        exit 1
    }
fi

MOUNTS=()
cleanup() {
    for m in "${MOUNTS[@]:-}"; do
        [[ -n "$m" ]] && umount -lf "$m" 2>/dev/null || true
    done
}
trap cleanup EXIT

mkdir -p "$OUT"

echo "==> debootstrap $SUITE/$ARCH -> $OUT"
if [[ $CROSS -eq 1 ]]; then
    debootstrap --arch="$ARCH" --foreign --components="$COMPONENTS" "$SUITE" "$OUT" "$MIRROR"
    cp /usr/bin/qemu-aarch64-static "$OUT/usr/bin/"
    chroot "$OUT" /debootstrap/debootstrap --second-stage
    rm -f "$OUT/usr/bin/qemu-aarch64-static"
else
    debootstrap --arch="$ARCH" --components="$COMPONENTS" "$SUITE" "$OUT" "$MIRROR"
fi

echo "==> base configuration"
cat > "$OUT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb $MIRROR $SUITE-security main contrib non-free-firmware
EOF

echo "phi-linux" > "$OUT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tphi-linux\n' > "$OUT/etc/hosts"
echo "en_US.UTF-8 UTF-8" > "$OUT/etc/locale.gen"

# The boot chain owns the rootfs; systemd should not try to fsck what the
# initramfs has already mounted (see phi.root= on the cmdline).
cat > "$OUT/etc/fstab" <<'EOF'
# <file system>  <mount>  <type>  <options>          <dump> <pass>
proc             /proc    proc    defaults           0      0
EOF

for d in dev dev/pts proc sys run tmp; do
    mkdir -p "$OUT/$d"
    mount --bind "/$d" "$OUT/$d" 2>/dev/null || true
    MOUNTS+=("$OUT/$d")
done

export DEBIAN_FRONTEND=noninteractive
chroot "$OUT" apt-get update -qq

if [[ $SKIP_PACKAGES -eq 0 && -f "$PKG_LIST" ]]; then
    mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKG_LIST")
    echo "==> installing ${#PKGS[@]} packages from $PKG_LIST"
    chroot "$OUT" apt-get install -y --no-install-recommends "${PKGS[@]}" || {
        echo "error: package install failed. The most likely cause on a cross build" >&2
        echo "       is a missing binfmt entry; check /proc/sys/fs/binfmt_misc/" >&2
        exit 1
    }
fi

echo "==> user + services"
chroot "$OUT" bash -c 'id phi >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev phi'
chroot "$OUT" bash -c 'echo "phi:phi" | chpasswd'
chroot "$OUT" systemctl enable systemd-networkd systemd-resolved ssh 2>/dev/null || true

echo
echo "==> rootfs ready: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "    next: make initramfs   then   make bootimg DEVICE=<codename>"
echo
echo "    NOTE: this is a stock Debian userland with Phi's packages layered on."
echo "          Device-specific bits (kernel, dtb, firmware, modem config) come"
echo "          from the port in config/devices/ and docs/DEVICE-BRINGUP.md."
