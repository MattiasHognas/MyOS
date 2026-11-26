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
mkdir -p "$iso_root/boot/limine" "$iso_root/EFI/BOOT"

# The layout is Linux's (the Filesystem Hierarchy Standard), with /usr
# merged as Debian, Fedora and Arch have it: programs in /usr/bin,
# libraries in /usr/lib, and /bin, /sbin, /lib, /lib64 links into /usr,
# so that paths programs have written into them (/bin/sh, the loader in
# /lib64) lead there. docs/architecture.md says what goes where.
mkdir -p "$initrd/usr/bin" "$initrd/usr/lib" "$initrd/usr/lib64" "$initrd/etc" \
    "$initrd/home" "$initrd/root" "$initrd/opt" "$initrd/var" "$initrd/mnt" "$initrd/media" "$initrd/run"
ln -s usr/bin "$initrd/bin"
ln -s usr/bin "$initrd/sbin"
ln -s usr/lib "$initrd/lib"
ln -s usr/lib64 "$initrd/lib64"

cp zig-out/bin/sh.elf "$initrd/usr/bin/sh"
cp zig-out/bin/hello.elf "$initrd/usr/bin/hello"
printf 'Welcome to MyOS!\n' > "$initrd/etc/motd"
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
        # Where Debian has them: the libraries and the loader in
        # /usr/lib/x86_64-linux-gnu, and the loader's name in /usr/lib64
        # (which /lib64 is) a link to it.
        mkdir -p "$initrd/usr/lib/x86_64-linux-gnu"
        cp sysroot/lib/x86_64-linux-gnu/* "$initrd/usr/lib/x86_64-linux-gnu/"
        cp sysroot/lib64/ld-linux-x86-64.so.2 "$initrd/usr/lib/x86_64-linux-gnu/"
        ln -s ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$initrd/usr/lib64/ld-linux-x86-64.so.2"
    fi
fi
if [[ "$mode" == --package-test ]]; then
    # User-mode test programs: zig-out/bin/test-<name>.elf -> /test/<name>
    mkdir -p "$initrd/test"
    # A file of about 100 KiB with known contents, for tests that map or
    # read something larger than a page: "1\n2\n3\n...".
    seq 1 20000 >"$initrd/test/data"
    for f in zig-out/bin/test-*.elf; do
        name="$(basename "$f" .elf)"
        cp "$f" "$initrd/test/${name#test-}"
    done
    # Programs for Linux built from tests/fixtures/src with other
    # toolchains (tests/fixtures/build.sh, which builds what this machine
    # has toolchains for, and only when something changed): /fixtures/<name>.
    # Only in test images: they are not MyOS's to hand out.
    bash tests/fixtures/build.sh >/dev/null
    mkdir -p "$initrd/fixtures"
    cp -r tests/fixtures/bin/. "$initrd/fixtures/"
    rm -f "$initrd/fixtures/.stamp"
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
