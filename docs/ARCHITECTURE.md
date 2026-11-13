# Phi Linux — architecture

Phi Linux is one operating system that behaves as a phone when held and as a
PC when docked, without becoming a battery-hostile desktop that happens to fit
in a pocket.

That single sentence sets the whole design: **the PC posture is the exception,
the phone posture is the default, and the transition must be cheap.**

---

## 1. Where the project actually is

| Layer | State |
| --- | --- |
| Kernel | Debian arm64 6.12.115, EFI-stub `Image`, boots under QEMU/GRUB |
| Boot | GRUB on a removable medium — a development convenience only |
| Userland | `rootfs/` contains an **x86-64** bash (host leftover); no arm64 userland is builder-produced yet |
| Build | Was not reproducible from the repo: no scripts, initramfs gitignored |
| Convergence | Not started |
| Power policy | Not started |

Two of those are structural problems rather than missing features, and both are
fixed by the build system that now lives in `Makefile` + `scripts/`:

1. **Architecture mismatch.** An x86-64 userland cannot exec on an arm64 kernel.
   `make check` fails loudly on this instead of letting it surface as a mystery
   `Exec format error` on device.
2. **Unreproducible artifact.** `grub.cfg` references
   `/initramfs-arm64.cpio.gz`, which is gitignored and was never committed.
   The committed ISO tree therefore cannot boot. `make initramfs` produces it.

## 2. Three postures, one system

| Posture | Trigger | Session | Power target |
| --- | --- | --- | --- |
| **phone** | default, pocket | Plasma Mobile on internal panel | ≤ 1.5 %/h idle |
| **desktop** | external display or DP altmode | Plasma Desktop on external display, panel off | mains power, latency first |
| **mirror** (later) | HDMI/DP present but user chose mirroring | Plasma Mobile on both | mains power |

`mirror` is deliberately deferred. It is a compositor feature, not a system
feature, and it competes for the same engineering time as making `desktop`
actually good.

### Signals that decide the posture

Two independent hardware facts, both read from sysfs:

- a DRM connector that is not the internal panel reports `connected`
- the USB-C port has an active DisplayPort alternate mode

Either one is sufficient. Both are debounced (1.5 s to enter, 3 s to leave) so
a bumped cable does not reconfigure the screen mid-sentence. A user override
outranks both, with an optional TTL, because hardware detection will be wrong
on some docks and the user must always be able to force the answer.

## 3. Layers

```
┌──────────────────────────────────────────────────────────────┐
│ apps        Kirigami / GTK / Electron      Android apps       │
│                                            (Waydroid)        │
├──────────────────────────────────────────────────────────────┤
│ shell       Plasma Mobile shell  ⇄  Plasma Desktop shell      │
│             (same KWin, same session, swapped plasmashell)    │
├──────────────────────────────────────────────────────────────┤
│ session     KWin/Wayland · KScreen · PipeWire · powerdevil    │
│             phi-session-mode (user unit): output layout       │
├──────────────────────────────────────────────────────────────┤
│ posture     phi-moded (root): decide docked, isolate target,  │
│             apply power profile                               │
├──────────────────────────────────────────────────────────────┤
│ base        Debian arm64 · systemd · NetworkManager ·         │
│             ModemManager · BlueZ · iio-sensor-proxy           │
├──────────────────────────────────────────────────────────────┤
│ kernel      mainline arm64 + Phi fragments + device tree      │
├──────────────────────────────────────────────────────────────┤
│ boot        Android bootloader (ABL/LK) → boot.img →           │
│             initramfs → switch_root → systemd                 │
└──────────────────────────────────────────────────────────────┘
```

An earlier draft of this document had a "HAL" box in the middle. It is gone:
Linux already has one, and inventing a private abstraction between userspace
and DRM/sysfs mostly produces a second, worse copy of it.

## 4. What a mode switch does, in order

```
 udev (DRM change) ──SIGHUP──▶ phi-moded
                                  │
                                  ├─ read sysfs: connector + typec altmode
                                  ├─ policy: debounce, override, decide
                                  ├─ systemctl isolate phi-desktop.target
                                  ├─ run /usr/lib/phi/moded/hooks/enter-desktop.d/*
                                  └─ write cpufreq governor/EPP, wifi power save
                                             │
                              /run/phi/mode-state.json  (written)
                                             │
                    systemd --user path unit fires
                                             │
                                  apply-mode.sh in the session:
                                    · kscreen-doctor: enable external, primary
                                    · kscreen-doctor: DISABLE the phone panel
                                    · optional plasmashell shell swap
```

Two details matter more than the rest:

**The panel goes off when docked.** A 6-inch AMOLED at working brightness is
among the largest single loads in the device. Leaving it on "in case the user
picks the phone up" costs more than every CPU governor tweak in this repo
combined. Phone-mode brightness is restored on undock.

**The switch is split across the privilege boundary.** `phi-moded` runs as
root and owns kernel knobs, targets and hooks. It cannot talk to KWin, and
must not try: a root process without the user's `XDG_RUNTIME_DIR` and session
bus cannot reconfigure outputs, and any attempt fails silently. So the decision
is published as a file and the *session* acts on it. This is the single most
common design mistake in docking implementations, and it is worth stating
explicitly: **policy is system-level, presentation is session-level.**

