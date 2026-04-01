; =====================================================================
; NoVa OS - Advanced 32-bit Monolithic Kernel (v1.4 "App Loader")
; Includes PMM, Paging, Tasking, FAT32 VFS, LFN, & Ring 3 Execution
; =====================================================================

; --- Multiboot Header ---
MBALIGN  equ  1 << 0
MEMINFO  equ  1 << 1
FLAGS    equ  MBALIGN | MEMINFO
MAGIC    equ  0x1BADB002
CHECKSUM equ -(MAGIC + FLAGS)

section .multiboot
align 4
    dd MAGIC
    dd FLAGS
    dd CHECKSUM

; =====================================================================
; KERNEL STRUCTURES & BSS
; =====================================================================
section .bss
align 16
stack_bottom:
    resb 32768
stack_top:

; Task Stacks
task0_stack_res resb 4096
task0_stack_top:
task1_stack_res resb 4096
task1_stack_top:

; --- User Space & Security ---
align 4096
user_stack resb 4096
user_stack_top:
align 4
tss_entry resb 104

; --- Kernel State Variables ---
cursor_x resd 1
cursor_y resd 1
kb_buffer resb 256
kb_buffer_pos resd 1
timer_ticks resd 1
itoa_buffer resb 16
current_dir_ptr resd 1
command_ready resb 1
shift_pressed resb 1
current_app_ptr resd 1      ; NEW: Tracks the RAM used by the running app

; --- Scheduler Variables ---
current_task resd 1
task_esp     resd 2

; --- Memory Manager Variables ---
mem_heap_ptr  resd 1
mem_total_used resd 1

; --- Disk & FAT32 Variables ---
sector_buffer resb 512
fat_buffer    resb 512
fat_target_name resb 11
lfn_buffer    resb 256        

fat32_bytes_per_sector  resw 1
fat32_sectors_per_clust resb 1
fat32_reserved_sectors  resw 1
fat32_num_fats          resb 1
fat32_sectors_per_fat   resd 1
fat32_root_cluster      resd 1
fat32_current_cluster   resd 1
fat32_fat_start_lba     resd 1
fat32_data_start_lba    resd 1
fat32_mounted           resb 1
fat32_path_str          resb 64
custom_text_ptr         resd 1

; --- Paging Structures ---
align 4096
page_directory resb 4096
page_table_1   resb 4096

section .text
global _start

_start:
    mov esp, stack_top
    cli

    mov byte [command_ready], 0
    mov byte [fat32_mounted], 0

    call init_pmm
    call init_vga
    call init_gdt
    call init_idt
    call init_pic
    call init_paging
    call init_scheduler

    mov eax, isr_timer_scheduler
    mov ebx, 32
    call set_idt_gate
    mov eax, isr_keyboard
    mov ebx, 33
    call set_idt_gate
    mov eax, isr_syscall
    mov ebx, 128
    call set_idt_gate

    sti

    mov eax, vfs_root
    mov [current_dir_ptr], eax

    ; Auto-mount FAT32 on boot
    call bin_f32mount

    mov esi, msg_welcome
    mov ah, 0x0B
    call print_string

    call shell_main

.kernel_halt:
    hlt
    jmp .kernel_halt

; =====================================================================
; PMM - PHYSICAL MEMORY MANAGER
; =====================================================================
init_pmm:
    mov dword [mem_heap_ptr], 0x200000
    mov dword [mem_total_used], 0
    ret

k_malloc:
    push ebx
    push ecx
    push edx
    add eax, 3
    and eax, ~3
    add eax, 8
    mov ecx, eax
    mov ebx, 0x200000
.search_loop:
    cmp ebx, [mem_heap_ptr]
    jae .grow_heap
    cmp dword [ebx + 4], 1
    jne .next_block
    mov edx, [ebx]
    cmp edx, ecx
    jb .next_block
    mov dword [ebx + 4], 0
    add [mem_total_used], edx
    mov eax, ebx
    add eax, 8
    jmp .done
.next_block:
    add ebx, [ebx]
    jmp .search_loop
.grow_heap:
    mov [ebx], ecx
    mov dword [ebx + 4], 0
    mov eax, ebx
    add eax, 8
    add [mem_heap_ptr], ecx
    add [mem_total_used], ecx
.done:
    pop edx
    pop ecx
    pop ebx
    ret

k_free:
    push ebx
    test eax, eax
    jz .done
    sub eax, 8
    mov dword [eax + 4], 1
    mov ebx, [eax]
    sub [mem_total_used], ebx
.done:
    pop ebx
    ret

; =====================================================================
; VIRTUAL MEMORY MANAGER (Paging)
; =====================================================================
init_paging:
    mov eax, 0x0
    mov ecx, 1024
    mov edi, page_table_1
.map_loop:
    mov edx, eax
    or edx, 7
    mov [edi], edx
    add eax, 4096
    add edi, 4
    loop .map_loop
    mov eax, page_table_1
    or eax, 7
    mov [page_directory], eax
    mov eax, page_directory
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    ret

; =====================================================================
; SCHEDULER ENGINE
; =====================================================================
init_scheduler:
    mov dword [current_task], 0
    mov eax, task1_stack_top
    sub eax, 4
    mov dword [eax], 0x202 
    sub eax, 4
    mov dword [eax], 0x08
    sub eax, 4
    mov dword [eax], background_task
    sub eax, 32
    mov [task_esp + 4], eax
    ret

isr_timer_scheduler:
    pushad
    mov eax, [current_task]
    mov edx, esp
    mov [task_esp + eax*4], edx
    inc eax
    and eax, 1
    mov [current_task], eax
    mov esp, [task_esp + eax*4]
    inc dword [timer_ticks]
    mov al, 0x20
    out 0x20, al
    popad
    iretd

background_task:
.loop:
    mov eax, [timer_ticks]
    and eax, 0x1F
    jnz .skip
    inc byte [0xB8000 + 158]
    mov byte [0xB8000 + 159], 0x0A
.skip:
    jmp .loop

; =====================================================================
; INTEGRATED SHELL (sh)
; =====================================================================
shell_main:
    call shell_prompt
.loop:
    cmp byte [command_ready], 1
    je .run_cmd
    hlt 
    jmp .loop

.run_cmd:
    mov byte [command_ready], 0
    call process_command
    call shell_prompt
    jmp .loop

shell_prompt:
    mov dword [kb_buffer_pos], 0
    mov esi, msg_user
    mov ah, 0x0B
    call print_string
    mov esi, [current_dir_ptr]
    mov ah, 0x0E
    call print_string
    mov esi, msg_prompt_sym
    mov ah, 0x0F
    call print_string
    ret

process_command:
    mov esi, kb_buffer
.trim_trailing:
    mov ebx, [kb_buffer_pos]
    test ebx, ebx
    jz .check_empty
    dec ebx
    cmp byte [kb_buffer + ebx], ' '
    jne .check_empty
    mov byte [kb_buffer + ebx], 0    
    mov [kb_buffer_pos], ebx
    jmp .trim_trailing
    
