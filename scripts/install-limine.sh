#!/usr/bin/env bash
# Download the Limine binary release, verify it, and build the `limine` host
# tool. Used by CI; locally, the distribution package works just as well.
#
# Usage: install-limine.sh <directory>
# Afterwards: export LIMINE=<directory> and add <directory> to PATH.
set -euo pipefail

# The version and its checksum are in tools.versions.
source "$(dirname "$0")/../tools.versions"
version="$LIMINE_VERSION"
sha256="$LIMINE_SHA256"
url="https://github.com/Limine-Bootloader/Limine/releases/download/v$version/limine-binary.tar.gz"

dir="${1:?usage: $0 <directory>}"
mkdir -p "$dir"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp" "$url"
echo "$sha256  $tmp" | sha256sum -c --quiet
tar -xzf "$tmp" -C "$dir" --strip-components=1
make -C "$dir" >/dev/null
"$dir/limine" --version | head -n 1
