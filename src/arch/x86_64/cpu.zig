// Write a byte to an I/O port.
pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}
// Write a 32-bit value to an I/O port.
pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}

// Read a 32-bit value from an I/O port.
pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

// Read a byte from an I/O port.
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

// Read a 64-bit value from an I/O port.
pub fn rdmsr(msr: u32) u64 {
    return asm volatile (
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        : [msr] "{ecx}" (msr),
        : .{ .rdx = true });
}

// Write a 64-bit value to an MSR.
pub fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [msr] "{ecx}" (msr),
    );
}
// Read the current value of the RFLAGS register.
pub fn saveAndDisableInterrupts() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[f]
        \\ cli
        : [f] "=r" (-> u64),
        :
        : .{ .memory = true });
}

// Restore the RFLAGS register, which may re-enable interrupts.
pub fn restoreInterrupts(flags: u64) void {
    if ((flags & (1 << 9)) != 0) asm volatile ("sti" ::: .{ .memory = true }); // bit 9 = IF
}
