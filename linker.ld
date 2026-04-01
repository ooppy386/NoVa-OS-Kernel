/* linker.ld */
ENTRY(_start)

SECTIONS
{
    /* * Load the kernel at 1 Megabyte. This is the conventional 
     * memory location for GRUB to place Multiboot kernels. 
     */
    . = 1M;

    /* Put the multiboot header first so the bootloader can find it */
    .text BLOCK(4K) : ALIGN(4K)
    {
        *(.multiboot)
        *(.text)
    }

    /* Read-only data (our strings) */
    .rodata BLOCK(4K) : ALIGN(4K)
    {
        *(.rodata)
    }

    /* Read-write data (initialized) */
    .data BLOCK(4K) : ALIGN(4K)
    {
        *(.data)
    }

    /* Read-write data (uninitialized) and stack */
    .bss BLOCK(4K) : ALIGN(4K)
    {
        *(COMMON)
        *(.bss)
    }
}