.check_empty:
    cmp byte [kb_buffer], 0
    je .done

    mov edi, cmd_cd
    mov ecx, 2
    call strncmp
    je .try_cd

    mov edi, cmd_cat
    mov ecx, 3
    call strncmp
    je .try_cat

    mov edi, cmd_run
    mov ecx, 4
    call strncmp
    je .try_run

    mov edi, cmd_f32read
    mov ecx, 7
    call strncmp
    je .try_f32read
    
    mov edi, cmd_f32write
    mov ecx, 8
    call strncmp
    je .try_f32write

    mov edi, cmd_f32cd
    mov ecx, 5
    call strncmp
    je .try_f32cd

    mov edi, cmd_f32rm
    mov ecx, 5
    call strncmp
    je .try_f32rm

    mov edi, cmd_f32mkdir
    mov ecx, 8
    call strncmp
    je .try_f32mkdir

    mov edi, cmd_clear
    call strcmp
    je sys_do_clear

    mov edi, cmd_help
    call strcmp
    je sys_do_help

    jmp .search_bin

.try_cd:
    mov al, [kb_buffer + 2]
    cmp al, ' '
    je sys_do_cd
    cmp al, 0
    je sys_do_cd
    cmp al, '.'
    jne .search_bin
    jmp .search_bin

.try_cat:
    mov al, [kb_buffer + 3]
    cmp al, ' '
    je sys_do_cat
    cmp al, 0
    je sys_do_cat
    jmp .search_bin

.try_run:
    mov al, [kb_buffer + 4]
    cmp al, ' '
    je bin_run
    cmp al, 0
    je bin_run
    jmp .search_bin

.try_f32read:
    mov al, [kb_buffer + 7]
    cmp al, ' '
    je bin_f32read
    cmp al, 0
    je bin_f32read
    jmp .search_bin

.try_f32write:
    mov al, [kb_buffer + 8]
    cmp al, ' '
    je bin_f32write
    cmp al, 0
    je bin_f32write
    jmp .search_bin

.try_f32cd:
    mov al, [kb_buffer + 5]
    cmp al, ' '
    je bin_f32cd
    cmp al, 0
    je bin_f32cd
    jmp .search_bin

.try_f32rm:
    mov al, [kb_buffer + 5]
    cmp al, ' '
    je bin_f32rm
    cmp al, 0
    je bin_f32rm
    jmp .search_bin

.try_f32mkdir:
    mov al, [kb_buffer + 8]
    cmp al, ' '
    je bin_f32mkdir
    cmp al, 0
    je bin_f32mkdir
    jmp .search_bin

.search_bin:
    call find_in_bin
    test eax, eax
    jz .not_found
    cmp eax, bin_test_syscall
    je execute_ring3
    call eax
    jmp .done
.not_found:
    mov esi, msg_unknown
    mov ah, 0x0C
    call print_string
    mov esi, kb_buffer
    mov ah, 0x0C        
    call print_string
    mov esi, msg_newline
    call print_string
.done:
    ret

find_in_bin:
    mov esi, vfs_table
.loop:
    cmp byte [esi], 0
    je .fail
    mov eax, [esi + 16]
    cmp eax, vfs_bin
    jne .next
    push esi
    mov edi, kb_buffer
    call strcmp
    pop esi
    je .match
.next:
    add esi, 32
    jmp .loop
.match:
    mov eax, [esi + 28]
    ret
.fail:
    xor eax, eax
    ret

; =====================================================================
; ADVANCED FAT32 ENGINE (Loader, LFN, Delete, Mkdir, Edit)
; =====================================================================

; Helper: Converts a FAT32 Cluster Number to a Physical LBA Sector
lba_from_cluster:
    sub eax, 2                          
    movzx ebx, byte [fat32_sectors_per_clust]
    imul eax, ebx                       
    add eax, [fat32_data_start_lba]     
    ret

; 1. FAT32 Format (REAL)
bin_f32format:
    mov esi, msg_formatting
    mov ah, 0x0E
    call print_string
    
    mov edi, sector_buffer
    mov ecx, 128            
    xor eax, eax
    rep stosd
    
    mov byte [sector_buffer + 0], 0xEB
    mov byte [sector_buffer + 1], 0x58
    mov byte [sector_buffer + 2], 0x90
    mov dword [sector_buffer + 3], 'NoVa'
    mov dword [sector_buffer + 7], ' OS '
    mov word [sector_buffer + 11], 512    
    mov byte [sector_buffer + 13], 1      
    mov word [sector_buffer + 14], 32     
    mov byte [sector_buffer + 16], 2      
    mov dword [sector_buffer + 36], 1000  
    mov dword [sector_buffer + 44], 2     
    mov dword [sector_buffer + 71], 'NOVA'
    mov dword [sector_buffer + 82], 'FAT3'
    mov dword [sector_buffer + 86], '2   '
    mov word [sector_buffer + 510], 0xAA55
    
    mov eax, 0
    mov esi, sector_buffer
    call ata_write_sector

    ; Initialize FAT
    mov edi, sector_buffer
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov dword [sector_buffer + 0], 0x0FFFFFF8 
    mov dword [sector_buffer + 4], 0xFFFFFFFF 
    mov dword [sector_buffer + 8], 0x0FFFFFFF 
    mov eax, 32
    mov esi, sector_buffer
    call ata_write_sector

    ; Zero Root Directory
    mov edi, sector_buffer
    mov ecx, 128
    xor eax, eax
    rep stosd
    mov eax, 2032
    mov esi, sector_buffer
    call ata_write_sector
    
    mov esi, msg_format_ok
    mov ah, 0x0A
    call print_string

    ; Automatically remount the drive so the OS sees the new format!
    call bin_f32mount
    ret

; 2. FAT32 Mount 
bin_f32mount:
    mov eax, 0
    mov edi, sector_buffer
    call ata_read_sector
    mov ax, [sector_buffer + 510]
    cmp ax, 0xAA55
    jne .no_fs

    mov ax, [sector_buffer + 11]
    mov [fat32_bytes_per_sector], ax
    mov al, [sector_buffer + 13]
    mov [fat32_sectors_per_clust], al
    mov ax, [sector_buffer + 14]
    mov [fat32_reserved_sectors], ax
    mov al, [sector_buffer + 16]
    mov [fat32_num_fats], al
    mov eax, [sector_buffer + 36]
    mov [fat32_sectors_per_fat], eax
    mov eax, [sector_buffer + 44]
    mov [fat32_root_cluster], eax
    mov [fat32_current_cluster], eax

    movzx eax, word [fat32_reserved_sectors]
    mov [fat32_fat_start_lba], eax

    movzx ebx, byte [fat32_num_fats]
    mov ecx, [fat32_sectors_per_fat]
    imul ebx, ecx
    add eax, ebx
    mov [fat32_data_start_lba], eax

    mov byte [fat32_mounted], 1
    mov esi, msg_f32_found
    mov ah, 0x0A
    call print_string
    ret
.no_fs:
    mov esi, msg_no_mbr
    mov ah, 0x0C
    call print_string
    ret

; 3. FAT32 List Directory
bin_f32ls:
    cmp byte [fat32_mounted], 1
    jne .not_mounted

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, msg_fat_root
    mov ah, 0x0A                         
    call print_string

    mov byte [lfn_buffer], 0    
    mov esi, sector_buffer
    mov ecx, 16                 
