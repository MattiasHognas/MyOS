# Debugging MyOS

## Reading kernel output

Everything the kernel prints goes to the serial port. `scripts/run-qemu.sh` connects
it to your terminal; the test runs save it to `zig-out/test/<scenario>/serial.log`.

Kernel messages go through `std.log` and look like `level(scope): message`:

```
info(pci): 00:03.0 1b36:0010 class 01.08.02
debug(acpi): IRQ 0 -> GSI 2 (flags 0x0)
```

Choose how much is printed at build time:

| Option | Effect |
| --- | --- |
| `-Dlog-level=err\|warn\|info\|debug` | Messages above the level are compiled out. Default: `debug` for Debug builds, `info` otherwise. |
| `-Dalloc-debug=true` | Log every kernel heap allocation and free (`debug(heap): ...`). Needs `-Dlog-level=debug`. |
| `-Dstack-usage=true\|false` | Measure how much of each kernel stack gets used and warn (`warn(kstack): thread N used ...`) when a thread went past 12 of its 16 KiB. Default: on in Debug builds, off otherwise. |
| `-Dassertions=false` | Compile out the subsystem assertions (`kernel/debug/assert.zig`). Default: on, in every build mode. |

In code, use a scoped logger: `const log = std.log.scoped(.my_subsystem);`,
then `log.info("...", .{...})`. Use `root.print` only for output that is not a
diagnostic (e.g. the console output of user programs).

## Panics, faults and backtraces

A kernel panic (`@panic`, a failed safety check, or a failed `assert.check`)
and a CPU exception in kernel mode both print a symbolized backtrace:

```
PANIC: scenario: assertion failed: deliberate test panic
backtrace:
  #0 0xffffffff800112ea main.scenarioPanicInner+0x4a
  #1 0xffffffff8001115e main.scenarioPanic+0xe
  #2 0xffffffff80000666 main.run+0x106
  #3 0xffffffff80000480 kmainOnStack+0x2f0
```

```
*** Page fault (vector 14, error 0x2)
RIP=0xffffffff80010fad CS=0x8 RFLAGS=0x10002
RSP=0xffff80000ff78d08 RAX=0xffffb00000000000 RBX=0x0
CR2=0xffffb00000000000 (faulting address)
backtrace:
  #0 0xffffffff80010fad main.scenarioFault+0x1d
  #1 0xffffffff80000699 main.run+0x139
```

A fault in a user program kills only that program (exit code 255) and prints
where it happened, without a backtrace:

```
*** thread 7 (/test/kernel_read): Page fault in user mode (vector 14, error 0x5), killed
RIP=0x400038 RSP=0x7ffffffefed0 RFLAGS=0x10202
CR2=0xffffffff80000000 (faulting address)
```

A double fault means the CPU could not deliver an exception, nearly always
because the kernel stack is unusable. It is reported from its own emergency
stack (as are NMIs), with the stack of the thread that was running:

```
*** Double fault (vector 8, error 0x0)
RIP=0xffffffff8001d0b3 CS=0x8 RFLAGS=0x86
RSP=0xffffb00000001000 RAX=0x286 RBX=0xffffffff8001d0a0
CR2=0xffffb00000000ff8 (last page-fault address)
thread 1 kernel stack 0xffffc00000006000-0xffffc0000000a000; RSP is outside it: corrupt stack pointer
backtrace:
  #0 0xffffffff8001d0b3 helpers.doubleFaultThread+0x13
```

A kernel stack overflow shows up the same way. Every kernel stack has an
unmapped guard page below it (`kernel/kstack.zig`); the fault on that page
cannot be delivered on the full stack, so it becomes a double fault:

```
*** Double fault (vector 8, error 0x0)
RIP=0xffffffff8001fddb CS=0x8 RFLAGS=0x86
RSP=0xffffc00000005fa0 RAX=0x0 RBX=0xffffffff8001fd70
CR2=0xffffc00000005f98 (last page-fault address)
CR2 is in a kernel stack guard page: kernel stack overflow
thread 1 kernel stack 0xffffc00000006000-0xffffc0000000a000; RSP is below it: stack overflow
backtrace:
  #0 0xffffffff8001fddb helpers.recurseForever+0xb
  #1 0xffffffff8001fee5 helpers.recurseForever+0x115
```

