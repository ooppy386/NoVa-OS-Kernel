/**
 * ============================================================================
 * NoVa Microkernel - Interrupt Assembly Stubs
 * Version: 0.1.0-alpha
 * * DESCRIPTION:
 * Catches interrupts, saves the CPU registers, calls the C handlers, 
 * and safely returns to whatever was running before.
 * ============================================================================
 */

.section .text

/* --- 1. COMMON ISR SAVE/RESTORE MACROS --- */

/* This macro saves CPU state and calls the C function `isr_handler` */
.extern isr_handler
isr_common_stub:
    pusha               /* Pushes edi,esi,ebp,esp,ebx,edx,ecx,eax */
    
    mov %ds, %ax        /* Lower 16-bits of eax = ds */
    push %eax           /* Save the data segment descriptor */
    
    mov $0x10, %ax      /* Load the kernel data segment descriptor */
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    
    push %esp           /* Push a pointer to the saved registers as a C argument */
    call isr_handler    /* Call our C code! */
    add $4, %esp        /* Clean up the pushed pointer */
    
    pop %eax            /* Reload the original data segment descriptor */
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    
    popa                /* Pops edi,esi,ebp... etc */
    add $8, %esp        /* Cleans up the pushed error code and ISR number */
    iret                /* Returns from the interrupt! */

/* --- 2. EXCEPTION STUBS (0-31) --- */
/* Example: Page Fault (Interrupt 14) */
.global isr14
.type isr14, @function
isr14:
    cli                 /* Disable interrupts */
    /* CPU automatically pushes an error code for Page Faults */
    push $14            /* Push the interrupt number */
    jmp isr_common_stub

/* (In a full kernel, we would define isr0 through isr31 here) */

/* --- 3. HARDWARE IRQ STUBS (32-47) --- */
.extern irq_handler
irq_common_stub:
    pusha
    mov %ds, %ax
    push %eax
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    push %esp
    call irq_handler
    add $4, %esp
    pop %eax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    popa
    add $8, %esp
    iret

/* System Timer (IRQ0 -> INT 32) */
.global irq0
.type irq0, @function
irq0:
    cli
    push $0             /* Push dummy error code */
    push $32            /* Push interrupt number */
    jmp irq_common_stub

/* --- 4. SYSTEM CALL STUB (INT 0x80 = 128) --- */
.extern syscall_handler
.global isr128
.type isr128, @function
isr128:
    cli
    push $0             /* Dummy error code */
    push $128           /* Interrupt number */
    
    /* Save state just like common stubs */
    pusha
    mov %ds, %ax
    push %eax
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    push %esp
    call syscall_handler /* Call the syscall handler! */
    add $4, %esp
    pop %eax
    mov %ax, %ds
    mov %ax, %es
    popa
    add $8, %esp
    iret
