# GDB setup for debugging the MyOS kernel under QEMU.
# Start QEMU with scripts/run-qemu.sh --gdb, then: gdb -x scripts/kernel.gdb
set confirm off
set pagination off
set disassembly-flavor intel
file zig-out/bin/kernel.elf
target remote localhost:1234
# A hardware breakpoint survives the bootloader loading the kernel over it.
hbreak kmain
continue
