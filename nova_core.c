/**
 * ============================================================================
 * NoVa Microkernel - Core Subsystems
 * Version: 0.1.0-alpha
 * Architecture: Abstract/Portable Core
 * * DESCRIPTION:
 * This file encapsulates the pure microkernel primitives:
 * 1. Physical Memory Management (Bitmap Allocator)
 * 2. Virtual Memory Management (Page Table Abstractions)
 * 3. Thread Management & Round-Robin Scheduling
 * 4. Synchronous Inter-Process Communication (IPC)
 * * DESIGN PHILOSOPHY:
 * Keep the supervisor mode code to an absolute minimum. All drivers, 
 * file systems, and network stacks MUST run in user-space and communicate
 * via the IPC mechanisms defined herein.
 * ============================================================================
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* --- 1. TYPE DEFINITIONS & MACROS --- */

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t  i32;

#define NULL ((void*)0)
#define PAGE_SIZE 4096
#define MAX_THREADS 256
#define KERNEL_HEAP_START 0xC0000000
#define SUCCESS 0
#define ERR_OUT_OF_MEMORY -1
#define ERR_INVALID_THREAD -2
#define ERR_IPC_BLOCKED -3

/* --- 2. PHYSICAL MEMORY MANAGER (PMM) --- */
/* Uses a bitmap to track 4KB physical frames. */

#define MAX_PHYSICAL_MEMORY (1024 * 1024 * 1024) // 1GB for prototype
#define TOTAL_FRAMES (MAX_PHYSICAL_MEMORY / PAGE_SIZE)
#define BITMAP_SIZE (TOTAL_FRAMES / 8)

static u8 pmm_bitmap[BITMAP_SIZE];
static u32 last_allocated_frame = 0;

/**
 * @brief Initializes the physical memory manager.
 * Marks all memory as used initially, bootloader info will free usable regions.
 */
void pmm_init(void) {
    for (u32 i = 0; i < BITMAP_SIZE; i++) {
        pmm_bitmap[i] = 0xFF; // 1 = Used/Reserved, 0 = Free
    }
    last_allocated_frame = 0;
}

/**
 * @brief Marks a specific physical frame as free.
 */
void pmm_free_frame(u32 frame_idx) {
    if (frame_idx >= TOTAL_FRAMES) return;
    pmm_bitmap[frame_idx / 8] &= ~(1 << (frame_idx % 8));
}

/**
 * @brief Marks a specific physical frame as used.
 */
void pmm_lock_frame(u32 frame_idx) {
    if (frame_idx >= TOTAL_FRAMES) return;
    pmm_bitmap[frame_idx / 8] |= (1 << (frame_idx % 8));
}

/**
 * @brief Allocates the next available physical frame.
 * @return Physical address of the frame, or 0 if out of memory.
 */
void* pmm_alloc_frame(void) {
    for (u32 i = last_allocated_frame; i < TOTAL_FRAMES; i++) {
        if ((pmm_bitmap[i / 8] & (1 << (i % 8))) == 0) {
            pmm_lock_frame(i);
            last_allocated_frame = i;
            return (void*)(i * PAGE_SIZE);
        }
    }
    
    // Wrap around search
    for (u32 i = 0; i < last_allocated_frame; i++) {
        if ((pmm_bitmap[i / 8] & (1 << (i % 8))) == 0) {
            pmm_lock_frame(i);
            last_allocated_frame = i;
            return (void*)(i * PAGE_SIZE);
        }
    }
    return NULL; // OOM
}

/* --- 3. VIRTUAL MEMORY MANAGER (VMM) --- */
/* Abstracted Page Directory structures. Architecture specific HAL will implement mapping. */

typedef struct {
    u32 entries[1024];
} page_table_t;

typedef struct {
    u32 entries[1024];
    page_table_t* tables[1024];
    u32 physical_address;
} page_directory_t;

page_directory_t* current_directory;
page_directory_t* kernel_directory;

/**
 * @brief Maps a physical address to a virtual address.
 * (Implementation requires inline assembly/HAL for actual CR3/MMU writes).
 */
