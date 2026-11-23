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
# Tried in order until one answers. The first picks a GNU mirror near the
# caller; www.gnu.org itself sometimes does not answer CI runners at all.
# The checksum is the same whichever one delivers the file.
urls=(
    "https://ftpmirror.gnu.org/gnu/xorriso/xorriso-$version.tar.gz"
    "https://ftp.gnu.org/gnu/xorriso/xorriso-$version.tar.gz"
    "https://www.gnu.org/software/xorriso/xorriso-$version.tar.gz"
)

prefix="${1:?usage: $0 <prefix>}"
xorriso="$prefix/bin/xorriso"
if [[ -x "$xorriso" ]] && "$xorriso" --version 2>&1 | head -n 1 | grep -qF "xorriso $version"; then
    echo "xorriso $version already installed in $prefix"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

fetched=0
for url in "${urls[@]}"; do
    # Give up on a server that does not connect within 20 s or takes more
    # than 2 minutes, and try the next one.
    if curl -fsSL --connect-timeout 20 --max-time 120 -o "$work/xorriso.tar.gz" "$url"; then
        fetched=1
        break
    fi
    echo "could not download $url; trying the next location" >&2
done
((fetched)) || { echo "error: xorriso $version could not be downloaded from any location" >&2; exit 1; }
echo "$sha256  $work/xorriso.tar.gz" | sha256sum -c --quiet
tar -xzf "$work/xorriso.tar.gz" -C "$work"
# The directory in the archive is named without the patch level.
cd "$work"/xorriso-*/
./configure --prefix="$prefix" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
rm -rf "${prefix:?}/share/man" "${prefix:?}/share/info"
"$xorriso" --version 2>&1 | head -n 1
