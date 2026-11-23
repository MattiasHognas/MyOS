#!/usr/bin/env bash
# Build the QEMU version MyOS is developed and tested with, from a pinned,
# checksum-verified source release: only the x86-64 system emulator, with
# no display, audio or network backends. Ubuntu's package is several major
# versions older. Does nothing if that version is already installed in
# <prefix> and runs (e.g. restored from the CI cache). Build dependencies
# (Ubuntu):
#   ninja-build pkg-config python3-venv libglib2.0-dev libpixman-1-dev
#
# Usage: install-qemu.sh <prefix>
# Afterwards: add <prefix>/bin to PATH.
set -euo pipefail

# The version and its checksum are in tools.versions.
source "$(dirname "$0")/../tools.versions"
version="$QEMU_VERSION"
sha256="$QEMU_SHA256"
url="https://download.qemu.org/qemu-$version.tar.xz"

prefix="${1:?usage: $0 <prefix>}"
qemu="$prefix/bin/qemu-system-x86_64"
if [[ -x "$qemu" ]] && "$qemu" --version 2>/dev/null | head -n 1 | grep -qF "version $version"; then
    echo "QEMU $version already installed in $prefix"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

curl -fsSL --retry 3 -o "$work/qemu.tar.xz" "$url"
echo "$sha256  $work/qemu.tar.xz" | sha256sum -c --quiet
tar -xJf "$work/qemu.tar.xz" -C "$work"
cd "$work/qemu-$version"
# Everything optional is off, then the two accelerators are named: TCG is
# what the tests run on, KVM costs nothing to keep for local use.
./configure --prefix="$prefix" --target-list=x86_64-softmmu \
    --without-default-features --enable-tcg --enable-kvm --enable-pixman \
    --disable-docs --disable-werror >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
rm -rf "${prefix:?}/share/doc" "${prefix:?}/share/man"
# Firmware for other architectures is most of the install (and of the CI
# cache). Keep what a PC needs: the BIOS, the VGA BIOSes and option ROMs.
find "${prefix:?}/share/qemu" -mindepth 1 -maxdepth 1 \
    ! -name 'bios*.bin' ! -name 'vgabios*.bin' ! -name '*.rom' \
    ! -name 'kvmvapic.bin' ! -name 'linuxboot*.bin' ! -name 'multiboot*.bin' ! -name 'pvh.bin' \
    -exec rm -rf {} +
"$qemu" --version | head -n 1
