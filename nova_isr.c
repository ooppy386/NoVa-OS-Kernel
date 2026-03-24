/**
 * ============================================================================
 * NoVa Microkernel - Interrupt & Syscall Handlers
 * Version: 0.1.0-alpha
 * * DESCRIPTION:
 * Catches CPU exceptions, hardware interrupts (IRQs), and user-space 
 * system calls. It also includes a basic VGA text-mode driver for kernel 
 * debugging output.
 * ============================================================================
 */

#include <stdint.h>

/* --- 1. BASIC VGA DEBUG OUTPUT --- */
/* The microkernel needs a way to print errors before user-space drivers load. */

static uint16_t* vga_buffer = (uint16_t*)0xB8000;
static int vga_cursor_x = 0;
static int vga_cursor_y = 0;

/**
 * @brief Sends an 8-bit value to a hardware I/O port (COM1 Serial).
 */
static inline void serial_outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

/**
 * @brief Prints a simple string to the screen.
 */
void kprint(const char* str) {
    uint8_t color = 0x0F; // White text on black background
    
    for (int i = 0; str[i] != '\0'; i++) {
        // Echo character to COM1 Serial Port (0x3F8) for GitHub Codespaces Terminal
        serial_outb(0x3F8, str[i]);

        if (str[i] == '\n') {
            vga_cursor_x = 0;
            vga_cursor_y++;
        } else {
            // Write character and color to VGA memory
            vga_buffer[vga_cursor_y * 80 + vga_cursor_x] = (uint16_t)str[i] | (uint16_t)color << 8;
            vga_cursor_x++;
        }
        
        // Handle screen wrap
        if (vga_cursor_x >= 80) {
            vga_cursor_x = 0;
            vga_cursor_y++;
        }
        if (vga_cursor_y >= 25) {
            vga_cursor_y = 0; // Simple wrap-around for now (no scrolling yet)
        }
    }
}

/* --- 2. CPU STATE DEFINITION --- */
/* Matches the registers pushed by our assembly stubs. */

typedef struct registers {
    uint32_t ds;                                     // Data segment selector
    uint32_t edi, esi, ebp, esp, ebx, edx, ecx, eax; // Pushed by pusha
    uint32_t int_no, err_code;                       // Interrupt number and error code
    uint32_t eip, cs, eflags, useresp, ss;           // Pushed by the CPU automatically
} registers_t;

/* --- 3. EXCEPTION HANDLER (ISRs 0-31) --- */

/**
 * @brief Handles CPU exceptions like Divide by Zero or Page Faults.
 */
void isr_handler(registers_t* r) {
    if (r->int_no == 14) {
        kprint("[KERNEL PANIC] Page Fault!\n");
        while(1); // Halt
    } else if (r->int_no == 13) {
        kprint("[KERNEL PANIC] General Protection Fault!\n");
        while(1);
    } else {
        kprint("[KERNEL PANIC] Unhandled CPU Exception.\n");
        while(1);
    }
}

/* --- 4. HARDWARE INTERRUPT HANDLER (IRQs 32-47) --- */

extern void hal_pic_send_eoi(uint8_t irq);

/**
 * @brief Handles hardware events like the Timer or Keyboard.
 */
void irq_handler(registers_t* r) {
    // If it's the system timer (IRQ 0 / INT 32)
    if (r->int_no == 32) {
        // Here we would call: sched_tick() from Phase 1
        // to switch to the next thread!
    }

    // Send End-Of-Interrupt to the PIC so it knows we handled it
    hal_pic_send_eoi(r->int_no - 32);
}

/* --- 5. SYSTEM CALL INTERFACE (INT 0x80) --- */

/**
 * @brief Dispatches requests from user-space programs.
 * eax = Syscall Number, ebx = Arg1, ecx = Arg2, edx = Arg3
 */
void syscall_handler(registers_t* r) {
    switch (r->eax) {
        case 1: // SYS_PRINT (Debug only)
            kprint((char*)r->ebx);
            break;
        case 2: // SYS_IPC_SEND
            // Call ipc_send() from Phase 1
            break;
        case 3: // SYS_IPC_RECEIVE
            // Call ipc_receive() from Phase 1
            break;
        case 4: // SYS_THREAD_YIELD
            // Call sched_yield() 
            break;
        default:
            kprint("[SYSCALL] Unknown system call requested.\n");
            break;
    }
}
