# MyOS

My own operating system: a small kernel in Zig with preemptive
threads, ring 3 user programs, syscalls, an initrd filesystem and a shell,
booted by Limine. Currently on x86-64, will add arm later.

## Quick start

```bash
zig build test          # host tests + QEMU integration tests
scripts/fetch-font.sh   # once: console font
scripts/build.sh        # build kernel, apps and os.iso
scripts/run-qemu.sh     # boot it in QEMU
```

Prerequisites (Zig 0.17.1, Limine, xorriso, QEMU), build options and the
project layout are in [docs/development.md](docs/development.md).

## Documentation

- [Architecture](docs/architecture.md): how the kernel works inside, and where each part is explained
- [Development](docs/development.md): setup, building, running, project layout, conventions
- [Testing](docs/testing.md): host tests, in-kernel tests, QEMU scenarios, coverage, CI
- [Syscall ABI](docs/syscalls.md): Linux's x86-64 ABI as MyOS implements it
- [Debugging](docs/debugging.md): logging, backtraces, QEMU + GDB
- [Concurrency and locking](docs/locking.md): the model the SMP work follows (proposed)
- [Roadmap](docs/todo.md)
- [Research notes](docs/research.md): code-review findings, papers and techniques, and what we do with each
- [Specs x86-64 (cheat sheet)](docs/specs-x86_64.md)
