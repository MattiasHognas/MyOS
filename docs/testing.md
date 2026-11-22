# Testing MyOS

There are three layers of tests. Add tests to the layer that fits whenever you
change or add a subsystem.

| Layer | Command | Where | What it is for |
| --- | --- | --- | --- |
| Host unit tests | `zig build test-host` | `tests/host/` | Hardware-independent kernel code (VFS, ELF symbol lookup, log formatting), compiled natively with fakes. Fast; covered by `zig build coverage`. |
| In-kernel tests | `zig build test-qemu` (scenario `tests`) | `tests/kernel/main.zig` | Code that needs the real kernel: PMM, VMM, heap, ELF loading, VFS on the initrd, symbolization, fw_cfg. |
| QEMU scenarios | `zig build test-qemu` | `test-qemu.sh` | Whole-system behaviour checked from the serial log, including runs that are meant to crash. |

`zig build test` runs the host tests and all QEMU scenarios. Add
`-Doptimize=ReleaseSafe` or `-Doptimize=ReleaseFast` to run the QEMU tests
against an optimized kernel. CI runs all three build modes.

## QEMU integration-test scenarios

`test-qemu.sh` boots the test kernel (`zig-out/bin/kernel-test.elf`) once per
scenario. The scenario name reaches the kernel through QEMU's fw_cfg device
(`-fw_cfg name=opt/myos/scenario,string=<name>`); `runTestScenario` in
`src/main.zig` reads it with `drivers/fw_cfg.zig`.

| Scenario | What the kernel does | What the script checks (kernel exit code; QEMU reports `code*2+1`) |
| --- | --- | --- |
| `tests` | Runs the in-kernel test suite | Exit code 0, `MYOS_TEST_PASS`, `failed=0`, no `[FAIL]` lines |
| `panic` | Fails a subsystem assertion two calls deep | Exit code 1, the panic message, a symbolized backtrace through `scenarioPanicInner` and `scenarioPanic` |
| `fault` | Writes to an unmapped kernel address | Exit code 1, `Page fault`, the right CR2, backtrace frame `#0` in `scenarioFault` |

Run a subset with `bash test-qemu.sh tests panic` (after `zig build test-kernel`
and `zig build`). The timeout per boot is 45 s, or `MYOS_QEMU_TIMEOUT` seconds.

Each scenario keeps its logs in `zig-out/test/<scenario>/serial.log` (raw) and
`serial-clean.log` (CR removed). When a check fails, the script prints the
serial log; CI uploads the logs as the `serial-logs-<mode>` artifact.

In the test kernel, `root.halt()` and the panic handler exit QEMU with status
1 (host status 3) instead of hanging, so crashes end the run immediately.

### Adding a scenario

1. Add a `noinline fn scenarioX() void` to `src/main.zig` and dispatch to it
   in `runTestScenario`.
2. Add a `X)` case to `run_scenario` in `test-qemu.sh` with its expected exit
   status (`expect_status`) and output (`expect_line`), and add it to the
   default list.
3. Document it in the table above.

## Adding in-kernel tests

Tests in `tests/kernel/main.zig` can't import kernel modules directly (that
would create a second copy of their global state). They call kernel services
through the `Api` struct of callbacks, which `src/main.zig` fills in. To add a
test:

1. If it needs a new kernel service, add a field to `Api` and a `testX`
   callback in `src/main.zig`, and pass it in `runTestScenario`.
2. Write `fn myTest(api: Api) TestError!void` using `check(...)`.
3. Add it to the `cases` list in `run`.

## Adding host tests

1. Keep the code under test free of kernel imports (only `std`).
2. Register it as a module for the host tests in `build.zig` (the list next to
   `vfs`, `symbols` and `log_format`).
3. Add `tests/host/<name>_test.zig` and reference it from `tests/host/main.zig`.

## Coverage

`zig build coverage` runs the host tests under [kcov](https://github.com/SimonKagstrom/kcov)
and writes an HTML report to `zig-out/coverage/index.html`. It needs `kcov`
installed. Coverage covers host-tested code only; kernel code that runs only in
QEMU is checked by the scenarios above instead.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

- **Build and test** (Debug, ReleaseSafe, ReleaseFast): builds the kernel and
  apps, runs the host tests and all QEMU scenarios, builds the docs (Debug only),
  and uploads the serial logs if anything fails.
- **Host test coverage**: runs `zig build coverage` and uploads the report.
  Informational; it does not fail the workflow.

CI gets Limine from its release tarball (`scripts/install-limine.sh`, checksum
verified) and the console font with `scripts/fetch-font.sh`.
