#!/usr/bin/env bash
# Boot the test kernel in QEMU once per integration-test scenario and check
# its serial output. The scenario name reaches the kernel through QEMU's
# fw_cfg device (opt/myos/scenario).
#
# Usage: scripts/test-qemu.sh [scenario...]   (default: all scenarios)
#
# Scenarios:
#   tests  run the in-kernel test suite; must report MYOS_TEST_PASS
#   panic  fail a subsystem assertion; must print a symbolized backtrace
#   fault  page-fault in kernel mode; must print CR2 and a symbolized backtrace
#   smap   read user memory from the kernel outside a user copy; must page-fault
#   smep   execute user memory from the kernel; must page-fault
#   double_fault  fault with an unusable kernel stack; must print a
#          double-fault report instead of triple-faulting
#
# Logs: zig-out/test/<scenario>/serial.log (raw) and serial-clean.log.
#
# MYOS_SIMULATE_FAILURE=true makes the run fail after all scenarios ran (used
# by CI to check that the serial logs of a failing run are uploaded).
set -euo pipefail
cd "$(dirname "$0")/.."  # run from the repository root

# Package the test ISO without recursively invoking zig build.
bash scripts/build.sh --package-test

out="zig-out/test"
iso="$out/os.iso"
timeout_s="${MYOS_QEMU_TIMEOUT:-45}"

# Boot one scenario; leaves the QEMU exit status in $status and the
# CR-stripped log path in $log.
boot() {
    local scenario="$1"
    local dir="$out/$scenario"
    mkdir -p "$dir"
    local raw="$dir/serial.log"
    log="$dir/serial-clean.log"

    # Use a disposable NVMe test image.
    local disk="$dir/disk.img"
    rm -f "$disk"
    truncate -s 64M "$disk"
    printf 'Hello from the NVMe test disk!' |
        dd of="$disk" conv=notrunc status=none

    set +e
    timeout --foreground "${timeout_s}s" qemu-system-x86_64 \
        -machine q35 -cpu max -smp 1 -m 256M \
        -cdrom "$iso" -boot d \
        -display none -monitor none -serial stdio \
        -no-reboot \
        -drive file="$disk",if=none,id=nvm,format=raw \
        -device nvme,serial=myos-test,drive=nvm \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -fw_cfg name=opt/myos/scenario,string="$scenario" \
        >"$raw" 2>&1
    status=$?
    set -e

    # Normalize serial CRLF line endings for log validation.
    tr -d '\r' <"$raw" >"$log"
}

failures=()

# Record a failed check for the current scenario.
fail() {
    echo "FAIL [$scenario]: $*" >&2
    failures+=("$scenario: $*")
}

# Require an extended regex to match some line of the log.
expect_line() {
    grep -Eq -- "$1" "$log" || fail "missing output matching: $1"
}

# Require the QEMU exit status. isa-debug-exit gives (code << 1) | 1, so the
# kernel's exit(0) is 1 and exit(1) is 3; 124 means the timeout fired.
expect_status() {
    if [[ "$status" != "$1" ]]; then
        case "$status" in
            124) fail "timed out after ${timeout_s}s" ;;
            *) fail "QEMU exit status $status, expected $1" ;;
        esac
    fi
}

# A symbolized backtrace line: "  #N 0x<16 hex digits> <name>+0x<offset>".
frame_re='^  #[0-9]+ 0x[0-9a-f]{16} [^?].*\+0x[0-9a-f]+$'

