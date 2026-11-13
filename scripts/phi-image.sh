#!/usr/bin/env bash
# Import the Phi rootfs as a real OCI image (podman/docker) and run it.
#
# This is for when you want an actual container: `podman ps`, `--network`,
# volumes, systemd as PID 1, or pushing the image somewhere. For quick "poke at
# the Debian system" work, scripts/phi-chroot.sh is faster and needs no
# container runtime at all.
#
# Running arm64 containers requires binfmt_misc on the host:
#   Arch:  yay -S qemu-user-static && sudo systemctl restart systemd-binfmt
# Without it podman/docker will fail with "exec format error", which is why
# phi-chroot.sh falls back to the build container instead.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${PHI_ROOTFS:-build/rootfs}"
IMAGE="${PHI_IMAGE_NAME:-phi-rootfs:latest}"
ENGINE=""
RUN=0
SYSTEMD=0
MOUNTS=()

usage() {
    cat <<'EOF'
usage: phi-image.sh [options]

  --rootfs <dir>    root filesystem to import (default build/rootfs)
  --tag <ref>       image reference (default phi-rootfs:latest)
  --engine <name>   docker | podman
  --run             import, then start it
  --systemd         with --run, boot systemd instead of a shell
  -v <host>:<ctr>   extra bind mount, repeatable
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)  ROOTFS="$2"; shift 2 ;;
        --tag)     IMAGE="$2"; shift 2 ;;
        --engine)  ENGINE="$2"; shift 2 ;;
        --run)     RUN=1; shift ;;
        --systemd) SYSTEMD=1; shift ;;
        -v)        MOUNTS+=(-v "$2"); shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$ENGINE" ]]; then
    for cand in podman docker nerdctl; do
        command -v "$cand" >/dev/null 2>&1 && { ENGINE="$cand"; break; }
    done
fi
[[ -n "$ENGINE" ]] || { echo "error: no container engine (podman/docker) found" >&2; exit 1; }

[[ -d "$ROOTFS" ]] || {
    echo "error: no root filesystem at $ROOTFS" >&2
    echo "       build one: scripts/phi-container.sh rootfs" >&2
    exit 1
}

# binfmt is what lets the kernel execute arm64 binaries in this container.
if [[ ! -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    cat <<'EOF'
warning: no binfmt_misc handler for aarch64 on this host.
         An arm64 image will import fine but fail at run time with
         "exec format error".

  Arch:           yay -S qemu-user-static && sudo systemctl restart systemd-binfmt
  Debian/Ubuntu:  sudo apt install qemu-user-static binfmt-support
  Any host:       scripts/phi-chroot.sh   (no binfmt needed)

EOF
fi

echo "==> importing $ROOTFS -> $IMAGE (arch arm64)"
mkdir -p build
TARBALL="build/phi-rootfs.tar"
# tar the contents (not the directory) so the image root is the filesystem
tar -C "$ROOTFS" -cf "$TARBALL" .
"$ENGINE" import \
    --arch arm64 \
    --change 'CMD ["/bin/bash"]' \
    --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    "$TARBALL" "$IMAGE"
rm -f "$TARBALL"

echo "==> imported $IMAGE ($("$ENGINE" image inspect --format '{{.Size}}' "$IMAGE" 2>/dev/null | awk '{printf "%.0f MB", $1/1024/1024}' || echo '?'))"
echo

if [[ $RUN -eq 0 ]]; then
    cat <<EOF
Run it:

  # shell, fastest way to poke around
  $ENGINE run --rm -it --arch arm64 ${MOUNTS[*]:-} $IMAGE /bin/bash

  # boot systemd inside the container (podman)
  $ENGINE run --rm -it --arch arm64 --privileged --systemd=always \\
      ${MOUNTS[*]:-} $IMAGE

  # or just
  scripts/phi-image.sh --run
EOF
    exit 0
fi

if [[ $SYSTEMD -eq 1 ]]; then
    echo "==> booting systemd in the container"
    exec "$ENGINE" run --rm -it --arch arm64 --privileged --systemd=always \
        "${MOUNTS[@]}" "$IMAGE"
else
    echo "==> starting a shell"
    exec "$ENGINE" run --rm -it --arch arm64 "${MOUNTS[@]}" "$IMAGE" /bin/bash
fi
