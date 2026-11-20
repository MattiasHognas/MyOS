#!/usr/bin/env bash
set -euo pipefail

zig build

LIMINE=/usr/share/limine
rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT

rm -rf initrd
mkdir -p initrd/bin initrd/etc

cp zig-out/bin/hello.elf initrd/bin/hello
echo "Welcome to MyOS!" > initrd/etc/motd
tar --format=ustar -cf iso_root/boot/initrd.tar -C initrd .

cp zig-out/bin/kernel.elf iso_root/boot/
cp limine.conf "$LIMINE"/limine-{bios.sys,bios-cd.bin,uefi-cd.bin} iso_root/boot/limine/
cp "$LIMINE"/BOOTX64.EFI iso_root/EFI/BOOT/

cp zig-out/bin/hello.elf iso_root/boot/

if [ ! -f disk.img ]; then
    truncate -s 64M disk.img
    printf 'Hello from the NVMe disk!' | dd of=disk.img conv=notrunc status=none
fi

xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
  -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  iso_root -o os.iso

limine bios-install os.iso