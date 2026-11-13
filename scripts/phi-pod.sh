#!/usr/bin/env bash
# A persistent container running the Phi Debian system, the way you would run
# one on Fedora: import, start once, exec into it forever.
#
#   scripts/phi-pod.sh up          # import build/rootfs, start systemd in it
#   podman exec -it phi bash       # ... or: scripts/phi-pod.sh shell
#   scripts/phi-pod.sh export      # container changes -> build/rootfs
#
# Changes live in the container until you remove it. `export` bakes them back
# into build/rootfs so `make disk` produces a bootable image with them in.
#
# The one host requirement is binfmt_misc: a container start is a real exec of
# an arm64 ELF, so the kernel has to recognise it. Fedora ships
# qemu-user-static in its repos and registers it for you; Arch does not, which
# is the only difference. `phi-pod.sh doctor` tells you exactly what is missing.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="${PHI_POD_NAME:-phi}"
IMAGE="${PHI_POD_IMAGE:-phi-rootfs:latest}"
ROOTFS="${PHI_ROOTFS:-build/rootfs}"
ENGINE=""
SYSTEMD=1

usage() {
    cat <<'EOF'
usage: phi-pod.sh <command>

  up            import the rootfs if needed and start the container (idempotent)
  shell         interactive shell inside it (podman exec -it NAME bash)
  exec -- cmd   run one command inside it
  status        container state + what is running inside
  stop          stop it (it survives; `up` or `podman start` brings it back)
  rm            delete the container (changes are lost unless exported)
  export        copy the container filesystem back into build/rootfs
  commit [tag]  snapshot the container as an image (default phi-rootfs:dev)
  doctor        check engine, cgroups, binfmt, rootfs
  logs          systemd journal from inside the container

env:
  PHI_POD_NAME   container name (default phi)
  PHI_POD_IMAGE  base image (default phi-rootfs:latest)
  PHI_ROOTFS     rootfs to import (default build/rootfs)
  PHI_SKIP_BINFMT_CHECK=1   skip the aarch64 handler check (unusual binfmt names)
EOF
    exit "${1:-0}"
}

CMD="${1:-}"
[[ -z "$CMD" ]] && usage 0
shift || true

# --- engine: podman first, this is the podman workflow ---------------------
detect_engine() {
    if [[ -n "$ENGINE" ]]; then return; fi
    for cand in podman docker; do
        command -v "$cand" >/dev/null 2>&1 && { ENGINE="$cand"; return; }
    done
    cat >&2 <<'EOF'
error: neither podman nor docker is installed.

  Arch:  sudo pacman -S podman        (in the official repos)
EOF
    exit 1
}

binfmt_ok() {
    # Some distros register the handler under a different name, and someone with
    # a hand-rolled registration may know better than this script.
    [[ "${PHI_SKIP_BINFMT_CHECK:-0}" == "1" ]] && return 0
    local f
    for f in /proc/sys/fs/binfmt_misc/qemu-aarch64 /proc/sys/fs/binfmt_misc/aarch64; do
        [[ -r "$f" ]] && grep -q '^enabled' "$f" 2>/dev/null && return 0
    done
    return 1
}

