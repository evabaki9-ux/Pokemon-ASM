# isolated test: the dialogue system, no game state involved
.intel_syntax noprefix
.include "defs.inc"

.section .rodata
hello:  .asciz "PROF. OAK\fHello there!\nThis is a test of\nthe dialogue system."
hello2: .asciz "Second message\fwith a second page."
q:      .asciz "Do you understand?"
outp:   .asciz "/tmp/text.txt"

.section .text
.globl _start
_start:
    mov edi, 1
    call set_headless
    mov edi, 12345
    call rng_seed
    call term_init
    mov edi, C_BLACK
    call fb_clear

    lea rdi, [rip+hello]
    mov esi, 0
    call msg_show
    lea rdi, [rip+hello2]
    call msg_push

    mov ebx, 0
1:  call frame_wait
    inc ebx
    # press A every 40 frames
    mov edx, ebx
    and edx, 63
    cmp edx, 32
    jne 2f
    mov edi, K_A
    call kq_push
2:  call input_poll
    call kq_pop
    mov byte ptr [rip+key], al
    mov byte ptr [rip+key_dlg], al
    cmp byte ptr [rip+tb_active], 0
    jne 3f
    mov edi, K_A
    call kq_push
    call input_poll
    call kq_pop
    mov byte ptr [rip+key], al
    mov byte ptr [rip+key_dlg], al
3:  call msg_frame
    test eax, eax
    jnz 4f
    jmp 5f
4:  cmp ebx, 200
    jb 1b
5:  lea rdi, [rip+outp]
    call dump_open
    call dump_screen
    call term_restore
    mov eax, 60
    xor edi, edi
    syscall
