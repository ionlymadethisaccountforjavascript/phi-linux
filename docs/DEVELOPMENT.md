# Working on Phi from any machine

The project targets arm64. Your laptop probably is not. This document is the
shortest path from `git clone` to a passing build, on whatever you happen to be
sitting in front of.

## The 60-second version

```sh
git clone https://github.com/ionlymadethisaccountforjavascript/phi-linux.git
cd phi-linux

make deps                         # prints your distro's package command
scripts/phi-container.sh test     # builds the image on first run, ~2-4 min
scripts/phi-container.sh check    # environment + architecture sanity
scripts/phi-container.sh shell    # interactive shell, repo mounted at /work
```

`check` will report **one expected failure**: the committed `rootfs/` is x86-64
(see `README.md`). That is a known defect being tracked, not your setup.

If you are on an arm64 Linux machine, skip the container entirely — you have
the best setup and section A applies.

## Running your Debian system in a container

Three tiers, cheapest first. All of them run **your** `build/rootfs`, not stock
Debian — so what you install and configure is what ends up on the phone.

| | Needs | Start time | Can test |
| --- | --- | --- | --- |
| **1. chroot** | nothing but the build image | instant | packages, systemd units, `phi-moded`, Plasma config |
| **2. OCI container** | binfmt on the host (AUR on Arch) | ~1 s | + `podman ps`, networking, volumes, systemd as PID 1 |
| **3. QEMU VM** | `make disk` | 30-60 s boot | kernel, DRM, suspend, cpufreq/EAS, USB-C |

### Tier 1 — chroot: works on Arch today, no AUR, nothing installed

```sh
scripts/phi-container.sh rootfs          # once, ~30 min, builds build/rootfs
sudo scripts/phi-chroot.sh               # a shell in your Debian system
sudo scripts/phi-chroot.sh --cmd 'dpkg -l | grep plasma'
sudo scripts/phi-chroot.sh --cmd 'systemctl --version'
```

Why this works without `qemu-user-static` on Arch: if the host cannot execute
arm64 binaries, the script re-executes itself inside the build container, which
ships its own `qemu-aarch64-static`. It also cleans up after itself — the
emulator is removed from the rootfs on exit, so it never ends up in a disk
image or on the phone.

If you *do* have binfmt registered (tier 2 setup below), the same command runs
at native-ish speed instead of through an explicit emulator. Same script, same
interface.

### Tier 2 — a real OCI container (podman on Arch)

Needs `binfmt_misc`, because the kernel has to recognise an arm64 ELF before
any runtime can start it:

```sh
yay -S qemu-user-static
sudo systemctl restart systemd-binfmt
ls /proc/sys/fs/binfmt_misc/qemu-aarch64        # expect: enabled

scripts/phi-image.sh --run                      # import + shell
scripts/phi-image.sh --run --systemd            # systemd as PID 1
scripts/phi-image.sh                            # print the run commands only

# afterwards, it is just an image:
podman run --rm -it --arch arm64 phi-rootfs:latest
podman run --rm -it --arch arm64 --privileged --systemd=always phi-rootfs:latest
```

If you only want a *stock* Debian arm64 shell rather than your own rootfs:

```sh
podman run --rm -it --arch arm64 debian:trixie bash    # still needs binfmt
```

### Tier 3 — the actual system, in a VM

```sh
make disk && make initramfs && make run
```

### What a container cannot test

Containers share the **host** kernel. The arm64 *userspace* runs; the arm64
*kernel* does not. So:

- no kernel modules, no device tree, no panel/touch drivers
- no suspend, no `s2idle`, no wakeup sources — the whole of `docs/POWER.md`
- no DRM hotplug or USB-C altmode, so `phi-moded` can be exercised but only
  with `--simulate` fixtures, not real hardware events
- systemd as PID 1 works but is not a boot: no initramfs, no `switch_root`

Use tier 1/2 to iterate on the OS, tier 3 or a phone to test the machine.

## Which host are you on?

| Host | Rootfs build | `make run` (QEMU) | Recommendation |
| --- | --- | --- | --- |
| arm64 Linux (ARM laptop, ARM server, Asahi, Arch ARM) | native, fast | KVM, fast | **No container.** Section A. |
| x86-64 Linux / WSL2 | qemu-user, medium | KVM if `/dev/kvm` | Container, section B (or native cross, section C) |
| Apple Silicon macOS | native arm64 inside the container, fast | HVF — usable | Container, section B |
| Intel macOS / Windows | qemu-user, slow | TCG only, very slow | Container, section B; expect a slideshow for Plasma |

