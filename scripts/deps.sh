#!/usr/bin/env bash
# Distro-aware dependency helper.
#
# The project's package lists are written for Debian in a dozen error messages,
# which is useless if you are on Arch, Fedora or Alpine. This script knows the
# names, prints the command, and only runs it when asked.
set -euo pipefail

MODE=print
GROUP=all

usage() {
    cat <<'EOF'
usage: deps.sh [--print|--install] [--group core|vm|rootfs|device|all]

  --print     show the install command for your distro (default)
  --install   run it (uses sudo unless already root)

groups:
  core    python, compression, busybox, build tools
  vm      QEMU + ISO/GRUB tooling for the VM track
  rootfs  debootstrap and cross-arch emulation
  device  adb/fastboot for the phone track
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --print)   MODE=print; shift ;;
        --install) MODE=install; shift ;;
        --group)   GROUP="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

DISTRO=unknown
PM=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
    case "${ID_LIKE:-}${ID:-}" in
        *arch*)            DISTRO=arch ;;
        *debian*|*ubuntu*) DISTRO=debian ;;
        *fedora*|*rhel*)   DISTRO=fedora ;;
        *suse*)            DISTRO=suse ;;
        *alpine*)          DISTRO=alpine ;;
    esac
fi
[[ "$DISTRO" == "unknown" ]] && command -v pacman >/dev/null 2>&1 && DISTRO=arch
[[ "$DISTRO" == "unknown" ]] && command -v apt-get >/dev/null 2>&1 && DISTRO=debian
DISTRO="${PHI_DISTRO:-$DISTRO}"

# Packages per distro per group. Keep these minimal: every extra package is one
# more thing that can break a build on a distro nobody has tested.
case "$DISTRO" in
    arch)
        PM="sudo pacman -S --needed --noconfirm"
        PM_LABEL=pacman
        CORE="base-devel python cpio gzip xz zstd busybox git"
        VM="qemu-system-aarch64 grub libisoburn mtools e2fsprogs dtc shellcheck"
        ROOTFS="debootstrap qemu-user-static"
        DEVICE="android-tools"
        AUR="debootstrap qemu-user-static"
        ;;
    debian)
        PM="sudo apt-get install -y"
        PM_LABEL=apt
        CORE="build-essential python3 cpio gzip xz-utils zstd busybox-static git shellcheck"
        VM="qemu-system-arm qemu-utils grub-efi-arm64-bin xorriso mtools e2fsprogs device-tree-compiler"
        ROOTFS="debootstrap qemu-user-static binfmt-support arch-test"
        DEVICE="adb fastboot"
        AUR=""
        ;;
    fedora)
        PM="sudo dnf install -y"
        PM_LABEL=dnf
        CORE="gcc make python3 cpio gzip xz zstd busybox git ShellCheck"
        VM="qemu-system-aarch64 qemu-img grub2-tools-extra xorriso mtools e2fsprogs dtc"
        ROOTFS="debootstrap qemu-user-static"
        DEVICE="android-tools"
        AUR=""
        ;;
    alpine)
        PM="sudo apk add"
        PM_LABEL=apk
        CORE="build-base python3 cpio gzip xz zstd busybox git shellcheck"
        VM="qemu-system-aarch64 qemu-img grub grub-efi xorriso mtools e2fsprogs dtc"
        ROOTFS="debootstrap qemu-aarch64"
        DEVICE="android-tools"
        AUR=""
        ;;
    suse)
        PM="sudo zypper install -y"
        PM_LABEL=zypper
        CORE="gcc make python3 cpio gzip xz zstd busybox git ShellCheck"
        VM="qemu-arm qemu-tools grub2-arm64-efi xorriso mtools e2fsprogs dtc"
        ROOTFS="debootstrap qemu-linux-user"
        DEVICE="android-tools"
        AUR=""
        ;;
    *)
        cat <<'EOF'
Unknown distro. Generic package names you need:

  core    python3 cpio gzip xz zstd busybox gcc make git
  vm      qemu-system-aarch64 grub(arm64-efi) xorriso mtools e2fsprogs dtc
  rootfs  debootstrap qemu-user-static (or qemu-aarch64)
  device  adb fastboot (android-tools)

Or skip host setup entirely:  scripts/phi-container.sh
EOF
        exit 0
        ;;
esac

pick() {
    case "$1" in
        core)   echo "$CORE" ;;
        vm)     echo "$VM" ;;
        rootfs) echo "$ROOTFS" ;;
        device) echo "$DEVICE" ;;
        all)    echo "$CORE $VM $ROOTFS $DEVICE" ;;
        *) echo "unknown group: $1" >&2; exit 1 ;;
    esac
}

PKGS="$(pick "$GROUP")"
# keep AUR-only packages out of the native package manager list
AUR_NEEDED=""
if [[ -n "${AUR:-}" ]]; then
    for p in $AUR; do
        if [[ " $PKGS " == *" $p "* ]]; then
            AUR_NEEDED="$AUR_NEEDED $p"
            PKGS="$(echo " $PKGS " | sed "s/ $p / /g" | xargs)"
        fi
    done
fi

echo "detected: $DISTRO (${PM_LABEL:-unknown package manager})"
[[ -n "$PKGS" ]] && echo "  $PM $PKGS"

if [[ -n "$AUR_NEEDED" ]]; then
    echo
    echo "  Not in the official repos, install with an AUR helper:"
    echo "    yay -S$AUR_NEEDED"
    echo "  debootstrap on Arch is only needed for 'make rootfs' on the host."
    echo "  The build container has it already, which is the easier path:"
    echo "    scripts/phi-container.sh rootfs"
fi

if [[ "$DISTRO" == "arch" && ( "$GROUP" == "vm" || "$GROUP" == "all" ) ]]; then
    echo
    echo "  Heads up: Arch's 'grub' ships only x86 modules, so 'make iso' needs"
    echo "  arm64-efi GRUB from the container. rootfs/initramfs/bootimg are fine."
fi

if [[ "$GROUP" == "all" || "$GROUP" == "rootfs" ]]; then
    if [[ "$DISTRO" != "debian" ]]; then
        echo
        echo "  Cross-building the arm64 rootfs on $DISTRO needs an emulator:"
        case "$DISTRO" in
            arch)   echo "    yay -S qemu-user-static   # ships a systemd-binfmt entry"
                    echo "    sudo systemctl restart systemd-binfmt"
                    echo "    # or skip it: scripts/phi-container.sh rootfs" ;;
            alpine) echo "    sudo apk add qemu-aarch64" ;;
            *)      echo "    install qemu-user-static for your distro" ;;
        esac
    fi
fi

[[ "$MODE" == "print" ]] && exit 0

echo
echo "==> installing (you will be asked for your password)"
if [[ $EUID -eq 0 ]]; then
    ${PM#sudo } $PKGS
else
    $PM $PKGS
fi
