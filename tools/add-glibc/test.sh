#!/usr/bin/env bash
# Test add-glibc.sh as a user would use it: a release image (built by
# scripts/build.sh --release) with a dynamically linked program in it, which
# cannot start there; the C library added with add-glibc.sh; the program
# then runs. Both images are booted with the release kernel, and the
# program's name is typed into the shell over the serial line.
#
# Needs what scripts/build.sh and add-glibc.sh need, QEMU, and the
# dynamically linked fixture (tests/fixtures/build.sh). Uses sysroot/
# (scripts/fetch-sysroot.sh) instead of fetching the packages again.
#
# Usage: tools/add-glibc/test.sh       (exit 0 when it passes)
set -euo pipefail
cd "$(dirname "$0")/../.."

program=tests/fixtures/bin/glibc-hello-dynamic
[[ -x "$program" ]] || bash tests/fixtures/build.sh >/dev/null
[[ -x "$program" ]] || { echo "add-glibc test: no $program (needs a C toolchain)" >&2; exit 2; }
bash scripts/fetch-sysroot.sh >/dev/null

out=zig-out/test/add-glibc
rm -rf "$out"
# The release build leaves zig-out/bin built for release (the test
# programs too); the ordinary build again afterwards, as the other
# commands expect it.
trap 'zig build >/dev/null 2>&1 || true' EXIT
mkdir -p "$out/extra/opt"
cp "$program" "$out/extra/opt/hello"
MYOS_INITRD_EXTRA="$out/extra" bash scripts/build.sh --release 0.0.0-test >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
plain=zig-out/release/myos-0.0.0-test.iso
with="$out/with-glibc.iso"

# The tool as it is released: unpacked from its archive.
tar -xzf zig-out/release/myos-0.0.0-test-add-glibc.tar.gz -C "$out"
MYOS_GLIBC_SYSROOT="$PWD/sysroot" bash "$out/add-glibc/add-glibc.sh" "$plain" "$with" 2>/dev/null >/dev/null

# Boot `iso`, type the program's name, log the serial line to `log`.
run() {
    local iso="$1" log="$2"
    {
        sleep "${MYOS_BOOT_WAIT:-10}"
        printf '/opt/hello from-release\r'
        sleep 4
    } | timeout --foreground 60s qemu-system-x86_64 \
        -machine q35 -cpu max -smp 2 -m 256M -cdrom "$iso" -boot d \
        -display none -monitor none -serial stdio -no-reboot >"$log.raw" 2>&1 || true
    tr -d '\r' <"$log.raw" >"$log"
}

failed=0
run "$plain" "$out/plain.log"
if grep -q '^argv\[1\]=from-release$' "$out/plain.log"; then
    echo "FAIL: the program ran in an image without the C library" >&2
    failed=1
fi
if ! grep -qi 'not found\|no such\|cannot' "$out/plain.log"; then
    echo "FAIL: the shell said nothing about a program that cannot start ($out/plain.log)" >&2
    failed=1
fi
run "$with" "$out/with.log"
if ! grep -q '^argv\[1\]=from-release$' "$out/with.log"; then
    echo "FAIL: the program did not run in the image with the C library ($out/with.log)" >&2
    failed=1
fi
# And the tool leaves an image that has it alone.
if MYOS_GLIBC_SYSROOT="$PWD/sysroot" bash "$out/add-glibc/add-glibc.sh" "$with" "$out/again.iso" 2>/dev/null; then
    echo "FAIL: add-glibc.sh added the C library twice" >&2
    failed=1
fi
((failed == 0)) && echo "add-glibc test: passed"
exit "$failed"
