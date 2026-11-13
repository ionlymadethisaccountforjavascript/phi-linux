#!/usr/bin/env bash
# Run Phi Linux builds inside the container, with the repo bind-mounted.
#
# The point of this script is the two things people get wrong by hand:
#   * file ownership: build output must belong to you, not to root
#   * privileges: `make rootfs` needs mount+chroot, everything else does not
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${PHI_IMAGE:-phi-linux-build:local}"
DOCKERFILE="docker/Containerfile"
ENGINE=""
REBUILD=0

usage() {
    cat <<'EOF'
usage: phi-container.sh [command] [-- args...]

  shell            interactive shell in the build container (default)
  test             make test
  check            make check
  initramfs        make initramfs
  iso              make iso
  run              make run (QEMU; needs a tty)
  rootfs           make rootfs (runs as root, fixes ownership afterwards)
  disk             make disk (pack build/rootfs into an ext4 image)
  make <target>    any make target
  build            (re)build the container image

  --engine docker|podman   force a container engine
  --rebuild                rebuild the image before running

examples:
  scripts/phi-container.sh                  # shell, uid-mapped, repo at /work
  scripts/phi-container.sh test
  scripts/phi-container.sh rootfs
  scripts/phi-container.sh make -- bootimg DEVICE=oneplus-enchilada
EOF
    exit "${1:-0}"
}

CMD_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)  ENGINE="$2"; shift 2 ;;
        --rebuild) REBUILD=1; shift ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
SUBCOMMAND="${1:-shell}"
[[ $# -gt 0 ]] && shift

# --- engine -----------------------------------------------------------------
if [[ -z "$ENGINE" ]]; then
    for cand in docker podman nerdctl; do
        command -v "$cand" >/dev/null 2>&1 && { ENGINE="$cand"; break; }
    done
fi
if [[ -z "$ENGINE" ]]; then
    cat >&2 <<'EOF'
error: no container engine found (docker, podman or nerdctl).

Install one:
  Arch            sudo pacman -S podman        (or docker from extra)
  Debian/Ubuntu   sudo apt install docker.io && sudo usermod -aG docker "$USER"
  Fedora          sudo dnf install podman
  macOS/Windows   Docker Desktop, then: docker desktop start

Or build without a container: docs/DEVELOPMENT.md lists the host packages for
an arm64 machine (no container needed at all) and for x86-64 (qemu-user-static).
EOF
    exit 1
fi

# Podman needs an explicit SELinux label on bind mounts.
MOUNT_OPTS=""
[[ "$ENGINE" == "podman" ]] && MOUNT_OPTS=":z"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# -t only when stdin is a terminal; CI has no tty and docker errors with -t.
TTY_FLAGS=(-i)
[[ -t 0 ]] && TTY_FLAGS+=(-t)

image_exists() {
    "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1
}

build_image() {
    echo "==> building $IMAGE from $DOCKERFILE ($(uname -m) host)"
    "$ENGINE" build -f "$DOCKERFILE" -t "$IMAGE" .
}

[[ $REBUILD -eq 1 ]] && build_image
image_exists || build_image

run_container() {
    local as_root="$1"; shift
    local user_args=(--user "$HOST_UID:$HOST_GID")
    local extra=()
    # Pass the host's KVM through so `make run` is not a slideshow. Harmless
    # when the host has no /dev/kvm (macOS, or a VM without nested virt).
    [[ -w /dev/kvm ]] && extra+=(--device /dev/kvm)
    if [[ "$as_root" == "root" ]]; then
        user_args=(--user 0:0)
        # mount --bind + chroot inside the container
        extra+=(--privileged)
    fi
    "$ENGINE" run --rm "${TTY_FLAGS[@]}" \
        "${user_args[@]}" "${extra[@]}" \
        --volume "$PWD:/work${MOUNT_OPTS}" \
        --workdir /work \
        --env "PHI_HOST_UID=$HOST_UID" \
        --env "PHI_HOST_GID=$HOST_GID" \
        --env "TERM=${TERM:-xterm}" \
        --env "HOME=/tmp" \
        "$IMAGE" "$@"
}

case "$SUBCOMMAND" in
    build)
        build_image
        ;;
    shell)
        echo "==> phi build container ($ENGINE, $(uname -m)). Repo is /work."
        echo "    make check | make test | make initramfs | scripts/phi-container.sh rootfs"
        run_container user /bin/bash
        ;;
    test|check|initramfs|iso|disk)
        run_container user make "$SUBCOMMAND"
        ;;
    run)
        run_container user make run
        ;;
    rootfs)
        # debootstrap needs root, mount and chroot. Ownership is fixed afterwards
        # so the host does not end up with a root-owned build/ directory.
        echo "==> building the arm64 rootfs as root inside the container"
        run_container root /bin/bash -c '
            set -o pipefail
            make rootfs
            rc=$?
            chown -R "${PHI_HOST_UID}:${PHI_HOST_GID}" build 2>/dev/null || true
            exit $rc
        '
        ;;
    make)
        run_container user make "$@"
        ;;
    *)
        exec "$ENGINE" run --rm "${TTY_FLAGS[@]}" \
            --user "$HOST_UID:$HOST_GID" \
            --volume "$PWD:/work${MOUNT_OPTS}" --workdir /work \
            --env "HOME=/tmp" "$IMAGE" "$SUBCOMMAND" "$@"
        ;;
esac