i32 vmm_map_page(page_directory_t* dir, void* phys_addr, void* virt_addr, u32 flags) {
    u32 pdindex = (u32)virt_addr >> 22;
    u32 ptindex = (u32)virt_addr >> 12 & 0x03FF;

    if (dir->tables[pdindex] == NULL) {
        // Allocate a new page table
        dir->tables[pdindex] = (page_table_t*)pmm_alloc_frame();
        if (!dir->tables[pdindex]) return ERR_OUT_OF_MEMORY;
        
        // Clear page table
        for(int i=0; i<1024; i++) dir->tables[pdindex]->entries[i] = 0;
        
        // Map the table in the directory (Architecture specific flags typically applied here)
        dir->entries[pdindex] = (u32)dir->tables[pdindex] | flags | 0x01; // 0x01 = Present
    }

    dir->tables[pdindex]->entries[ptindex] = (u32)phys_addr | flags | 0x01;
    return SUCCESS;
}


/* --- 4. THREAD & SCHEDULER MANAGEMENT --- */

typedef enum {
    THREAD_EMPTY,
    THREAD_READY,
    THREAD_RUNNING,
    THREAD_BLOCKED_IPC_RX,
    THREAD_BLOCKED_IPC_TX,
    THREAD_ZOMBIE
} thread_state_t;

// Context saved by ISR (Architecture specific, assuming generic x86-like for now)
typedef struct {
    u32 edi, esi, ebp, esp, ebx, edx, ecx, eax;
    u32 int_no, err_code;
    u32 eip, cs, eflags, useresp, ss;
} cpu_context_t;

typedef struct thread_control_block {
    u32 tid;                        // Thread ID
    u32 pid;                        // Process ID (for resource grouping)
    thread_state_t state;           // Current execution state
    cpu_context_t context;          // Saved CPU state
    void* stack_ptr;                // Kernel stack pointer
    void* user_stack_ptr;           // User stack pointer
    page_directory_t* page_dir;     // Virtual memory space
    
    // IPC Ring Buffers / Mailbox state
    u32 ipc_target_tid;             // Who this thread is waiting to send/recv from
    struct ipc_message* pending_msg; // Pointer to physical msg struct in transit
    
    u32 time_slice;                 // Remaining ticks
    u32 priority;                   // 0 (Highest) to 255 (Lowest)
} tcb_t;

static tcb_t thread_table[MAX_THREADS];
static u32 current_thread_idx = 0;
static u32 active_threads_count = 0;

/**
 * @brief Initializes the scheduler system.
 */
void sched_init(void) {
    for (int i = 0; i < MAX_THREADS; i++) {
        thread_table[i].state = THREAD_EMPTY;
        thread_table[i].tid = i;
    }
    current_thread_idx = 0;
    active_threads_count = 0;
}

/**
 * @brief Spawns a new thread within a specific page directory (process).
 */
i32 sched_spawn_thread(void* entry_point, page_directory_t* pdir, u32 priority) {
    for (u32 i = 0; i < MAX_THREADS; i++) {
        if (thread_table[i].state == THREAD_EMPTY || thread_table[i].state == THREAD_ZOMBIE) {
            tcb_t* t = &thread_table[i];
            
            t->pid = 1; // Simplification: Single process container for now
            t->state = THREAD_READY;
            t->page_dir = pdir;
            t->priority = priority;
            t->time_slice = 10; // Default quantum
            
            // Allocate kernel stack for this thread
            t->stack_ptr = pmm_alloc_frame();
            if (!t->stack_ptr) return ERR_OUT_OF_MEMORY;
            
            // Initialize context (Architecture specific offset setup required here)
            t->context.eip = (u32)entry_point;
            t->context.cs = 0x08; // Kernel code segment stub
            t->context.eflags = 0x202; // Interrupts enabled
            
            active_threads_count++;
            return t->tid;
        }
    }
    return ERR_OUT_OF_MEMORY; // Thread table full
}

/**
 * @brief The core Round-Robin Scheduler. Called by Timer Interrupt.
 * @return Returns the TCB of the next thread to run.
 */
tcb_t* sched_tick(void) {
    if (active_threads_count == 0) return NULL; // Halt system or run idle thread
    
    tcb_t* current = &thread_table[current_thread_idx];
    
    // Decrease quantum
    if (current->state == THREAD_RUNNING) {
        if (current->time_slice > 0) {
            current->time_slice--;
            return current; // Continue execution
        }
        current->state = THREAD_READY; // Time slice expired
    }

    // Find next ready thread
    u32 start_idx = current_thread_idx;
    do {
        current_thread_idx = (current_thread_idx + 1) % MAX_THREADS;
        if (thread_table[current_thread_idx].state == THREAD_READY) {
            tcb_t* next = &thread_table[current_thread_idx];
            next->state = THREAD_RUNNING;
            next->time_slice = 10; // Reset quantum
            return next;
        }
    } while (current_thread_idx != start_idx);

    // If no other ready threads, and current was running, keep running
    if (current->state == THREAD_READY) {
        current->state = THREAD_RUNNING;
        current->time_slice = 10;
        return current;
    }

    return NULL; // Only reachable if ALL threads are blocked/empty
}