.parse_loop:
    cmp byte [esi], 0           
    je .done
    cmp byte [esi], 0xE5        
    je .next_entry
    
    mov al, [esi + 11]          
    cmp al, 0x0F                
    je .process_lfn

    mov ah, 0x0F                         
    test al, 0x10               
    jz .check_lfn
    mov ah, 0x09                
.check_lfn:
    push eax
    mov al, ' '
    call print_char
    pop eax

    cmp byte [lfn_buffer], 0
    je .print_83

    push esi
    mov esi, lfn_buffer
    call print_string
    pop esi
    mov byte [lfn_buffer], 0    
    jmp .newline

.print_83:
    push esi
    push ecx
    mov ecx, 11
    call print_n_chars                   
    pop ecx
    pop esi
.newline:
    push eax
    mov esi, msg_newline
    call print_string
    pop eax
    jmp .next_entry

.process_lfn:
    push eax
    push ebx
    push edx
    push edi

    mov al, [esi]               
    and al, 0x3F                
    dec al                      
    mov bl, 13                  
    mul bl
    mov edi, lfn_buffer
    add edi, eax                

    mov al, [esi + 1]
    mov [edi + 0], al
    mov al, [esi + 3]
    mov [edi + 1], al
    mov al, [esi + 5]
    mov [edi + 2], al
    mov al, [esi + 7]
    mov [edi + 3], al
    mov al, [esi + 9]
    mov [edi + 4], al
    mov al, [esi + 14]
    mov [edi + 5], al
    mov al, [esi + 16]
    mov [edi + 6], al
    mov al, [esi + 18]
    mov [edi + 7], al
    mov al, [esi + 20]
    mov [edi + 8], al
    mov al, [esi + 22]
    mov [edi + 9], al
    mov al, [esi + 24]
    mov [edi + 10], al
    mov al, [esi + 28]
    mov [edi + 11], al
    mov al, [esi + 30]
    mov [edi + 12], al
    mov byte [edi + 13], 0      
    
    pop edi
    pop edx
    pop ebx
    pop eax

.next_entry:
    add esi, 32                          
    dec ecx
    jnz .parse_loop
.done:
    ret
.not_mounted:
    mov esi, msg_not_mounted
    mov ah, 0x0C
    call print_string
    ret

; 4. FAT32 Read File (Text)
bin_f32read:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 8], 0
    je .no_arg

    mov esi, kb_buffer + 8
    mov edi, fat_target_name
    call format_fat_name

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov ecx, 16                 
.search_loop:
    cmp byte [esi], 0           
    je .not_found
    cmp byte [esi], 0xE5        
    je .next_entry
    mov al, [esi + 11]          
    cmp al, 0x0F                
    je .next_entry

    push esi
    mov edi, fat_target_name
    push ecx
    mov ecx, 11
    repe cmpsb
    pop ecx
    pop esi
    je .read_file

.next_entry:
    add esi, 32
    dec ecx
    jnz .search_loop

.not_found:
    mov esi, msg_file_miss
    mov ah, 0x0C
    call print_string
    ret

.read_file:
    movzx eax, word [esi + 20]
    shl eax, 16
    mov ax, word [esi + 26]
    
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector
    
    mov byte [sector_buffer + 511], 0
    mov esi, sector_buffer
    mov ah, 0x0F
    call print_string
    mov esi, msg_newline
    call print_string
    ret

.no_arg:
    mov esi, msg_fatr_err
    mov ah, 0x0C
    call print_string
    ret

; 5. FAT32 Write & Edit Target
bin_f32write:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 9], 0
    je .no_arg

    mov esi, kb_buffer + 9
    mov edi, fat_target_name
    call format_fat_name

    mov esi, kb_buffer
.search_flag:
    cmp byte [esi], 0
    je .use_default_text
    push esi
    mov edi, str_text_touch
    mov ecx, 14
    repe cmpsb
    pop esi
    je .found_flag
    inc esi
    jmp .search_flag
.found_flag:
    add esi, 14
    mov [custom_text_ptr], esi
    jmp .start_write
.use_default_text:
    mov dword [custom_text_ptr], msg_write_data

.start_write:
    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov edx, 16
.check_exists:
    cmp byte [esi], 0
    je .file_is_new
    cmp byte [esi], 0xE5
    je .check_next
    mov al, [esi + 11]
    cmp al, 0x0F
    je .check_next

    push esi
    mov edi, fat_target_name
    mov ecx, 11
    repe cmpsb
    pop esi
    je .overwrite_existing

.check_next:
    add esi, 32
    dec edx
    jnz .check_exists

.file_is_new:
    mov eax, [fat32_fat_start_lba]
    mov edi, fat_buffer
    call ata_read_sector

    mov ecx, 3                  
.find_cluster:
    mov eax, ecx
    shl eax, 2                  
    cmp dword [fat_buffer + eax], 0
    je .found_cluster
    inc ecx
    cmp ecx, 128
    jl .find_cluster

    mov esi, msg_disk_full
    mov ah, 0x0C
    call print_string
    ret

.found_cluster:
    push ecx
    mov eax, ecx
    shl eax, 2
    mov dword [fat_buffer + eax], 0x0FFFFFFF
    mov eax, [fat32_fat_start_lba]
    mov esi, fat_buffer
    call ata_write_sector

    pop ecx                     
    push ecx
    jmp .write_data_to_cluster

.overwrite_existing:
    mov ax, [esi + 20]
    shl eax, 16
    mov ax, [esi + 26]
    mov ecx, eax
    push ecx                    

.write_data_to_cluster:
    mov edi, sector_buffer
    push ecx
    mov ecx, 128
    xor eax, eax
    rep stosd
    pop ecx

    mov esi, [custom_text_ptr]
    mov edi, sector_buffer
.copy_str:
    lodsb
    stosb
    test al, al
    jnz .copy_str

    mov eax, edi
    sub eax, sector_buffer
    dec eax                     
    push eax                    

    mov eax, ecx
    call lba_from_cluster
    mov esi, sector_buffer
    call ata_write_sector

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    pop ebx                     
    pop ecx                     

    mov esi, sector_buffer
    mov edx, 16
.find_dir_slot_edit:
    mov al, [esi]
    test al, al
    jz .make_new_entry
    cmp al, 0xE5
    je .make_new_entry

    push esi
    mov edi, fat_target_name
    push ecx
    mov ecx, 11
    repe cmpsb
    pop ecx
    pop esi
    je .update_size_only
    
    add esi, 32
    dec edx
    jnz .find_dir_slot_edit

.make_new_entry:
    mov edi, esi
    push edi
    mov esi, fat_target_name
    push ecx
    mov ecx, 11
    rep movsb
    pop ecx
    pop edi

    mov byte [edi + 11], 0x20   

    push edi
    add edi, 12
    push ecx
    mov ecx, 20
    xor al, al
    rep stosb
    pop ecx
    pop edi

    mov eax, ecx
    shr eax, 16
    mov word [edi + 20], ax     
    mov word [edi + 26], cx     
    
