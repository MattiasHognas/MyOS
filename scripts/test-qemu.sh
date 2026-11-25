#!/usr/bin/env bash
# Boot the test kernel in QEMU once per integration-test scenario and check
# its serial output. The scenario name reaches the kernel through QEMU's
# fw_cfg device (opt/myos/scenario).
#
# Usage: scripts/test-qemu.sh [scenario...]   (default: all scenarios)
#
# Scenarios:
#   tests  run the in-kernel test suite; must report MYOS_TEST_PASS
#   tests_fxsave  the same suite on a CPU without XSAVE and AVX, so the
#          kernel saves x87/SSE state with FXSAVE
#   tests_smp  the same suite on a machine with four CPUs: all must come
#          up, each with its own state, set up like the boot CPU
#   tests_kvm  the four-CPU run on the host's own CPU, with KVM: real
#          hardware and real parallelism instead of the emulator. Skipped
#          where KVM cannot be used, or where the kernel refuses the host CPU
#   panic  fail a subsystem assertion; must print a symbolized backtrace
#   panic_smp  panic on a machine with four CPUs that are all printing;
#          the report must come out whole, with nothing after it
#   fault  page-fault in kernel mode; must print CR2 and a symbolized backtrace
#   smap   read user memory from the kernel outside a user copy; must page-fault
#   smep   execute user memory from the kernel; must page-fault
#   double_fault  fault with an unusable kernel stack; must print a
#          double-fault report instead of triple-faulting
#   stack_overflow  recurse until a kernel stack is used up; must hit the
#          guard page and be reported as a kernel stack overflow
#   use_after_free  write to freed heap memory; the next allocation must
#          panic, naming the address
#   relro  write to a table of function pointers that the bootloader
#          relocated; it is read-only once the kernel runs, so must page-fault
#   text_alias  write to kernel code through the direct map of physical
#          memory; it is read-only there too, so must page-fault
#   lock_order  take two spinlocks against the lock order; must panic,
#          naming both
#   sleep_with_lock  sleep while holding a spinlock; must panic
#
# After the scenarios, the addresses the kernel was loaded at are compared:
# with KASLR they must not be the same in every boot.
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
# Only there to end a boot that hangs: a full run takes 15 to 30 s on a
# developer's machine and two to three times that on a CI runner.
timeout_s="${MYOS_QEMU_TIMEOUT:-180}"

