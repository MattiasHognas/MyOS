//! Thin wrappers around x86-64 instructions: port I/O, model-specific
//! registers (MSRs) and the interrupt flag.

/// Write the byte `val` to I/O port `port`.
pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

/// Write the 16-bit value `val` to I/O port `port`.
pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "N{dx}" (port),
    );
}

/// Write the 32-bit value `val` to I/O port `port`.
pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}

/// Read a 32-bit value from I/O port `port`.
pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

/// Read a byte from I/O port `port`.
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Read the 64-bit model-specific register `msr`.
pub fn rdmsr(msr: u32) u64 {
    return asm volatile (
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        : [msr] "{ecx}" (msr),
        : .{ .rdx = true });
}

/// Write the 64-bit value `val` to model-specific register `msr`.
pub fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [msr] "{ecx}" (msr),
    );
}

/// Disable interrupts and return the previous RFLAGS value.
///
/// Pass the result to `restoreInterrupts` to undo it. Calls nest correctly:
/// interrupts are only re-enabled by the outermost restore.
pub fn saveAndDisableInterrupts() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[f]
        \\ cli
        : [f] "=r" (-> u64),
        :
        : .{ .memory = true });
}

/// Re-enable interrupts if they were enabled in `flags`, as returned by
/// `saveAndDisableInterrupts`. Does nothing if they were already disabled.
pub fn restoreInterrupts(flags: u64) void {
    if ((flags & (1 << 9)) != 0) asm volatile ("sti" ::: .{ .memory = true }); // bit 9 = IF
}

/// Registers returned by `cpuid`.
pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// Run `cpuid` for `leaf` and `subleaf`.
pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (eax),
          [b] "={ebx}" (ebx),
          [c] "={ecx}" (ecx),
          [d] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Read control register CR0.
pub fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Write control register CR0.
pub fn writeCr0(val: u64) void {
    asm volatile ("mov %[val], %%cr0"
        :
        : [val] "r" (val),
        : .{ .memory = true });
}

/// Read control register CR3: the physical address of the loaded page-table
/// root, plus flag bits in the low 12.
pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Read control register CR4.
pub fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Write control register CR4.
pub fn writeCr4(val: u64) void {
    asm volatile ("mov %[val], %%cr4"
        :
        : [val] "r" (val),
        : .{ .memory = true });
}

/// Return the current RFLAGS value.
pub fn readFlags() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[f]
        : [f] "=r" (-> u64),
        :
        : .{ .memory = true });
}
