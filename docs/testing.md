# Testing MyOS

There are three layers of tests. Add tests to the layer that fits whenever you
change or add a subsystem.

| Layer | Command | Where | What it is for |
| --- | --- | --- | --- |
| Host unit tests | `zig build test-host` | `tests/host/` | Hardware-independent kernel code (VFS, ELF symbol lookup, log formatting), compiled natively with fakes. Fast; covered by `zig build coverage`. |
| In-kernel tests | `zig build test-qemu` (scenario `tests`) | `tests/kernel/main.zig`, `tests/user/` | Code that needs the real kernel: PMM, VMM, heap, ELF loading, scheduler and processes, syscalls from ring 3, tarfs, NVMe reads, symbolization, fw_cfg. |
| QEMU scenarios | `zig build test-qemu` | `scripts/test-qemu.sh` | Whole-system behaviour checked from the serial log, including runs that are meant to crash. |

`zig build test` runs the host tests and all QEMU scenarios. Add
`-Doptimize=ReleaseSafe` or `-Doptimize=ReleaseFast` to run the QEMU tests
against an optimized kernel. CI runs all three build modes.

## QEMU integration-test scenarios

`scripts/test-qemu.sh` boots the test kernel (`zig-out/bin/kernel-test.elf`) once per
scenario. The scenario name reaches the kernel through QEMU's fw_cfg device
(`-fw_cfg name=opt/myos/scenario,string=<name>`); `run` in
`tests/kernel/main.zig` reads it with `tests/kernel/fw_cfg.zig`.

| Scenario | What the kernel does | What the script checks (kernel exit code; QEMU reports `code*2+1`) |
| --- | --- | --- |
| `tests` | Runs the in-kernel test suite | Exit code 0, `MYOS_TEST_PASS`, `failed=0`, no `[FAIL]` lines |
| `panic` | Fails a subsystem assertion two calls deep | Exit code 1, the panic message, a symbolized backtrace through `scenarioPanicInner` and `scenarioPanic` |
| `fault` | Writes to an unmapped kernel address | Exit code 1, `Page fault`, the right CR2, backtrace frame `#0` in `scenarioFault` |

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
(syscall validation, user/kernel isolation). The build installs each as
`zig-out/bin/test-<name>.elf`, and `scripts/build.sh --package-test` puts them
in the test initrd as `/test/<name>`. In-kernel tests run them with
`api.run_program("/test/<name>")`, which returns the exit code (255 if the
kernel killed the process for a fault).

To add one: create `tests/user/<name>.zig` (import the runtime with
`@import("lib")`, export `_start`), add `<name>` to the list in `build.zig`,
and call it from a test in `tests/kernel/main.zig`. Report failures through
the exit code, e.g. the number of the first failing check.

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
  apps, runs the host tests and all QEMU scenarios, builds the docs (Debug only),
  and uploads the serial logs if anything fails.
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

Each job caches the Zig toolchain (keyed on the Zig version) and its Zig build
cache `.zig-cache` (keyed on job, build mode and a hash of the sources, falling
back to the newest cache of the same job). The build cache is dropped once it
passes 1 GiB, so it is rebuilt from scratch now and then. To change the Zig
version, update both `ZIG_VERSION` in the workflow and the version and
checksum in `scripts/install-zig.sh`.
