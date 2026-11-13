# Phi Linux — roadmap

Ordered so that every phase ends with something demonstrable, and so that the
riskiest assumption (external display) is tested before the most expensive work
(shell convergence) is done.

Effort is in focused weeks for one person. These are estimates, not promises.

---

## P0 — Boot in a VM (mostly done)

**State:** arm64 Debian kernel 6.12.115 boots under GRUB/QEMU. Userland is
x86-64 and the initramfs was never committed, so the artifact was not
reproducible.

**Work now done in this repo:** `Makefile`, `scripts/check-env.sh`,
`scripts/mkinitramfs.sh`, `scripts/mkiso.sh`, `scripts/run-qemu.sh`,
`initramfs/init`.

**Exit criteria**
- [ ] `make check` passes (fails today, correctly: x86-64 userland)
- [ ] `make rootfs` produces `build/rootfs` (arm64)
- [ ] `make disk` packs it into a bootable ext4 image
- [ ] `make initramfs` builds the initramfs
- [ ] `make run` reaches a systemd `multi-user` prompt on the serial console
- [ ] the same tree rebuilds from a clean clone on a second machine

## P1 — Real hardware boots to a shell (3-6 weeks)

The wall. Until a phone boots a shell, nothing else is real.

**Work**
- pick the reference codename, unlock, back up partitions
- inherit the device tree and kernel config from the postmarketOS port
- `make bootimg DEVICE=...`, dry-run deploy, first boot
- USB gadget networking for SSH-into-the-boot; `pstore` for post-mortems

**Exit criteria**
- [ ] `boot.img` flashes and the kernel reaches userspace
- [ ] journal accessible over USB networking
- [ ] panel + backlight + touch work
- [ ] root filesystem on `userdata`, stock OS still restorable
- [ ] a documented, tested recovery procedure (written down *before* it is needed)

**Kill criteria:** three months in, no working modem — switch to a different
codename rather than fighting the SoC.

## P2 — Phone posture is usable (3-4 weeks)

A phone that runs a desktop is useless if it is not a phone.

**Work**
- Plasma Mobile session autostarts to the mobile shell
- modem: calls, SMS, data via ModemManager
- Wi-Fi, Bluetooth, audio (UCM profile), sensors
- calls do not break when the screen rotates or a headset attaches

**Exit criteria**
- [ ] a full day carrying only Phi: call, message, browse, photograph nothing (camera is P5)
- [ ] battery ≥ 12 h of light use
- [ ] no silent crash of the session in a day of normal use

## P3 — Convergence MVP (4-6 weeks)

The demo that defines the product.

**Work**
- external display: test DP altmode first; if it fails, ship DisplayLink or
  Wi-Fi display and keep going (see `docs/ARCHITECTURE.md` §7)
- `phi-moded` + targets + session bridge (already in this repo, untested on hardware)
- output layout: external primary, phone panel off while docked
- desktop shell: continuous strategy first, shell swap behind a flag
- USB-C hub: keyboard, mouse, storage, Ethernet

**Exit criteria**
- [ ] plug in a display+keyboard: desktop appears in under 3 s, windows survive
- [ ] unplug: phone shell returns, panel restores at previous brightness
- [ ] mode flapping: 20 plug/unplug cycles with no wrong state and no stuck screen
- [ ] `phi-moded status` explains the current posture in one screen

## P4 — Battery is credible (4-6 weeks, ongoing)

See `docs/POWER.md` for the numbers and the protocol.

**Work**
- verify EAS is actually active (energy model present, `schedutil`, correct EPP)
- `s2idle` working: modem, Wi-Fi WoWLAN, touch, USB-C PD as wakeup sources
- kill userspace wakeups; make `upowerd` event-driven
- zram tuned for pressure, not for fun
- docked: charge cap, panel off, DPMS on the external output

**Exit criteria**
- [ ] ≤ 1.5 %/h idle with LTE standby, measured, twice, on different days
- [ ] wakes from suspend reliably (100 cycles, no black screen)
- [ ] `scripts/power-report.sh` in CI as a soft regression signal

## P5 — Product (ongoing)

- Waydroid for Android apps (binderfs is already in the kernel fragment)
- encrypted root with a sane unlock (PIN/password on a phone keyboard)
- A/B OTA updates, or a documented `boot-deploy`-based update path
- camera (`libcamera`), which is usually the last big mainline gap
- accessories: dock detection for a *specific* dock, alert-slider mode toggle

**Exit criteria**
- [ ] a non-developer can install and update Phi
- [ ] an app with no Linux build still runs (Waydroid)

---

## Sequencing rationale

1. **Boot before shell.** Shell work on a device that does not boot is
   speculative.
2. **Display path before shell convergence.** If DP altmode does not work, the
   desktop posture still exists — but the shell work changes shape. Find out
   first, cheaply.
3. **Battery after convergence.** Not because it is less important, but because
   you cannot measure idle drain until the device suspends and the modem is up.
4. **Waydroid late.** It is a large dependency and it will not save a phone that
   cannot make a call.
