#!/usr/bin/env bash
# Download the Limine binary release, verify it, and build the `limine` host
# tool. Used by CI; locally, the distribution package works just as well.
#
# Usage: install-limine.sh <directory>
# Afterwards: export LIMINE=<directory> and add <directory> to PATH.
set -euo pipefail

version="12.10.0"
sha256="365ba8785d4e4b55c3368738a642681b31f606afec9f77179e07fc26ebe841e2"
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