# Boot one scenario on the CPU model $2 (default: max, every feature QEMU
# emulates; "host" runs on the host's CPU with KVM) with $3 CPUs (default:
# 1). $4 is the scenario name the kernel is told (default: $1). Leaves the QEMU exit status in $status and the CR-stripped log
# path in $log.
boot() {
    local scenario="$1"
    local cpu="${2:-max}"
    local cpus="${3:-1}"
    local told="${4:-$scenario}"
    local accel=()
    [[ "$cpu" == host ]] && accel=(-enable-kvm)
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
        -machine q35 "${accel[@]}" -cpu "$cpu" -smp "$cpus" -m 256M \
        -cdrom "$iso" -boot d \
        -display none -monitor none -serial stdio \
        -no-reboot \
        -drive file="$disk",if=none,id=nvm,format=raw \
        -device nvme,serial=myos-test,drive=nvm \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -fw_cfg name=opt/myos/scenario,string="$told" \
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

skipped=()

# Leave the current scenario out, saying why.
skip() {
    echo "SKIP [$scenario]: $*"
    skipped+=("$scenario")
    rm -rf "${out:?}/$scenario"
}

run_scenario() {
    scenario="$1"
    echo "=== QEMU scenario: $scenario"
    if [[ "$scenario" == tests_kvm && ! -w /dev/kvm ]]; then
        skip "/dev/kvm cannot be used here"
        return
    fi
    case "$scenario" in
        tests_kvm) boot "$scenario" host 4 tests_smp ;;
        # Without XSAVE there is no AVX either (and nothing that builds on it).
        tests_fxsave) boot "$scenario" max,xsave=off ;;
        tests_smp | panic_smp) boot "$scenario" max 4 ;;
        *) boot "$scenario" ;;
    esac
    local before=${#failures[@]}

    # The kernel does not run on a CPU that is affected by Meltdown. That
    # is its decision about the host, not a failure of the kernel.
    if [[ "$scenario" == tests_kvm ]] && grep -q 'affected by Meltdown, and MyOS has no page-table isolation' "$log"; then
        skip "the kernel refuses this host's CPU (Meltdown)"
        return
    fi

    case "$scenario" in
        tests | tests_fxsave | tests_smp | tests_kvm)
            expect_status 1
            if [[ "$scenario" == tests_fxsave ]]; then
                expect_line 'extended state: FXSAVE, 512 bytes \(no XSAVE; AVX off\)$'
            elif [[ "$scenario" == tests_kvm ]]; then
                expect_line 'extended state: (XSAVE|FXSAVE), [0-9]+ bytes' # whatever the host has
            else
                expect_line 'extended state: XSAVE, 832 bytes, AVX on$'
            fi
            if [[ "$scenario" == tests_smp || "$scenario" == tests_kvm ]]; then
                expect_line 'info\(smp\): 4 of 4 CPUs online$'
            else
                expect_line 'info\(smp\): 1 of 1 CPUs online$'
            fi
            expect_line '^MyOS [^ ]+ booting$' # the banner names the version ("dev" unless -Dversion)
            expect_line '^MYOS_TEST_PASS$'
            expect_line '^MYOS_TEST_SUMMARY passed=[1-9][0-9]* failed=0$'
            if grep -q '^\[FAIL\]' "$log"; then fail "failing test cases: $(grep '^\[FAIL\]' "$log" | tr '\n' ' ')"; fi
            # The deepest kernel stack use of the run is reported and under the warning level.
            expect_line '^MYOS_STACK_PEAK bytes=[1-9][0-9]* of=16384 limit=12288$'
            expect_line '^\[PASS\] kernel stack usage below the warning level$'
            # So is the deepest use of an emergency stack (a debug trap that ends a process).
            expect_line '^MYOS_IST_PEAK bytes=[1-9][0-9]* of=8192$'
            expect_line '^\[PASS\] emergency stack usage below the warning level$'
            if grep -q 'of its kernel stack' "$log"; then fail "a thread came close to filling its kernel stack: $(grep 'of its kernel stack' "$log" | tr '\n' ' ')"; fi
            # User-fault diagnostics: process, fault, vector, error code, then RIP/RSP, and CR2 for page faults.
            expect_line '^\*\*\* thread [0-9]+ \(/test/kernel_read\): Page fault in user mode \(vector 14, error 0x5\), killed$'
            expect_line '^CR2=0xffff800000100000 \(faulting address\)$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/privileged\): General protection in user mode \(vector 13, error 0x0\), killed$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/div_zero\): Divide error in user mode \(vector 0, error 0x0\), killed$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/single_step\): Debug in user mode \(vector 1, error 0x0\), killed$'
            expect_line '^\*\*\* thread [0-9]+ \(/test/invalid_opcode\): Invalid opcode in user mode \(vector 6, error 0x0\), killed$'
            expect_line '^RIP=0x4[0-9a-f]{5} RSP=0x7ff[b-f][0-9a-f]{8} RFLAGS=0x[0-9a-f]+$'
            # The user's GS base is its own: reading through it faults on a user address.
            expect_line '^\*\*\* thread [0-9]+ \(/test/gs_base\): Page fault in user mode \(vector 14, error 0x4\), killed$'
            expect_line '^CR2=0x5a5000 \(faulting address\)$'
            # Syscall returns to states the CPU cannot return to kill the process.
            expect_line '^\*\*\* thread [0-9]+ \(/test/bad_return\): invalid return state after syscall, killed$'
            expect_line '^RIP=0x800000000000 RSP=0x7ff[b-f][0-9a-f]{8} RFLAGS=0x[0-9a-f]+ CS=0x23 SS=0x1b$'
            expect_line '^RIP=0xffffffff[89a-f][0-9a-f]{7} RSP=0x7ff[b-f][0-9a-f]{8} RFLAGS=0x[0-9a-f]+ CS=0x23 SS=0x1b$'
            expect_line '^RIP=0x4[0-9a-f]{5} RSP=0x7ff[b-f][0-9a-f]{8} RFLAGS=0x[0-9a-f]+ CS=0x8 SS=0x1b$'
            expect_line '^RIP=0x4[0-9a-f]{5} RSP=0x7ff[b-f][0-9a-f]{8} RFLAGS=0x[0-9a-f]+ CS=0x23 SS=0x10$'
            expect_line '^fuzz done$'
            # A C program built for Linux against musl prints what it was started with.
            expect_line '^hello from musl: 3 args$'
            expect_line '^argv\[0\]=musl-hello$'
            expect_line '^argv\[2\]=two words$'
            expect_line '^env GREETING=hi$'
            expect_line '^env EMPTY=$'
            expect_line '^linux_abi: writev works$'
            # A pthreads program built for Linux checks its own numbers.
            expect_line '^threads: 8 threads, counter 160000 of 160000, baton passed 24 times, timed wait timed out, main.s own count 0$'
            expect_line '^threads: all correct$'
            if grep -q '^threads: WRONG' "$log"; then fail "the pthreads program found a wrong result"; fi
            # A Go program built for Linux: goroutines on every CPU, a channel, a GC.
            expect_line '^hello from go: 3 args$'
            expect_line '^goroutines: 8 sum: 479976 cpus: [0-9]+$'
            expect_line '^GREETING=hi go$'
            if grep -q '^syscall trace: ' "$log"; then fail "a fixture made a call the kernel does not know: $(grep -m3 '^syscall trace: ' "$log" | tr '\n' ' ')"; fi
            # A .NET program compiled ahead of time for Linux: managed threads, a GC.
            expect_line '^hello from dotnet: 2 args$'
            expect_line '^threads: 8 sum: 12188000 cpus: [0-9]+ collected: True$'
            expect_line '^GREETING=hi dotnet$'
            # A Rust program built for Linux, with its standard library.
            expect_line '^hello from rust: 3 args$'
            expect_line '^argv\[2\]=MyOS$'
            expect_line '^sum of squares below 100000: 333328333350000$'
            expect_line '^GREETING=hi rust$'
            # A dynamically linked C program, if the image has one.
            if [[ -f zig-out/test/initrd/lib64/ld-linux-x86-64.so.2 ]]; then
                expect_line '^env GREETING=hi dynamic$'
                expect_line '^argv\[2\]=at run time$'
            fi
            # .NET published ahead of time the ordinary way: dynamic, glibc.
            if [[ -f zig-out/test/initrd/lib64/ld-linux-x86-64.so.2 ]]; then
                expect_line '^hello from dotnet: 2 args$'
                expect_line '^GREETING=hi dotnet aot$'
            fi
            # The same C and Rust programs as position-independent executables.
            expect_line '^env GREETING=hi pie$'
            expect_line '^GREETING=hi rust pie$'
            # A program past its memory limit is told so, and killed like any fault.
            expect_line '^\*\*\* thread [0-9]+ \(/test/vm\): no memory for the page it touched'
            expect_line '^\*\*\* thread [0-9]+ \(/test/vm\): Page fault in user mode \(vector 14, error 0x[0-9a-f]+\), killed$'
            ;;
        panic)
            expect_status 3
            expect_line '^PANIC: scenario: assertion failed: deliberate test panic$'
            expect_line '^backtrace:$'
            expect_line "$frame_re"
            expect_line ' [^ ]*scenarioPanicInner\+0x'
            expect_line ' [^ ]*scenarioPanic\+0x'
            ;;
        panic_smp)
            expect_status 3
            expect_line '^chatter from thread [0-9]+$' # the other CPUs were busy printing
            expect_line '^PANIC: scenario: assertion failed: deliberate test panic$'
            expect_line '^backtrace:$'
            expect_line ' [^ ]*scenarioPanicSmp\+0x'
            # Everything from the panic on is the report: the others were stopped first.
            if sed -n '/^PANIC: /,$p' "$log" | grep -q 'chatter'; then fail "another CPU printed after the panic began"; fi
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
        stack_overflow)
            # The fault on the guard page cannot be delivered on the full stack,
            # so it arrives as a double fault on the emergency stack.
            expect_status 3
            expect_line '^\*\*\* Double fault \(vector 8, error 0x0\)$'
            expect_line '^CR2=0xffffc[0-9a-f]{11} \(last page-fault address\)$'
            expect_line '^CR2 is in a kernel stack guard page: kernel stack overflow$'
            expect_line '^thread [0-9]+ kernel stack 0xffffc[0-9a-f]{11}-0xffffc[0-9a-f]{11}; RSP is below it: stack overflow$'
            expect_line '^  #[0-9]+ 0x[0-9a-f]{16} [^ ]*recurseForever\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel survived a stack overflow"; fi
            ;;
        use_after_free)
            expect_status 3
            expect_line '^PANIC: heap: freed memory at 0x[0-9a-f]+ was written to \(0x42 at offset 64 of a 128-byte block\)$'
            expect_line '^backtrace:$'
            expect_line ' [^ ]*writeAfterFree\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel did not notice a write to freed memory"; fi
            ;;
        relro)
            # Error 0x3: protection violation on a supervisor write to a present page.
            expect_status 3
            expect_line '^\*\*\* Page fault \(vector 14, error 0x3\)$'
            expect_line '^CR2=0xffffffff[89a-f][0-9a-f]{7} \(faulting address\)$' # in the kernel image
            expect_line '^  #0 0x[0-9a-f]{16} [^ ]*writeRelocatedTable\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel wrote to a relocated table"; fi
            ;;
        text_alias)
            expect_status 3
            expect_line '^\*\*\* Page fault \(vector 14, error 0x3\)$'
            expect_line '^CR2=0xffff8[0-9a-f]{11} \(faulting address\)$' # in the direct map
            expect_line '^  #0 0x[0-9a-f]{16} [^ ]*writeTextThroughDirectMap\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel wrote to its own code through the direct map"; fi
            ;;
        lock_order)
            expect_status 3
            expect_line '^PANIC: spinlock: taking a condition lock while holding a timer lock \(docs/locking.md, lock order\)$'
            expect_line '^backtrace:$'
            expect_line ' [^ ]*takeLocksOutOfOrder\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel took two locks in the wrong order"; fi
            ;;
        sleep_with_lock)
            expect_status 3
            expect_line '^PANIC: spinlock: assertion failed: blocking with 1 spinlocks held, not 0$'
            expect_line '^backtrace:$'
            expect_line ' [^ ]*sleepHoldingSpinlock\+0x'
            if grep -q 'was not caught' "$log"; then fail "the kernel slept while holding a spinlock"; fi
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
((${#scenarios[@]})) || scenarios=(tests tests_fxsave tests_smp tests_kvm panic panic_smp fault smap smep double_fault stack_overflow use_after_free relro text_alias lock_order sleep_with_lock)
for s in "${scenarios[@]}"; do run_scenario "$s"; done

# KASLR: the kernel reports where it was loaded in every boot. Seeing the
# same address in all of several boots means it is not being randomized.
if ((${#scenarios[@]} >= 4)); then
    scenario="kaslr"
    slides=$(for s in "${scenarios[@]}"; do grep -a -m1 '^MYOS_KERNEL_SLIDE ' "$out/$s/serial-clean.log" 2>/dev/null || true; done | sort -u | wc -l)
    if ((slides < 2)); then
        fail "the kernel was loaded at the same address in all ${#scenarios[@]} boots"
    else
        echo "PASS [kaslr]: $slides different kernel addresses in ${#scenarios[@]} boots"
    fi
fi

if [[ "${MYOS_SIMULATE_FAILURE:-}" == true ]]; then
    scenario="all"
    fail "simulated failure (MYOS_SIMULATE_FAILURE=true)"
fi

if ((${#failures[@]})); then
    echo "QEMU integration tests failed:" >&2
    printf '  %s\n' "${failures[@]}" >&2
    exit 1
fi
((${#skipped[@]})) && echo "Skipped: ${skipped[*]}"
echo "QEMU integration tests passed (${scenarios[*]})"
