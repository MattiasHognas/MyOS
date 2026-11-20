# MyOS

My own operating system

## Delopment

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
  -serial stdio -no-reboot -no-shutdown
```