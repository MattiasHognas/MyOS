#!/usr/bin/env bash
set -euo pipefail

# Called by build.zig AFTER installing kernel-test.elf and the userspace ELFs.
# Never call 'zig build' from here (would recursively invoke the build graph).
bash build.sh --package-test

out="zig-out/test"
log="$out/serial.log"
iso="$out/os.iso"
disk="$out/disk.img"

# Avoid touching the developer's disk.img.
truncate -s 64M "$disk"
printf 'Hello from the NVMe test disk!' | dd of="$disk" conv=notrunc status=none

set +e
timeout --foreground 45s qemu-system-x86_64 \
    -machine q35 -cpu max -smp 1 -m 256M \
    -cdrom "$iso" -boot d \
    -display none -monitor none -serial stdio \
    -no-reboot \
    -drive file="$disk",if=none,id=nvm,format=raw \
    -device nvme,serial=myos-test,drive=nvm \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    >"$log" 2>&1
status=$?
set -e

cat "$log"
case "$status" in
    1)
        if grep -q '^MYOS_TEST_PASS' "$log" && grep -q '^MYOS_TEST_SUMMARY passed=2 failed=0' "$log"; then
            echo "QEMU integration tests passed"
            exit 0
        fi
        echo "QEMU exit status 1 without success markers" >&2
        exit 1
        ;;
    3) echo "QEMU integration tests reported failure" >&2; exit 1 ;;
    124) echo "QEMU integration tests timed out" >&2; exit 1 ;;
    *) echo "QEMU terminated unexpectedly (exit status $status)" >&2; exit 1 ;;
esac
