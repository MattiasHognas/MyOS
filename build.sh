#!/usr/bin/env bash
set -euo pipefail

# Normal build: compile and package os.iso/disk.img as before.
# Test packaging: use prebuilt artifacts and keep all files under zig-out/test/.
mode="${1:-normal}"
case "$mode" in
    normal)
        zig build
        out_dir="."
        kernel="zig-out/bin/kernel.elf"
        ;;
    --package-test)
        out_dir="zig-out/test"
        kernel="zig-out/bin/kernel-test.elf"
        ;;
    *) echo "Usage: $0 [--package-test]" >&2; exit 2 ;;
esac

LIMINE="${LIMINE:-/usr/share/limine}"
iso_root="$out_dir/iso_root"
initrd="$out_dir/initrd"
mkdir -p "$out_dir"
rm -rf "$iso_root" "$initrd"
mkdir -p "$iso_root/boot/limine" "$iso_root/EFI/BOOT" "$initrd/bin" "$initrd/etc"

cp zig-out/bin/sh.elf "$initrd/bin/sh"
cp zig-out/bin/hello.elf "$initrd/bin/hello"
printf 'Welcome to MyOS!\n' > "$initrd/etc/motd"
tar --format=ustar -cf "$iso_root/boot/initrd.tar" -C "$initrd" .

# Limine config always refers to /boot/kernel.elf.
cp "$kernel" "$iso_root/boot/kernel.elf"
cp limine.conf "$iso_root/boot/limine/limine.conf"
cp "$LIMINE"/limine-{bios.sys,bios-cd.bin,uefi-cd.bin} "$iso_root/boot/limine/"
cp "$LIMINE/BOOTX64.EFI" "$iso_root/EFI/BOOT/"

if [[ "$mode" == normal && ! -f disk.img ]]; then
    truncate -s 64M disk.img
    printf 'Hello from the NVMe disk!' | dd of=disk.img conv=notrunc status=none
fi

xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$iso_root" -o "$out_dir/os.iso"
limine bios-install "$out_dir/os.iso"
