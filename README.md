```
              Phi Linux
   a phone that is also a PC, and stays a phone
```

Phi Linux is an ARM64 operating system for phones: Plasma Mobile when you hold
it, a desktop when you dock it, battery life treated as a hard requirement
rather than a tuning exercise.

## Status

Early. The kernel boots; the operating system around it is being built.

| Area | State |
| --- | --- |
| Kernel | arm64 6.12.115 (Debian), boots under QEMU with GRUB |
| Build | reproducible build system (`make initramfs` / `rootfs` / `iso` / `bootimg`) |
| Userland | Debian arm64 via debootstrap, Plasma Mobile package set defined |
| Convergence | `phi-moded` mode manager implemented and unit-tested, not yet on hardware |
| Power | kernel fragments + measurement tooling; no measurements on hardware yet |

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first, then
[`docs/ROADMAP.md`](docs/ROADMAP.md).

## Quick start

Not on an arm64 machine? `docs/DEVELOPMENT.md` has a container that covers
every host (x86-64 Linux, WSL2, Arch, Apple Silicon, Intel macOS), and native
paths per distro. `make deps` knows the Arch/Debian/Fedora/Alpine package
names.

```sh
make deps           # install build packages for your distro (prints by default)
make check          # toolchain + architecture sanity; fails loudly on mismatch
make test           # 35 mode-manager tests, no hardware needed
make rootfs         # arm64 Debian userland into build/rootfs   (needs root)
make disk           # pack it into build/rootfs.ext4 for the VM
make initramfs      # build/initramfs-arm64.cpio.gz
make run            # boot the whole thing in QEMU (no ISO, no GRUB)
```

On a non-arm64 host, prefix with the build container:
`scripts/phi-container.sh rootfs`, `… disk`, `… run`. See
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

For a real phone:

```sh
cp config/devices/example.conf config/devices/<codename>.conf   # fill in
make initramfs
make bootimg DEVICE=<codename>
scripts/deploy-device.sh --device <codename> --bootimg build/boot-<codename>.img   # dry run
```

Then read [`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md). The first flash is
the step that can cost you a phone.

## How the two postures work

```
        dock / external display / DP altmode
                     │  (sysfs: DRM connector + typec altmode)
                     ▼
   phi-moded ── decides, debounced, overridable
        ├── systemctl isolate phi-desktop.target | phi-phone.target
        ├── cpufreq governor + EPP, Wi-Fi power save
        └── /run/phi/mode-state.json
                     │
                     ▼
   session (user unit) ── apply-mode.sh
        ├── external display primary, phone panel OFF while docked
        └── optional Plasma Mobile ⇄ Plasma Desktop shell swap
```

The split is deliberate: policy needs root, presentation needs the session bus,
and mixing the two produces a dock that silently does nothing.

Set the mode by hand at any time:

```sh
phi-moded status
phi-moded set desktop --ttl 3600
phi-moded clear
```

## Layout

```
Makefile                 build entry points (vm + device tracks)
initramfs/init           PID 1: modules, find phi.root=, switch_root, rescue shell
scripts/                 build, deploy, power reporting
moded/phi_moded/         mode manager: detect / policy / actions / notify
moded/tests/             35 unit tests, no hardware required
systemd/                 posture targets, daemon unit, user session bridge
docker/                  build environment for any host (plus .devcontainer)
config/kernel/           kernel config fragments (convergence, power)
config/devices/          per-codename device profiles
config/rootfs-packages.txt
docs/                    architecture, roadmap, power, device bring-up
hooks/                   posture hook contract and samples
iso-root/                kernel + GRUB tree for the VM track
rootfs/                  legacy x86-64 tree, see note below
```

### Note on `rootfs/`

The committed `rootfs/` is **x86-64** — a host-architecture leftover from
before the ARM64 target was chosen. It cannot run on the target kernel.
`make check` fails on it on purpose. The real userland is built by
`make rootfs` into `build/rootfs` (gitignored). The legacy tree is kept only
until its few useful files are confirmed redundant; deleting it is a one-line
change once `make rootfs` has run successfully at least once.

## Development

```sh
make test           # moded unit tests + shell syntax check
make power          # live battery / cpufreq / suspend / dock report
make kernel-config  # merge the fragments onto a kernel tree
```

`phi-moded` is testable with no phone attached:

```sh
phi-moded run --once --simulate ./some/fixture/dir --dry-run --config config/moded.toml
```

## Non-goals

A custom init system, a compositor fork, a package manager, a second desktop
environment, and GRUB on a phone. See `docs/ARCHITECTURE.md` §9.
