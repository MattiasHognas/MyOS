#!/usr/bin/env bash
# Fetch the native part of the .NET runtime (its JIT compiler, garbage
# collector and host libraries, as shared libraries) and unpack it to
# dotnet-runtime/, from where scripts/build.sh completes the .NET test
# program with it.
#
# `dotnet publish -r linux-x64 --self-contained` copies these files,
# unchanged, from Microsoft's runtime package into every program's folder:
# 20 MB that are the same for all of them. The repository holds the rest
# of such a folder (tests/fixtures/bin/dotnet-hello-app) and takes these
# from the package itself, pinned by version and checksum. The version is
# the one the folder was published with (tests/fixtures/build.sh says how
# to change both together).
#
# Usage: scripts/fetch-dotnet-runtime.sh   (does nothing if it is complete)
set -euo pipefail
cd "$(dirname "$0")/.."

version="10.0.13"
sha256="28c62a37549d17009f457ac53cd4acdd60f1598ba3f00e22587bbac318c679c6"
package="microsoft.netcore.app.runtime.linux-x64"
url="https://api.nuget.org/v3-flatcontainer/$package/$version/$package.$version.nupkg"
dest="dotnet-runtime"
stamp="$dest/.complete"

if [[ -f "$stamp" && "$(cat "$stamp")" == "$version $sha256" ]]; then
    echo "dotnet runtime: $dest (up to date)"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The package may be here already, if .NET programs are built on this machine.
cached="$HOME/.nuget/packages/$package/$version/$package.$version.nupkg"
if [[ -f "$cached" ]] && echo "$sha256  $cached" | sha256sum -c --quiet 2>/dev/null; then
    cp "$cached" "$work/runtime.nupkg"
else
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$work/runtime.nupkg" "$url"
    echo "$sha256  $work/runtime.nupkg" | sha256sum -c --quiet
fi
# A .nupkg is a zip archive.
unzip -q -j "$work/runtime.nupkg" 'runtimes/linux-x64/native/*' -d "$work/native"

rm -rf "$dest"
mkdir -p "$dest"
# The shared libraries and the one program (createdump) a publish folder gets.
cp "$work"/native/*.so "$work/native/createdump" "$dest/"
echo "$version $sha256" >"$stamp"
echo "dotnet runtime: $dest ($version)"
ls -l "$dest"