.update_size_only:
    mov dword [esi + 28], ebx   

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov esi, sector_buffer
    call ata_write_sector

    mov esi, msg_write_ok
    mov ah, 0x0A
    call print_string
    ret

.no_arg:
    mov esi, msg_fatw_err
    mov ah, 0x0C
    call print_string
    ret

; 6. FAT32 Change Directory
bin_f32cd:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 6], 0    
    je .go_root

    cmp word [kb_buffer + 6], '..'
    je .handle_parent

    mov esi, kb_buffer + 6
    mov edi, fat_target_name
    call format_fat_name
    jmp .read_current_dir

.handle_parent:
    mov esi, dot_dot_name
    mov edi, fat_target_name
    mov ecx, 11
    rep movsb

.read_current_dir:
    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov edx, 16                 
.find_dir:
    mov al, [esi]
    test al, al                 
    jz .not_found
    cmp al, 0xE5                
    je .next_entry

    mov al, [esi + 11]
    and al, 0x10
    jz .next_entry              

    push esi
    mov edi, fat_target_name
    mov ecx, 11
    repe cmpsb
    pop esi
    je .found

.next_entry:
    add esi, 32
    dec edx
    jnz .find_dir

.not_found:
    mov esi, msg_dir_not_found
    mov ah, 0x0C
    call print_string
    ret

.found:
    mov ax, [esi + 20]          
    shl eax, 16
    mov ax, [esi + 26]          

    test eax, eax
    jnz .set_cluster
    mov eax, [fat32_root_cluster]
    
.set_cluster:
    mov [fat32_current_cluster], eax

    cmp eax, [fat32_root_cluster]
    je .go_root_prompt
    cmp eax, 0
    je .go_root_prompt

    mov esi, fat_target_name
    mov edi, fat32_path_str
    mov byte [edi], '/'
    inc edi
    mov ecx, 11
.copy_name:
    lodsb
    cmp al, ' '
    je .skip_space
    stosb
.skip_space:
    loop .copy_name
    mov byte [edi], 0
    mov dword [current_dir_ptr], fat32_path_str
    jmp .done_cd

.go_root_prompt:
    mov dword [current_dir_ptr], vfs_root

.done_cd:
    mov esi, msg_dir_changed
    mov ah, 0x0A
    call print_string
    ret

.go_root:
    mov eax, [fat32_root_cluster]
    mov [fat32_current_cluster], eax
    mov dword [current_dir_ptr], vfs_root
    mov esi, msg_dir_changed
    mov ah, 0x0A
    call print_string
    ret

; 7. FAT32 Remove
bin_f32rm:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 6], 0
    je .no_arg

    mov esi, kb_buffer + 6
    mov edi, fat_target_name
    call format_fat_name

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov ecx, 16
.search_loop:
    cmp byte [esi], 0
    je .not_found
    cmp byte [esi], 0xE5
    je .next_entry
    mov al, [esi + 11]
    cmp al, 0x0F
    je .next_entry

    push esi
    mov edi, fat_target_name
    push ecx
    mov ecx, 11
    repe cmpsb
    pop ecx
    pop esi
    je .delete_entry

.next_entry:
    add esi, 32
    dec ecx
    jnz .search_loop

.not_found:
    mov esi, msg_file_miss
    mov ah, 0x0C
    call print_string
    ret

.delete_entry:
    mov byte [esi], 0xE5
    movzx eax, word [esi + 20]
    shl eax, 16
    mov ax, word [esi + 26]
    push eax

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov esi, sector_buffer
    call ata_write_sector

    pop ecx                     
    mov eax, [fat32_fat_start_lba]
    mov edi, fat_buffer
    call ata_read_sector

.free_chain:
    cmp ecx, 0x0FFFFFF8         
    jae .done_freeing
    cmp ecx, 0                  
    je .done_freeing

    mov eax, ecx
    shl eax, 2                  
    mov edx, [fat_buffer + eax] 
    mov dword [fat_buffer + eax], 0 
    mov ecx, edx                
    jmp .free_chain

.done_freeing:
    mov eax, [fat32_fat_start_lba]
    mov esi, fat_buffer
    call ata_write_sector

    mov esi, msg_deleted
    mov ah, 0x0A
    call print_string
    ret

.no_arg:
    mov esi, msg_rm_err
    mov ah, 0x0C
    call print_string
    ret

; 8. FAT32 Make Directory
bin_f32mkdir:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 9], 0
    je .no_arg

    mov esi, kb_buffer + 9
    mov edi, fat_target_name
    call format_fat_name

    mov eax, [fat32_fat_start_lba]
    mov edi, fat_buffer
    call ata_read_sector

    mov ecx, 3                  
.find_cluster:
    mov eax, ecx
    shl eax, 2                  
    cmp dword [fat_buffer + eax], 0
    je .found_cluster
    inc ecx
    cmp ecx, 128
    jl .find_cluster

    mov esi, msg_disk_full
    mov ah, 0x0C
    call print_string
    ret

.found_cluster:
    mov eax, ecx
    shl eax, 2
    mov dword [fat_buffer + eax], 0x0FFFFFFF 
    mov eax, [fat32_fat_start_lba]
    mov esi, fat_buffer
    call ata_write_sector

    mov edi, sector_buffer
    push ecx
    mov ecx, 128
    xor eax, eax
    rep stosd
    pop ecx

    mov esi, dot_name
    mov edi, sector_buffer
    push ecx
    mov ecx, 11
    rep movsb
    pop ecx
    mov byte [sector_buffer + 11], 0x10 
    mov eax, ecx
    shr eax, 16
    mov word [sector_buffer + 20], ax
    mov word [sector_buffer + 26], cx

    mov esi, dot_dot_name
    mov edi, sector_buffer + 32
    push ecx
    mov ecx, 11
    rep movsb
    pop ecx
    mov byte [sector_buffer + 32 + 11], 0x10
    mov eax, [fat32_current_cluster]
    cmp eax, [fat32_root_cluster]
    jne .not_root_parent
    xor eax, eax 
.not_root_parent:
    mov ebx, eax
    shr eax, 16
    mov word [sector_buffer + 32 + 20], ax
    mov word [sector_buffer + 32 + 26], bx

    mov eax, ecx
    call lba_from_cluster
    mov esi, sector_buffer
    call ata_write_sector

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov edx, 16
.find_dir_slot:
    mov al, [esi]
    test al, al
    jz .make_entry
    cmp al, 0xE5
    je .make_entry
    add esi, 32
    dec edx
    jnz .find_dir_slot

    mov esi, msg_dir_full
    mov ah, 0x0C
    call print_string
    ret

.make_entry:
    mov edi, esi
    mov esi, fat_target_name
    push ecx
    mov ecx, 11
    rep movsb
    pop ecx

    mov byte [edi + 11], 0x10   
    
    push edi
    add edi, 12
    push ecx
    mov ecx, 20
    xor al, al
    rep stosb
    pop ecx
    pop edi

    mov eax, ecx
    shr eax, 16
    mov word [edi + 20], ax     
    mov word [edi + 26], cx     
    mov dword [edi + 28], 0     

    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov esi, sector_buffer
    call ata_write_sector

    mov esi, msg_mkdir_ok
    mov ah, 0x0A
    call print_string
    ret

