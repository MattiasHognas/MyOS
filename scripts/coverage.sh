#!/usr/bin/env bash
# Run a test binary under kcov. Called by `zig build coverage`.
#
# Usage: coverage.sh <source dir to include> <output dir> <test binary>
set -euo pipefail

if ! command -v kcov >/dev/null; then
    cat >&2 <<'MSG'
kcov is not installed, so coverage cannot be measured.
  Arch:          sudo pacman -S kcov
  Debian/Ubuntu: build it with scripts/install-kcov.sh (see docs/development.md)
MSG
    exit 1
fi

# kcov matches the absolute source paths in the debug info. Its output (the
# test runner's progress) is only shown if something fails, because zig build
# reports any stderr output of a step as if the command had failed.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! kcov --clean --include-path="$(realpath "$1")" "$2" "$3" >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
fi
