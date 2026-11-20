ENTRY(kmain)
SECTIONS {
    . = 0xffffffff80000000;
    __text_start = .;
    .text   : { *(.text .text.*) }
    . = ALIGN(4096);
    __text_end = .;

    __rodata_start = .;
    .rodata : { *(.rodata .rodata.*) }
    . = ALIGN(4096);
    __rodata_end = .;

    __data_start = .;
    .data   : { KEEP(*(.limine_requests)) *(.data .data.*) *(.data.rel.ro*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }
    . = ALIGN(4096);
    __data_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.note .note.*) }
}