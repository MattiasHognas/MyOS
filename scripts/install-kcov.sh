#!/usr/bin/env bash
# Build kcov from a pinned, checksum-verified source release. Ubuntu 24.04
# has no kcov package. Build dependencies (Ubuntu):
#   cmake binutils-dev libssl-dev libcurl4-openssl-dev libelf-dev zlib1g-dev
#   libdw-dev libiberty-dev
#
# Usage: install-kcov.sh <prefix>
# Afterwards: add <prefix>/bin to PATH.
set -euo pipefail

version="43"
sha256="4cbba86af11f72de0c7514e09d59c7927ed25df7cebdad087f6d3623213b95bf"
url="https://github.com/SimonKagstrom/kcov/archive/refs/tags/v$version.tar.gz"

prefix="${1:?usage: $0 <prefix>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/kcov.tar.gz" "$url"
echo "$sha256  $work/kcov.tar.gz" | sha256sum -c --quiet
tar -xzf "$work/kcov.tar.gz" -C "$work"
cmake -S "$work/kcov-$version" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
cmake --build "$work/build" --parallel "$(nproc)" >/dev/null
cmake --install "$work/build" >/dev/null
"$prefix/bin/kcov" --version
