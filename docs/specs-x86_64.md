# Specs x86-64

## I/O ports

Accessed with `in`/`out` instructions (`inb`/`outb`, `inw`/`outw`, `inl`/`outl`). These are fixed legacy addresses on every PC and in QEMU.

| Port | Device | Notes |
| --- | --- | --- |
| 0x3F8 | COM1 serial | Base. COM2 0x2F8, COM3 0x3E8, COM4 0x2E8 |
| base+0 | UART data / divisor low | Divisor low when DLAB (LCR bit 7) is set |
| base+1 | UART interrupt enable / divisor high |  |
| base+2 | UART FIFO control (write) / IIR (read) | 0xC7 = enable + clear FIFOs |
| base+3 | UART line control (LCR) | 0x03 = 8N1, 0x80 = DLAB |
| base+4 | UART modem control | 0x03 = DTR + RTS |
| base+5 | UART line status (LSR) | Bit 5 = transmit empty, bit 0 = data ready |
| 0x20 / 0x21 | Master PIC command / data | EOI = write 0x20 to 0x20 |
| 0xA0 / 0xA1 | Slave PIC command / data | Mask all (0xFF to both data ports) when using APIC |
| 0x40–0x42 | PIT channels 0–2 | Base frequency 1,193,182 Hz |
| 0x43 | PIT mode/command |  |
| 0x60 | PS/2 data | Keyboard scancodes |
| 0x64 | PS/2 status (read) / command (write) | Write 0xFE = CPU reset |
| 0x70 / 0x71 | CMOS/RTC index / data | Index bit 7 = disable NMI |
| 0x80 | POST code port | Write anything for a \~1 µs `io_wait` |
| 0xCF8 / 0xCFC | PCI config address / data | Legacy PCI config access |
| 0xCF9 | Reset control | Write 0x06 = hard reset |
| 0xE9 | QEMU debugcon | Needs `-debugcon stdio`; no UART setup |
| 0x604 | QEMU (q35) ACPI PM1a control | `outw(0x604, 0x2000)` = power off |
| 0xF4 | QEMU isa-debug-exit | Only with `-device isa-debug-exit,iobase=0xf4,iosize=0x04` |

## Memory-mapped addresses

These are physical addresses. Map them before use, for example at HHDM offset + physical address. The typical values below are defaults; read the real ones from the MSR or ACPI table listed.

| Physical address | Device | Where the real value comes from |
| --- | --- | --- |
| 0xFEE00000 | Local APIC | `IA32_APIC_BASE` MSR (0x1B), bits 12+ |
| 0xFEC00000 | I/O APIC | ACPI MADT |
| 0xFED00000 | HPET | ACPI HPET table |
| 0xB0000000 | PCIe ECAM (QEMU q35) | ACPI MCFG |
| 0xB8000 | VGA text buffer | Legacy BIOS boot only, absent under UEFI |

**Local APIC register offsets** (32-bit, 16-byte aligned)

| Offset | Register |
| --- | --- |
| 0x020 | ID |
| 0x030 | Version |
| 0x080 | Task priority (TPR) |
| 0x0B0 | EOI (write 0) |
| 0x0F0 | Spurious vector + enable (bit 8) |
| 0x300 / 0x310 | Interrupt command (ICR) low / high |
| 0x320 | LVT timer |
| 0x380 | Timer initial count |
| 0x390 | Timer current count |
| 0x3E0 | Timer divide configuration |

**I/O APIC:** write a register index to base+0x00 (IOREGSEL), then read or write it at base+0x10 (IOWIN). Register 0x00 = ID, 0x01 = version (bits 16–23 = max redirection entry), 0x10 + 2n = redirection entry n (two 32-bit halves).

**Virtual layout (Limine)**

| Virtual address | What |
| --- | --- |
| 0xFFFFFFFF80000000 | Kernel base (linker script, `-mcmodel=kernel`) |
| HHDM offset | All physical memory mapped linearly. Read the offset from the HHDM response, commonly 0xFFFF800000000000 with 4-level paging |
| 0x00007FFFFFFFFFFF | Top of the lower canonical half (userspace) |
| 0xFFFF800000000000 | Start of the upper canonical half (kernel) |

## MSRs

