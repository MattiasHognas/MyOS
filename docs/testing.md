# Testing MyOS

There are three layers of tests. Add tests to the layer that fits whenever you
change or add a subsystem.

| Layer | Command | Where | What it is for |
| --- | --- | --- | --- |
| Host unit tests | `zig build test-host` | `tests/host/` | Hardware-independent kernel code (VFS, ELF image validation with a fixed-seed mutation fuzzer, ELF symbol lookup, log formatting, user address-range checks, the ABI's numbers against Linux's, the `sysretq`/`iretq` decision, extended-state feature selection, the physical allocator's page bookkeeping against a model and at every position in a 64-bit word, the timer queue against a model, the spinlock under real multi-threaded contention, the lock order and the record of locks held, the random generator's core, the Meltdown rule; two coverage-guided fuzz tests, see [fuzzing](#fuzzing)), compiled natively with fakes. Fast; covered by `zig build coverage`. |
| In-kernel tests | `zig build test-qemu` (scenarios `tests`, `tests_fxsave`) | `tests/kernel/main.zig`, `tests/user/` | Code that needs the real kernel: PMM, VMM (mapping conflicts, unmapping, TLB flushes for user and global kernel mappings, which kernel mappings are global, what in the kernel is writable), memory exhaustion and failed allocations, heap, kernel stacks, process limits, spinlocks, wait queues, mutexes, timers and sleeping, the CPUs (all of them up; per-CPU state, GDT, TSS, emergency and kernel stacks of their own; control registers and `syscall` MSRs the same on each; timer interrupts on each), the speculation barrier after the conditional `swapgs`, the locking model (the locks a CPU holds through waits, switches and interrupts; a thread woken while its CPU idles on its stack; timers that wake a thread), the random-number generator, poisoning and zeroing of memory, speculation guards (also that the user-copy routines cannot be made to touch kernel memory), address randomization, the process lifecycle (late waits, orphans, a stress run), ELF loading, scheduler and processes (round robin, no idling while a thread is ready, the address space a kernel thread runs on), syscalls from ring 3 (errors, register preservation, return states, a fuzzer), kernel entry and exit (GS base, stacks, address spaces, preemption), x87/SSE/AVX state, user-memory copies, tarfs, NVMe reads, symbolization, fw_cfg. |
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
| `tests_smp` | Runs the same suite on a machine with four CPUs (`-smp 4`). The CPU test then checks all four; the others run on the boot CPU while the rest take interrupts | As `tests`, and the boot log says `4 of 4 CPUs online` (`tests` and `tests_fxsave` require `1 of 1`) |
| `panic` | Fails a subsystem assertion two calls deep | Exit code 1, the panic message, a symbolized backtrace through `scenarioPanicInner` and `scenarioPanic` |
| `fault` | Writes to an unmapped kernel address | Exit code 1, `Page fault`, the right CR2, backtrace frame `#0` in `scenarioFault` |
| `smap` | Reads a mapped user page from kernel code outside a user copy | Exit code 1, `Page fault` with error 0x1 and CR2 = the user page, frame `#0` in `scenarioSmap` (SMAP is enforced) |
| `smep` | Calls code in a mapped user page from ring 0 | Exit code 1, `Page fault` with error 0x11, RIP and CR2 = the user page (SMEP is enforced) |
| `double_fault` | A kernel thread points RSP at unmapped memory and pushes | Exit code 1, `Double fault` with the bad RSP, CR2, the thread's stack bounds and frame `#0` in `doubleFaultThread` (a triple fault would end QEMU with status 0 and no report) |
| `stack_overflow` | A kernel thread recurses until its stack is used up | Exit code 1, `Double fault` with CR2 in a kernel stack guard page, `kernel stack overflow`, RSP below the thread's stack, backtrace frames in `recurseForever` |
| `use_after_free` | Writes to a heap block after freeing it, then allocates again | Exit code 1, a panic naming the address, the byte written and its offset, a backtrace through `writeAfterFree` |
| `relro` | Writes to the heap's table of function pointers, which the bootloader relocated | Exit code 1, `Page fault` with error 0x3 and CR2 in the kernel image, frame `#0` in `writeRelocatedTable` (relocated tables are read-only once the kernel runs) |
| `lock_order` | Takes two spinlocks against the lock order | Exit code 1, a panic naming both locks' ranks, a backtrace through `takeLocksOutOfOrder` (the order is enforced on one CPU too, see [locking](locking.md#checks-in-the-code)) |
| `sleep_with_lock` | Sleeps while holding a spinlock | Exit code 1, a panic saying a spinlock was held when the thread blocked, a backtrace through `sleepHoldingSpinlock` |
| `text_alias` | Writes to kernel code through the direct map of physical memory | Exit code 1, `Page fault` with error 0x3 and CR2 in the direct map, frame `#0` in `writeTextThroughDirectMap` (kernel code is read-only under every address) |

After the scenarios the script compares where the kernel was loaded in each
boot (the test kernel prints `MYOS_KERNEL_SLIDE`): with KASLR the addresses
must not all be the same.

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

## Model checks

The kernel's blocking protocols (sleeping and waking, the context switch
and idling, timeouts, the mutex) are checked as models before they are
relied on with several CPUs. A model
describes a protocol as a handful of variables and steps;
`tools/modelcheck/modelcheck.zig` tries the steps in every order they can
happen and reports an invariant that breaks, a state where nothing can move
although the model is not finished (a deadlock or a lost wake-up), or a
state from which it can never finish, with the shortest sequence of steps
that leads there.

- The models are in `tests/models/`; `docs/locking.md` says what they show.
- `zig build check-models` runs them and the checker's own tests. It is part
  of `zig build test` and CI, and takes a second or two.
- Every rule a protocol depends on can be switched off in its model
  (`Config`), and `tests/models/main.zig` has a test that expects the
  failure that follows. Add such a test with every rule: a model that
  cannot fail proves nothing.
- A model is not the code. When the code it names changes, change the model.

## Syscall dispatch check

The normal kernel calls its syscall dispatcher directly. Only the test
kernel reaches it through a pointer (`arch.syscall.setHandler`), so that
tests can watch and alter syscalls; in the normal kernel such a pointer
would be one more thing a stray write could redirect, and an indirect branch
on every syscall. `zig build check-dispatch` (run by `zig build test` and by
CI in every build mode) looks in the symbol tables: `scripts/check-dispatch.sh`
fails if `kernel.elf` has the pointer, and also if `kernel-test.elf` does
not, since then the check is looking for the wrong name.

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

The thread that runs the tests has interrupts off unless a test turns them
on (`helpers.enableInterrupts`), which tests of preemption, sleeping and
interrupt state do. A helper that starts a process and wants its result
calls `process.wait`; one that does not calls `process.release`.

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
| `single_step` | Single-stepping into a syscall: the debug trap is delivered in ring 3 after the return, never in the kernel |
| `gs_base` | The kernel's GS base is not visible in ring 3 |
| `fpu`, `fpu_clean` | x87, SSE and AVX registers survive switches between two processes; a new process starts clean (`fpu_regs.zig` holds the shared assembly) |
| `fuzz` | 20 000 random syscalls from a fixed seed: the kernel survives and leaks nothing |
| `recurse` | A program that starts itself until the kernel refuses: `ENOMEM` when memory runs out, `EAGAIN` at the descendant limit |
| `open_count`, `run_many` | The descriptor limit; children that have exited no longer count against the descendant limit |
| `getchar` | Waits for one key; the kernel test starts several and feeds them keys with `keyboard.inject` |
| `zero_pages` | Memory the program has not written (`.bss`, the unused stack) is zero, after the kernel test has filled all free memory with a pattern |
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

### Tests of running out of memory

Two things make memory run out on purpose:

- `drainMemory(leave)` allocates physical pages until only `leave` are
  free, and `releaseDrained` gives them back. Use it to test what happens
  with no memory, or with a known small amount.
- `pmm.fail_after = n` (test kernel only) lets `n` more page allocations
  succeed and then fails every one, until it is set to null. Running an
  operation with `n` = 0, 1, 2, ... until it succeeds makes each of its
  allocations fail once; `spawnAllocationFailures` does this for starting
  a process.

A third hook, `pmm.critical_hook`, runs inside the allocator's critical
section; `pmmLockHolds` uses it to stay in there longer than a time slice
and show that no other thread gets in.

Compare `helpers.footprint()` before and after to check that nothing was
lost. It counts free pages together with the pages the heap holds, because
the heap keeps memory it has grown by; free pages alone go down the first
time something large is allocated.

## Adding host tests

1. Keep the code under test free of kernel imports (only `std`).
2. Register it as a module for the host tests in `build.zig` (the list next to
   `vfs`, `symbols` and `log_format`).
3. Add `tests/host/<name>_test.zig` and reference it from `tests/host/main.zig`.

## Fuzzing

Two kinds of fuzz tests run on the host:

- **Fixed-seed** tests are ordinary tests that feed thousands of generated
  inputs to the code (the ELF validator, the page bitmap and the timer
  queue against models). The same inputs every run, so they run in
  `zig build test-host` and CI.
- **Coverage-guided** tests call `std.testing.fuzz`. In an ordinary run
  each executes once. Under the fuzzer they run for as long as they are
  left to, and the fuzzer keeps the inputs that reach new code:

  ```bash
  zig build fuzz-host --fuzz=5M                           # five million cases, then a report
  zig build fuzz-host --fuzz=5M -Dtest-filter="elf image"   # one test
  zig build fuzz-host --fuzz                              # until stopped, with a web page showing coverage
  ```

  Today: the ELF validator and the ELF symbol table. `fuzz-host` is the
  host tests built with LLVM, which the instrumentation needs
  (`zig build test-host --fuzz` finds nothing to instrument). What the
  fuzzer has learned is kept in `.zig-cache`. A failure is reported like
  a failing test.

To add one, write `fn fuzzOne(_: void, smith: *std.testing.Smith) !void`,
which builds an input from the choices `smith` hands out and checks the
result, and a test that calls `std.testing.fuzz({}, fuzzOne, .{})`. Start
from a valid input and let the fuzzer overwrite parts of it: from pure
noise it rarely gets past the first check.

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

CI uses the same tool versions as development. They are written down in
one file, `tools.versions`, with the checksum of each release archive:

| Tool | Installed in CI by |
| --- | --- |
| Zig | `scripts/install-zig.sh` (binary from ziglang.org) |
| Limine | `scripts/install-limine.sh` (release tarball) |
| QEMU | `scripts/install-qemu.sh` (built from source: the x86-64 system emulator only) |
| xorriso | `scripts/install-xorriso.sh` (built from source) |
| kcov | `scripts/install-kcov.sh` (built from source) |

`scripts/check-tools.sh` compares the tools on `PATH` with that file. Every
`zig build` checks Zig, `zig build test-qemu` checks Limine, QEMU and
xorriso too, `zig build coverage` checks kcov, and `scripts/build.sh`
checks what makes the ISO.

- **In CI** (the `CI` variable is set) a missing tool or another version
  fails the job.
- **On a development machine** it prints a warning and carries on, because a
  distribution's packages move on by themselves:

  ```
  warning: tool versions differ from tools.versions (CI uses exactly those):
    qemu: found 11.2.0, want 11.1.3
  ```

  Either install the pinned version (`scripts/install-qemu.sh ~/tools/qemu`,
  then put `~/tools/qemu/bin` first in `PATH`), or move the project to the
  new version. `MYOS_STRICT_TOOLS=1` makes the check fail locally as it
  does in CI.

To move to a new version of a tool, change its version and checksum in
`tools.versions`: the install scripts, the check and the CI caches all
follow from that file. `scripts/test-check-tools.sh` tests the check with
fake tools.

The console font comes from `scripts/fetch-font.sh`. `objdump`, for the
stack frame check, is the one tool taken from the runner's distribution.

The jobs cache the Zig toolchain and the QEMU, xorriso and kcov builds (keyed
on `tools.versions` and the install script, so a version change rebuilds them
once; QEMU takes several minutes to build when its cache is empty) and, except for the release job, the Zig
build cache `.zig-cache`. The build cache is keyed on job, build mode,
`tools.versions` and `build.zig` only, not on the sources: what it saves is compiler-rt,
the build runner and unchanged programs (about 80 s from nothing), while the
kernel is recompiled on every change anyway. A commit that changes `build.zig`
therefore builds from an empty cache once per job. Zig's cache is
content-addressed, so a restored cache never gives stale results. The release
job builds from an empty cache on purpose. To change the Zig
version, update its version and checksum in `tools.versions`.
