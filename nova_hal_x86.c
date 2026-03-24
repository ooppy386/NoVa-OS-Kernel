/**
 * ============================================================================
 * NoVa Microkernel - Hardware Abstraction Layer (HAL)
 * Version: 0.1.0-alpha
 * Architecture: x86 (32-bit Protected Mode)
 * * DESCRIPTION:
 * This module isolates all architecture-specific hardware interactions.
 * It configures CPU segmentation (GDT), interrupt handling (IDT, PIC), 
 * and low-level port I/O required to drive the core microkernel subsystems.
 * ============================================================================
 */

#include <stdint.h>

/* --- 1. LOW-LEVEL PORT I/O --- */

/**
 * @brief Sends an 8-bit value to a hardware I/O port.
 */
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

/**
 * @brief Receives an 8-bit value from a hardware I/O port.
 */
static inline uint8_t inb(uint16_t port) {
    uint8_t ret;
    __asm__ volatile ("inb %1, %0" : "=a"(ret) : "Nd"(port));
    return ret;
}

/**
 * @brief Pauses the CPU briefly to wait for sluggish hardware.
 */
static inline void io_wait(void) {
    outb(0x80, 0);
}

/* --- 2. GLOBAL DESCRIPTOR TABLE (GDT) --- */
/* Defines memory segments for Kernel Code/Data and User Code/Data. */

typedef struct gdt_entry {
    uint16_t limit_low;
    uint16_t base_low;
    uint8_t  base_middle;
    uint8_t  access;
    uint8_t  granularity;
    uint8_t  base_high;
} __attribute__((packed)) gdt_entry_t;

typedef struct gdt_ptr {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) gdt_ptr_t;

static gdt_entry_t gdt[5];
static gdt_ptr_t   gdt_p;

/**
 * @brief Internal function to set up a GDT entry.
 */
static void gdt_set_gate(int32_t num, uint32_t base, uint32_t limit, uint8_t access, uint8_t gran) {
    gdt[num].base_low    = (base & 0xFFFF);
    gdt[num].base_middle = (base >> 16) & 0xFF;
    gdt[num].base_high   = (base >> 24) & 0xFF;

    gdt[num].limit_low   = (limit & 0xFFFF);
    gdt[num].granularity = ((limit >> 16) & 0x0F);
    gdt[num].granularity |= (gran & 0xF0);
    gdt[num].access      = access;
}

/**
 * @brief Initializes the standard x86 Flat Memory Model GDT.
 */
void hal_gdt_install(void) {
    gdt_p.limit = (sizeof(gdt_entry_t) * 5) - 1;
    gdt_p.base  = (uint32_t)&gdt;

    gdt_set_gate(0, 0, 0, 0, 0);                // Null segment
    gdt_set_gate(1, 0, 0xFFFFFFFF, 0x9A, 0xCF); // Kernel Code segment
    gdt_set_gate(2, 0, 0xFFFFFFFF, 0x92, 0xCF); // Kernel Data segment
    gdt_set_gate(3, 0, 0xFFFFFFFF, 0xFA, 0xCF); // User Code segment
    gdt_set_gate(4, 0, 0xFFFFFFFF, 0xF2, 0xCF); // User Data segment

    // Load GDT pointer (Requires external assembly routine 'gdt_flush')
    // extern void gdt_flush(uint32_t);
    // gdt_flush((uint32_t)&gdt_p);
}

/* --- 3. INTERRUPT DESCRIPTOR TABLE (IDT) --- */
/* Maps hardware interrupts and CPU exceptions to our C handlers. */

typedef struct idt_entry {
    uint16_t base_lo;
    uint16_t sel;
    uint8_t  always0;
    uint8_t  flags;
    uint16_t base_hi;
} __attribute__((packed)) idt_entry_t;

typedef struct idt_ptr {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) idt_ptr_t;

static idt_entry_t idt[256];
static idt_ptr_t   idt_p;