Read with `rdmsr`, write with `wrmsr` (index in ECX, value in EDX:EAX).

| MSR | Name | Key bits / use |
| --- | --- | --- |
| 0x1B | IA32\_APIC\_BASE | Bit 11 = APIC enable, bits 12+ = LAPIC physical base |
| 0x277 | IA32\_PAT | Page attribute table (memory types) |
| 0x6E0 | IA32\_TSC\_DEADLINE | APIC timer in TSC-deadline mode |
| 0xC0000080 | IA32\_EFER | Bit 0 SCE (syscall), bit 8 LME, bit 10 LMA, bit 11 NXE |
| 0xC0000081 | STAR | Bits 32–47 kernel CS, bits 48–63 user segment base for `sysret` |
| 0xC0000082 | LSTAR | 64-bit `syscall` entry point |
| 0xC0000083 | CSTAR | Compat-mode `syscall` entry (unused in 64-bit only) |
| 0xC0000084 | SFMASK | RFLAGS bits cleared on `syscall` (set IF to disable interrupts) |
| 0xC0000100 | FS\_BASE | FS segment base (thread-local storage) |
| 0xC0000101 | GS\_BASE | Current GS base |
| 0xC0000102 | KERNEL\_GS\_BASE | Swapped with GS\_BASE by `swapgs` |
| 0xC0000103 | TSC\_AUX | Returned by `rdtscp` (e.g. CPU number) |

## Exception vectors

Vectors 0–31 are reserved for CPU exceptions; 32–255 are yours (remap the PIC to 32–47, spurious APIC vector is often 0xFF). Exceptions marked with an error code push it onto the stack, so your stub must not push a dummy one for those.

| Vector | Mnemonic | Name | Error code |
| --- | --- | --- | --- |
| 0 | #DE | Divide error | No |
| 1 | #DB | Debug | No |
| 2 | NMI | Non-maskable interrupt | No |
| 3 | #BP | Breakpoint (`int3`) | No |
| 4 | #OF | Overflow | No |
| 5 | #BR | Bound range exceeded | No |
| 6 | #UD | Invalid opcode | No |
| 7 | #NM | Device not available (FPU) | No |
| 8 | #DF | Double fault | Yes (always 0) |
| 9 | — | Coprocessor segment overrun (legacy) | No |
| 10 | #TS | Invalid TSS | Yes |
| 11 | #NP | Segment not present | Yes |
| 12 | #SS | Stack-segment fault | Yes |
| 13 | #GP | General protection | Yes |
| 14 | #PF | Page fault (address in CR2) | Yes |
| 16 | #MF | x87 floating-point | No |
| 17 | #AC | Alignment check | Yes |
| 18 | #MC | Machine check | No |
| 19 | #XM | SIMD floating-point | No |
| 20 | #VE | Virtualization | No |
| 21 | #CP | Control protection | Yes |
| 28 | #HV | Hypervisor injection | No |
| 29 | #VC | VMM communication | Yes |
| 30 | #SX | Security | Yes |

15, 22–27 and 31 are reserved.

**Page-fault error code bits**

| Bit | Set means |
| --- | --- |
| 0 (P) | Page was present (protection violation); clear = not present |
| 1 (W) | Write access; clear = read |
| 2 (U) | Fault happened in user mode |
| 3 (RSVD) | Reserved bit set in a page-table entry |
| 4 (I) | Instruction fetch (NX violation) |
| 5 (PK) | Protection-key violation |
| 6 (SS) | Shadow-stack access |

## Control registers

