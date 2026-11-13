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
DRYRUN=0

usage() {
    cat <<'EOF'
usage: mkrootfs.sh [options]

  --arch <arm64|amd64>   target arch (default arm64)
  --suite <codename>     Debian suite (default trixie)
  --mirror <url>         Debian mirror
  --out <dir>            output directory (default build/rootfs)
  --packages <file>      package list (default config/rootfs-packages.txt)
  --minimal              skip the Phi package list entirely
  --dry-run              print the resolved build plan and exit (no root needed)
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
        --dry-run)  DRYRUN=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
CROSS=0
if [[ "$HOST_ARCH" != "$ARCH" && "$HOST_ARCH" != "arm64" ]]; then
    CROSS=1
fi

# Cross builds run arm64 binaries (apt, postinst scripts, sh) on the host. Two
# ways to do that, and neither should be a prerequisite for the other:
#
#   binfmt_misc registered  -> plain `chroot` just works (Docker Desktop, or a
#                              host where systemd-binfmt/qemu-user-static ran)
#   not registered          -> call qemu-aarch64-static inside the chroot
#                              explicitly. This is the path inside an
#                              unprivileged container, where registering a
#                              binfmt handler would need CAP_SYS_ADMIN on the
#                              host kernel.
QEMU_STATIC=""
if [[ $CROSS -eq 1 ]]; then
    if [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
       && grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        echo "==> cross build: binfmt_misc qemu-aarch64 is registered"
    else
        for cand in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static \
                    /usr/libexec/qemu-binfmt/aarch64-binfmt-P; do
            [[ -x "$cand" ]] && { QEMU_STATIC="$cand"; break; }
        done
        [[ -n "$QEMU_STATIC" ]] || MISSING_QEMU=1
        if [[ -n "${MISSING_QEMU:-}" ]]; then
            cat >&2 <<EOF
error: cross-building $ARCH on $HOST_ARCH needs qemu-user-static.

  any distro:           make deps        (installs the right emulator)
  Arch:                 yay -S qemu-user-static
                        (AUR only; ships its own systemd-binfmt entry)
  Debian/Ubuntu:        sudo apt install qemu-user-static binfmt-support
  Fedora:               sudo dnf install qemu-user-static
  Alpine/pmOS:          sudo apk add qemu-aarch64

  Or skip host setup entirely, the container has all of it:
                        scripts/phi-container.sh rootfs   (docs/DEVELOPMENT.md)
EOF
            [[ $DRYRUN -eq 1 ]] || exit 1
        else
            echo "==> cross build: no binfmt entry, using $QEMU_STATIC explicitly"
        fi
    fi
fi

# Resolved plan, useful before committing 20 minutes to a debootstrap run.
if [[ $DRYRUN -eq 1 ]]; then
    # Same capability as the bind mounts below, tested on a throwaway dir.
    bindfs="unavailable (unprivileged? rootfs build needs SYS_ADMIN)"
    tmpdir="$(mktemp -d)"
    if mount -t tmpfs tmpfs "$tmpdir" 2>/dev/null; then
        umount "$tmpdir" 2>/dev/null || true
        bindfs="ok"
    fi
    rmdir "$tmpdir" 2>/dev/null || true
    cat <<EOF

Phi rootfs build plan
  host          $HOST_ARCH ($(uname -sr))
  target        $ARCH / $SUITE
  cross build   $([[ $CROSS -eq 1 ]] && echo yes || echo "no (native)")
  emulator      $( if [[ $CROSS -eq 0 ]]; then echo "not needed (native)";
                    elif [[ -n "${MISSING_QEMU:-}" ]]; then echo "MISSING - see the error above";
                    else echo "${QEMU_STATIC:-binfmt_misc handler for aarch64}"; fi )
  output        $OUT
  packages      $([[ $SKIP_PACKAGES -eq 1 ]] && echo "<minimal>" || echo "$PKG_LIST")
  bind mounts   $bindfs
  root          $([[ $EUID -eq 0 ]] && echo ok || echo "required for a real run")
EOF
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "error: mkrootfs needs root (debootstrap + mounts)" >&2; exit 1; }
command -v debootstrap >/dev/null 2>&1 || {
    echo "error: debootstrap not installed." >&2
    echo "       Debian/Ubuntu: sudo apt install debootstrap" >&2
    echo "       Arch:          yay -S debootstrap    (AUR)" >&2
    echo "       Any distro:    scripts/phi-container.sh rootfs   (already has it)" >&2
    exit 1
}