The backtrace shows what used the stack up. No frame is large enough to step
over the guard page: the build checks that (see
[stack frame check](testing.md#stack-frame-check)).

To see how close the stacks are to that, build with `-Dstack-usage` (the
default in Debug builds). New stacks are then filled with a pattern, and when
a thread exits the kernel looks for the lowest word that was overwritten. A
thread that used more than three quarters of its stack gets a warning:

```
warn(kstack): thread 7 used 12840 of 16384 bytes of its kernel stack
```

The boot thread, which never exits, logs its usage once at the end of boot
(`debug(boot): boot used ...`).

Panic and assertion messages are cut off after 256 bytes, since they are
formatted on the stack.

How it works: the kernel is built with frame pointers, `kernel/debug/backtrace.zig`
walks the RBP chain (checking each frame against the page tables first), and
the names come from the kernel's own `.symtab`, which Limine passes to the kernel
through the executable-file request. Frame `#0` is the faulting instruction (for
faults) or the code that called the panic (for panics).

In optimized builds, inlined functions do not get their own frame, so a frame
may show the function it was inlined into (e.g. a large offset into `kmain`).
To get file and line numbers for an address, symbolize it on the host:

```bash
addr2line -f -i -e zig-out/bin/kernel.elf 0xffffffff800112ea
# or
llvm-symbolizer --obj=zig-out/bin/kernel.elf 0xffffffff800112ea
```

Use the ELF that was booted: `zig-out/bin/kernel.elf` for `scripts/build.sh`,
`zig-out/bin/kernel-test.elf` for the QEMU tests.

The kernel is loaded at a random address on every boot (KASLR), while the
ELF file holds the addresses it was linked at. A backtrace says how far it
was moved:

```
backtrace:
  (kernel loaded 0x14cb4000 above its link address)
  #0 0xffffffff94d20304 ...
```

Subtract that from an address before giving it to `addr2line`
(`0xffffffff94d20304 - 0x14cb4000 = 0xffffffff8006c304`). The names in the
backtrace are already right.

### What the other CPUs were doing

With several CPUs, the CPU that panics stops the others with an NMI first,
and each records where it was. After its own backtrace the report shows,
for each other CPU, its count of timer interrupts, whether it had
interrupts on, its local APIC's interrupts in service and requested (the
timer's and the IPIs' vectors), and its backtrace (or that it was running a
program). Then the timers (the current tick and the next ones due) and
every process with its threads, their states and signals. A lock held for
ever, a request never answered, or time that stopped is most often another
CPU's doing, and shows here:

```
this CPU (1): 9467 timer interrupts
CPU 0: 404 timer interrupts; interrupts off; APIC in service 0x0, requested 0xf0000 (vectors 32-63), ...
timers: tick 404, 1 pending, lock free
  due at tick 406 (in 2)
```

(CPU 0 there had shut its interrupts out: its own four vectors waited,
and time, which its tick advances, stood still.)

### A test case that hangs

In the test kernel each test case has 90 s (`WATCHDOG_NS` in
`tests/kernel/main.zig`); one that takes longer is reported as a panic
(`test watchdog: the test case has not finished in time`) from whichever
CPU's timer sees it first, with the report above, instead of the run just
timing out. To attach GDB to a boot that hangs anyway, pass QEMU's
debugger option through the test script: `MYOS_QEMU_EXTRA="-s"
scripts/test-qemu.sh tests_kvm`, then `target remote :1234`.

## Debugging with QEMU and GDB

1. Build a Debug kernel and the ISO with the kernel at its link address,
   so the debugger's symbols match: `MYOS_KASLR=no scripts/build.sh`
   (the VS Code task does this). User programs' stacks are still at random
   addresses; their code is not.
2. Start QEMU paused, with a GDB server on `localhost:1234`:

   ```bash
   scripts/run-qemu.sh --gdb          # add --bios for legacy BIOS boot, --no-kvm for TCG
   ```

3. In another terminal, attach GDB. `scripts/kernel.gdb` loads the kernel
   symbols, connects, and stops at `kmain`:

   ```bash
   gdb -x scripts/kernel.gdb
   ```

Useful commands once stopped:

```gdb
hbreak kernel.pmm.alloc        # functions are named after their namespace path
hbreak src/kernel/heap.zig:120 # or file:line
bt                             # backtrace (uses the same frame pointers)
info registers rip rsp cr3
x/8i $rip                      # disassemble at the current instruction
p kernel.pmm.free_pages        # read a global
```

Notes:

- Use `hbreak` (hardware breakpoints) for breakpoints set before the kernel is
  loaded. Software breakpoints (`break`) only work once the code is mapped,
  e.g. after you have stopped in `kmain`.
- QEMU starts in real mode. GDB shows `0x000000000000fff0 in ?? ()` until the
  kernel runs; that is expected.
- With KVM, use hardware breakpoints only. With `--no-kvm` (TCG) both kinds work.
- To debug a test program, add its symbols: `add-symbol-file zig-out/bin/test-files.elf`
  (they are linked at fixed addresses and keep their debug info in Debug
  builds), or `add-symbol-file zig-out/bin/hello.elf`. MyOS's own programs
  (`bin-*`) are built stripped, to keep the image small; build one without
  `.strip = true` in `build.zig` to debug it.

## Debugging in VS Code

The same QEMU GDB server works from the editor, with the CodeLLDB extension
(`vadimcn.vscode-lldb`, in the workspace recommendations):

1. Set breakpoints in the kernel sources.
2. Run and Debug -> "MyOS: Debug kernel (QEMU)" (F5) for the kernel alone, or
   "MyOS: Debug kernel + user programs (QEMU)" to also stop at breakpoints
   in `app/`.

This runs the task "MyOS: QEMU (wait for debugger)" (`scripts/build.sh`, then
`scripts/run-qemu.sh --gdb --no-kvm`) and attaches LLDB to `localhost:1234`
with the symbols of `zig-out/bin/kernel.elf`. The serial output is in the
task's terminal.

- QEMU starts halted at the reset vector (`0xfff0`); the launch configuration
  continues from there automatically (`postRunCommands`). If you ever see a
  "signal SIGTRAP" stop at `0xfff0` with `addb %al, (%rax)` disassembly, that
  is this initial halt, not a fault: press Continue (F5).
- Stopping the debug session also quits QEMU (the task "MyOS: Stop QEMU (debug)").
- Step Over works everywhere except directly in `kmain`: it has no caller, so
  LLDB steps into the call instead. Use Step Out to get back, or set a
  breakpoint on the next line.
- The task uses `--no-kvm` so that editor breakpoints work before the kernel is
  loaded (see the notes above), so the OS runs slower than a normal run.
- "MyOS: Debug kernel + user programs (QEMU)" also loads the symbols of
  `sh.elf` and `hello.elf`, so breakpoints in `app/` work in the same session
  as kernel breakpoints. Each user program is linked at its own address
  (`sh` at `0x400000`, `hello` at `0x800000`, see `build.zig`), which is what
  lets the debugger tell them apart. For a new user program, give it a free
  address in `build.zig` and add a `target modules add` line to
  `.vscode/launch.json`.
- User programs keep their symbols and debug info in Debug builds only
  (`strip` in `build.zig`), so this needs the default `scripts/build.sh` build.
- Stepping over a syscall does not follow it
  into the kernel. Set a kernel breakpoint (e.g. in the syscall handler) to
  cross over.

## Other QEMU tools

- `-d int,cpu_reset -D qemu.log` logs every interrupt and CPU reset, which helps
  with triple faults (the machine reboots, or stops with `-no-reboot`). Pass it
  after `--`: `scripts/run-qemu.sh --no-kvm -- -d int,cpu_reset -D qemu.log`
- `-monitor stdio` instead of `-serial stdio` gives the QEMU monitor:
  `info registers`, `info mem` (page table mappings), `info tlb`, `x /10i $pc`.