| Register | Bit | Name | Meaning |
| --- | --- | --- | --- |
| CR0 | 0 | PE | Protected mode |
| CR0 | 1 | MP | Monitor coprocessor |
| CR0 | 2 | EM | x87 emulation (clear to use FPU/SSE) |
| CR0 | 3 | TS | Task switched (lazy FPU save traps #NM) |
| CR0 | 16 | WP | Kernel honours read-only pages |
| CR0 | 31 | PG | Paging enabled |
| CR2 | — | — | Faulting address on #PF |
| CR3 | 12+ | — | Physical address of the top-level page table (PML4) |
| CR4 | 5 | PAE | Physical address extension (required in long mode) |
| CR4 | 7 | PGE | Global pages |
| CR4 | 9 | OSFXSR | Enable SSE / `fxsave` |
| CR4 | 10 | OSXMMEXCPT | SIMD exceptions go to #XM |
| CR4 | 12 | LA57 | 5-level paging |
| CR4 | 18 | OSXSAVE | Enable `xsave` / AVX |
| CR4 | 20 | SMEP | Kernel may not execute user pages |
| CR4 | 21 | SMAP | Kernel may not access user pages (outside `stac`/`clac`) |

Writing CR3 flushes all non-global TLB entries; `invlpg` flushes one page.

## Paging (4-level, 4 KiB pages)

A 48-bit virtual address splits into four 9-bit table indexes and a 12-bit offset; bits 48–63 must copy bit 47 (canonical form).

| Bits | Index into | Page size if this level is the last |
| --- | --- | --- |
| 39–47 | PML4 | — |
| 30–38 | PDPT | 1 GiB (PS bit set) |
| 21–29 | Page directory | 2 MiB (PS bit set) |
| 12–20 | Page table | 4 KiB |
| 0–11 | Offset in page | — |

**Entry flag bits** (same layout at every level)

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | P | Present |
| 1 | RW | Writable |
| 2 | US | User accessible |
| 3 | PWT | Write-through |
| 4 | PCD | Cache disable (use for MMIO) |
| 5 | A | Accessed (set by CPU) |
| 6 | D | Dirty (set by CPU, last level only) |
| 7 | PS / PAT | Huge page in PDPT/PD; PAT bit in a PTE |
| 8 | G | Global (survives CR3 reload) |
| 9–11 | — | Free for OS use |
| 12–51 | Address | Physical address of the next table or page |
| 52–62 | — | Free for OS use (59–62 = protection key if enabled) |
| 63 | NX | No execute (needs EFER.NXE) |

Index helper: `(vaddr >> (12 + 9 * level)) & 0x1FF`, with level 3 = PML4 down to 0 = page table. Address mask: `0x000FFFFFFFFFF000`.

## GDT layout

This order makes `syscall`/`sysret` work with STAR = (0x0013 << 48) | (0x0008 << 32). User selectors get RPL 3 (`| 3`) when loaded.

| Selector | Entry | Descriptor value |
| --- | --- | --- |
| 0x00 | Null | 0x0000000000000000 |
| 0x08 | Kernel code (64-bit) | 0x00AF9A000000FFFF |
| 0x10 | Kernel data | 0x00CF92000000FFFF |
| 0x18 (0x1B) | User data | 0x00CFF2000000FFFF |
| 0x20 (0x23) | User code (64-bit) | 0x00AFFA000000FFFF |
| 0x28 | TSS (16 bytes, two slots) | Built at runtime from the TSS address; load with `ltr 0x28` |

`sysret` takes user data from STAR\[63:48\] + 8 and user code from + 16, which is why user data comes before user code. Limine's own GDT on entry uses 0x28 for 64-bit code and 0x30 for data; replace it before relying on these selectors.

## Limine protocol

Every request ID is the common magic followed by two request-specific values. These were written from memory, so check them against `limine.h` in the Limine protocol repo before relying on them.

| Item | Values |
| --- | --- |
| Common magic (id\[0..1\]) | 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b |
| Base revision tag | 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, revision |
| Framebuffer request (id\[2..3\]) | 0x9d5827dcd881dd75, 0xa3148604f6fab11b |
| Memory map request | 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 |
| HHDM request | 0x48dcf1cb8ad2b852, 0x63984e959a98244b |
| RSDP request | 0xc5e77b6b397e7b43, 0x27637845accdcf3c |
| Kernel address request | 0x71ba76863cc55f63, 0xb2644a48c516a487 |

**Memory map entry types**

| Type | Meaning | Usable by your allocator |
| --- | --- | --- |
| 0 | Usable | Yes |
| 1 | Reserved | No |
| 2 | ACPI reclaimable | After parsing ACPI tables |
| 3 | ACPI NVS | No |
| 4 | Bad memory | No |
| 5 | Bootloader reclaimable | After you stop using Limine's responses and page tables |
| 6 | Kernel and modules | No |
| 7 | Framebuffer | No |
