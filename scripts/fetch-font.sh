#!/usr/bin/env bash
# Put the console font where the kernel embeds it (src/assets/font.psf).
#
# Uses the kbd package's default8x16 font if it is installed locally
# (/usr/share/kbd/consolefonts), otherwise downloads the same file from the
# kbd project at a pinned commit and verifies its checksum.
set -euo pipefail

dest="$(dirname "$0")/../src/assets/font.psf"
local_font="/usr/share/kbd/consolefonts/default8x16.psfu.gz"
kbd_commit="1800ad0b22651fccfdcb10b53ed485a62fea2171"
url="https://raw.githubusercontent.com/legionus/kbd/$kbd_commit/data/consolefonts/default8x16.psfu"
sha256="27c671292282a42ebb442100a37cc77712d5abebe087ac29b016e523e913fcfd"

mkdir -p "$(dirname "$dest")"
if [[ -f "$local_font" ]]; then
    gunzip -c "$local_font" >"$dest"
else
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$tmp" "$url"
    echo "$sha256  $tmp" | sha256sum -c --quiet
    mv "$tmp" "$dest"
fi
echo "font: $dest"