## A. Native host — no container

Best on an arm64 machine (everything is native), but any distro works; only the
package names change. `make deps` knows them.

| Distro | Install | arm64 rootfs on the host |
| --- | --- | --- |
| Debian / Ubuntu | `make deps` | `debootstrap` + `qemu-user-static`, official repos |
| Arch | `make deps` | **both are AUR-only** — see below |
| Fedora | `make deps` | official repos |
| Alpine / pmOS | `make deps` | `qemu-aarch64` |
| anything else | `scripts/deps.sh` prints generic names | — |

```sh
make deps               # print the install command for your distro
make deps INSTALL=1     # ... or run it
make check && make test
sudo make rootfs        # debootstrap writes a lot of files as root
make disk               # pack the rootfs into build/rootfs.ext4
make initramfs
make run                # serial console, ctrl-a x to quit
```

### Arch specifics

Three things bite on Arch, in this order:

1. **`debootstrap` and `qemu-user-static` are AUR-only.**
   ```sh
   yay -S debootstrap qemu-user-static
   sudo systemctl restart systemd-binfmt   # qemu-user-static ships the entry
   ```
   `qemu-user-static` only matters on **x86-64** Arch. On Arch ARM you are
   native and need neither.

2. **Arch's `grub` ships x86 modules only**, so `make iso` cannot produce an
   arm64-efi ISO on Arch. Either build it in the container
   (`scripts/phi-container.sh iso`) or skip the ISO — `make run` boots the
   kernel directly and does not need GRUB at all.

3. **`podman` is in the official repos** and the wrapper prefers it if
   `docker` is absent, so the container path costs one `pacman -S podman`.

On x86-64 Arch the container is still the smoother route: it brings
`debootstrap`, the emulator and the arm64 GRUB modules in one step, with none
of the AUR wait.

## B. The container (recommended for everything else)

The image is built for **your host's architecture**, not pinned to arm64. Only
the target userland runs under emulation. Pinning the image to `linux/arm64`
would emulate the compiler, `debootstrap`, `xorriso` and GRUB too — a build
that takes two minutes becomes twenty.

```sh
# 1. an engine
sudo apt install docker.io && sudo usermod -aG docker "$USER"   # Debian/Ubuntu
# macOS / Windows: Docker Desktop
# Fedora: sudo dnf install podman

# 2. build the image once
scripts/phi-container.sh build

# 3. use it
scripts/phi-container.sh shell
scripts/phi-container.sh test
scripts/phi-container.sh check
scripts/phi-container.sh rootfs        # runs as root, fixes ownership after
scripts/phi-container.sh run           # QEMU, needs a tty
scripts/phi-container.sh make -- bootimg DEVICE=oneplus-enchilada
```

| `make` target | wrapper |
| --- | --- |
| `make test` | `scripts/phi-container.sh test` |
| `make check` | `scripts/phi-container.sh check` |
| `make initramfs` | `scripts/phi-container.sh initramfs` |
| `make iso` | `scripts/phi-container.sh iso` |
| `make run` | `scripts/phi-container.sh run` |
| `make rootfs` | `scripts/phi-container.sh rootfs` |
| `make disk` | `scripts/phi-container.sh disk` |
| anything else | `scripts/phi-container.sh make -- <args>` |

What the wrapper does for you, and why each part matters:

- **uid mapping** — output files belong to you, not root. Without this, a
  container build leaves `build/` owned by uid 0 and the next non-container
  command fails with permission denied.
- **`--privileged` for `rootfs` only** — `debootstrap` runs `mount --bind` and
  `chroot`; unprivileged containers get `EPERM`. Every other target runs
  unprivileged.
- **`/dev/kvm` passthrough when present** — so `make run` uses hardware
  acceleration instead of emulation.
- **`:z` mount label on podman** — otherwise SELinux denies the bind mount on
  Fedora.

VS Code and Codespaces users: `.devcontainer/devcontainer.json` wraps all of
this. *Dev Containers: Reopen in Container*.

## C. x86-64 Linux without a container

Perfectly possible, and worth knowing because it is also what the container is
doing internally:

```sh
sudo apt install build-essential python3 git debootstrap cpio gzip \
    qemu-user-static binfmt-support busybox-static \
    qemu-system-arm qemu-utils grub-efi-arm64-bin xorriso mtools
sudo make rootfs
```

`mkrootfs.sh` detects whether `binfmt_misc` has a `qemu-aarch64` handler:

