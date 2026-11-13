# Phi Linux build system
#
# Two artifact tracks, because a phone is not a CD:
#   vm     : kernel + initramfs + ISO        (fast iteration in QEMU)
#   device : kernel + dtb + initramfs -> boot.img  (real Android hardware)
#
# The ISO track is for development only. Phones boot from an Android boot
# partition, not from GRUB on removable media.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ARCH        ?= arm64
BUILD       ?= build
KERNEL      ?= iso-root/Image
DTB         ?= $(BUILD)/dtb/$(DEVICE).dtb
INITRAMFS   ?= $(BUILD)/initramfs-$(ARCH).cpio.gz
BOOTIMG     ?= $(BUILD)/boot-$(DEVICE).img
ISO         ?= $(BUILD)/phi-linux-$(ARCH).iso
DISK        ?= $(BUILD)/rootfs.ext4
ISO_TREE    ?= iso-root
ROOTFS      ?= $(BUILD)/rootfs
SUITE       ?= trixie
MIRROR      ?= http://deb.debian.org/debian
DEVICE      ?=

# --- meta -------------------------------------------------------------------

help:
	@echo "Phi Linux"
	@echo ""
	@echo "  make deps                  install build packages for your distro"
	@echo "  make check                 verify toolchain, kernel arch, rootfs arch"
	@echo "  make initramfs             build the initramfs cpio.gz"
	@echo "  make run                   boot the VM track in QEMU (no ISO needed)"
	@echo "  make iso                   build a bootable ISO (VM track)"
	@echo "  make rootfs                debootstrap an arm64 Debian rootfs"
	@echo "  make disk                  pack build/rootfs into a bootable ext4 image"
	@echo "  make shell                 shell inside build/rootfs (chroot, no VM)"
	@echo "  make bootimg DEVICE=<codename>      pack kernel+dtb+initramfs -> boot.img"
	@echo "  make deploy DEVICE=<codename>       (dry-run) push boot.img to a device"
	@echo "  make kernel-config         merge Phi's kernel config fragments"
	@echo "  make power                 live battery / power state report"
	@echo "  make test                  run moded + script tests"
	@echo "  make container             build shell via the build container (any host)"
	@echo "  make clean                 remove build artifacts"
	@echo ""
	@echo "  DEVICE is a codename such as 'oneplus-enchilada'."
	@echo "  Read docs/DEVICE-BRINGUP.md before the first flash."

deps:
	@scripts/deps.sh $(if $(INSTALL),--install,--print) $(if $(GROUP),--group $(GROUP),)

check:
	@scripts/check-env.sh

# --- vm track ---------------------------------------------------------------

initramfs: $(INITRAMFS)

$(INITRAMFS): $(KERNEL) | $(BUILD)
	@scripts/mkinitramfs.sh --arch $(ARCH) --out $@ --rootfs $(ROOTFS)

iso:
	@scripts/mkiso.sh --tree $(ISO_TREE) --initramfs $(INITRAMFS) --out $(ISO)

# Boots the disk image when one exists; otherwise the initramfs rescue shell.
run: $(INITRAMFS)
	@if [ -f "$(DISK)" ]; then \
		scripts/run-qemu.sh --kernel $(KERNEL) --initramfs $(INITRAMFS) --disk $(DISK); \
	else \
		echo "note: no $(DISK); booting the initramfs rescue shell only"; \
		echo "      run 'make rootfs && make disk' for a full system"; \
		scripts/run-qemu.sh --kernel $(KERNEL) --initramfs $(INITRAMFS); \
	fi

# --- device track -----------------------------------------------------------

bootimg:
ifeq ($(strip $(DEVICE)),)
	@echo "error: DEVICE is required, e.g. make bootimg DEVICE=oneplus-enchilada"; exit 1
endif
	@scripts/mkbootimg-device.sh --device $(DEVICE) --kernel $(KERNEL) \
		--dtb $(DTB) --initramfs $(INITRAMFS) --out $(BOOTIMG)

deploy:
ifeq ($(strip $(DEVICE)),)
	@echo "error: DEVICE is required"; exit 1
endif
	@scripts/deploy-device.sh --device $(DEVICE) --bootimg $(BOOTIMG)

kernel-config:
	@scripts/merge-kernel-config.sh

# --- rootfs -----------------------------------------------------------------

disk:
	@scripts/mkdisk.sh --rootfs $(ROOTFS) --out $(DISK)

# Fastest loop for userspace work: your Debian system, no VM, no boot.
shell:
	@scripts/phi-chroot.sh

rootfs: | $(BUILD)
	@scripts/mkrootfs.sh --arch $(ARCH) --suite $(SUITE) --mirror $(MIRROR) \
		--out $(ROOTFS)

# --- diagnostics ------------------------------------------------------------

power:
	@scripts/power-report.sh

container:
	@scripts/phi-container.sh

test:
	@echo "== moded ==" && python3 -m unittest discover -s moded/tests -t moded -v
	@echo "== scripts ==" && for s in scripts/*.sh initramfs/init; do bash -n "$$s" || exit 1; done && echo "syntax ok"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)

.PHONY: help deps check initramfs iso run bootimg deploy rootfs disk shell kernel-config power test container clean