/**
 * @brief Wires an interrupt number to a handler address.
 */
void hal_idt_set_gate(uint8_t num, uint32_t base, uint16_t sel, uint8_t flags) {
    idt[num].base_lo = base & 0xFFFF;
    idt[num].base_hi = (base >> 16) & 0xFFFF;
    idt[num].sel     = sel;
    idt[num].always0 = 0;
    idt[num].flags   = flags | 0x60; // Ensure Ring 3 can call software interrupts
}

/**
 * @brief Initializes the IDT and prepares the CPU to receive interrupts.
 */
void hal_idt_install(void) {
    idt_p.limit = sizeof(idt_entry_t) * 256 - 1;
    idt_p.base  = (uint32_t)&idt;

    // Clear out the entire IDT initially
    for(int i = 0; i < 256; i++) {
        hal_idt_set_gate(i, 0, 0, 0);
    }

    // Load IDT pointer (Requires external assembly routine 'idt_load')
    // extern void idt_load(uint32_t);
    // idt_load((uint32_t)&idt_p);
}

/* --- 4. PROGRAMMABLE INTERRUPT CONTROLLER (PIC) --- */
/* Remaps hardware IRQs (0-15) to IDT vectors 32-47 to avoid CPU exception conflicts. */

#define PIC1_CMD  0x20
#define PIC1_DATA 0x21
#define PIC2_CMD  0xA0
#define PIC2_DATA 0xA1

void hal_pic_remap(void) {
    uint8_t a1, a2;

    a1 = inb(PIC1_DATA); // Save masks
    a2 = inb(PIC2_DATA);

    // Start initialization sequence in cascade mode
    outb(PIC1_CMD, 0x11); io_wait();
    outb(PIC2_CMD, 0x11); io_wait();

    // Set vector offsets (IRQ0 -> INT 32, IRQ8 -> INT 40)
    outb(PIC1_DATA, 0x20); io_wait();
    outb(PIC2_DATA, 0x28); io_wait();

    // Tell Master PIC that there is a slave PIC at IRQ2
    outb(PIC1_DATA, 4); io_wait();
    // Tell Slave PIC its cascade identity
    outb(PIC2_DATA, 2); io_wait();

    // 8086/88 (MCS-80/85) mode
    outb(PIC1_DATA, 0x01); io_wait();
    outb(PIC2_DATA, 0x01); io_wait();

    // Restore saved masks
    outb(PIC1_DATA, a1);
    outb(PIC2_DATA, a2);
}

/**
 * @brief Sends End-Of-Interrupt (EOI) to the PICs.
 */
void hal_pic_send_eoi(uint8_t irq) {
    if(irq >= 8) {
        outb(PIC2_CMD, 0x20);
    }
    outb(PIC1_CMD, 0x20);
}

/* --- 5. SYSTEM TIMER (PIT) --- */
/* Drives the scheduler we built in Phase 1. */

#define PIT_CMD  0x43
#define PIT_DATA0 0x40

/**
 * @brief Configures the hardware timer to fire interrupts at a specific frequency.
 */
void hal_timer_install(uint32_t frequency) {
    uint32_t divisor = 1193180 / frequency; // Hardware clock is ~1.19MHz
    
    // Command byte: Channel 0, LSB/MSB access, Mode 3 (Square Wave), 16-bit binary
    outb(PIT_CMD, 0x36);
    
    // Send divisor
    outb(PIT_DATA0, (uint8_t)(divisor & 0xFF));
    outb(PIT_DATA0, (uint8_t)((divisor >> 8) & 0xFF));
}

/* --- 6. HAL INITIALIZATION ENTRY --- */

/**
 * @brief Prepares all hardware components for microkernel execution.
 */
void hal_init(void) {
    hal_gdt_install();
    hal_idt_install();
    hal_pic_remap();
    hal_timer_install(1000); // Set system tick to 1000Hz (1ms)
    
    // Enable CPU Interrupts
    __asm__ volatile("sti");
}
