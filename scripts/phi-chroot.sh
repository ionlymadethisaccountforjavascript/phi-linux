#!/usr/bin/env bash
# Enter the Phi Debian rootfs as a container.
#
# "Container" here means: the same namespace isolation you would get from
# `podman run`, without building an image, without a container runtime, and
# without a binfmt_misc registration. It is a chroot with qemu-aarch64-static
# invoked explicitly, which is what lets this work on an x86-64 host that has
# never installed the AUR qemu-user-static package.
#
# The result is a shell inside your own arm64 Debian system, in about a second,
# instead of a 40-second QEMU boot. Use it to iterate on userspace: packages,
# systemd units, phi-moded, Plasma config. Use `make run` for anything that
# needs the kernel (DRM, suspend, power management).
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${PHI_ROOTFS:-build/rootfs}"
CMD="/bin/bash"
INTERACTIVE=1
MOUNTS=1

usage() {
    cat <<'EOF'
usage: phi-chroot.sh [options] [-- command...]

  --rootfs <dir>    root filesystem to enter (default build/rootfs)
  --cmd <string>    command to run instead of a login shell
  --no-mounts       do not bind /proc, /sys, /dev (chroot still works)
  -h, --help        this text

examples:
  scripts/phi-chroot.sh                       # shell in your Debian system
  scripts/phi-chroot.sh --cmd 'dpkg -l | grep plasma'
  scripts/phi-chroot.sh --cmd 'systemctl --version'
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)    ROOTFS="$2"; shift 2 ;;
        --cmd)       CMD="$2"; INTERACTIVE=0; shift 2 ;;
        --no-mounts) MOUNTS=0; shift ;;
        -h|--help)   usage 0 ;;
        --)          shift; CMD="$*"; INTERACTIVE=0; break ;;
        *)           echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

if [[ ! -d "$ROOTFS" ]]; then
    cat >&2 <<EOF
error: no root filesystem at $ROOTFS

Build one first:
  scripts/phi-container.sh rootfs      # arm64 Debian, ~30 min, no host deps
EOF
    exit 1
fi

# --- can this host execute arm64 binaries? ----------------------------------
BINFMT=0
if [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
   && grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
    BINFMT=1
fi

QEMU_HOST=""
for cand in /usr/bin/qemu-aarch64-static /usr/local/bin/qemu-aarch64-static; do
    [[ -x "$cand" ]] && { QEMU_HOST="$cand"; break; }
done

# Nothing on the host can run arm64: hand the whole job to the build container,
# which has its own static qemu and does not need the host kernel to know about
# arm64 at all. PHI_IN_CONTAINER is set by docker/Containerfile, which stops the
# recursion.
if [[ $BINFMT -eq 0 && -z "$QEMU_HOST" && "${PHI_IN_CONTAINER:-0}" != "1" ]]; then
    echo "==> host has no arm64 emulation; re-running inside the build container"
    echo "    (this needs nothing from your host: no binfmt, no AUR)"
    exec scripts/phi-container.sh root -- scripts/phi-chroot.sh \
        --rootfs "$ROOTFS" --cmd "$CMD"
fi

# --- set up ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || {
    echo "error: entering the rootfs needs root (mount + chroot)" >&2
    echo "       sudo scripts/phi-chroot.sh" >&2
    exit 1
}

QEMU_INSTALLED=0
MOUNTED=()
cleanup() {
    for m in "${MOUNTED[@]}"; do
        [[ -n "$m" ]] && umount -lf "$m" 2>/dev/null || true
    done
    # Never leave the emulator inside the rootfs: it would be baked into the
    # disk image and shipped on the phone.
    [[ $QEMU_INSTALLED -eq 1 ]] && rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" 2>/dev/null || true
}
trap cleanup EXIT

if [[ $BINFMT -eq 0 ]]; then
    if [[ -n "$QEMU_HOST" ]]; then
        install -m 755 "$QEMU_HOST" "$ROOTFS/usr/bin/qemu-aarch64-static"
        QEMU_INSTALLED=1
    elif [[ -x "$ROOTFS/usr/bin/qemu-aarch64-static" ]]; then
        :   # already inside (put there by the container's mkrootfs run)
    else
        echo "error: no arm64 emulator available, inside or outside the rootfs" >&2
        exit 1
    fi
fi

if [[ $MOUNTS -eq 1 ]]; then
    for d in proc sys dev dev/pts; do
        mkdir -p "$ROOTFS/$d"
        if mount --bind "/$d" "$ROOTFS/$d" 2>/dev/null; then
            MOUNTED+=("$ROOTFS/$d")
        else
            echo "    warning: could not bind /$d (unprivileged container?)" >&2
        fi
    done
    # A private /run: the host's is full of sockets the target cannot use.
    mkdir -p "$ROOTFS/run"
    if mount -t tmpfs -o mode=755 tmpfs "$ROOTFS/run" 2>/dev/null; then
        MOUNTED+=("$ROOTFS/run")
    fi
fi

# --- run ------------------------------------------------------------------
echo "==> entering $ROOTFS ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))"
echo "    emulation: $([[ $BINFMT -eq 1 ]] && echo 'binfmt_misc (native speed)' || echo 'qemu-aarch64-static (explicit)')"
echo "    this is your Debian system, not the host. 'exit' to leave."
echo

if [[ $BINFMT -eq 1 ]]; then
    exec chroot "$ROOTFS" /bin/bash -c "$CMD"
else
    exec chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -c "$CMD"
fi
