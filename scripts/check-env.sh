#!/usr/bin/env bash
# Preflight checks for the Phi Linux build.
#
# Catches the two failure modes that cost the most time on a convergence
# project: architecture mismatch (host x86_64 binaries grafted into an ARM64
# image) and a missing host toolchain discovered halfway through a build.
set -euo pipefail

cd "$(dirname "$0")/.."

KERNEL="${KERNEL:-iso-root/Image}"
ARCH="${ARCH:-arm64}"
fail=0
warn=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; warn=1; }
head_() { printf '\n%s\n' "$*"; }

# ELF/PE machine id -> human name
machine_name() {
    python3 - "$@" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    d = f.read(0x400)
if d[:4] == b'\x7fELF':
    m = struct.unpack('<H', d[18:20])[0]
    print({62: 'x86-64', 183: 'arm64', 40: 'arm32', 3: 'i386'}.get(m, f'elf-{m}'))
elif d[:2] == b'MZ':
    off = struct.unpack('<I', d[0x3c:0x40])[0]
    m = struct.unpack('<H', d[off+4:off+6])[0]
    print({0xaa64: 'arm64', 0x8664: 'x86-64', 0x1c: 'arm32'}.get(m, f'pe-{m:#x}'))
else:
    print('not-a-binary')
PY
}

head_ "0. Host"
HOST_ARCH="$(uname -m)"
printf '  %-22s %s\n' "architecture" "$HOST_ARCH"
printf '  %-22s %s\n' "kernel" "$(uname -sr)"
distro="unknown"
if [[ -r /etc/os-release ]]; then
    distro="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$NAME}")"
fi
printf '  %-22s %s\n' "distro" "$distro"
for pm in pacman apt-get dnf zypper apk; do
    command -v "$pm" >/dev/null 2>&1 && printf '  %-22s %s\n' "package manager" "$pm" && break
done
if [[ -f /.dockerenv ]] || grep -qa 'docker\|podman\|containerd' /proc/1/cgroup 2>/dev/null; then
    printf '  %-22s %s\n' "container" "yes"
fi
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    ok "native arm64 host: no emulation needed, KVM available for 'make run'"
else
    note "host is $HOST_ARCH, target is $ARCH"
    echo "        containers:  scripts/phi-container.sh          (recommended)"
    echo "        bare metal:  make deps    (installs for your distro)"
    echo "        full guide:  docs/DEVELOPMENT.md"
fi

head_ "1. Kernel"
if [[ -f "$KERNEL" ]]; then
    kmach="$(machine_name "$KERNEL")"
    if [[ "$kmach" == arm64 && "$ARCH" == arm64 ]]; then
        kver="$(grep -a -o -m1 -E 'Linux version [0-9][^ ]*' "$KERNEL" | sed 's/Linux version //' || true)"
        ok "kernel $KERNEL is arm64 (${kver:-version unknown})"
        if ! grep -aq 'CONFIG_IKCONFIG' "$KERNEL"; then
            note "kernel has no /proc/config.gz; run 'make kernel-config' and verify the config on device"
        fi
    else
        bad "kernel $KERNEL is $kmach but ARCH=$ARCH"
    fi
else
    bad "kernel not found at $KERNEL"
fi

head_ "2. Userland architecture"
# Any ELF committed under rootfs/ must match the target arch. This is the check
# that catches 'works on my laptop' breakage before a 20 minute flash cycle.
mismatched=0
checked=0
if [[ -d rootfs ]]; then
    while IFS= read -r -d '' f; do
        m="$(machine_name "$f")"
        [[ "$m" == "not-a-binary" ]] && continue
        checked=$((checked + 1))
        if [[ "$m" != "$ARCH" ]]; then
            mismatched=$((mismatched + 1))
            [[ $mismatched -le 3 ]] && note "wrong arch: $f is $m"
        fi
    done < <(find rootfs -type f -print0 2>/dev/null)
fi
if [[ $mismatched -gt 0 ]]; then
    bad "rootfs/ holds $mismatched $([ "$ARCH" = arm64 ] && echo x86-64 || echo "$ARCH") binaries (of $checked ELF files)"
    echo "        rootfs/ as committed is a host-architecture leftover. It cannot run"
    echo "        on an arm64 kernel. Real rootfs images are built into build/rootfs"
    echo "        by 'make rootfs', which is what the initramfs and boot.img consume."
    echo "        Once 'make rootfs' succeeds, remove the leftover:"
    echo "            git rm -r rootfs"
elif [[ $checked -gt 0 ]]; then
    ok "rootfs/ ELF files match $ARCH ($checked checked)"
else
    note "rootfs/ has no ELF files; run 'make rootfs' to generate build/rootfs"
fi

head_ "3. Host toolchain"
need_core=(python3 gzip)
for t in "${need_core[@]}"; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || bad "$t missing (run 'make deps')"
done
# cpio is optional: busybox ships an applet and mkinitramfs falls back to it
if command -v cpio >/dev/null 2>&1; then
    ok "cpio"
elif command -v busybox >/dev/null 2>&1; then
    note "cpio missing; using the busybox applet ('make deps' avoids this)"
else
    bad "cpio missing (run 'make deps')"
fi
command -v busybox >/dev/null 2>&1 \
    && ok "busybox ($(busybox 2>&1 | head -1))" \
    || note "busybox missing - needed by 'make initramfs' (run 'make deps')"

head_ "4. Optional: VM track"
for t in qemu-system-aarch64 grub-mkrescue xorriso; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || note "$t missing (VM track only)"
done

head_ "5. Optional: device track"
for t in debootstrap mkbootimg fastboot; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || note "$t missing"
done
if command -v mkbootimg >/dev/null 2>&1 && command -v fastboot >/dev/null 2>&1; then
    ok "boot.img + flashing tools present"
fi

printf '\n'
if [[ $fail -ne 0 ]]; then
    printf '\033[31mcheck failed\033[0m\n'
    exit 1
fi
[[ $warn -ne 0 ]] && printf '\033[33mcheck passed with warnings\033[0m\n' || printf '\033[32mcheck passed\033[0m\n'