## 5. Session preservation vs. shell swap

Restarting `plasmashell` looks alarming and is mostly harmless: application
windows are children of KWin, not of the shell. Swapping the mobile shell for
the desktop shell therefore keeps every open window, and recreates only the
panel, launcher and homescreen. Expect a visible flash, and expect the task
list to reorder.

That means there are two supported strategies:

| Strategy | Behaviour | Default |
| --- | --- | --- |
| **continuous** | one shell, Kirigami apps reflow, no restart | yes (`PHI_SWITCH_SHELL=0`) |
| **shell swap** | plasmashell re-execs into the other shell | opt-in (`PHI_SWITCH_SHELL=1`) |

The continuous strategy first, because it never loses the user's context and
because the Kirigami apps that matter (Settings, Discover, Kalendar, Kongress)
already adapt. The shell swap is for users who want a *real* desktop panel and
window list, and it is one config flag away.

## 6. Boot chain on an Android phone

There is no GRUB on a phone. The relevant chain:

```
SoC boot ROM → Android bootloader (Qualcomm ABL / MediaTek LK)
             → boot partition: boot.img  (kernel + dtb + initramfs)
             → our initramfs /init
             → mount phi.root=  → switch_root → systemd
             → phi-phone.target (default) → phi-moded → session
```

Consequences for this repo:

- The `iso` target is a **VM-only** artifact. It exists to iterate quickly.
- The shippable artifact is a `boot.img` (`make bootimg DEVICE=...`), packed by
  a real `mkbootimg` rather than a hand-rolled header writer.
- `userdata` holds the Phi root filesystem so the stock OS stays intact and
  recoverable. Never flash experiments to `super` or `vendor_boot`.
- Slot A/B and AVB (`vbmeta`) are real. Read `docs/DEVICE-BRINGUP.md` before
  the first flash; boot loops on locked-verity devices are the normal first
  experience and the recovery procedure is not obvious.

## 7. Display paths, ranked by risk

This is the load-bearing assumption of the whole project, so it gets its own
table. "External display" is not one thing.

| Path | Works when | Latency | Risk | Notes |
| --- | --- | --- | --- | --- |
| USB-C DP altmode | SoC DPU + ports driver both work | best | **high** | Requires DP support in the SoC's DRM driver, typec altmode negotiation, and board wiring. Verify on the *stock* OS first: if the phone ships without video-out, the hardware may not route it. |
| DisplayLink (USB3) | any device with USB host | medium | low | Out-of-tree `evdi` or `udl` for DL-1xx; costs CPU to encode, so it is a battery compromise, not a free win. |
| Wi-Fi display (Miracast) | no cable needed at all | medium-high | medium | `wpa_supplicant` + `gnome-network-displays`/`miraclecast`. Attractive fallback; useless for a desk setup. |
| Remote session (VNC/RDP into the phone) | always | high | very low | Already possible. A legitimate product mode for "use my phone's desktop from a laptop". |
| USB-C hub only (no video) | keyboard, mouse, storage | n/a | very low | Works today on nearly every mainline port and is worth shipping on its own. |

**The honest position:** the convergence demo does not depend on DP altmode.
Peripherals over USB-C plus a remote or Wi-Fi display already produce a usable
desktop posture. Shipping that, and treating DP altmode as an enhancement
rather than a requirement, is the difference between a project that ships and
one that stalls on a driver.

## 8. Userland choice

Debian, because it is what the project already bootstraps, because arm64 is a
first-class Debian architecture, and because Mobian proved the model: Debian +
a phone shell + mainline device trees borrowed from postmarketOS, delivered as
an Android `boot.img`.

What Phi takes from postmarketOS is the *hard half*: device trees, kernel
fragments per SoC, `boot-deploy`, and the accumulated knowledge of what breaks
on each board. Reimplementing that from scratch is a multi-year distraction
from convergence, which is the actual differentiator.

## 9. Deliberate non-goals

- **No custom init system, compositor fork, or package manager.** Every hour
  spent there is an hour not spent on the dock, display, and battery behaviour
  that makes this product different.
- **No second desktop environment.** One shell stack, two shells.
- **No `tlp` alongside `powerdevil`.** They fight over the same knobs and the
  result is worse than either alone.
- **No GRUB on device.** It is a VM tool.

## 10. Risks and kill criteria

| Risk | Impact | Mitigation | Give up if |
| --- | --- | --- | --- |
| No DP altmode on target hardware | loses cable-based video | DisplayLink / Wi-Fi display / remote session; USB-C peripherals still work | never — there are three fallbacks |
| Mainline port stalls (panel, modem, camera) | device unusable as a phone | pick a well-supported codename; keep the stock OS bootable | 3 months with no working modem |
| Idle drain > 3 %/h | product is unusable off charger | EAS verification, s2idle, wakeup-source hunt (`docs/POWER.md`) | never — this is grindable |
| Plasma Mobile shell instability | bad demo | continuous strategy, no shell swap by default | if the shell crashes on dock in 1/3 attempts |
| Boot loop bricks the only device | project stops | buy two of the reference device; keep a backup image | — |
