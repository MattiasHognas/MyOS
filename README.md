# MyOS

My own operating system

## Documentation
[Specs x86-64 (cheat sheet)](docs/specs-x86_64.md) 

## Usage

### Commands

- `zig build`: normal kernel and userspace builds.
- `./build.sh`: normal ISO creation, plus a `disk.img` only if absent.
- `zig build test-host`: native host unit tests using an injected fake filesystem.
- `zig build test-kernel`: compile the test kernel (no QEMU boot).
- `zig build test-qemu`: package a separate test ISO and run QEMU.
- `zig build test`: run both host and QEMU tests.


### Development

Install packages
```bash
sudo pacman -S zls zig qemu-desktop limine xorriso
```

Get a font
```bash
gunzip -c /usr/share/kbd/consolefonts/default8x16.psfu.gz > src/font.psf
```

Build elf/iso
```bash
chmod +x build.sh
./build.sh
```

Run iso
```bash
qemu-system-x86_64 -M q35 -m 2G -cdrom os.iso \
  -bios /usr/share/edk2/x64/OVMF.4m.fd \
  -serial stdio -no-reboot -no-shutdown -enable-kvm \
  -drive file=disk.img,if=none,id=nvm,format=raw \
  -device nvme,serial=myos0001,drive=nvm
```