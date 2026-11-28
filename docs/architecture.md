# Architecture

A map of how MyOS works inside: what the parts are, how they fit together,
and where each is explained. It is short on purpose. The detail lives next to
the code, in the comment at the top of each source file (`zig build docs`
renders them), and in a few documents on topics that span many files.

For where files are, see the [project layout](development.md#project-layout).
For what is planned, see the [roadmap](todo.md).

## The kernel in brief

MyOS is a monolithic kernel for x86-64, written in Zig and booted by Limine.
It runs user programs in ring 3, each in its own address space, and they ask
for services with Linux's system-call interface, so a program built for
Linux needs no changes (the goal is an unmodified .NET program; see the
roadmap).

The main objects:

- A **thread** is a kernel stack, saved registers and a scheduling state. It
  is what the scheduler runs.
- A **process** is an address space, a loaded program, a table of open files
  and limits on what it may use. Today it has exactly one thread.
- An **address space** is a set of page tables. The upper half is the
  kernel's and the same in every address space; the lower half is the
  process's own.

Every CPU of the machine is started and runs threads: there is one queue
of ready threads, and a thread runs on whichever CPU picks it up. The rules
that keep this correct are in [concurrency and locking](locking.md).

## How a program runs

1. `process.spawn` makes an address space, has the ELF loader check the
   whole image and then map it, maps a stack at a random address, and makes
   a thread.
2. The scheduler switches to the thread, which drops to ring 3 with every
   register cleared.
3. The program runs until it makes a system call, causes an exception, or a
   timer interrupt ends its time slice. Each of the three enters the kernel
   on that thread's kernel stack.
4. A system call is carried out by the thread that made it; it may block.
   An exception the program caused kills the process. A timer interrupt may
   switch to another thread.
5. When the program exits, its files are closed and its exit status is kept
   for whoever waits for it. Its address space and kernel stack are freed by
   the next thread that runs.

## Boot

Limine loads the kernel and the initrd, answers the requests declared in
`src/main.zig`, and jumps to `kmain`, which brings up, in this order:

1. serial port, GDT and TSS, per-CPU data, IDT, framebuffer console;
2. the page allocator, the kernel's own page tables, and the protections
   that keep the kernel away from user memory (SMEP, SMAP, UMIP);
3. the Meltdown check, x87/SSE/AVX state, the random-number generator;
4. a guarded kernel stack for the boot thread, which then leaves the
   bootloader's stack;
5. kernel symbols, ACPI, the interrupt controllers, the HPET, PCI and NVMe,
   the timer and system calls;
6. the other CPUs, one at a time, each set up like the boot CPU and
   checked against it (`src/arch/x86_64/smp.zig`);
7. the initrd as the root filesystem.

The normal kernel then starts `/sbin/init`, which starts the shell, and its
boot thread blocks for good.
The test kernel runs the test scenario QEMU asked for instead
([testing](testing.md)).

The initrd is a tar archive built by `scripts/build.sh`: MyOS's programs in
`/usr/bin` (`/bin` and `/sbin` are links to it), `/etc/motd`, and `/test/*`
and `/fixtures/*` in the test image. The programs are ordinary Linux
programs: `init`, the shell and the commands are built with Zig's standard
library for `x86_64-linux` (`app/bin/`, sharing `app/util.zig` and
`app/sh_words.zig`), `wc` and `head` are C built against musl (`app/c/`).
Only `/usr/bin/hello` and the test programs use MyOS's own small runtime
(`app/lib.zig`).

## Address-space layout

| Addresses | What | Notes |
| --- | --- | --- |
| `0x0` to 64 KiB | Never mapped | A null pointer faults, also with a small offset |
| 64 KiB upwards | The program | Wherever its ELF file says, below the stack's range |
| Below the stack | `mmap` | Placed top down from 1 MiB below the stack's region; memory comes when it is touched |
| Below `0x7FFF_FFFF_0000` | The user stack | Its top is random within 16 GiB; it may grow to 8 MiB, and its pages come as it is used |
| Last page below `0x8000_0000_0000` | Never mapped | See `vmm.USER_MAP_END` |
| `0xFFFF_8000_0000_0000` | Direct map of all physical memory | 2 MiB pages; never executable; the kernel image's read-only pages are read-only here too |
| `0xFFFF_9000_0000_0000` | Kernel heap | Up to 1 GiB, grows on demand |
| `0xFFFF_A000_0000_0000` | Device registers | Mapped at boot, uncached |
| `0xFFFF_C000_0000_0000` | Kernel stacks | 16 KiB each, with an unmapped guard page below |
| Top 2 GiB | The kernel image | At a random address chosen by the bootloader; code, constants and data each with their own permissions |

Each kernel region has a top-level page-table slot to itself, and all those
slots are filled at boot, which is how every address space shares the kernel
half. Kernel mappings are global: they stay in the TLB when the address
space changes.

## Subsystems

Each entry says what the part does and where it is explained.

**Entering and leaving the kernel.** Interrupts and exceptions come in
through the IDT; system calls through the `syscall` instruction. Both switch
to the kernel's GS base and the thread's kernel stack. Four exceptions that
can strike at any instruction (double fault, NMI, debug, machine check) run
on stacks of their own. Read: `src/arch/x86_64/idt.zig`, `syscall.zig`,
`sysret.zig`, `gdt.zig`, `percpu.zig`.

**System calls.** Linux's numbers, argument registers, error values and
structure layouts. Read: [syscall ABI](syscalls.md), `src/kernel/syscall.zig`.

**User memory.** The kernel never follows a pointer from a program. It
copies through routines that check the range, cannot be made to reach kernel
memory, and turn a fault into an error. Read: `src/kernel/uaccess.zig`,
`src/arch/x86_64/usercopy.zig`, `nospec.zig`.

**Physical memory.** One bit per 4 KiB page; pages that go to a program or
become page tables are zeroed first. Read: `src/kernel/pmm.zig`,
`page_bitmap.zig`.

**Virtual memory.** Four-level page tables. Mapping never replaces a
mapping, and either succeeds or changes nothing. Read:
`src/arch/x86_64/vmm.zig`.

**Kernel heap and kernel stacks.** A first-fit heap for the kernel's own
objects; stacks in their own region with guard pages, so an overflow faults
instead of corrupting memory. Read: `src/kernel/heap.zig`, `kstack.zig`.

**Threads and scheduling.** One round-robin queue for all CPUs, with a
50 ms time slice; kernel code can be preempted. There is no idle thread
that takes turns: with nothing to run, a CPU halts inside the thread that
ran last, and is woken by an interrupt when a thread becomes ready. A kernel thread runs on
whichever address space is loaded. Read: `src/kernel/thread.zig`,
`src/arch/x86_64/context.zig`.

**Waiting and time.** Spinlocks, wait queues, mutexes and timers; the rules
for using them and for several CPUs. Read: [concurrency and
locking](locking.md), `src/kernel/sync/`, `src/kernel/timer.zig`.

**Processes.** Who owns what, what is freed when, the process tree, and
per-process limits. Read: `src/kernel/process.zig`.

**Loading programs.** The whole ELF image is validated before anything is
mapped, by code with no kernel dependencies so that it can be tested and
fuzzed on the host. Read: `src/kernel/elf_image.zig`, `elf.zig`.

**Extended CPU state.** The kernel itself uses no floating-point or vector
registers, so they are saved and restored only when the CPU moves from one
user thread to another. Read: `src/arch/x86_64/fpu.zig`.

**Files.** A small virtual filesystem layer with one filesystem behind it:
the read-only initrd. Read: `src/kernel/vfs.zig`, `src/kernel/fs/tarfs.zig`; for what a descriptor can refer to besides a file (the console, a pipe, a device): `src/kernel/open_file.zig`, `src/kernel/pipe.zig`; for the text files of `/proc`: `src/kernel/procfs.zig`; for the archive format of the initrd: `src/kernel/fs/tar.zig`; for the filesystem in memory at `/tmp`: `src/kernel/fs/ramfs.zig`, `src/kernel/fs/tmpfs.zig`; for the terminal: `src/kernel/tty_core.zig` (line editing), `src/kernel/tty.zig`; for signals: `src/kernel/signal.zig`, `src/kernel/signal_frame.zig`; for `eventfd` and `epoll`: `src/kernel/epoll.zig`.

**Devices.** Serial port, framebuffer console, PS/2 keyboard, HPET, local
and I/O APIC, PCI, and NVMe (reads, polled). Read: `src/drivers/`,
`src/arch/x86_64/apic.zig`, `src/firmware/acpi.zig`.

**Hardening.** What limits a bug or an attacker: the kernel is never
writable and executable at once under any address, kernel and user stacks
and the kernel image are at random addresses, freed memory is poisoned in
debug builds, and CPUs on which programs could read kernel memory are
refused. Read: roadmap sections 2.9 and 2.10, `src/kernel/random.zig`,
`src/arch/x86_64/meltdown.zig`.

**Diagnostics.** Log levels, assertions per subsystem, symbolized
backtraces, and fault reports. Read: [debugging](debugging.md),
`src/kernel/debug/`.

## The filesystem layout

Linux's, as the Filesystem Hierarchy Standard has it, in the "merged
`/usr`" form of Debian, Fedora and Arch: programs built for Linux have
paths written into them (`/bin/sh`, the loader in `/lib64`, `/etc/...`),
so MyOS uses those names rather than names of its own.

| Path | Holds |
| --- | --- |
| `/usr/bin` | Programs: MyOS's own (`sh`, `hello`) and installed ones |
| `/usr/lib`, `/usr/lib/x86_64-linux-gnu` | Libraries; glibc's in the second, where Debian puts them, with its loader |
| `/usr/lib64` | The loader's name programs ask for (`ld-linux-x86-64.so.2`), a link into `/usr/lib/x86_64-linux-gnu` |
| `/bin`, `/sbin`, `/lib`, `/lib64` | Links into `/usr` |
| `/etc` | Settings |
| `/home`, `/root` | Users' files |
| `/opt/<app>` | Self-contained applications, such as a `dotnet publish` folder |
| `/var`, `/run` | State the system keeps; what is only there while it runs |
| `/tmp` | Temporary files, in memory (`fs/tmpfs.zig`) |
| `/mnt`, `/media` | Other disks, once there are any |
| `/proc`, `/dev` | Made by the kernel (`procfs.zig`, `syscall.zig`) |
| `/boot` | The kernel and the boot loader, on the ISO |
| `/test`, `/fixtures` | Test images only: MyOS's test programs, and programs built for Linux by `tests/fixtures/build.sh` |

glibc is in development and test images (`scripts/fetch-sysroot.sh`), not
in release images, so that it comes from Debian to whoever installs it.
A release has the tool for that beside the image
(`myos-<version>-add-glibc.tar.gz`, from `tools/add-glibc/`): run on the
user's machine, it fetches the pinned packages and writes a new image with
them. Installing it on a running MyOS waits for a disk and a network.

## What is tested, and how

Four layers: tests of hardware-independent code on the host, tests inside
the running kernel, whole-system scenarios under QEMU (including ones meant
to crash), and model checks of the blocking protocols. Read:
[testing](testing.md).

## Topic documents

- [Concurrency and locking](locking.md): locks, their order, sleeping and
  waking, per-CPU state, TLB rules.
- [Syscall ABI](syscalls.md): what a program sees.
- [Research notes](research.md): what we have read and what we do with it.
- [x86-64 cheat sheet](specs-x86_64.md): the hardware facts the code relies on.
