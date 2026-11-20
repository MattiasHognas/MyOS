// Long mode ignores base and limit; only access byte + flags matter.
//   0x9A = present | ring 0 | code | executable | readable
//   0x92 = present | ring 0 | data | writable
//   0xFA / 0xF2 = same, but ring 3 (DPL 3)
//   flags 0xA = 4K granularity | 64-bit code (L), 0xC = 4K | 32-bit (data)
var gdt = [_]u64{
    0x0000000000000000, // 0x00 null
    0x00AF9A000000FFFF, // 0x08 kernel code
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data   (before user code, for sysret)
    0x00AFFA000000FFFF, // 0x20 user code
    // 0x28: TSS goes here later (step 14)
};

pub const KERNEL_CODE = 0x08;
pub const KERNEL_DATA = 0x10;

const GdtPtr = extern struct {
    limit: u16,
    base: u64 align(1), // lgdt wants exactly 10 bytes, no padding
};

pub fn init() void {
    const ptr = GdtPtr{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });

    // CS can't be set with mov; push the selector + return address and
    // do a far return. Then load the data segment registers.
    asm volatile (
        \\ pushq $0x08
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw $0x10, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%ss
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        ::: .{ .rax = true, .memory = true });
}

pub fn readCs() u16 {
    return asm volatile ("movw %%cs, %[ret]"
        : [ret] "=r" (-> u16),
    );
}
