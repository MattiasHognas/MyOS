#!/usr/bin/env bash
set -euo pipefail

zig build

LIMINE=/usr/share/limine
rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT

cp zig-out/bin/kernel.elf iso_root/boot/
cp limine.conf "$LIMINE"/limine-{bios.sys,bios-cd.bin,uefi-cd.bin} iso_root/boot/limine/
cp "$LIMINE"/BOOTX64.EFI iso_root/EFI/BOOT/

xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
  -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  iso_root -o os.iso

limine bios-install os.iso