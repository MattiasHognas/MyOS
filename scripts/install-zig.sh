#!/usr/bin/env bash
# Install the Zig version MyOS uses (x86_64 Linux) into a directory, from
# ziglang.org with checksum verification. Does nothing if that version is
# already installed there (e.g. restored from the CI cache).
#
# Usage: install-zig.sh <directory>
# Afterwards: add <directory> to PATH.
set -euo pipefail

version="0.17.1"
sha256="3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"
url="https://ziglang.org/download/$version/zig-x86_64-linux-$version.tar.xz"

dir="${1:?usage: $0 <directory>}"
if [[ -x "$dir/zig" && "$("$dir/zig" version)" == "$version" ]]; then
    echo "zig $version already installed in $dir"
    exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "$url"
echo "$sha256  $tmp" | sha256sum -c --quiet
rm -rf "$dir"
mkdir -p "$dir"
tar -xJf "$tmp" -C "$dir" --strip-components=1
"$dir/zig" version
