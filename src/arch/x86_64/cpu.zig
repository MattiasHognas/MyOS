pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn rdmsr(msr: u32) u64 {
    return asm volatile (
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        : [msr] "{ecx}" (msr),
        : .{ .rdx = true });
}

pub fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [msr] "{ecx}" (msr),
    );
}