.no_arg:
    mov esi, msg_mkdir_err
    mov ah, 0x0C
    call print_string
    ret

; 9. FAT32 Execute Binary (THE APP LOADER!)
; Reads binary file from drive into RAM and drops to Ring 3 to execute it.
bin_run:
    cmp byte [fat32_mounted], 1
    jne bin_f32ls.not_mounted

    cmp byte [kb_buffer + 4], 0
    je .no_arg

    mov esi, kb_buffer + 4
    mov edi, fat_target_name
    call format_fat_name

    ; Find File
    mov eax, [fat32_current_cluster]
    call lba_from_cluster
    mov edi, sector_buffer
    call ata_read_sector

    mov esi, sector_buffer
    mov ecx, 16                 
.search_loop:
    cmp byte [esi], 0           
    je .not_found
    cmp byte [esi], 0xE5        
    je .next_entry
    mov al, [esi + 11]          
    cmp al, 0x0F                
    je .next_entry
    test al, 0x10               ; Ignore Directories
    jnz .next_entry

    push esi
    mov edi, fat_target_name
    push ecx
    mov ecx, 11
    repe cmpsb
    pop ecx
    pop esi
    je .load_file

.next_entry:
    add esi, 32
    dec ecx
    jnz .search_loop

.not_found:
    mov esi, msg_file_miss
    mov ah, 0x0C
    call print_string
    ret

.load_file:
    ; Extract Cluster & Size
    movzx eax, word [esi + 20]
    shl eax, 16
    mov ax, word [esi + 26]
    mov ecx, eax                ; ECX = Starting Cluster

    mov eax, [esi + 28]         ; EAX = File size
    test eax, eax
    jz .empty_file

    ; Allocate Memory via PMM
    call k_malloc
    mov [current_app_ptr], eax  ; NEW: Save the pointer so we can free it later!
    mov ebx, eax                ; EBX = Current Destination Pointer
    push eax                    ; SAVE ENTRY POINT FOR LATER!

.load_cluster:
    ; Read cluster into temporary buffer
    mov eax, ecx
    push ecx                    ; Save FAT cluster
    call lba_from_cluster
    
    movzx edx, byte [fat32_sectors_per_clust]
.read_sectors:
    push eax                    ; Save LBA
    push edx                    ; Save remaining sector count
    
    mov edi, sector_buffer
    call ata_read_sector
    
    ; Copy sector to allocated executable memory
    mov esi, sector_buffer
    mov edi, ebx
    push ecx
    mov ecx, 128                ; 128 DWORDS = 512 bytes
    rep movsd                   ; EDI increments automatically
    mov ebx, edi                ; Save updated dest pointer
    pop ecx
    
    pop edx
    pop eax
    inc eax                     ; Next Sector
    dec edx
    jnz .read_sectors

    ; Walk the FAT chain to find next cluster
    pop ecx                     ; Restore current FAT cluster
    mov eax, [fat32_fat_start_lba]
    mov edi, fat_buffer
    call ata_read_sector
    
    mov eax, ecx
    shl eax, 2
    mov ecx, [fat_buffer + eax] ; Look up next cluster
    
    cmp ecx, 0x0FFFFFF8         ; Is it EOF?
    jae .execute_it
    cmp ecx, 0                  ; Safety catch
    je .execute_it
    jmp .load_cluster           ; Load next part!

.execute_it:
    pop eax                     ; Restore the original memory Entry Point into EAX
    mov esi, msg_executing
    mov ah, 0x0A
    call print_string
    
    jmp execute_ring3           ; HARDWARE SWITCH to Ring 3 User Space!

.empty_file:
    mov esi, msg_file_miss
    mov ah, 0x0C
    call print_string
    ret

.no_arg:
    mov esi, msg_run_err
    mov ah, 0x0C
    call print_string
    ret


; Helper to format command line args into 8.3 FAT format
format_fat_name:
    push ecx
    mov ecx, 11
    mov al, ' '
    push edi
    rep stosb           
    pop edi
    pop ecx
    mov ecx, 8          
.name_loop:
    mov al, [esi]
    cmp al, '.'
    je .do_ext
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    cmp al, 'a'
    jl .skip_up
    cmp al, 'z'
    jg .skip_up
    sub al, 32
.skip_up:
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .name_loop
.find_dot:
    mov al, [esi]
    cmp al, '.'
    je .do_ext
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    inc esi
    jmp .find_dot
.do_ext:
    inc esi
    mov edi, fat_target_name + 8
    mov ecx, 3
.ext_loop:
    mov al, [esi]
    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    cmp al, 'a'
    jl .skip_up2
    cmp al, 'z'
    jg .skip_up2
    sub al, 32
.skip_up2:
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .ext_loop
.done:
    ret


; =====================================================================
; BASIC OS BINARIES
; =====================================================================
bin_ls:
    mov ebx, [current_dir_ptr]
    mov esi, vfs_table
.loop:
    cmp byte [esi], 0
    je .done
    mov eax, [esi + 16]
    cmp eax, ebx
    jne .skip
    push esi
    mov al, [esi + 20]
    cmp al, 1
    je .dir
    mov ah, 0x0F
    jmp .print
.dir:
    mov ah, 0x09
.print:
    call print_string
    mov al, ' '
    call print_char
    pop esi
.skip:
    add esi, 32
    jmp .loop
.done:
    mov esi, msg_newline
    call print_string
    ret

bin_free:
    mov esi, msg_mem_info
    mov ah, 0x0E
    call print_string
    mov eax, [mem_total_used]
    mov edi, itoa_buffer
    call itoa
    mov esi, itoa_buffer
    mov ah, 0x0F
    call print_string
    mov esi, msg_bytes
    mov ah, 0x0E
    call print_string
    ret

bin_uptime:
    mov eax, [timer_ticks]
    mov edi, itoa_buffer
    call itoa
    mov esi, msg_uptime_pre
    mov ah, 0x0B
    call print_string
    mov esi, itoa_buffer
    mov ah, 0x0F
    call print_string
    mov esi, msg_newline
    call print_string
    ret

