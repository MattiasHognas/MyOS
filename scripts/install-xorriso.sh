#!/usr/bin/env bash
# Build the xorriso version MyOS's ISO images are made with, from a pinned,
# checksum-verified GNU release. Does nothing if that version is already
# installed in <prefix> and runs (e.g. restored from the CI cache). Needs
# only a C compiler and make.
#
# Usage: install-xorriso.sh <prefix>
# Afterwards: add <prefix>/bin to PATH.
set -euo pipefail

# The version and its checksum are in tools.versions.
source "$(dirname "$0")/../tools.versions"
version="$XORRISO_VERSION"
sha256="$XORRISO_SHA256"
url="https://www.gnu.org/software/xorriso/xorriso-$version.tar.gz"

prefix="${1:?usage: $0 <prefix>}"
xorriso="$prefix/bin/xorriso"
if [[ -x "$xorriso" ]] && "$xorriso" --version 2>&1 | head -n 1 | grep -qF "xorriso $version"; then
    echo "xorriso $version already installed in $prefix"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

curl -fsSL --retry 3 -o "$work/xorriso.tar.gz" "$url"
echo "$sha256  $work/xorriso.tar.gz" | sha256sum -c --quiet
tar -xzf "$work/xorriso.tar.gz" -C "$work"
# The directory in the archive is named without the patch level.
cd "$work"/xorriso-*/
./configure --prefix="$prefix" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
rm -rf "${prefix:?}/share/man" "${prefix:?}/share/info"
"$xorriso" --version 2>&1 | head -n 1
