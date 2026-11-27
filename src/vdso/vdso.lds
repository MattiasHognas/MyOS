/* The vDSO in one segment, as Linux lays its own out
   (arch/x86/entry/vdso/vdso-layout.lds.S): headers, dynamic symbols,
   then code, all readable and executable, nothing writable. */
SECTIONS
{
    . = SIZEOF_HEADERS;
    .hash : { *(.hash) } :text
    .gnu.hash : { *(.gnu.hash) }
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .gnu.version : { *(.gnu.version) }
    .gnu.version_d : { *(.gnu.version_d) }
    .gnu.version_r : { *(.gnu.version_r) }
    .dynamic : { *(.dynamic) } :text :dynamic
    .rodata : { *(.rodata*) } :text
    .data : { *(.data*) *(.got*) *(.bss*) }
    .eh_frame_hdr : { *(.eh_frame_hdr) } :text :eh_frame_hdr
    .eh_frame : { KEEP(*(.eh_frame)) } :text
    .text : { *(.text*) } :text
    /DISCARD/ : { *(.comment*) *(.note*) *(.debug*) }
}
PHDRS
{
    text PT_LOAD FLAGS(5) FILEHDR PHDRS;
    dynamic PT_DYNAMIC FLAGS(4);
    eh_frame_hdr PT_GNU_EH_FRAME;
}
