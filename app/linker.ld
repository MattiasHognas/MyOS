/* USER_BASE (the link address) is prepended by build.zig, per program. */
ENTRY(_start)
SECTIONS {
    . = USER_BASE;
    .text   : { *(.text .text.*) }
    . = ALIGN(4096);
    .rodata : { *(.rodata .rodata.*) }
    . = ALIGN(4096);
    .data   : { *(.data .data.*) *(.data.rel.ro*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }
    /DISCARD/ : { *(.eh_frame*) *(.note .note.*) }
}