run_scenario() {
    scenario="$1"
    echo "=== QEMU scenario: $scenario"
    boot "$scenario"
    local before=${#failures[@]}

    case "$scenario" in
        tests)
            expect_status 1
            expect_line '^MyOS [^ ]+ booting$' # the banner names the version ("dev" unless -Dversion)
            expect_line '^MYOS_TEST_PASS$'
            expect_line '^MYOS_TEST_SUMMARY passed=[1-9][0-9]* failed=0$'
            if grep -q '^\[FAIL\]' "$log"; then fail "failing test cases: $(grep '^\[FAIL\]' "$log" | tr '\n' ' ')"; fi
            # User-fault diagnostics: process, fault, vector, error code, then RIP/RSP, and CR2 for page faults.
            expect_line '^\*\*\* thread [0-9]+ \(/test/kernel_read\): Page fault in user mode \(vector 14, error 0x5\), killed$'
            expect_line '^CR2=0xffffffff80000000 \(faulting address\)$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/privileged\): General protection in user mode \(vector 13, error 0x0\), killed$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/div_zero\): Divide error in user mode \(vector 0, error 0x0\), killed$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/invalid_opcode\): Invalid opcode in user mode \(vector 6, error 0x0\), killed$'
            expect_line '^RIP=0x4[0-9a-f]{5} RSP=0x7fff[0-9a-f]{8} RFLAGS=0x[0-9a-f]+$'
            ;;
        panic)
            expect_status 3
            expect_line '^PANIC: scenario: assertion failed: deliberate test panic$'
            expect_line '^backtrace:$'
            expect_line "$frame_re"
            expect_line ' [^ ]*scenarioPanicInner\+0x'
            expect_line ' [^ ]*scenarioPanic\+0x'
            ;;
        fault)
            expect_status 3
            expect_line '^\*\*\* Page fault \(vector 14, error 0x[0-9a-f]+\)$'
            expect_line '^CR2=0xffffb00000000000 \(faulting address\)$'
            expect_line '^backtrace:$'
            expect_line '^  #0 0x[0-9a-f]{16} [^ ]*scenarioFault\+0x'
            ;;
        smap)
            # Error 0x1: protection violation on a supervisor read of a present page.
            expect_status 3
            expect_line '^\*\*\* Page fault \(vector 14, error 0x1\)$'
            expect_line '^CR2=0x400000 \(faulting address\)$'
            expect_line '^  #0 0x[0-9a-f]{16} [^ ]*scenarioSmap\+0x'
            if grep -q 'not enforced' "$log"; then fail "the kernel read user memory"; fi
            ;;
        smep)
            # Error 0x11: protection violation on a supervisor instruction fetch.
            expect_status 3
            expect_line '^\*\*\* Page fault \(vector 14, error 0x11\)$'
            expect_line '^RIP=0x400000 '
            expect_line '^CR2=0x400000 \(faulting address\)$'
            if grep -q 'not enforced' "$log"; then fail "the kernel executed user memory"; fi
            ;;
        double_fault)
            # A triple fault would stop QEMU (-no-reboot) with status 0 and no report.
            expect_status 3
            expect_line '^\*\*\* Double fault \(vector 8, error 0x0\)$'
            expect_line '^RSP=0xffffb00000001000 '
            expect_line '^CR2=0xffffb00000000ff8 \(last page-fault address\)$'
            expect_line '^thread [0-9]+ kernel stack 0x[0-9a-f]+-0x[0-9a-f]+; RSP is outside it: corrupt stack pointer$'
            expect_line '^backtrace:$'
            expect_line '^  #0 0x[0-9a-f]{16} [^ ]*doubleFaultThread\+0x'
            if grep -q 'no double fault' "$log"; then fail "the kernel survived losing its stack"; fi
            ;;
        *)
            echo "unknown scenario: $scenario" >&2
            exit 2
            ;;
    esac

    if ((${#failures[@]} > before)); then
        echo "--- serial log ($out/$scenario/serial.log) ---" >&2
        cat "$log" >&2
        echo "--- end of serial log ---" >&2
    else
        echo "PASS [$scenario]"
    fi
}

scenarios=("$@")
((${#scenarios[@]})) || scenarios=(tests panic fault smap smep double_fault)
for s in "${scenarios[@]}"; do run_scenario "$s"; done

if [[ "${MYOS_SIMULATE_FAILURE:-}" == true ]]; then
    scenario="all"
    fail "simulated failure (MYOS_SIMULATE_FAILURE=true)"
fi

if ((${#failures[@]})); then
    echo "QEMU integration tests failed:" >&2
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
echo "QEMU integration tests passed (${scenarios[*]})"
