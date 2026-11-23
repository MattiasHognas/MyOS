# Testing MyOS

There are three layers of tests. Add tests to the layer that fits whenever you
change or add a subsystem.

| Layer | Command | Where | What it is for |
| --- | --- | --- | --- |
| Host unit tests | `zig build test-host` | `tests/host/` | Hardware-independent kernel code (VFS, ELF image validation with a fixed-seed mutation fuzzer, ELF symbol lookup, log formatting, user address-range checks, the ABI's numbers against Linux's, the `sysretq`/`iretq` decision, extended-state feature selection), compiled natively with fakes. Fast; covered by `zig build coverage`. |
| In-kernel tests | `zig build test-qemu` (scenarios `tests`, `tests_fxsave`) | `tests/kernel/main.zig`, `tests/user/` | Code that needs the real kernel: PMM, VMM, heap, kernel stacks, ELF loading, scheduler and processes, syscalls from ring 3 (errors, register preservation, return states, a fuzzer), kernel entry and exit (GS base, stacks, address spaces, preemption), x87/SSE/AVX state, user-memory copies, tarfs, NVMe reads, symbolization, fw_cfg. |
| QEMU scenarios | `zig build test-qemu` | `scripts/test-qemu.sh` | Whole-system behaviour checked from the serial log, including runs that are meant to crash. |

