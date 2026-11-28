#!/usr/bin/env bash
# Fetch the C library that dynamically linked Linux programs expect to find
# on the system, and unpack it to sysroot/, from where scripts/build.sh puts
# it into the image.
#
# A program built for Linux the ordinary way brings its own code and names
# the rest: the dynamic loader (/lib64/ld-linux-x86-64.so.2) and shared
# libraries (libc.so.6, libm.so.6, libstdc++.so.6, libgcc_s.so.1). Every
# Linux distribution ships those; MyOS takes them, unchanged, from Debian 13
# (glibc 2.41, GCC 14), built for any x86-64 CPU. The packages are pinned
# by checksum.
#
# They are not part of the repository (sysroot/ is ignored), and are
# licensed under the LGPL and the GPL with the GCC runtime exception: an
# image that contains them passes them on, with what that asks for. A
# release image carries none; its user adds them (add-glibc.sh).
#
# Usage: fetch.sh <dest>     (does nothing if <dest> is complete)
#
# Used by scripts/fetch-sysroot.sh (dest sysroot/, for test images) and by
# add-glibc.sh (for a release image, on the user's machine).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:?Usage: $0 <dest>}"
stamp="$dest/.complete"
# <file in Debian's pool> <sha256>, from packages.txt beside this script.
mapfile -t packages < <(grep -v '^#' "$here/packages.txt" | grep -v '^$')
# The mirror drops a file when a newer one replaces it; the snapshot
# archive keeps every one.
mirrors=(
    "https://deb.debian.org/debian"
    "https://snapshot.debian.org/archive/debian/20261120T000000Z"
)
# What an image gets: the loader where programs name it, the libraries
# where that loader looks first.
libdir="lib/x86_64-linux-gnu"
libs=(libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libgcc_s.so.1 libstdc++.so.6)

want="$(printf '%s\n' "${packages[@]}" | sha256sum | cut -d' ' -f1)"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]]; then
    echo "sysroot: $dest (up to date)"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/root"
for entry in "${packages[@]}"; do
    read -r file sha256 <<<"$entry"
    deb="$work/$(basename "$file")"
    for mirror in "${mirrors[@]}"; do
        curl -fsSL --retry 2 --connect-timeout 20 --max-time 300 -o "$deb" "$mirror/$file" && break
    done
    echo "$sha256  $deb" | sha256sum -c --quiet
    # A .deb is an ar archive; its files are in data.tar.*
    (cd "$work" && ar x "$deb" && tar -xf data.tar.* -C root && rm -f data.tar.* control.tar.* debian-binary)
done

rm -rf "$dest"
mkdir -p "$dest/lib64" "$dest/$libdir"
# Real files, not Debian's symbolic links: the initrd has none.
cp -L "$work/root/usr/lib64/ld-linux-x86-64.so.2" "$dest/lib64/" 2>/dev/null ||
    cp -L "$work/root/usr/$libdir/ld-linux-x86-64.so.2" "$dest/lib64/"
for lib in "${libs[@]}"; do
    cp -L "$work/root/usr/$libdir/$lib" "$dest/$libdir/"
done
echo "$want" >"$stamp"
echo "sysroot: $dest"
ls -l "$dest/lib64" "$dest/$libdir"