bin_lookie:
    mov esi, msg_lk_n1
    mov ah, 0x08           
    call print_string
    mov esi, msg_lk_v1
    mov ah, 0x0D           
    call print_string
    mov esi, msg_lk_key_os
    mov ah, 0x0B           
    call print_string
    mov esi, msg_lk_val_os
    mov ah, 0x0F           
    call print_string
    mov esi, msg_newline
    call print_string
    mov esi, msg_lk_n2
    mov ah, 0x08
    call print_string
    mov esi, msg_lk_v2
    mov ah, 0x0D
    call print_string
    mov esi, msg_lk_key_kr
    mov ah, 0x0B
    call print_string
    mov esi, msg_lk_val_kr
    mov ah, 0x0F
    call print_string
    mov esi, msg_newline
    call print_string
    mov esi, msg_lk_n3
    mov ah, 0x08
    call print_string
    mov esi, msg_lk_v3
    mov ah, 0x0D
    call print_string
    mov esi, msg_lk_i3
    mov ah, 0x0B
    call print_string
    mov eax, [timer_ticks]
    mov edi, itoa_buffer
    call itoa
    mov esi, itoa_buffer
    mov ah, 0x0F
    call print_string
    mov esi, msg_lk_ticks
    mov ah, 0x0F
    call print_string
    mov esi, msg_newline
    call print_string
    mov esi, msg_lk_n4
    mov ah, 0x08
    call print_string
    mov esi, msg_lk_v4
    mov ah, 0x0D
    call print_string
    mov esi, msg_lk_i4
    mov ah, 0x0B
    call print_string
    mov eax, [mem_total_used]
    mov edi, itoa_buffer
    call itoa
    mov esi, itoa_buffer
    mov ah, 0x0F
    call print_string
    mov esi, msg_bytes     
    mov ah, 0x0F
    call print_string
    mov esi, msg_lk_n5
    mov ah, 0x08
    call print_string
    mov esi, msg_lk_key_sh
    mov ah, 0x0B
    call print_string
    mov esi, msg_lk_val_sh
    mov ah, 0x0F
    call print_string
    mov esi, msg_newline
    call print_string
    ret

execute_ring3:
    cli
    mov bx, 0x23            ; User Data Segment
    mov ds, bx
    mov es, bx
    mov fs, bx
    mov gs, bx
    push 0x23               ; SS
    push user_stack_top     ; User ESP
    push 0x202              ; EFLAGS (Interrupts Enabled)
    push 0x1B               ; CS (User Code Segment)
    push eax                ; EIP (App Entry Point allocated by k_malloc!)
    iretd                   ; Hardware Context Switch!

bin_test_syscall:
    mov eax, 0                  
    mov ebx, msg_syscall_test   
    mov ecx, 0x0D               
    int 0x80                    
    mov eax, 3                  
    int 0x80                    
    hlt

sys_do_cd:
    cmp byte [kb_buffer + 2], 0  
    je .done
    mov edi, kb_buffer + 3
    cmp byte [edi], '.'
    jne .search
    cmp byte [edi+1], '.'
    jne .search
    cmp byte [edi+2], 0
    jne .search
    jmp sys_do_cd_up
.search:
    mov esi, vfs_table
.loop:
    cmp byte [esi], 0
    je .no_dir
    push esi
    call strcmp
    pop esi
    je .found
    add esi, 32
    jmp .loop
.found:
    cmp byte [esi+20], 1   
    jne .not_dir
    mov [current_dir_ptr], esi
    ret
.no_dir:
    mov esi, msg_no_dir
    mov ah, 0x0C
    call print_string
    ret
.not_dir:
    mov esi, msg_not_dir
    mov ah, 0x0C
    call print_string
.done:
    ret

sys_do_cd_up:
    mov ebx, [current_dir_ptr]
    mov eax, [ebx + 16]
    test eax, eax
    jz .done_up
    mov [current_dir_ptr], eax
.done_up:
    ret

sys_do_cat:
    cmp byte [kb_buffer + 3], 0  
    je .cat_no_file
    mov edi, kb_buffer + 4      
    mov ebx, [current_dir_ptr]
    mov esi, vfs_table
.cat_loop:
    cmp byte [esi], 0
    je .cat_no_file
    mov eax, [esi + 16]         
    cmp eax, ebx
    jne .cat_next
    push esi
    call strcmp                 
    pop esi
    je .cat_found
.cat_next:
    add esi, 32
    jmp .cat_loop
.cat_found:
    cmp byte [esi+20], 1        
    je .cat_is_dir
    mov esi, [esi+28]           
    mov ah, 0x0F                
    call print_string
    mov esi, msg_newline
    call print_string
    ret
.cat_no_file:
    mov esi, msg_no_file
    mov ah, 0x0C
    call print_string
    ret
.cat_is_dir:
    mov esi, msg_is_dir
    mov ah, 0x0C
    call print_string
    ret

sys_do_clear:
    call clear_screen
    ret

sys_do_help:
    mov esi, msg_help_text
    mov ah, 0x0E
    call print_string
    ret

; =====================================================================
; VFS DATA 
; =====================================================================
align 4
%macro VFS_ENTRY 5
%%start:
    db %1
    times 16 - ($ - %%start) db 0    
    dd %2, %3, %4, %5
%endmacro

vfs_table:
vfs_root:   VFS_ENTRY '/', 0, 1, 0, 0
vfs_bin:    VFS_ENTRY 'bin', vfs_root, 1, 0, 0
vfs_dev:    VFS_ENTRY 'dev', vfs_root, 1, 0, 0
vfs_ls:     VFS_ENTRY 'ls', vfs_bin, 0, 0, bin_ls
vfs_free:   VFS_ENTRY 'free', vfs_bin, 0, 0, bin_free
vfs_uptime: VFS_ENTRY 'uptime', vfs_bin, 0, 0, bin_uptime
vfs_test:   VFS_ENTRY 'test', vfs_bin, 0, 0, bin_test_syscall
vfs_f32fmt: VFS_ENTRY 'f32format', vfs_bin, 0, 0, bin_f32format
vfs_f32mnt: VFS_ENTRY 'f32mount', vfs_bin, 0, 0, bin_f32mount
vfs_f32ls:  VFS_ENTRY 'f32ls', vfs_bin, 0, 0, bin_f32ls
vfs_f32rd:  VFS_ENTRY 'f32read', vfs_bin, 0, 0, bin_f32read
vfs_f32wr:  VFS_ENTRY 'f32write', vfs_bin, 0, 0, bin_f32write
vfs_f32cd:  VFS_ENTRY 'f32cd', vfs_bin, 0, 0, bin_f32cd
vfs_f32rm:  VFS_ENTRY 'f32rm', vfs_bin, 0, 0, bin_f32rm
vfs_f32mk:  VFS_ENTRY 'f32mkdir', vfs_bin, 0, 0, bin_f32mkdir
vfs_lookie: VFS_ENTRY 'lookie.me', vfs_bin, 0, 0, bin_lookie
vfs_readme: VFS_ENTRY 'readme.txt', vfs_root, 0, 0, data_readme
    db 0   

data_readme db 'NoVa OS v1.4. The Executable Program Loader is live!', 0

; =====================================================================
; HARDWARE DRIVERS & UTILS
; =====================================================================
init_vga:
    mov dword [cursor_x], 0
    mov dword [cursor_y], 0
    call clear_screen
    ret
clear_screen:
    mov edi, 0xB8000
    mov ecx, 80 * 25
    mov ax, 0x0F20
    rep stosw
    mov dword [cursor_x], 0
    mov dword [cursor_y], 0
    call update_cursor
    ret
print_string:
.loop:
    lodsb
    test al, al
    jz .done
    call print_char
    jmp .loop
.done:
    ret
print_n_chars:
.loop:
    test ecx, ecx
    jz .done
    lodsb
    call print_char
    dec ecx
    jmp .loop
.done:
    ret
print_char:
    pushad
    cmp al, 0x0A
    je .newline
    cmp al, 0x08
    je .backspace
    mov cx, ax               
    mov eax, [cursor_y]
    mov ebx, 80
    mul ebx
    add eax, [cursor_x]
    shl eax, 1
    add eax, 0xB8000
    mov [eax], cx            
    inc dword [cursor_x]
    cmp dword [cursor_x], 80
    jl .update
