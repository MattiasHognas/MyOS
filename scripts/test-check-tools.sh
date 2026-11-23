#!/usr/bin/env bash
# Test scripts/check-tools.sh against fake tools that report chosen versions.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-tools.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tools.versions"

# Each case gets a fresh directory of fake tools under this one.
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
bin=""
case_no=0

# The few ordinary commands check-tools.sh needs. The real /usr/bin is kept
# off PATH, or the tools installed on this machine would be found.
base="$work/base"
mkdir "$base"
for command in bash sh grep head dirname; do
    ln -s "$(command -v "$command")" "$base/$command"
done

# Start a new, empty directory of fake tools.
new_bin() {
    case_no=$((case_no + 1))
    bin="$work/bin$case_no"
    mkdir "$bin"
}

# fake <command> <version output>: a command that prints that line.
fake() {
    printf '#!/bin/sh\necho "%s"\n' "$2" >"$bin/$1"
    chmod +x "$bin/$1"
}

# All four tools at the pinned versions, in each tool's real output format.
all_right() {
    new_bin
    fake zig "$ZIG_VERSION"
    fake limine "Limine $LIMINE_VERSION"
    fake qemu-system-x86_64 "QEMU emulator version $QEMU_VERSION"
    fake xorriso "xorriso $XORRISO_VERSION : RockRidge filesystem manipulator, libburnia project."
}

# All four, except the one named $1.
all_but() {
    all_right
    mv "$bin/$1" "$work/unused$case_no"
}

failures=0
# expect <name> <exit status> <text the output must contain, or ''> <env...> -- [tools...]
expect() {
    local name="$1" want_status="$2" want_text="$3" out status
    shift 3
    local env=()
    while [[ "$1" != -- ]]; do
        env+=("$1")
        shift
    done
    shift
    # Only the fake tools and the basics are on PATH.
    out="$(env -i PATH="$bin:$base" "${env[@]}" "$base/bash" "$script" "$@" 2>&1)" && status=0 || status=$?
    if [[ "$status" != "$want_status" ]]; then
        echo "FAIL: $name: exit status $status, want $want_status; output: $out" >&2
        failures=$((failures + 1))
    elif [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
        echo "FAIL: $name: output lacks '$want_text'; output: $out" >&2
        failures=$((failures + 1))
    elif [[ -z "$want_text" && -n "$out" ]]; then
        echo "FAIL: $name: expected no output, got: $out" >&2
        failures=$((failures + 1))
    fi
}

all_right
expect "all versions right" 0 '' --
expect "all versions right, in CI" 0 '' CI=true --

# Other real output formats of the same versions.
fake xorriso "GNU xorriso $XORRISO_VERSION : RockRidge filesystem manipulator, libburnia project."
fake qemu-system-x86_64 "QEMU emulator version $QEMU_VERSION (qemu-$QEMU_VERSION-2)"
expect "GNU xorriso and a packaged QEMU" 0 '' CI=true --

# A wrong version: a warning on a development machine, a failure in CI.
all_right
fake qemu-system-x86_64 "QEMU emulator version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.4)"
expect "old QEMU, locally" 0 "warning: tool versions differ" --
expect "old QEMU, locally: names both versions" 0 "qemu: found 8.2.2, want $QEMU_VERSION" --
expect "old QEMU, in CI" 1 "qemu: found 8.2.2, want $QEMU_VERSION" CI=true --
expect "old QEMU, strict by hand" 1 "error: tool versions differ" MYOS_STRICT_TOOLS=1 --
expect "old QEMU, in CI but not strict" 0 "warning:" CI=true MYOS_STRICT_TOOLS=0 --
# Only the tools asked about are checked.
expect "old QEMU, not asked about" 0 '' CI=true -- zig limine xorriso

# A patch level counts.
all_right
fake xorriso "xorriso 1.5.8 : RockRidge filesystem manipulator, libburnia project."
expect "xorriso without the patch level" 1 "xorriso: found 1.5.8, want $XORRISO_VERSION" CI=true --

# A longer version is not the same version.
all_right
fake zig "${ZIG_VERSION}0"
expect "zig with one more digit" 1 "zig: found ${ZIG_VERSION}0" CI=true --

# A missing tool.
all_but limine
expect "limine missing, locally" 0 "limine: not found (want $LIMINE_VERSION)" --
expect "limine missing, in CI" 1 "limine: not found" CI=true --

# Several problems are all listed.
fake zig "0.1.0"
expect "two problems" 1 "zig: found 0.1.0" CI=true --
expect "two problems, second one" 1 "limine: not found" CI=true --

# kcov is checked only when asked for.
all_right
expect "kcov not installed, not asked" 0 '' CI=true --
expect "kcov not installed, asked" 1 "kcov: not found (want $KCOV_VERSION)" CI=true -- kcov
fake kcov "kcov $KCOV_VERSION"
expect "kcov right" 0 '' CI=true -- zig kcov

expect "unknown tool name" 2 "unknown tool" -- gcc

if ((failures)); then
    echo "check-tools tests: $failures failed" >&2
    exit 1
fi
echo "check-tools tests passed"
