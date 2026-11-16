/* Program in the lower 128K of LMB BRAM; heap in cached DDR (see platform.h). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { LMB (rwx) : ORIGIN = 0x00000000, LENGTH = 128K }

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.* .gnu.linkonce.t.*)
        KEEP(*(.init)) KEEP(*(.fini))
    } > LMB
    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
        KEEP(*(.preinit_array)) KEEP(*(.init_array*)) KEEP(*(.fini_array*))
        *(.eh_frame*)
    } > LMB
    .data : {
        *(.data .data.*)
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > LMB
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > LMB
    __stack_top = ORIGIN(LMB) + LENGTH(LMB);
    ASSERT(__bss_end + 16K <= __stack_top, "program too large: less than 16K left for the stack")
}