.newline:
    mov dword [cursor_x], 0
    inc dword [cursor_y]
    cmp dword [cursor_y], 25
    jl .update
    call scroll_screen
    jmp .update
.backspace:
    cmp dword [cursor_x], 0
    je .update
    dec dword [cursor_x]
    mov eax, [cursor_y]
    mov ebx, 80
    mul ebx
    add eax, [cursor_x]
    shl eax, 1
    add eax, 0xB8000
    mov word [eax], 0x0F20
.update:
    call update_cursor
    popad
    ret
scroll_screen:
    mov esi, 0xB8000 + 160
    mov edi, 0xB8000
    mov ecx, 80 * 24 * 2
    rep movsb
    mov edi, 0xB8000 + (80 * 24 * 2)
    mov ecx, 80
    mov ax, 0x0F20
    rep stosw
    mov dword [cursor_y], 24
    ret
update_cursor:
    pushad
    mov eax, [cursor_y]
    mov ebx, 80
    mul ebx
    add eax, [cursor_x]
    mov ebx, eax
    mov al, 0x0F
    mov dx, 0x03D4
    out dx, al
    mov al, bl
    mov dx, 0x03D5
    out dx, al
    mov al, 0x0E
    mov dx, 0x03D4
    out dx, al
    mov al, bh
    mov dx, 0x03D5
    out dx, al
    popad
    ret
ata_read_sector:
    pushad
    mov ebx, eax            
    mov edx, 0x3F6
    mov al, 0x02
    out dx, al
    mov edx, 0x1F6
    shr eax, 24
    or al, 0xE0             
    out dx, al
    mov edx, 0x1F2
    mov al, 1
    out dx, al
    mov edx, 0x1F3
    mov eax, ebx
    out dx, al
    mov edx, 0x1F4
    shr eax, 8
    out dx, al
    mov edx, 0x1F5
    shr eax, 8
    out dx, al
    mov edx, 0x1F7
    mov al, 0x20
    out dx, al
.wait_ready:
    in al, dx
    test al, 0x80           
    jnz .wait_ready
    test al, 0x08           
    jz .wait_ready
    mov edx, 0x1F0          
    mov ecx, 256            
    rep insw                
    popad
    ret
ata_write_sector:
    pushad
    mov ebx, eax
    mov edx, 0x3F6
    mov al, 0x02
    out dx, al
    mov edx, 0x1F6
    shr eax, 24
    or al, 0xE0
    out dx, al
    mov edx, 0x1F2
    mov al, 1
    out dx, al
    mov edx, 0x1F3
    mov eax, ebx
    out dx, al
    mov edx, 0x1F4
    shr eax, 8
    out dx, al
    mov edx, 0x1F5
    shr eax, 8
    out dx, al
    mov edx, 0x1F7
    mov al, 0x30    
    out dx, al
.wait_ready:
    in al, dx
    test al, 0x80
    jnz .wait_ready
    test al, 0x08
    jz .wait_ready
    mov edx, 0x1F0
    mov ecx, 256
    rep outsw       
    mov edx, 0x1F7
    mov al, 0xE7
    out dx, al
.wait_flush:
    in al, dx
    test al, 0x80
    jnz .wait_flush
    popad
    ret
init_gdt:
    mov eax, tss_entry
    mov word [gdt_tss], 103      
    mov word [gdt_tss+2], ax     
    shr eax, 16
    mov byte [gdt_tss+4], al     
    mov byte [gdt_tss+5], 0x89   
    mov byte [gdt_tss+6], 0      
    mov byte [gdt_tss+7], ah     
    mov dword [tss_entry + 4], stack_top 
    mov dword [tss_entry + 8], 0x10      
    lgdt [gdt_descriptor]
    jmp 0x08:.reload
.reload:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov ax, 0x28                 
    ltr ax
    ret
align 8
gdt_start: dq 0
gdt_code:  dq 0x00CF9A000000FFFF 
gdt_data:  dq 0x00CF92000000FFFF 
gdt_ucode: dq 0x00CFFA000000FFFF 
gdt_udata: dq 0x00CFF2000000FFFF 
gdt_tss:   dq 0                  
gdt_end:
gdt_descriptor: dw gdt_end - gdt_start - 1
                dd gdt_start
init_idt:
    lidt [idt_descriptor]
    ret
set_idt_gate:
    mov ecx, idt_start
    imul ebx, 8
    add ecx, ebx
    mov word [ecx], ax
    mov word [ecx+2], 0x08
    cmp ebx, 128            
    je .user_gate
    mov word [ecx+4], 0x8E00 
    jmp .finish
.user_gate:
    mov word [ecx+4], 0xEE00 
.finish:
    shr eax, 16
    mov word [ecx+6], ax
    ret
init_pic:
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0x00
    out 0x21, al
    out 0xA1, al
    ret
align 8
idt_start: times 256 dq 0
idt_end:
idt_descriptor: dw idt_end - idt_start - 1
                dd idt_start
isr_keyboard:
    pushad
    in al, 0x60
    
    cmp al, 0x2A        
    je .shift_down
    cmp al, 0x36        
    je .shift_down
    cmp al, 0xAA        
    je .shift_up
    cmp al, 0xB6        
    je .shift_up
    
    test al, 0x80
    jnz .done
    
    movzx ebx, al
    cmp byte [shift_pressed], 1
    je .use_shift
    mov al, [scancode_map + ebx]
    jmp .got_char
    
.use_shift:
    mov al, [scancode_map_shift + ebx]
    
.got_char:
    test al, al
    jz .done
    cmp al, 0x0A
    je .enter
    cmp al, 0x08
    je .back
    mov ah, 0x0F
    call print_char
    mov ebx, [kb_buffer_pos]
    cmp ebx, 255
    jge .done
    mov [kb_buffer + ebx], al
    inc dword [kb_buffer_pos]
    jmp .done

.back:
    mov ebx, [kb_buffer_pos]
    test ebx, ebx
    jz .done
    dec dword [kb_buffer_pos]
    mov ah, 0x0F
    mov al, 0x08
    call print_char
    jmp .done

.enter:
    mov ebx, [kb_buffer_pos]
    mov byte [kb_buffer + ebx], 0
    mov ah, 0x0F
    mov al, 0x0A
    call print_char
    mov byte [command_ready], 1
    jmp .done

.shift_down:
    mov byte [shift_pressed], 1
    jmp .done
.shift_up:
    mov byte [shift_pressed], 0
    
.done:
    mov al, 0x20
    out 0x20, al
    popad
    iretd
isr_syscall:
    pushad                  
    push ds                 
    push es                 
    mov bx, 0x10
    mov ds, bx
    mov es, bx
    cmp eax, 0
    je .sys_print
    cmp eax, 1
    je .sys_malloc
    cmp eax, 2
    je .sys_free
    cmp eax, 3
    je .sys_exit
    jmp .sys_done           
.sys_print:
    mov esi, ebx            
    mov ah, cl              
    call print_string
    jmp .sys_done