`zig build test` runs the host tests, the [stack frame check](#stack-frame-check) and all QEMU scenarios. Add
`-Doptimize=ReleaseSafe` or `-Doptimize=ReleaseFast` to run the QEMU tests
against an optimized kernel. CI runs all three build modes.

## QEMU integration-test scenarios

`scripts/test-qemu.sh` boots the test kernel (`zig-out/bin/kernel-test.elf`) once per
scenario. The scenario name reaches the kernel through QEMU's fw_cfg device
(`-fw_cfg name=opt/myos/scenario,string=<name>`); `run` in
`tests/kernel/main.zig` reads it with `tests/kernel/fw_cfg.zig`.

| Scenario | What the kernel does | What the script checks (kernel exit code; QEMU reports `code*2+1`) |
| --- | --- | --- |
| `tests` | Runs the in-kernel test suite | Exit code 0, `MYOS_TEST_PASS`, `failed=0`, no `[FAIL]` lines, the peak kernel stack usage (`MYOS_STACK_PEAK`) under the warning level, the diagnostics of the user faults the suite provokes (program name, vector, error code, RIP/RSP, CR2), the reports of syscall returns to invalid states, and the fuzzer finishing |
| `tests_fxsave` | Runs the same suite on a CPU without XSAVE and AVX (`-cpu max,xsave=off`), so extended state is saved with FXSAVE | As `tests`, and the boot log names FXSAVE (`tests` requires XSAVE with AVX) |
| `panic` | Fails a subsystem assertion two calls deep | Exit code 1, the panic message, a symbolized backtrace through `scenarioPanicInner` and `scenarioPanic` |
| `fault` | Writes to an unmapped kernel address | Exit code 1, `Page fault`, the right CR2, backtrace frame `#0` in `scenarioFault` |
| `smap` | Reads a mapped user page from kernel code outside a user copy | Exit code 1, `Page fault` with error 0x1 and CR2 = the user page, frame `#0` in `scenarioSmap` (SMAP is enforced) |
| `smep` | Calls code in a mapped user page from ring 0 | Exit code 1, `Page fault` with error 0x11, RIP and CR2 = the user page (SMEP is enforced) |
| `double_fault` | A kernel thread points RSP at unmapped memory and pushes | Exit code 1, `Double fault` with the bad RSP, CR2, the thread's stack bounds and frame `#0` in `doubleFaultThread` (a triple fault would end QEMU with status 0 and no report) |
| `stack_overflow` | A kernel thread recurses until its stack is used up | Exit code 1, `Double fault` with CR2 in a kernel stack guard page, `kernel stack overflow`, RSP below the thread's stack, backtrace frames in `recurseForever` |

Run a subset with `scripts/test-qemu.sh tests panic` (after `zig build test-kernel`
and `zig build`). The timeout per boot is 45 s, or `MYOS_QEMU_TIMEOUT` seconds.

Each scenario keeps its logs in `zig-out/test/<scenario>/serial.log` (raw) and
`serial-clean.log` (CR removed). When a check fails, the script prints the
serial log; CI uploads the logs as the `serial-logs-<mode>` artifact.

In the test kernel, `root.halt()` and the panic handler exit QEMU with status
1 (host status 3) instead of hanging, so crashes end the run immediately.

### Adding a scenario

1. Add a `noinline fn scenarioX() void` to `tests/kernel/main.zig` and dispatch
   to it in `run`.
2. Add a `X)` case to `run_scenario` in `scripts/test-qemu.sh` with its expected exit
   status (`expect_status`) and output (`expect_line`), and add it to the
   default list.
3. Document it in the table above.

## Stack frame check

A kernel stack is 16 KiB with one unmapped guard page below it. A function
whose stack frame is smaller than a page cannot move the stack pointer past
the guard without touching it, so `zig build check-frames` (run by
`zig build test` and by CI in every build mode) makes sure all of them are:

- `scripts/check-frames.sh` disassembles `kernel.elf` and `kernel-test.elf`
  with `objdump` and reads each function's frame size from its prologue.
- A frame over 4088 bytes fails the build. A frame over 2048 bytes prints a
  warning: fix it before it grows.
- A function over the limit that nothing in the disassembly refers to is
  only noted. These are library routines the linker kept in Debug builds
  (compiler-rt's big-integer division); calling one makes the check fail.

If it fails, move the large local to the heap or to static storage, or pass
large structs by pointer. Typical causes: a buffer declared as a local (the
tests share `page_buf` in `tests/kernel/main.zig` for this), an `inline for`
with many iterations in a Debug build, and standard-library helpers with big
internal buffers (`std.debug.panic`; use `kernel.debug.panic.panicFmt`).

The frame check bounds one function; total stack depth is measured at run
time. The test kernel records the high-water mark of every kernel stack
(`-Dstack-usage`, see [debugging](debugging.md)) and the `tests` scenario
fails if any thread used more than 12 of its 16 KiB.

`scripts/test-check-frames.sh` tests the script itself against hand-written
disassembly. The limits can be changed with `MYOS_FRAME_HARD_LIMIT` and
`MYOS_FRAME_SOFT_LIMIT`.

## Adding in-kernel tests

All test code lives in `tests/kernel/`; the only hooks in `src/main.zig` are
the call to `run` after boot and the QEMU exit in `halt` and the panic handler.
The tests reach the kernel through `@import("root")` (for example
`root.kernel.pmm`), never by importing a kernel file by path: that would
create a second copy of the module and its global state. To add a test:

1. If it needs to poke at kernel internals, add a helper to
   `tests/kernel/helpers.zig`. A kernel declaration it needs may have to
   become `pub`.
2. Write `fn myTest() TestError!void` in `tests/kernel/main.zig` using
   `check(...)`.
3. Add it to the `cases` list in `runCases`.

## User-mode test programs

Programs in `tests/user/` run in ring 3 and test the kernel from the outside
(syscall validation, bad user pointers, user/kernel isolation). The build installs each as
`zig-out/bin/test-<name>.elf`, and `scripts/build.sh --package-test` puts them
in the test initrd as `/test/<name>`. In-kernel tests run them with
`helpers.runProgram("/test/<name>")`, which returns the exit status (255 if the
kernel killed the process for a fault), or two copies at once with
`helpers.runPair`, for tests that need processes to interleave.

| Program | What it checks |
| --- | --- |
| `syscalls` | Every failure of every syscall returns its Linux error number; descriptors and paths at their limits |
| `user_pointers` | Unmapped, partly mapped and read-only buffers and paths: `EFAULT` or a short count, never a crash |
| `syscall_abi` | A syscall preserves every register but `rax`, `rcx` and `r11`, the flags and the stack pointer (through `checked.zig`, which other programs use for their syscalls too) |
| `preempt` | Long syscalls that the timer preempts halfway, run as a pair |
| `bad_return` | Syscall returns through `iretq`, with privileged flags, and to states the CPU cannot return to (with the kernel test altering the saved state) |
| `gs_base` | The kernel's GS base is not visible in ring 3 |
| `fpu`, `fpu_clean` | x87, SSE and AVX registers survive switches between two processes; a new process starts clean (`fpu_regs.zig` holds the shared assembly) |
| `fuzz` | 20 000 random syscalls from a fixed seed: the kernel survives and leaks nothing |
| `entry_regs` | General-purpose registers are zero at program start |
| `kernel_read`, `privileged`, `write_text`, `umip`, `div_zero`, `invalid_opcode` | Each fault kills only the process |

The in-kernel side of the entry tests is a pair of probes in
`tests/kernel/helpers.zig` (`installProbes`): they wrap the syscall handler
and the timer handler and check, at every syscall and every timer
interrupt, that interrupts are masked or enabled as they should be, that
the frame sits where it should on the thread's kernel stack, and that the GS
base and address space belong to the running process. Tests that depend on
the timer hitting a particular place (inside a syscall, say) repeat until
the probes have seen it, so they do not depend on the machine's speed.

To add one: create `tests/user/<name>.zig` (import the runtime with
`@import("lib")`, export `_start`), add `<name>` to the list in `build.zig`,
and call it from a test in `tests/kernel/main.zig`. Report failures through
the exit code, e.g. the number of the first failing check. For a program that is
meant to be killed, the fault report it produces can be checked from the
serial log in the `tests` case of `scripts/test-qemu.sh`.

## Adding host tests

1. Keep the code under test free of kernel imports (only `std`).
2. Register it as a module for the host tests in `build.zig` (the list next to
   `vfs`, `symbols` and `log_format`).
3. Add `tests/host/<name>_test.zig` and reference it from `tests/host/main.zig`.

## Coverage

`zig build coverage` runs the host tests under [kcov](https://github.com/SimonKagstrom/kcov)
and writes an HTML report to `zig-out/coverage/index.html`. It needs `kcov`
installed (most distributions package it; on Ubuntu 24.04, build it with
`scripts/install-kcov.sh`). Coverage covers host-tested code only; kernel code that runs only in
QEMU is checked by the scenarios above instead.

Coverage uses its own build of the host tests with the LLVM backend: kcov
cannot read the debug info of Zig's self-hosted x86 backend (used by
`zig build test-host`) and would report 0 lines.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

- **Build and test** (Debug, ReleaseSafe, ReleaseFast): builds the kernel and
  apps, runs the host tests, the stack frame check and all QEMU scenarios, builds the docs (Debug only),
  and uploads the serial logs if anything fails.
- **Release** (pushes to `main` only, after all three build-and-test jobs
  pass): tags the commit and publishes a GitHub release. See
  [releases](development.md#releases).
- **Host test coverage**: runs `zig build coverage` and uploads the report.
  Informational; it does not fail the workflow.

To check that a failing run publishes its serial logs, start the workflow by
hand with **simulate failure** enabled (Actions → CI → Run workflow, or
`gh workflow run ci.yml -f simulate_failure=true`). The QEMU tests then fail
on purpose after running, and each matrix job uploads `serial-logs-<mode>`.

CI installs Zig from ziglang.org (`scripts/install-zig.sh`, checksum verified)
and gets Limine from its release tarball (`scripts/install-limine.sh`, checksum
verified), kcov from source (`scripts/install-kcov.sh`), and the console font
with `scripts/fetch-font.sh`.

The jobs cache the Zig toolchain (keyed on the Zig version), the kcov build
(keyed on `scripts/install-kcov.sh`) and, except for the release job, the Zig
build cache `.zig-cache`. The build cache is keyed on job, build mode, Zig
version and `build.zig` only, not on the sources: what it saves is compiler-rt,
the build runner and unchanged programs (about 80 s from nothing), while the
kernel is recompiled on every change anyway. A commit that changes `build.zig`
therefore builds from an empty cache once per job. Zig's cache is
content-addressed, so a restored cache never gives stale results. The release
job builds from an empty cache on purpose. To change the Zig
version, update both `ZIG_VERSION` in the workflow and the version and
checksum in `scripts/install-zig.sh`.
