//! Exit QEMU from inside the guest, for automated tests.

/// Exit QEMU via the test-only isa-debug-exit device at I/O port 0xf4.
/// The QEMU host exit status is `(code << 1) | 1`: pass (0) = 1, fail (1) = 3.
pub fn exit(code: u32) noreturn {
    asm volatile ("outl %[value], $0xf4"
        :
        : [value] "{eax}" (code),
    );
    while (true) asm volatile ("cli; hlt");
}