/* --- 5. INTER-PROCESS COMMUNICATION (IPC) --- */
/* Synchronous Message Passing. Threads block until rendezvous. */

typedef struct ipc_message {
    u32 sender_tid;
    u32 type;       // Message Type / System Call Number
    u32 arg1;
    u32 arg2;
    u32 arg3;
    u32 arg4;
} ipc_message_t;

/**
 * @brief Sends a message to a target thread. Blocks if target is not waiting.
 */
i32 ipc_send(u32 target_tid, ipc_message_t* msg) {
    if (target_tid >= MAX_THREADS || thread_table[target_tid].state == THREAD_EMPTY) {
        return ERR_INVALID_THREAD;
    }
    
    tcb_t* sender = &thread_table[current_thread_idx];
    tcb_t* receiver = &thread_table[target_tid];
    
    // Secure the sender's identity
    msg->sender_tid = sender->tid;

    if (receiver->state == THREAD_BLOCKED_IPC_RX) {
        // Receiver is already waiting. Transfer message directly.
        if (receiver->pending_msg != NULL) {
            // Copy data to receiver's buffer
            *(receiver->pending_msg) = *msg;
        }
        // Unblock receiver
        receiver->state = THREAD_READY;
        receiver->pending_msg = NULL;
        return SUCCESS;
    } else {
        // Receiver is NOT waiting. Sender must block.
        sender->state = THREAD_BLOCKED_IPC_TX;
        sender->ipc_target_tid = target_tid;
        sender->pending_msg = msg; // Hold pointer (must remain valid in memory space)
        
        // Force context switch (implemented in assembly/HAL)
        // sched_yield(); 
        
        return SUCCESS; // Will return here once receiver picks it up and unblocks us
    }
}

/**
 * @brief Receives a message. Blocks if no message is pending.
 * If source_tid is 0xFFFFFFFF, accepts from ANY sender.
 */
i32 ipc_receive(u32 source_tid, ipc_message_t* buffer) {
    tcb_t* receiver = &thread_table[current_thread_idx];

    // Check if a sender is already blocked waiting for us
    for (u32 i = 0; i < MAX_THREADS; i++) {
        tcb_t* sender = &thread_table[i];
        if (sender->state == THREAD_BLOCKED_IPC_TX && 
            sender->ipc_target_tid == receiver->tid &&
            (source_tid == 0xFFFFFFFF || sender->tid == source_tid)) {
            
            // Transfer message
            *buffer = *(sender->pending_msg);
            
            // Unblock Sender
            sender->state = THREAD_READY;
            sender->pending_msg = NULL;
            sender->ipc_target_tid = 0;
            
            return SUCCESS;
        }
    }

    // No pending sender found. Receiver must block.
    receiver->state = THREAD_BLOCKED_IPC_RX;
    receiver->ipc_target_tid = source_tid;
    receiver->pending_msg = buffer;
    
    // Force context switch
    // sched_yield();
    
    return SUCCESS;
}

/* --- 6. KERNEL ENTRY POINT --- */

/**
 * @brief The main entry point for the NoVa Microkernel.
 * Called by the architecture-specific boot code (e.g., GRUB Multiboot).
 */
void nova_main(u32 magic, void* multiboot_info) {
    // 1. Initialize Memory
    pmm_init();
    
    // TODO: Parse multiboot_info to free specific RAM regions using pmm_free_frame()
    // TODO: Initialize VMM & enable paging via HAL
    
    // 2. Initialize Scheduler
    sched_init();
    
    // 3. Mount core system threads (e.g., Idle Thread, Root Namespace Server)
    // sched_spawn_thread(&idle_thread_loop, kernel_directory, 255);
    // sched_spawn_thread(&vfs_server_loop, kernel_directory, 1);
    
    // 4. Hand off control to the scheduler (Architecture specific assembly needed here)
    // start_scheduler();
    
    // Should never reach here
    while(1) {}
}
