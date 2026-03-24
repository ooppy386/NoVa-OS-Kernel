/**
 * ============================================================================
 * NoVa Microkernel - Global Definitions Header
 * Version: 0.1.0-alpha
 * * DESCRIPTION:
 * This header acts as the glue between our modular files. It exposes the 
 * function prototypes from nova_core.c, nova_hal_x86.c, and the assembly 
 * bridges so that the compiler can link them successfully.
 * ============================================================================
 */

#ifndef NOVA_H
#define NOVA_H

#include <stdint.h>

/* --- Core Kernel Functions (nova_core.c) --- */
void pmm_init(void);
void sched_init(void);
void nova_main(uint32_t magic, void* multiboot_info);

/* --- Hardware Abstraction Layer (nova_hal_x86.c) --- */
void hal_init(void);
void hal_gdt_install(void);
void hal_idt_install(void);
void hal_pic_remap(void);
void hal_timer_install(uint32_t frequency);

/* --- Assembly Bridges (boot.S / interrupts.S) --- */
/**
 * @brief Loads the GDT pointer into the CPU's GDTR register.
 * @param gdt_ptr Address of the GDT pointer structure.
 */
extern void gdt_flush(uint32_t gdt_ptr);

/**
 * @brief Loads the IDT pointer into the CPU's IDTR register.
 * @param idt_ptr Address of the IDT pointer structure.
 */
extern void idt_load(uint32_t idt_ptr);

#endif // NOVA_H