exists() { "$ENGINE" container exists "$NAME" >/dev/null 2>&1; }
running() { [[ "$("$ENGINE" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == "true" ]]; }

# --- doctor ---------------------------------------------------------------
cmd_doctor() {
    detect_engine
    echo "engine      : $ENGINE $("$ENGINE" --version | head -1 | awk '{print $NF}')"
    echo "cgroups     : $(stat -fc %T /sys/fs/cgroup) (systemd in a container wants cgroup v2)"
    if binfmt_ok; then
        echo "binfmt      : qemu-aarch64 registered"
    else
        cat <<'EOF'
binfmt      : MISSING - arm64 containers cannot start

  Arch:
      yay -S qemu-user-static              # or qemu-user-static-bin (prebuilt)
      sudo systemctl restart systemd-binfmt
      ls /proc/sys/fs/binfmt_misc/ | grep aarch64

  Fedora:
      sudo dnf install qemu-user-static    # this is why it "just worked" there

  Debian/Ubuntu:
      sudo apt install qemu-user-static binfmt-support

  No binfmt and no AUR? Use the chroot instead, which needs neither:
      sudo scripts/phi-chroot.sh
EOF
    fi
    echo "rootfs      : $([[ -d "$ROOTFS" ]] && du -sh "$ROOTFS" | cut -f1 || echo 'missing - run scripts/phi-container.sh rootfs')"
    if exists; then
        echo "container   : $NAME ($([[ $(running) == true ]] && echo running || echo stopped))"
    else
        echo "container   : $NAME (does not exist yet)"
    fi
}

# --- up -------------------------------------------------------------------
cmd_up() {
    detect_engine
    binfmt_ok || {
        cat >&2 <<'EOF'
error: no aarch64 binfmt handler, so an arm64 container cannot start.

  Arch:    yay -S qemu-user-static && sudo systemctl restart systemd-binfmt
  Then:    scripts/phi-pod.sh up

Without it you can still run the system, just not as a container:
  sudo scripts/phi-chroot.sh
EOF
        exit 1
    }

    if exists; then
        if running; then
            echo "==> $NAME already running"
        else
            echo "==> starting existing container $NAME"
            "$ENGINE" start "$NAME" >/dev/null
        fi
    else
        [[ -d "$ROOTFS" ]] || {
            echo "error: no rootfs at $ROOTFS (scripts/phi-container.sh rootfs)" >&2
            exit 1
        }
        echo "==> importing $ROOTFS -> $IMAGE"
        scripts/phi-image.sh --rootfs "$ROOTFS" --tag "$IMAGE" >/dev/null

        echo "==> creating container $NAME"
        local vol="$PWD:/work"
        [[ "$ENGINE" == "podman" ]] && vol="$vol:z"
        local common=(
            --name "$NAME"
            --hostname phi-linux
            --arch arm64
            --privileged
            --volume "$vol"
        )
        if [[ "$ENGINE" == "podman" ]]; then
            "$ENGINE" run -d "${common[@]}" --systemd=always "$IMAGE" /sbin/init >/dev/null
        else
            # docker has no --systemd; it needs the host cgroup tree instead
            "$ENGINE" run -d "${common[@]}" --cgroupns=host \
                --volume /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" /sbin/init >/dev/null
        fi
    fi

    # give systemd a moment, then report what actually came up
    for _ in $(seq 1 20); do
        "$ENGINE" exec "$NAME" /bin/sh -c 'test -d /run/systemd/system' 2>/dev/null && break
        sleep 0.5
    done

    if running; then
        echo "==> $NAME is up ($("$ENGINE" exec "$NAME" /bin/sh -c 'uname -m' 2>/dev/null || echo '?'))"
        echo
        echo "    shell:   scripts/phi-pod.sh shell"
        echo "    or:      $ENGINE exec -it $NAME bash"
        echo "    bake changes back:  scripts/phi-pod.sh export"
    else
        echo "error: container exited immediately; logs:" >&2
        "$ENGINE" logs --tail 20 "$NAME" >&2 || true
        exit 1
    fi
}

need_container() {
    detect_engine
    exists || { echo "error: no container '$NAME' yet (scripts/phi-pod.sh up)" >&2; exit 1; }
}

cmd_shell() {
    need_container
    if running; then
        exec "$ENGINE" exec -it "$NAME" /bin/bash
    else
        # a stopped container still gives a shell, which is handy for rescue
        exec "$ENGINE" start -ai "$NAME" /bin/bash
    fi
}

cmd_exec() {
    need_container
    [[ "${1:-}" == "--" ]] && shift
    [[ $# -gt 0 ]] || { echo "error: nothing to run (phi-pod.sh exec -- cmd)" >&2; exit 1; }
    if running; then
        exec "$ENGINE" exec -it "$NAME" "$@"
    else
        exec "$ENGINE" start -ai "$NAME" "$@"
    fi
}

cmd_status() {
    need_container
    state=stopped
    running && state=running
    echo "container : $NAME ($state)"
    echo "image     : $("$ENGINE" inspect -f '{{.ImageName}}' "$NAME" 2>/dev/null || echo '?')"
    img="$("$ENGINE" inspect -f '{{.Image}}' "$NAME" 2>/dev/null || echo '')"
    echo "arch      : $("$ENGINE" image inspect -f '{{.Architecture}}' "$img" 2>/dev/null || echo '?')"
    if running; then
        echo
        echo "units:"
        "$ENGINE" exec "$NAME" systemctl list-units --state=running --no-legend --no-pager 2>/dev/null | head -12 || true
    fi
}

cmd_stop() {
    need_container
    "$ENGINE" stop "$NAME" >/dev/null
    echo "==> stopped $NAME (changes kept; 'up' or '$ENGINE start $NAME' resumes)"
}

cmd_rm() {
    detect_engine
    exists || { echo "no container $NAME"; exit 0; }
    "$ENGINE" rm -f "$NAME" >/dev/null
    echo "==> removed $NAME"
}

cmd_export() {
    need_container
    if running; then
        echo "==> note: exporting the filesystem of a running container may be inconsistent" >&2
    fi
    [[ -d "$ROOTFS" ]] || { echo "error: no $ROOTFS to export into" >&2; exit 1; }

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "==> exporting $NAME -> $tmp"
    "$ENGINE" export "$NAME" | tar -x -C "$tmp" --exclude='./proc/*' --exclude='./sys/*' \
        --exclude='./dev/*' --exclude='./run/*' 2>/dev/null || true

    # Merge rather than replace: the rootfs' own /proc,/sys,/dev,/run
    # mountpoints must survive.
    echo "==> merging into $ROOTFS"
    if command -v rsync >/dev/null 2>&1; then
        rsync -aHAX --delete \
            --exclude '/proc/***' --exclude '/sys/***' --exclude '/dev/***' \
            --exclude '/run/***' --exclude '/tmp/***' \
            "$tmp/" "$ROOTFS/"
    else
        # Without rsync, files deleted inside the container are not deleted from
        # the rootfs. Say so instead of pretending the merge is identical.
        echo "    (rsync absent: extracting without deleting; removed packages stay)" >&2
        tar -C "$tmp" -cf - \
            --exclude='./proc' --exclude='./sys' --exclude='./dev' \
            --exclude='./run' --exclude='./tmp' . \
            | tar -C "$ROOTFS" -xpf -
        echo "    tip: 'sudo pacman -S rsync' gives exact sync next time" >&2
    fi

    echo "==> done. $(du -sh "$ROOTFS" | cut -f1) in $ROOTFS"
    echo "    next: make disk   (then make run, or make bootimg DEVICE=...)"
}

cmd_commit() {
    need_container
    tag="${1:-phi-rootfs:dev}"
    "$ENGINE" commit "$NAME" "$tag" >/dev/null
    echo "==> committed $NAME -> $tag"
    echo "    (a snapshot for rollback; 'export' is what feeds build/rootfs)"
}

cmd_logs() {
    need_container
    "$ENGINE" logs --tail 50 "$NAME" 2>&1 | tail -50
}

case "$CMD" in
    up)     cmd_up ;;
    shell)  cmd_shell ;;
    exec)   cmd_exec "$@" ;;
    status) cmd_status ;;
    stop)   cmd_stop ;;
    rm)     cmd_rm ;;
    export) cmd_export ;;
    commit) cmd_commit ;;
    doctor) cmd_doctor ;;
    logs)   cmd_logs ;;
    -h|--help|help) usage 0 ;;
    *) echo "unknown command: $CMD" >&2; usage 1 ;;
esac
