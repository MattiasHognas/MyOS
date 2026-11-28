#!/usr/bin/env bash
# Add the C library that dynamically linked Linux programs need (glibc,
# libgcc_s, libstdc++: Debian 13's, pinned by checksum in packages.txt) to
# a MyOS release image, on your own machine.
#
# A release image carries no C library: MyOS does not pass it on (its
# licences ask things of whoever does). Programs built for Linux that are
# linked statically run without it; the ordinary output of `gcc`, `cargo
# build` and `dotnet publish` (without Native AOT and static linking) needs
# it. This fetches the packages from Debian, checks them, and writes a new
# image with the libraries where those programs look for them
# (/usr/lib/x86_64-linux-gnu, and /lib64/ld-linux-x86-64.so.2).
#
# Usage: add-glibc.sh <myos-VERSION.iso> [<output.iso>]
#        (output: <name>-glibc.iso next to the input)
#
# Needs: bash, curl, sha256sum, ar (binutils), tar, xorriso; and `limine`
# for booting the result from a USB stick on a BIOS machine (without it the
# image still boots as a CD and on UEFI, and this says so).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

in="${1:?Usage: $0 <myos.iso> [<output.iso>]}"
out="${2:-${in%.iso}-glibc.iso}"
[[ -f "$in" ]] || { echo "add-glibc: no such file: $in" >&2; exit 2; }
for tool in curl sha256sum ar tar xorriso; do
    command -v "$tool" >/dev/null || { echo "add-glibc: needs $tool" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. The libraries, fetched and checked. (MYOS_GLIBC_SYSROOT: ones
#    fetch.sh fetched before, for test.sh, which runs without a network.)
sysroot="$work/sysroot"
if [[ -n "${MYOS_GLIBC_SYSROOT:-}" ]]; then
    sysroot="$MYOS_GLIBC_SYSROOT"
    [[ -f "$sysroot/.complete" ]] || { echo "add-glibc: $sysroot is not complete" >&2; exit 2; }
else
    bash "$here/fetch.sh" "$sysroot" >/dev/null
fi

# 2. The image's files.
xorriso -osirrox on -indev "$in" -extract / "$work/iso" 2>/dev/null
chmod -R u+w "$work/iso"
initrd="$work/iso/boot/initrd.tar"
[[ -f "$initrd" ]] || { echo "add-glibc: $in is not a MyOS image (no boot/initrd.tar)" >&2; exit 1; }
if tar -tf "$initrd" | grep -q 'usr/lib/x86_64-linux-gnu/libc.so.6$'; then
    echo "add-glibc: $in has a C library already" >&2
    exit 1
fi

# 3. Added to the initrd where build.sh puts them in test images: the
#    libraries and the loader in /usr/lib/x86_64-linux-gnu, the loader's
#    name in /usr/lib64 (which /lib64 is) a link to it.
add="$work/add"
mkdir -p "$add/usr/lib/x86_64-linux-gnu" "$add/usr/lib64"
cp "$sysroot/lib/x86_64-linux-gnu/"* "$add/usr/lib/x86_64-linux-gnu/"
cp "$sysroot/lib64/ld-linux-x86-64.so.2" "$add/usr/lib/x86_64-linux-gnu/"
ln -s ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$add/usr/lib64/ld-linux-x86-64.so.2"
# (The image has ./usr/lib and ./usr/lib64 already; tar keeps the first
# of an entry, so only what is new is added.)
tar --format=ustar -rf "$initrd" -C "$add" ./usr/lib/x86_64-linux-gnu ./usr/lib64/ld-linux-x86-64.so.2

# 4. The image again, made as scripts/build.sh makes it.
xorriso -as mkisofs -R -r -J \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
    -apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$work/iso" -o "$out" 2>/dev/null
if command -v limine >/dev/null; then
    limine bios-install "$out" >/dev/null
else
    echo "add-glibc: no limine tool: $out boots as a CD and on UEFI, not from a USB stick on a BIOS machine" >&2
fi
echo "add-glibc: $out"