# Everything that should run inside the target rootfs goes through this.
chroot_run() {
    if [[ -n "$QEMU_STATIC" ]]; then
        chroot "$OUT" /usr/bin/qemu-aarch64-static "$@"
    else
        chroot "$OUT" "$@"
    fi
}

QEMU_INSTALLED=0
MOUNTS=()
cleanup() {
    for m in "${MOUNTS[@]:-}"; do
        [[ -n "$m" ]] && umount -lf "$m" 2>/dev/null || true
    done
    [[ "${QEMU_INSTALLED:-0}" == "1" ]] && rm -f "$OUT/usr/bin/qemu-aarch64-static" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$OUT"

echo "==> debootstrap $SUITE/$ARCH -> $OUT"
if [[ $CROSS -eq 1 ]]; then
    debootstrap --arch="$ARCH" --foreign --components="$COMPONENTS" "$SUITE" "$OUT" "$MIRROR"
    if [[ -n "$QEMU_STATIC" ]]; then
        # The emulator must live inside the target before anything can execute.
        install -m 755 "$QEMU_STATIC" "$OUT/usr/bin/qemu-aarch64-static"
        QEMU_INSTALLED=1
    fi
    chroot_run /debootstrap/debootstrap --second-stage
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

BIND_FAILED=0
for d in dev dev/pts proc sys run tmp; do
    mkdir -p "$OUT/$d"
    if mount --bind "/$d" "$OUT/$d" 2>/dev/null; then
        MOUNTS+=("$OUT/$d")
    else
        BIND_FAILED=1
    fi
done
if [[ $BIND_FAILED -eq 1 ]]; then
    # Normal in an unprivileged container. apt and systemctl still work; they
    # just see the container's /proc instead of a private one.
    echo "==> warning: could not bind-mount /proc,/sys,/dev into the rootfs"
    echo "    (unprivileged container?). Continuing; if apt fails, re-run the"
    echo "    same command with 'scripts/phi-container.sh rootfs' instead."
fi

export DEBIAN_FRONTEND=noninteractive
chroot_run apt-get update -qq

if [[ $SKIP_PACKAGES -eq 0 && -f "$PKG_LIST" ]]; then
    mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKG_LIST")
    echo "==> installing ${#PKGS[@]} packages from $PKG_LIST"
    chroot_run apt-get install -y --no-install-recommends "${PKGS[@]}" || {
        echo "error: package install failed inside the target rootfs." >&2
        echo "       On a cross build the usual causes are:" >&2
        echo "         - qemu-user-static missing or the wrong qemu-aarch64-static" >&2
        echo "         - no network in the container (check the mirror)" >&2
        echo "         - a bind-mounted /proc that the target cannot read" >&2
        exit 1
    }
fi

echo "==> user + services"
chroot_run bash -c 'id phi >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev phi'
chroot_run bash -c 'echo "phi:phi" | chpasswd'
chroot_run systemctl enable systemd-networkd systemd-resolved ssh 2>/dev/null || true

echo
echo "==> rootfs ready: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "    next: make initramfs   then   make bootimg DEVICE=<codename>"
echo
echo "    NOTE: this is a stock Debian userland with Phi's packages layered on."
echo "          Device-specific bits (kernel, dtb, firmware, modem config) come"
echo "          from the port in config/devices/ and docs/DEVICE-BRINGUP.md."
