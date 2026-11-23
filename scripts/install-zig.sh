#!/usr/bin/env bash
# Install the Zig version MyOS uses (x86_64 Linux) into a directory, from
# ziglang.org with checksum verification. Does nothing if that version is
# already installed there (e.g. restored from the CI cache).
#
# Usage: install-zig.sh <directory>
# Afterwards: add <directory> to PATH.
set -euo pipefail

# The version and its checksum are in tools.versions.
source "$(dirname "$0")/../tools.versions"
version="$ZIG_VERSION"
sha256="$ZIG_SHA256"
url="https://ziglang.org/download/$version/zig-x86_64-linux-$version.tar.xz"

dir="${1:?usage: $0 <directory>}"
if [[ -x "$dir/zig" && "$("$dir/zig" version)" == "$version" ]]; then
    echo "zig $version already installed in $dir"
    exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$tmp" "$url"
echo "$sha256  $tmp" | sha256sum -c --quiet
rm -rf "$dir"
mkdir -p "$dir"
tar -xJf "$tmp" -C "$dir" --strip-components=1
"$dir/zig" version
