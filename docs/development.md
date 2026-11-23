# Developing MyOS

Everything needed to build, run and work on MyOS. See also
[testing](testing.md), [debugging](debugging.md) and the [roadmap](todo.md).

## Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| [Zig](https://ziglang.org/download/) | 0.17.1 (CI pins this) | everything |
| [Limine](https://github.com/Limine-Bootloader/Limine) | 12.x (CI uses 12.10.0) | the bootable ISO |
| xorriso | any | the bootable ISO |
| QEMU (x86-64) | any recent | running and testing |
| binutils (`objdump`) | any | the stack frame check in `zig build test` |
| OVMF (edk2) | any | UEFI boot in `scripts/run-qemu.sh` (optional, `--bios` works without) |
| GDB | any | debugging (optional) |
| kcov | any | `zig build coverage` (optional) |

Arch Linux:

```bash
sudo pacman -S zig zls limine xorriso qemu-desktop edk2-ovmf binutils gdb kcov
```

Debian/Ubuntu (Zig and Limine are not packaged in the right versions; install
them with the scripts, as CI does):

```bash
sudo apt install qemu-system-x86 xorriso ovmf binutils gdb
scripts/install-zig.sh ~/.local/zig              # checksum-verified 0.17.1
export PATH=~/.local/zig:$PATH
scripts/install-limine.sh ~/.local/limine        # checksum-verified 12.10.0
export LIMINE=~/.local/limine PATH=~/.local/limine:$PATH
scripts/install-kcov.sh ~/.local                 # optional, for coverage
```

`scripts/build.sh` looks for Limine's boot files in `$LIMINE` (default
`/usr/share/limine`) and runs the `limine` tool from `PATH`.

## First-time setup

The console font is not in the repository. Put it in place once:

```bash
scripts/fetch-font.sh
```

It copies kbd's `default8x16` font from `/usr/share/kbd/consolefonts/` to
`src/assets/font.psf`, or downloads the same file (checksum verified) if kbd
is not installed. The kernel embeds it at compile time, so the build fails
without it.

Then build and boot:

```bash
scripts/build.sh      # zig build + os.iso (+ disk.img the first time)
scripts/run-qemu.sh   # boots into the shell; type "hello", or "exit"
```

## Building

