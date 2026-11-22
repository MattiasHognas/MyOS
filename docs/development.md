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
| OVMF (edk2) | any | UEFI boot in `scripts/run-qemu.sh` (optional, `--bios` works without) |
| GDB | any | debugging (optional) |
| kcov | any | `zig build coverage` (optional) |

Arch Linux:

```bash
sudo pacman -S zig zls limine xorriso qemu-desktop edk2-ovmf gdb kcov
```

Debian/Ubuntu (Zig and Limine are not packaged in the right versions; install
them with the scripts, as CI does):

```bash
sudo apt install qemu-system-x86 xorriso ovmf gdb
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
| `zig build test-qemu` | Package a test ISO and run the QEMU scenarios (`tests`, `panic`, `fault`). |
| `zig build test` | Host tests and QEMU scenarios. |
| `zig build coverage` | Host tests under kcov; report in `zig-out/coverage/`. |

Build options (they apply to the test commands too):

| Option | Values | Default |
| --- | --- | --- |
| `-Doptimize` | `Debug`, `ReleaseSafe`, `ReleaseFast` | `Debug` |
| `-Dlog-level` | `err`, `warn`, `info`, `debug` | `debug` in Debug, `info` otherwise |
| `-Dassertions` | `true`, `false` | `true` |
| `-Dalloc-debug` | `true`, `false` (log every heap allocation) | `false` |
| `-Dtest-filter` | name filter for `test-host` | none |

`scripts/build.sh` always builds with the defaults. For an optimized ISO, run
`zig build -Doptimize=ReleaseSafe` and then repackage; `build.sh` packages
whatever is in `zig-out/bin`.

### Build outputs

| Path | Contents |
| --- | --- |
| `zig-out/bin/` | `kernel.elf`, `kernel-test.elf`, user programs (`hello.elf`, `sh.elf`, `test-*.elf`) |
| `os.iso`, `iso_root/`, `initrd/` | Bootable image and the files packed into it (from `scripts/build.sh`) |
| `disk.img` | NVMe test disk; kept between builds, delete it to recreate |
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
| `src/main.zig` | Kernel entry (`kmain`), boot order, `print`/`log`/panic handling, test scenarios and test callbacks |
| `src/arch/x86_64/` | GDT/TSS, IDT and interrupt entry, APIC, paging (`vmm`), context switch, syscall entry, port I/O |
| `src/boot/limine.zig` | Limine boot protocol requests and responses |
| `src/drivers/` | Serial, PS/2 keyboard, HPET, PCI, NVMe, QEMU fw_cfg |
| `src/firmware/acpi.zig` | ACPI table discovery and MADT parsing |
| `src/kernel/` | Physical memory (`pmm`), heap, threads/scheduler, processes, ELF loader, syscalls, VFS, console |
| `src/kernel/fs/` | Filesystems (`tarfs` for the initrd) |
| `src/kernel/debug/` | Assertions, backtraces, ELF symbol lookup, log formatting |
| `src/assets/` | Console font (fetched, not committed) |
| `app/` | User programs (`sh`, `hello`) and their runtime `lib.zig`; linked at 0x400000 by `app/linker.ld` |
| `tests/host/` | Host unit tests |
| `tests/kernel/` | In-kernel test suite |
| `tests/user/` | Ring 3 test programs, packaged as `/test/<name>` in the test initrd |
| `tests/support/` | QEMU exit device helper for the test kernel |
| `scripts/` | Build, run, test, CI install scripts and the GDB setup |
| `linker.ld`, `limine.conf` | Kernel link layout (higher half at 0xffffffff80000000) and boot menu |
| `.github/workflows/ci.yml` | CI (see [testing](testing.md#ci)) |

### Boot flow

Limine loads `kernel.elf` and `initrd.tar`, answers the requests in
`src/main.zig`, and jumps to `kmain`. `kmain` brings up, in order: serial, GDT,
IDT, framebuffer console, PMM, page tables, kernel symbols, ACPI, APIC, HPET,
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
2. Add `_ = userProgram(b, "<name>", "app/<name>.zig", target, optimize);` in
   `build.zig`.
3. Copy it into the initrd in `scripts/build.sh` (`cp zig-out/bin/<name>.elf "$initrd/bin/<name>"`).

### Adding a syscall

1. Add the number and an implementation to `src/kernel/syscall.zig` and a case
   in `dispatch`. Validate every user pointer with `userSlice`.
2. Add a wrapper to `app/lib.zig` (the numbers must match).
3. Test it from ring 3 in `tests/user/syscalls.zig` (see [testing](testing.md)).

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

VS Code with the Zig extension and ZLS works out of the box
(`.vscode/settings.json`). `.vscode/tasks.json` has tasks for the host tests,
the QEMU tests and all tests ("Run Test Task"); the test explorer runs single
host tests through `zig build test-host -Dtest-filter=<name>`.

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
