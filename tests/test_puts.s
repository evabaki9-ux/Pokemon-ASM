# isolated test of fb_puts / fb_putg
.intel_syntax noprefix
.include "defs.inc"
.section .rodata
msg1: .asciz "FIRE RED"
msg2: .asciz "ABCDEFGHIJ"
msg3: .asciz "POKeMON"
outpath: .asciz "/tmp/puts.txt"
.section .text
.globl _start
_start:
    mov edi, 1
    call set_headless
    call term_init
    xor edi, edi
    call fb_clear
    mov edi, 0
    mov esi, 0
    lea rdx, [rip+msg1]
    mov ecx, A_NORM
    call fb_puts
    mov edi, 0
    mov esi, 1
    lea rdx, [rip+msg2]
    mov ecx, A_NORM
    call fb_puts
    mov edi, 0
    mov esi, 2
    lea rdx, [rip+msg3]
    mov ecx, A_NORM
    call fb_puts
    lea rdi, [rip+outpath]
    call dump_open
    call dump_screen
    mov eax, 60
    xor edi, edi
    syscall