| Command | What it does |
| --- | --- |
| `zig build` | Build the kernel (`zig-out/bin/kernel.elf`) and user programs (`zig-out/bin/*.elf`). |
| `scripts/build.sh` | `zig build`, then pack the initrd and create `os.iso`. Creates `disk.img` (64 MiB NVMe disk) only if it doesn't exist. |
| `zig build docs` | Generate API docs from `//!` and `///` comments into `zig-out/docs/`. |
| `zig build test-host` | Native host unit tests. |
| `zig build test-kernel` | Compile the test kernel only (no QEMU). |
| `zig build check-frames` | Check that no kernel function has a stack frame near the size of a stack guard page (see [testing](testing.md#stack-frame-check)). |
| `zig build test-qemu` | Package a test ISO and run the QEMU scenarios (`tests`, `panic`, `fault`, `smap`, `smep`, `double_fault`, `stack_overflow`). |
| `zig build test` | Host tests, the stack frame check and QEMU scenarios. |
| `zig build coverage` | Host tests under kcov; report in `zig-out/coverage/`. |

Build options (they apply to the test commands too):

| Option | Values | Default |
| --- | --- | --- |
| `-Doptimize` | `Debug`, `ReleaseSafe`, `ReleaseFast` | `Debug` |
| `-Dlog-level` | `err`, `warn`, `info`, `debug` | `debug` in Debug, `info` otherwise |
| `-Dassertions` | `true`, `false` | `true` |
| `-Dalloc-debug` | `true`, `false` (log every heap allocation) | `false` |
| `-Dstack-usage` | `true`, `false` (measure kernel stack high-water marks) | `true` for Debug, else `false` |
| `-Dpoison` | `true`, `false` (fill freed heap memory and pages with a pattern, and check it when heap memory is reused) | `true` for Debug, else `false` |
| `-Dallow-meltdown` | `true`, `false` (boot on CPUs where user programs can read kernel memory, instead of refusing) | `false` |
| `-Dtest-filter` | name filter for `test-host` | none |

`scripts/build.sh` always builds with the defaults. `MYOS_KASLR=no
scripts/build.sh` makes an ISO that loads the kernel at its link address
instead of a random one (for debuggers). For an optimized ISO, run
`zig build -Doptimize=ReleaseSafe` and then repackage; `build.sh` packages
whatever is in `zig-out/bin`.

### Build outputs

| Path | Contents |
| --- | --- |
| `zig-out/bin/` | `kernel.elf`, `kernel-test.elf`, user programs (`hello.elf`, `sh.elf`, `test-*.elf`) |
| `os.iso`, `iso_root/`, `initrd/` | Bootable image and the files packed into it (from `scripts/build.sh`) |
| `disk.img` | Empty 64 MiB NVMe disk for `scripts/run-qemu.sh`; kept between builds, delete it to recreate |
| `zig-out/test/` | Test ISO and per-scenario serial logs (`<scenario>/serial.log`) |
| `zig-out/docs/` | Generated API docs (serve over HTTP: `python3 -m http.server -d zig-out/docs`) |
| `zig-out/coverage/` | kcov report |

All of these are ignored by git.

## Running

`scripts/run-qemu.sh` boots `os.iso` with the serial port on the terminal:

| Option | Effect |
| --- | --- |
| `--bios` | Legacy BIOS boot instead of UEFI (OVMF) |
| `--no-kvm` | Software emulation even if `/dev/kvm` is usable |
| `--gdb` | Start paused and wait for GDB on `localhost:1234` (see [debugging](debugging.md)) |
| `-- <args>` | Extra QEMU arguments |

It runs roughly:

```bash
qemu-system-x86_64 -M q35 -m 2G -cdrom os.iso \
  -bios /usr/share/edk2/x64/OVMF.4m.fd \
  -serial stdio -no-reboot -no-shutdown -enable-kvm -cpu host \
  -drive file=disk.img,if=none,id=nvm,format=raw \
  -device nvme,serial=myos0001,drive=nvm
```

Kernel output goes to both the serial port (your terminal) and the QEMU
window. Keyboard input only comes from the QEMU window (the kernel has a PS/2
keyboard driver, not serial input), so click into the window to type. The
shell (`/bin/sh`) runs `/bin/<name>` for a typed name, or a path containing
`/`; `exit` leaves it. Quit QEMU by closing the window or pressing Ctrl+C in
the terminal.

## Project layout

| Path | Contents |
| --- | --- |
| `src/main.zig` | Kernel entry (`kmain`), boot order, `print`/`log`/panic handling |
| `src/abi/linux.zig` | The user/kernel ABI (Linux's syscall numbers, error values and flags), imported by the kernel and by user programs (see [syscalls](syscalls.md)) |
| `src/arch/x86_64/` | GDT/TSS with the double-fault, NMI and debug emergency stacks, IDT and interrupt entry, APIC, paging (`vmm`), context switch, syscall entry and the `sysretq`/`iretq` choice (`syscall`, `sysret`), per-CPU data behind the GS base (`percpu`), x87/SSE/AVX state (`fpu`), fault-tolerant user copies and UMIP/SMEP/SMAP (`usercopy`), speculation guards (`nospec`), the Meltdown check (`meltdown`), port I/O |
| `src/boot/limine.zig` | Limine boot protocol requests and responses |
| `src/drivers/` | Serial, PS/2 keyboard, HPET, PCI, NVMe |
| `src/firmware/acpi.zig` | ACPI table discovery and MADT parsing |
| `src/kernel/` | Physical memory (`pmm`, with its bookkeeping in `page_bitmap`), heap, guarded kernel stacks (`kstack`), threads/scheduler, processes and their limits, the random-number generator (`random`), ELF image validation (`elf_image`) and loader (`elf`), syscalls, user-memory access (`uaccess`, `user_range`), VFS, console |
| `src/kernel/sync/` | Spinlocks, wait queues, mutexes and the timer queue; `src/kernel/timer.zig` drives the timers and provides sleep |
| `src/kernel/fs/` | Filesystems (`tarfs` for the initrd) |
| `src/kernel/debug/` | Assertions, small-buffer panic formatting, backtraces, ELF symbol lookup, log formatting |
| `src/assets/` | Console font (fetched, not committed) |
| `app/` | User programs (`sh`, `hello`) and their runtime `lib.zig`; linked by `app/linker.ld`, each at its own address set in `build.zig` |
| `tests/host/` | Host unit tests |
| `tests/kernel/` | In-kernel test suite, its kernel-side helpers, the crash scenarios and the QEMU fw_cfg reader |
| `tests/user/` | Ring 3 test programs, packaged as `/test/<name>` in the test initrd |
| `tests/support/` | QEMU exit device helper for the test kernel |
| `scripts/` | Build, run, test, release, CI install scripts and the GDB setup |
| `VERSION` | `<major>.<minor>` of the next release (see [releases](#releases)) |
| `linker.ld`, `limine.conf` | Kernel link layout (a position-independent executable linked at 0xffffffff80000000) and boot menu, which turns on KASLR |
| `.github/workflows/ci.yml` | CI (see [testing](testing.md#ci)) |

### Boot flow

Limine loads `kernel.elf` and `initrd.tar`, answers the requests in
`src/main.zig`, and jumps to `kmain`. `kmain` brings up, in order: serial, GDT,
per-CPU data (GS base), IDT, framebuffer console, PMM, page tables, SMEP/SMAP, SSE/AVX and their save area, kernel symbols, ACPI, APIC, HPET,
PCI (and NVMe if present), the APIC timer, syscalls and the initrd. The
normal kernel then starts `/bin/sh` and becomes the idle thread; the test
kernel runs the scenario QEMU asks for instead.

The initrd is a ustar archive built by `scripts/build.sh` from
`zig-out/bin/` (`/bin/sh`, `/bin/hello`, `/etc/motd`, plus `/test/*` in the
test image).

## Making changes

### Adding a user program

1. Create `app/<name>.zig`: import `lib.zig`, set `pub const panic = lib.panic;`
   and export `_start` (see `app/hello.zig`).
2. Add it in `build.zig` next to `hello`: `userProgram(b, "<name>",
   "app/<name>.zig", <link address>, user_target, optimize)`, with the `abi`
   import that `lib.zig` needs. User programs are built for baseline x86-64
   with SSE2; the kernel is built without SSE.
3. Copy it into the initrd in `scripts/build.sh` (`cp zig-out/bin/<name>.elf "$initrd/bin/<name>"`).

### Waiting, locking and time in kernel code

- **Short critical section, or data an interrupt handler touches:** a
  `SpinLock` (`sync/spinlock.zig`). `acquire` turns interrupts off and
  returns what `release` needs to restore them. Never block while holding one.
- **Waiting for something to happen:** a `WaitQueue` (`sync/wait_queue.zig`)
  that belongs to the thing waited for. With interrupts off, the waiter runs
  `while (!condition) queue.wait();` and the other side sets the condition
  and calls `wakeOne` or `wakeAll`. `waitTimeout` gives up after a number
  of ticks.
- **A longer section that may block:** a `Mutex` (`sync/mutex.zig`).
- **Later, or after a delay:** `timer.sleepTicks`/`sleepMs` for a thread;
  `timer.add` with a callback (run in the timer interrupt: keep it short)
  for anything else.
- **A process someone else started:** `process.spawn` gives the caller a
  reference, which it must hand back with `process.wait` (to get the exit
  status) or `process.release`. The rules for who owns what are at the top
  of `src/kernel/process.zig`; the thread states at the top of
  `src/kernel/thread.zig`.

`thread.block` and `thread.wake` are the mechanism underneath; use a wait
queue instead.

### Adding a syscall

The ABI is Linux's ([syscalls](syscalls.md)), so a new call takes Linux's
number, arguments, result and error values. Only something Linux has no call
for gets a private number.

1. Add the number to `src/abi/linux.zig` (and any error value or flag it
   needs, with Linux's values), an implementation to `src/kernel/syscall.zig`
   and a case in `dispatch`. Never dereference a user pointer: copy the data
   into a kernel buffer with `uaccess.copyFromUser` (or
   `copyStringFromUser` for a path), or out with `uaccess.copyToUser`, and
   return `err(.FAULT)` when they fail with `error.Fault` (with SMAP on, a
   direct access is a kernel page fault). Return a specific error for every
   failure.
2. Add a wrapper to `app/lib.zig`.
3. Describe it in `docs/syscalls.md`, including what differs from Linux.
4. Test it from ring 3: each error in `tests/user/syscalls.zig`, its pointer
   arguments in `tests/user/user_pointers.zig`, and add its number to
   `implemented` in `tests/user/fuzz.zig` (see [testing](testing.md)).

### Releases

Every push to `main` that passes all three build-and-test jobs is released
automatically by the `release` job in `.github/workflows/ci.yml`. Nothing is
tagged by hand.

- **Version**: `<major>.<minor>.<patch>`. `<major>.<minor>` is the contents of
  the `VERSION` file; `<patch>` is one more than the highest existing tag
  `v<major>.<minor>.*`, starting at 0 (`scripts/next-version.sh`, tested by
  `scripts/test-next-version.sh`).
- **Automatic part**: the patch number. With `VERSION` at `0.0`, releases are
  `0.0.0`, `0.0.1`, `0.0.2`, ... with no manual step.
- **Bumping the minor or major number**: change the one line in `VERSION`
  (for example from `0.0` to `0.1`) and push it to `main` like any other
  change. That push is released as `0.1.0`, and the patch number counts up
  from there. Versions below 1.0 are published as pre-releases.
- **Contents**: `myos-<version>.iso` (BIOS and UEFI, built with
  `-Doptimize=ReleaseSafe`), `myos-<version>-kernel.elf` (the same kernel
  with symbols, for backtraces) and `SHA256SUMS`. The release notes list the
  commits since the previous release.
- **Version in the kernel**: `-Dversion=<v>` sets the name in the boot banner
  (`MyOS <v> booting`); ordinary builds say `dev`.
- **Locally**: `scripts/build.sh --release <version>` writes the same files to
  `zig-out/release/`. It rebuilds `zig-out/bin` in ReleaseSafe mode, so run
  `zig build` afterwards to get the Debug binaries back.
- Pushes to other branches and pull requests run the tests but never release.
  Re-running the workflow on a commit that already has a version tag does
  nothing.

### Conventions

- **Tests with every change.** Each roadmap section has its own test items; a
  feature is done when its tests are. Where tests go: [testing](testing.md).
- **Keep [the roadmap](todo.md) current**: tick items when done and demonstrated,
  add sub-items for partial work.
- **Doc comments**: `//!` at the top of every file, `///` on declarations. They
  become the generated docs; check them with `zig build docs`. Plain `//` is for
  implementation notes (and is required above `comptime` blocks).
- **Formatting**: run `zig fmt src app tests build.zig`; `zig fmt --check` on the
  same paths should report nothing.
- **Logging**: use `std.log.scoped(.subsystem)` for diagnostics; `root.print` only
  for real console output. Use `assert.check(.subsystem, ok, fmt, args)` for
  invariants, not `std.debug.assert`.
- **Never trust user input**: pointers, lengths and executables from user space
  are validated before use; use overflow-checked arithmetic on their values.
- **Architecture-specific code** goes in `src/arch/x86_64/`.
- **New modules in the docs**: the API docs only show what `src/main.zig`
  exposes. Add new kernel files to the matching namespace (`arch`, `boot`,
  `drivers`, `firmware`, `kernel`) there.

## Editor setup

VS Code with the Zig extension and ZLS works out of the box: open the
repository folder (`.vscode/settings.json`) or the workspace file
`MyOS.code-workspace`, which repeats the same settings because VS Code ignores
the folder's Zig settings in a workspace window. Avoid an "Untitled
(Workspace)" window: its settings live outside the repository and override
these. `.vscode/tasks.json` has tasks for the host tests,
the QEMU tests and all tests ("Run Test Task"); the test explorer runs single
host tests through `zig build test-host -Dtest-filter=<name>`. "Debug Test"
builds them with `zig build debug-test-host -Dtest-filter=<name>`, which puts the
binary at `zig-out/bin/debug-unit-tests` for the debugger. The launch
configurations "MyOS: Debug kernel (QEMU)" and "MyOS: Debug kernel + user
programs (QEMU)" boot the OS in QEMU under the
debugger; see [debugging.md](debugging.md#debugging-in-vs-code).

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Build fails on `@embedFile("../assets/font.psf")` | Run `scripts/fetch-font.sh`. |
| `limine: command not found` or missing `limine-bios.sys` | Install Limine, or set `LIMINE` and `PATH` as in [Prerequisites](#prerequisites). |
| `OVMF firmware not found` | Install OVMF (`edk2-ovmf` / `ovmf`) or use `scripts/run-qemu.sh --bios`. |
| QEMU is slow / no KVM | Check that you can write `/dev/kvm` (usually: be in the `kvm` group). Tests do not need KVM. |
| Compile errors in `std` or the build script | Check `zig version`; MyOS tracks Zig 0.17.1 and its standard library changes between versions. |
| QEMU test timed out | Look at `zig-out/test/<scenario>/serial.log`; raise the limit with `MYOS_QEMU_TIMEOUT=<seconds>`. |
| Machine reboots or freezes early | Triple fault: run with `-- -d int,cpu_reset -D qemu.log` (see [debugging](debugging.md)). |
| `disk.img` has old contents | It is only created when missing; delete it and run `scripts/build.sh`. |
