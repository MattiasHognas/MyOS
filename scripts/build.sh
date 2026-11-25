#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."  # run from the repository root

# Normal build: compile and package os.iso/disk.img as before.
# Test packaging: use prebuilt artifacts and keep all files under zig-out/test/.
# Release: build an optimized kernel that reports <version> and write
#   zig-out/release/myos-<version>.iso, myos-<version>-kernel.elf (with
#   symbols, for symbolizing backtraces) and SHA256SUMS.
# What makes the ISO must be the pinned versions in CI; elsewhere a
# difference is a warning (scripts/check-tools.sh).
bash scripts/check-tools.sh zig limine xorriso

mode="${1:-normal}"
iso_name="os.iso"
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
    --release)
        version="${2:?Usage: $0 --release <version>}"
        # ReleaseSafe: optimized, with Zig's safety checks still on.
        zig build -Doptimize=ReleaseSafe -Dversion="$version"
        out_dir="zig-out/release"
        kernel="zig-out/bin/kernel.elf"
        iso_name="myos-$version.iso"
        rm -rf "$out_dir"
        ;;
    *) echo "Usage: $0 [--package-test | --release <version>]" >&2; exit 2 ;;
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
# Programs built for Linux by other toolchains (tests/fixtures), to run by hand.
cp tests/fixtures/bin/* "$initrd/bin/"
# The C library dynamically linked Linux programs expect on the system:
# the loader and shared libraries of scripts/fetch-sysroot.sh, if they have
# been fetched. Not in a release image: passing them on has licence terms
# of its own (see that script).
if [[ "$mode" != --release && -f sysroot/.complete ]]; then
    cp -r sysroot/lib64 sysroot/lib "$initrd/"
elif [[ "$mode" != --release ]]; then
    echo "note: no sysroot/ (scripts/fetch-sysroot.sh): dynamically linked programs will not start" >&2
fi
if [[ "$mode" == --package-test ]]; then
    # User-mode test programs: zig-out/bin/test-<name>.elf -> /test/<name>
    mkdir -p "$initrd/test"
    for f in zig-out/bin/test-*.elf; do
        name="$(basename "$f" .elf)"
        cp "$f" "$initrd/test/${name#test-}"
    done
    # Programs built for Linux by other toolchains (tests/fixtures): /fixtures/<name>
    mkdir -p "$initrd/fixtures"
    cp tests/fixtures/bin/* "$initrd/fixtures/"
fi
tar --format=ustar -cf "$iso_root/boot/initrd.tar" -C "$initrd" .

# Limine config always refers to /boot/kernel.elf.
cp "$kernel" "$iso_root/boot/kernel.elf"
# MYOS_KASLR=no loads the kernel at its link address, for debuggers, which
# read symbol addresses from the ELF file (docs/debugging.md).
if [[ "${MYOS_KASLR:-yes}" == no ]]; then
    sed 's/kaslr: yes/kaslr: no/' limine.conf >"$iso_root/boot/limine/limine.conf"
else
    cp limine.conf "$iso_root/boot/limine/limine.conf"
fi
cp "$LIMINE"/limine-{bios.sys,bios-cd.bin,uefi-cd.bin} "$iso_root/boot/limine/"
cp "$LIMINE/BOOTX64.EFI" "$iso_root/EFI/BOOT/"

if [[ "$mode" == normal && ! -f disk.img ]]; then
    truncate -s 64M disk.img # empty NVMe disk for scripts/run-qemu.sh
fi

xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$iso_root" -o "$out_dir/$iso_name"
limine bios-install "$out_dir/$iso_name"

if [[ "$mode" == --release ]]; then
    cp "$kernel" "$out_dir/myos-$version-kernel.elf"
    rm -rf "$iso_root" "$initrd" # only the release files stay in $out_dir
    (cd "$out_dir" && sha256sum myos-* >SHA256SUMS)
    echo "release files in $out_dir:"
    ls -l "$out_dir"
fi