.sys_malloc:
    mov eax, ebx            
    call k_malloc
    mov [esp + 36], eax     
    jmp .sys_done
.sys_free:
    mov eax, ebx            
    call k_free
    jmp .sys_done
.sys_exit:
    ; --- NEW: Memory Leak Patch ---
    mov eax, [current_app_ptr]
    test eax, eax               ; Did we allocate memory for an app?
    jz .skip_app_free
    call k_free                 ; Free the app's memory!
    mov dword [current_app_ptr], 0 ; Reset the tracker
.skip_app_free:
    ; ------------------------------
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov esp, stack_top      
    sti
    jmp shell_main        
.sys_done:
    pop es
    pop ds
    popad                   
    iretd                   
strcmp:
    push esi
    push edi
    push ebx
.loop:
    mov al, [esi]
    mov bl, [edi]
    cmp al, bl
    jne .no
    test al, al
    jz .yes
    inc esi
    inc edi
    jmp .loop
.no: 
    pop ebx
    pop edi
    pop esi
    clc
    ret
.yes: 
    pop ebx
    pop edi
    pop esi
    cmp eax, eax
    ret
strncmp:
    push esi
    push edi
    push ecx
    push ebx
.loop:
    test ecx, ecx
    jz .yes
    mov al, [esi]
    mov bl, [edi]
    cmp al, bl
    jne .no
    inc esi
    inc edi
    dec ecx
    jmp .loop
.no: 
    pop ebx
    pop ecx
    pop edi
    pop esi
    clc
    ret
.yes: 
    pop ebx
    pop ecx
    pop edi
    pop esi
    cmp eax, eax
    ret
itoa:
    pusha
    mov ecx, 10
    mov ebx, edi
    add ebx, 15
    mov byte [ebx], 0
    dec ebx
.l: 
    xor edx, edx
    div ecx
    add dl, '0'
    mov [ebx], dl
    dec ebx
    test eax, eax
    jnz .l
    inc ebx
.c: 
    mov al, [ebx]
    mov [edi], al
    inc edi
    inc ebx
    test al, al
    jnz .c
    popa
    ret
scancode_map:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0A, 0, 'a', 's'
    db 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, '\', 'z', 'x', 'c', 'v'
    db 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ', 0
    times 128 db 0

scancode_map_shift:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0A, 0, 'A', 'S'
    db 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V'
    db 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' ', 0
    times 128 db 0

; Strings & UI Texts
msg_welcome   db 'NoVa Monolithic Kernel v1.4 [App Loader Ready]', 0x0A, 'Type "help" for commands.', 0x0A, 0
msg_user      db 'root@nova:', 0
msg_prompt_sym db '# ', 0
msg_unknown   db 'sh: command not found: ', 0
msg_newline   db 0x0A, 0
msg_uptime_pre db 'Ticks: ', 0
msg_mem_info  db 'Kernel Heap Usage: ', 0
msg_bytes     db ' bytes used.', 0x0A, 0
msg_no_dir    db 'cd: no such directory', 0x0A, 0
msg_not_dir   db 'cd: not a directory', 0x0A, 0
msg_no_file   db 'cat: file not found (in VFS)', 0x0A, 0
msg_is_dir    db 'cat: is a directory', 0x0A, 0

msg_help_text db 'Commands: ls, cd, cat, free, uptime, test, clear, lookie.me', 0x0A, 'FAT32 Tools: f32format, f32mount, f32ls, f32read, f32write, f32cd, f32rm, f32mkdir', 0x0A, 'App Loader: run <filename.bin>', 0x0A, 0

msg_syscall_test db 'Hello from User Space via int 0x80 Syscall!', 0x0A, 0
msg_no_mbr    db 'FAIL: No valid boot signature found on sector 0. (Run "f32format" first!)', 0x0A, 0
msg_fat_root  db 'FAT32 Directory Contents:', 0x0A, 0
msg_formatting db 'Formatting Drive with pure FAT32 Structures...', 0x0A, 0
msg_format_ok  db 'Format Complete! FAT32 Root Directory built at LBA 2032.', 0x0A, 0
msg_fatr_err   db 'Usage: f32read <filename.ext>', 0x0A, 0
msg_file_miss  db 'Error: File/Folder not found.', 0x0A, 0

cmd_cd        db 'cd ', 0
cmd_cat       db 'cat ', 0
cmd_run       db 'run ', 0
cmd_f32read   db 'f32read', 0
cmd_f32write  db 'f32write', 0
cmd_f32cd     db 'f32cd', 0
cmd_f32rm     db 'f32rm', 0
cmd_f32mkdir  db 'f32mkdir', 0
cmd_clear     db 'clear', 0
cmd_help      db 'help', 0

str_text_touch db '--text_touch: ', 0

msg_f32_found   db 'Drive successfully mounted! FAT32 Variables initialized.', 0x0A, 0
msg_not_mounted db 'Error: Run "f32mount" first to initialize the disk variables!', 0x0A, 0
msg_disk_full   db 'Error: Disk full (or FAT sector 0 full).', 0x0A, 0
msg_dir_full    db 'Error: Directory full.', 0x0A, 0
msg_write_data  db 'SUCCESS! You have mastered the FAT32 Write Sequence!', 0x0A, 'This text is physically stored on the drive.', 0x0A, 0
msg_write_ok    db 'File successfully written/updated on disk!', 0x0A, 0
msg_fatw_err    db 'Usage: f32write <filename.ext> [--text_touch: data]', 0x0A, 0

msg_deleted     db 'Target successfully deleted. FAT chains freed.', 0x0A, 0
msg_rm_err      db 'Usage: f32rm <filename.ext>', 0x0A, 0
msg_mkdir_ok    db 'Directory created successfully!', 0x0A, 0
msg_mkdir_err   db 'Usage: f32mkdir <dirname>', 0x0A, 0

msg_executing   db 'Loading binary into memory... Jumping to User Space (Ring 3)!', 0x0A, 0
msg_run_err     db 'Usage: run <filename.bin>', 0x0A, 0

dot_name          db '.          '
dot_dot_name      db '..         '
msg_dir_not_found db 'Error: Directory not found.', 0x0A, 0
msg_dir_changed   db 'Directory changed.', 0x0A, 0

msg_lk_n1     db '    //   //  ', 0
msg_lk_v1     db '\ \  / /     ', 0
msg_lk_key_os db 'OS: ', 0
msg_lk_val_os db 'NoVa OS v1.4', 0
msg_lk_n2     db '   ///  //   ', 0
msg_lk_v2     db ' \ \/ /      ', 0
msg_lk_key_kr db 'Kernel: ', 0
msg_lk_val_kr db 'App Loader', 0
msg_lk_n3     db '  //  ///    ', 0
msg_lk_v3     db '  \  /       ', 0
msg_lk_i3     db 'Uptime: ', 0
msg_lk_n4     db ' //   // .   ', 0
msg_lk_v4     db '   \/        ', 0
msg_lk_i4     db 'Memory: ', 0
msg_lk_n5     db '                          ', 0 
msg_lk_key_sh db 'Shell: ', 0
msg_lk_val_sh db 'Integrated sh', 0
msg_lk_ticks  db ' ticks', 0