- **registered** — arm64 binaries run under plain `chroot`, transparently
- **not registered** — the script invokes `qemu-aarch64-static` inside the
  chroot explicitly (`chroot $OUT /usr/bin/qemu-aarch64-static ...`)

The second path exists so a build works inside an unprivileged container,
where registering a binfmt handler would require privileges on the *host*
kernel. You do not need to choose: the script picks.

## What each command actually needs

| Command | Requires | Time (native) | Time (emulated) |
| --- | --- | --- | --- |
| `make check` | python3 | seconds | seconds |
| `make test` | python3 | seconds | seconds |
| `make initramfs` | busybox built for arm64* | seconds | seconds |
| `make rootfs` | root, debootstrap, qemu-user (if cross) | 15-30 min | 45-90 min |
| `make disk` | e2fsprogs (`mke2fs -d`, no root needed) | ~1 min | ~1 min |
| `make iso` | grub-efi-arm64-bin, xorriso | ~1 min | ~1 min |
| `make run` | qemu-system-arm, KVM/HVF ideally | — | 5-20× slower |
| `make bootimg` | mkbootimg, a device profile | seconds | seconds |
| `deploy-device.sh` | fastboot **with USB access** | — | — |

\* On a cross build, `mkinitramfs.sh` needs an *arm64* busybox. The simplest
source is the rootfs you just built: `make rootfs` puts one in
`build/rootfs/usr/bin/busybox`, and the script picks it up automatically.

**Flashing runs on the host, not in the container.** USB hotplug from inside a
container needs `--device` plumbing for a device that appears after the
container started. Run `scripts/deploy-device.sh` directly on the host.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Exec format error` | arm64 binary executed with no emulator | container/section C; or you ran the legacy x86-64 `rootfs/` |
| `chroot: failed to run command '/debootstrap/debootstrap': Exec format error` | no binfmt handler and no `qemu-aarch64-static` found | `sudo apt install qemu-user-static`, or use the wrapper |
| `mount: permission denied` during `make rootfs` | unprivileged container | `scripts/phi-container.sh rootfs` (adds `--privileged`) |
| `docker: image ... does not match the specified platform` | you forced `--platform linux/arm64` | do not pin it; the image is host-native by design |
| `-accel kvm: invalid accelerator kvm` | no `/dev/kvm` (VM without nested virt) | `make run` with `--accel tcg` |
| `No space left on device` | rootfs is ~1.5 GB, +Plasma ~4-6 GB | 15 GB free in the build volume |
| `Release file expired` | clock skew in the container | restart Docker, or `sudo hwclock -s` |
| Arch: `target not found: debootstrap` | AUR-only package | `yay -S debootstrap`, or use the container |
| Arch: `no arm64-efi GRUB platform modules` | Arch `grub` is x86-only | `scripts/phi-container.sh iso`, or use `make run` |
| `podman run --arch arm64` fails: `exec format error` | no binfmt handler | `yay -S qemu-user-static` + restart `systemd-binfmt`, or use `scripts/phi-chroot.sh` |
| `chroot: cannot run /bin/bash` in tier 1 | rootfs has no arm64 `bash`/emulator | rebuild the rootfs (`scripts/phi-container.sh rootfs`) |
| podman: `SELinux is preventing access` | missing mount label | the wrapper adds `:z`; pass `--engine podman` explicitly if autodetect missed |
| Apple Silicon: everything is slow | you built with `--platform linux/amd64` | rebuild without it |

## Where your work lives

- **In git:** kernel `Image` (38 MB), `iso-root/`, scripts, docs, `moded/`.
- **Ignored:** `build/` — rootfs, initramfs, ISOs, boot images. `make clean`
  removes it. Nothing you need to preserve lives there except time.
- **Reproducible:** a fresh clone plus `make rootfs && make initramfs` is the
  whole state of the project. There are no untracked secrets in the build.

## Resuming where the project stands

1. `make check` — expect the legacy-rootfs failure, and the missing-tool
   warnings that tell you what your host lacks.
2. `make test` — 35 mode-manager tests, no hardware required.
3. `make rootfs` → `make disk` → `make initramfs` → `make run` — a serial
   console into systemd. That is the end of `docs/ROADMAP.md` phase P0.
   (Without `make disk`, `make run` deliberately drops to an initramfs rescue
   shell: there is no root filesystem to switch to.)
4. After that, phase P1 needs a phone: `docs/DEVICE-BRINGUP.md`.
