# Phi Linux — device bring-up (Android phones)

Everything in this document is about survival: keeping a phone you cannot
afford to lose bootable while you replace its operating system.

## 1. Choosing the first device

Criteria, in order:

1. **A mainline port already exists** (postmarketOS device page, or the
   upstream `arch/arm64/boot/dts/qcom` tree). You are not writing a SoC port.
2. **The modem works on that port.** A phone without calls is a tablet.
3. **Bootloader is unlockable without an exploit**, and you accept the wipe.
4. **USB-C video out exists in hardware** — check on the *stock* OS with a
   USB-C→HDMI adapter *before* buying. If the stock OS does not do video out,
   assume the hardware does not either, and plan on the fallbacks in
   `docs/ARCHITECTURE.md`.
5. **Two of them are affordable.** One will get stuck in a state you cannot
   recover from on a bad evening.

Reference target in this repo: `oneplus-enchilada` (sdm845) — a template, not a
verified port. Other well-trodden options are other sdm845 devices and the
Fairphone 4 / Xperia 10 III class. Verify support status on the postmarketOS
wiki before committing: mainline support is per-codename, not per-SoC, and it
changes month to month.

## 2. Before you flash anything

```sh
# the stock OS, booted and healthy:
adb shell getprop ro.product.device          # codename
adb shell getprop ro.boot.slot_suffix        # _a or _b
adb reboot bootloader
fastboot getvar product
fastboot getvar unlocked
fastboot getvar current-slot

# back up the partitions you are about to touch
fastboot fetch boot_a boot_a-stock.img
fastboot fetch vbmeta_a vbmeta_a-stock.img
```

Store those backups somewhere that is not the phone. If `fastboot fetch` is not
supported on your fastboot version, get the images from a stock ROM package for
your exact build number — not "the same model", the same build.

## 3. Unlocking (changes per OEM, none of it is optional)

| OEM family | Reality |
| --- | --- |
| Google / OnePlus / Fairphone / Sony | documented unlock flow, wipes data |
| Xiaomi | account-bound, often a multi-day waiting period |
| Samsung | Knox permanently tripped, warranty gone, no way back |
| Huawei | effectively closed for recent devices — pick another phone |

The unlock **wipes userdata**, which is also where Phi will live. Do it once,
at the start.

## 4. Partition model

Phi does not reformat the phone's Android partitions. The layout it assumes:

```
boot_a / boot_b      Phi boot.img  (kernel + dtb + initramfs)
vendor_boot          untouched, except where the port's dtb must live there (v4)
userdata             Phi root filesystem  (LUKS, ext4/btrfs)
super                untouched — the stock system, kept for recovery
vbmeta               untouched unless the port documents otherwise
```

`phi.root=` in the device profile points at the root filesystem inside
`userdata`. Keeping `super` intact is what lets you go back to Android by
flashing stock `boot`/`vbmeta`.

**Never flash an experiment to `vendor_boot` or `super` as a first step.**
A boot image that fails to boot is recoverable with fastboot. A corrupted
super partition is a multi-hour low-level recovery, or a paperweight.

## 5. First boot: expect silence

The first Phi boot will probably do nothing visible. That is normal and it is
not diagnosable through the touchscreen. Have one of these before you start:

| Channel | Requirement | Use |
| --- | --- | --- |
| Debug UART (`ttyMSM0`) | disassembly / test points | the only true early console |
| USB gadget networking | kernel + initramfs with `g_ether`/`rndis`, `172.16.42.1` | SSH into the booting system; postmarketOS does this |
| `pstore`/`ramoops` | `CONFIG_PSTORE_RAM` + dtb reserve-memory node | read the panic from the *next* boot |
| Bootloader logs | `fastboot oem ...`, varies | tells you if boot.img was even accepted |

Practical order: build the smallest possible initramfs that starts a shell on
the USB gadget, get that much working, and only then add systemd and Plasma.

```sh
make initramfs
make bootimg DEVICE=oneplus-enchilada
scripts/deploy-device.sh --device oneplus-enchilada --bootimg build/boot-oneplus-enchilada.img
# (dry run first; then --yes)
```

## 6. Bring-up order

Each step ends with something observable. Do not skip ahead; a phone that
cannot show a console is not ready for a desktop mode.

1. **Kernel boots at all** — you see *any* output on UART/USB/gadget.
2. **Initramfs runs** — shell, `mount`, `dmesg`.
3. **Root filesystem mounts** — `phi.root=` is right, LUKS opens.
4. **systemd reaches multi-user** — journal is readable.
5. **Display and backlight** — panel shows a console; brightness controllable.
6. **Touch input** — `evtest` shows events; rotation from `iio-sensor-proxy`.
7. **USB** — host mode with a hub, gadget mode with networking.
8. **Wi-Fi** — associated, DHCP, powersave toggles.
9. **Modem** — `ModemManager` registers on the network; call + SMS + data.
10. **Audio** — speaker, earpiece, headset, with correct UCM profile.
11. **Suspend** — `echo freeze > /sys/power/state` resumes cleanly.
12. **Only now:** Plasma Mobile session, then `phi-moded`, then convergence.

Steps 1-4 are the wall. Everything after is per-driver grind with visible
progress, which is why the convergence work is scheduled after a booting
rootfs (see `docs/ROADMAP.md`).

## 7. Keeping the port alive

- Keep the device tree and kernel patches in this repo under `config/devices/`
  and a `ports/` directory once you start carrying patches, not in a
  half-remembered local branch.
- Use `boot-deploy` (from postmarketOS) on-device once the port boots: it
  regenerates `boot.img` from `/boot` after every kernel update, so a kernel
  bump does not require a host-side repack.
- Upstream every device tree change you can. A privately maintained board is a
  board that dies at the next kernel release.
- Record the stock partition backups and the exact fastboot commands that
  restored the device. You will need them again.
