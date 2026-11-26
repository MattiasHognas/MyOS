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
find tests/fixtures/bin -maxdepth 1 -type f -exec cp {} "$initrd/bin/" \;
# With the notices of the code their toolchains put into them.
cp tests/fixtures/THIRD_PARTY_NOTICES.txt "$initrd/bin/"
# The C library dynamically linked Linux programs expect on the system:
# the loader and shared libraries of scripts/fetch-sysroot.sh, fetched the
# first time (and checked against pinned checksums) so that a program
# built with plain gcc or cargo runs without anything else to do. Without
# a network the image is built without them, with a warning. Not in a
# release image: passing them on has licence terms of its own (see that
# script), which are to be settled first.
if [[ "$mode" != --release ]]; then
    if [[ ! -f sysroot/.complete ]]; then
        bash scripts/fetch-sysroot.sh >/dev/null || echo "warning: could not fetch the C library (scripts/fetch-sysroot.sh): dynamically linked programs will not start" >&2
    fi
    if [[ -f sysroot/.complete ]]; then
        cp -r sysroot/lib64 sysroot/lib "$initrd/"
    fi
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
    cp -r tests/fixtures/bin/* "$initrd/fixtures/"
    cp tests/fixtures/THIRD_PARTY_NOTICES.txt "$initrd/fixtures/"
    # The .NET program published as a folder is complete with the runtime's
    # native libraries, which every such folder has the same copy of
    # (scripts/fetch-dotnet-runtime.sh). Without them it is left out, and
    # the kernel test for it says so.
    if [[ -f dotnet-runtime/.complete ]]; then
        cp dotnet-runtime/* "$initrd/fixtures/dotnet-hello-app/"
    else
        rm -rf "$initrd/fixtures/dotnet-hello-app"
        echo "note: no dotnet-runtime/ (scripts/fetch-dotnet-runtime.sh): the self-contained .NET program is left out" >&2
    fi
fi
# Anything else the image is to hold: the tree under MYOS_INITRD_EXTRA is
# copied over the root, so <dir>/app/hello becomes /app/hello. This is how
# a program built elsewhere (a `dotnet publish` folder, say) gets into an
# image until there is a disk to copy it to.
if [[ -n "${MYOS_INITRD_EXTRA:-}" ]]; then
    cp -rL "$MYOS_INITRD_EXTRA"/. "$initrd/"
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
