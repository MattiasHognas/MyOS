# MyOS

My own operating system

## Documentation
- [Specs x86-64 (cheat sheet)](docs/specs-x86_64.md)
- [Testing](docs/testing.md): host tests, in-kernel tests, QEMU scenarios, coverage, CI
- [Debugging](docs/debugging.md): logging, backtraces, QEMU + GDB
- [Roadmap](docs/todo.md)

## Usage

### Commands

- `zig build`: normal kernel and userspace builds.
- `./build.sh`: normal ISO creation, plus a `disk.img` only if absent.
- `zig build test-host`: native host unit tests using an injected fake filesystem.
- `zig build test-kernel`: compile the test kernel (no QEMU boot).
- `zig build test-qemu`: package a separate test ISO and run the QEMU scenarios (`tests`, `panic`, `fault`).
- `zig build test`: run both host and QEMU tests.
- `zig build coverage`: run the host tests under kcov; report in `zig-out/coverage/`.
- `zig build docs`: generate documentation.
- `./run-qemu.sh [--gdb] [--bios] [--no-kvm]`: run `os.iso`; `--gdb` waits for `gdb -x scripts/kernel.gdb`.

Build options (also for the test commands): `-Doptimize=Debug|ReleaseSafe|ReleaseFast`,
`-Dlog-level=err|warn|info|debug`, `-Dassertions=true|false`, `-Dalloc-debug=true|false`.

### Development

Install packages
```bash
sudo pacman -S zls zig qemu-desktop limine xorriso
```

Get a font (copies kbd's default8x16 into `src/assets/font.psf`, or downloads it)
```bash
scripts/fetch-font.sh
```

Build elf/iso
```bash
chmod +x build.sh
./build.sh
```

Run iso
```bash
./run-qemu.sh
```
which runs
```bash
qemu-system-x86_64 -M q35 -m 2G -cdrom os.iso \
  -bios /usr/share/edk2/x64/OVMF.4m.fd \
  -serial stdio -no-reboot -no-shutdown -enable-kvm -cpu host \
  -drive file=disk.img,if=none,id=nvm,format=raw \
  -device nvme,serial=myos0001,drive=nvm
```