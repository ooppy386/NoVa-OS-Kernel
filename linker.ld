/**
 * ============================================================================
 * NoVa Microkernel - Linker Script
 * * DESCRIPTION:
 * Instructs the GCC Linker on how to arrange our compiled code in memory.
 * We tell it to put the Multiboot header at the very beginning (1MB mark)
 * so the bootloader can find it immediately.
 * ============================================================================
 */

ENTRY(_start)

SECTIONS {
    /* Begin putting sections at 1 Megabyte (standard x86 boot convention) */
    . = 1M;

    /* The Multiboot header MUST come first, followed by kernel code */
    .text BLOCK(4K) : ALIGN(4K) {
        *(.multiboot)
        *(.text)
    }

    /* Read-only data (like our string literals: "[KERNEL PANIC]") */
    .rodata BLOCK(4K) : ALIGN(4K) {
        *(.rodata)
    }

    /* Initialized read-write data */
    .data BLOCK(4K) : ALIGN(4K) {
        *(.data)
    }

    /* Uninitialized data and the kernel stack */
    .bss BLOCK(4K) : ALIGN(4K) {
        *(COMMON)
        *(.bss)
    }
}
