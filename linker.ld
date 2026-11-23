ENTRY(kmain)

/* The kernel is a position-independent executable linked at the base of the
   top 2 GiB. With `kaslr: yes` in limine.conf the bootloader loads it at a
   random address in that range and applies the relocations in .rela.dyn;
   without it, it is loaded here. */
PHDRS {
    text    PT_LOAD    FLAGS(5);   /* read, execute */
    rodata  PT_LOAD    FLAGS(4);   /* read */
    data    PT_LOAD    FLAGS(6);   /* read, write */
    dynamic PT_DYNAMIC FLAGS(6);
}

SECTIONS {
    . = 0xffffffff80000000;
    __text_start = .;
    .text   : { *(.text .text.*) } :text
    . = ALIGN(4096);
    __text_end = .;

    __rodata_start = .;
    .rodata : { *(.rodata .rodata.*) } :rodata
    /* What the bootloader needs to relocate the kernel. Read-only once it runs. */
    .dynsym   : { *(.dynsym) } :rodata
    .dynstr   : { *(.dynstr) } :rodata
    .hash     : { *(.hash) } :rodata
    .gnu.hash : { *(.gnu.hash) } :rodata
    .rela.dyn : { *(.rela*) } :rodata
    . = ALIGN(4096);
    __rodata_end = .;

    __data_start = .;
    .data   : { KEEP(*(.limine_requests)) *(.data .data.*) *(.data.rel.ro*) } :data
    .dynamic : { *(.dynamic) } :data :dynamic
    .got    : { *(.got .got.*) } :data
    .bss    : { *(.bss .bss.*) *(COMMON) } :data
    . = ALIGN(4096);
    __data_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.note .note.*) *(.interp) }
}
