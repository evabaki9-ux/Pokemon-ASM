# ============================================================================
#  text.s - FireRed-style dialogue boxes: typewriter reveal, paging (\f),
#           YES/NO chooser, HP bars, generic framed panels.
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

.set TXB_X,     1
.set TXB_Y,     17
.set TXB_W,     78
.set TXB_H,     7
.set TXT_X,     2
.set TXT_Y,     18
.set TXT_W,     74
.set MSG_SPEED, 2

.section .bss
.align 8
.globl tb_active, tb_reveal, tb_len, tb_ptr, tb_choice, ch_sel, ch_res
.globl msg_q, msg_n, msg_i, tb_mode
tb_active:    .byte 0
tb_mode:      .byte 0
tb_reveal:    .word 0
tb_len:       .word 0
tb_delay:     .byte 0
tb_ptr:       .quad 0
msg_q:        .skip 64
msg_n:        .byte 0
msg_i:        .byte 0
tb_choice:    .byte 0
ch_sel:       .byte 0
ch_res:       .byte 0
.globl key_dlg
key_dlg:      .byte 0


.section .text
.globl msg_clear
msg_clear:
    mov byte ptr [rip+msg_n], 0
    mov byte ptr [rip+msg_i], 0
    ret

.globl msg_push
msg_push:                                # rdi=str
    movzx eax, byte ptr [rip+msg_n]
    cmp eax, 8
    jae 1f
    lea rcx, [rip+msg_q]
    mov qword ptr [rcx+rax*8], rdi
    inc eax
    mov byte ptr [rip+msg_n], al
1:  ret

# msg_begin(rdi=first, esi=mode)  mode 0 dialog, 1 battle, 2 yes/no
.globl msg_begin
msg_begin:
    cmp rdi, 0x400000                    # sanity: a real string pointer
    jae 8f
    push rdi
    mov edi, '!'
    call dbg_mark
    pop rdi
    push rdi
    call dbg_hex
    pop rdi
    lea rdi, [rip+str_corrupt]
8:  mov qword ptr [rip+tb_ptr], rdi
    mov byte ptr [rip+tb_mode], sil
    mov byte ptr [rip+tb_active], 1
    mov word ptr [rip+tb_reveal], 0
    mov byte ptr [rip+tb_delay], MSG_SPEED
    mov byte ptr [rip+ch_sel], 0
    mov byte ptr [rip+ch_res], 0
    mov byte ptr [rip+tb_choice], 0
    cmp esi, 2
    jne 1f
    mov byte ptr [rip+tb_choice], 1
1:  mov rdi, qword ptr [rip+tb_ptr]
    call tb_page_len
    mov word ptr [rip+tb_len], ax
    ret

str_corrupt: .asciz "?? MESSAGE ERROR ??"

# msg_show(rdi=str, esi=mode): single message, replaces the queue
.globl msg_show
msg_show:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    call msg_clear
    mov rdi, rbx
    call msg_push
    mov rdi, rbx
    mov esi, r12d
    call msg_begin
    pop r12
    pop rbx
    ret

# msg_begin_queue(esi=mode): show the whole queue
.globl msg_begin_queue
msg_begin_queue:
    cmp byte ptr [rip+msg_n], 0
    je 1f
    lea rcx, [rip+msg_q]
    mov rdi, qword ptr [rcx]
    jmp msg_begin
1:  ret

.globl msg_active_p
msg_active_p:
    movzx eax, byte ptr [rip+tb_active]
    ret

.globl tb_page_len
tb_page_len:                             # rdi=str -> eax glyphs in page
    xor eax, eax
1:  movzx edx, byte ptr [rdi]
    test dl, dl
    jz 4f
    cmp dl, 0x0c
    je 4f
    inc eax
    cmp dl, 0xc0
    jb 2f
    cmp dl, 0xe0
    jb 3f
    add rdi, 3
    jmp 1b
3:  add rdi, 2
    jmp 1b
2:  inc rdi
    jmp 1b
4:  ret

.globl tb_page_last_p
tb_page_last_p:                          # rdi=str -> eax=1 when this page is the last
    push rdi
    call tb_page_end
    movzx ecx, byte ptr [rax]
    xor eax, eax
    test ecx, ecx
    setz al
    pop rdi
    ret

.globl tb_page_end
tb_page_end:                             # rdi=str -> rax ptr to \f or NUL
    mov rax, rdi
1:  movzx edx, byte ptr [rax]
    test dl, dl
    jz 3f
    cmp dl, 0x0c
    je 3f
    cmp dl, 0xc0
    jb 2f
    cmp dl, 0xe0
    jb 4f
    add rax, 3
    jmp 1b
4:  add rax, 2
    jmp 1b
2:  inc rax
    jmp 1b
3:  ret

# tb_render(rdi=str, esi=reveal count, edx=x, ecx=y, r8d=wrap width, r9d=attr)
.globl tb_render
tb_render:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r8d
    mov ebx, r9d
    xor r10d, r10d                       # glyph index
    xor r11d, r11d                       # column
    xor r9d, r9d                         # row
.Ltr_loop:
    movzx eax, byte ptr [r12]
    test al, al
    jz .Ltr_done
    cmp al, 0x0c
    je .Ltr_done
    cmp al, 0x0a
    jne .Ltr_glyph
    inc r10d
    xor r11d, r11d
    inc r9d
    inc r12
    jmp .Ltr_loop
.Ltr_glyph:
    mov ecx, 1
    cmp al, 0xc0
    jb 1f
    mov ecx, 2
    cmp al, 0xe0
    jb 1f
    mov ecx, 3
1:  mov r8d, ecx
    cmp r10d, r13d
    jae 2f
    push r8
    push r9
    push r10
    push r11
    mov edi, r14d
    add edi, r11d
    mov esi, r15d
    add esi, r9d
    mov rdx, r12
    mov ecx, r8d
    mov r8d, ebx
    call fb_putn
    pop r11
    pop r10
    pop r9
    pop r8
2:  inc r10d
    inc r11d
    add r12, r8
    cmp r11d, ebp
    jb .Ltr_loop
    xor r11d, r11d
    inc r9d
    jmp .Ltr_loop
.Ltr_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# msg_frame(): one frame of dialogue. eax=1 active, 0 finished
.globl msg_frame
msg_frame:
    cmp byte ptr [rip+tb_active], 0
    jne 1f
    xor eax, eax
    ret
1:  push rbx
    cmp byte ptr [rip+tb_delay], 0
    je 2f
    dec byte ptr [rip+tb_delay]
    jmp .Lmf_input
2:  movzx eax, word ptr [rip+tb_reveal]
    movzx ecx, word ptr [rip+tb_len]
    cmp eax, ecx
    jae .Lmf_input
    inc word ptr [rip+tb_reveal]
    mov byte ptr [rip+tb_delay], MSG_SPEED
.Lmf_input:
    movzx eax, byte ptr [rip+key_dlg]
    movzx ecx, word ptr [rip+tb_reveal]
    movzx edx, word ptr [rip+tb_len]
    cmp ecx, edx
    jb .Lmf_paint
    cmp byte ptr [rip+tb_choice], 1
    jne .Lmf_plain
    push rax
    mov rdi, qword ptr [rip+tb_ptr]
    call tb_page_last_p
    mov ecx, eax
    pop rax
    test ecx, ecx
    jz .Lmf_plain
    cmp eax, K_UP
    je .Lmf_tog
    cmp eax, K_DOWN
    je .Lmf_tog
    cmp eax, K_LEFT
    je .Lmf_tog
    cmp eax, K_RIGHT
    je .Lmf_tog
    cmp eax, K_A
    je .Lmf_yes
    cmp eax, K_START
    je .Lmf_yes
    cmp eax, K_B
    je .Lmf_no
    jmp .Lmf_paint
.Lmf_tog:
    movzx ecx, byte ptr [rip+ch_sel]
    xor ecx, 1
    mov byte ptr [rip+ch_sel], cl
    jmp .Lmf_paint
.Lmf_yes:
    mov byte ptr [rip+ch_res], 1
    jmp .Lmf_next
.Lmf_no:
    mov byte ptr [rip+ch_res], 0
    jmp .Lmf_next
.Lmf_plain:
    cmp eax, K_A
    je .Lmf_adv
    cmp eax, K_START
    je .Lmf_adv
    cmp eax, K_B
    je .Lmf_adv
    jmp .Lmf_paint
.Lmf_adv:
    mov rdi, qword ptr [rip+tb_ptr]
    call tb_page_end
    cmp byte ptr [rax], 0x0c
    jne .Lmf_next
    inc rax
    mov qword ptr [rip+tb_ptr], rax
    mov word ptr [rip+tb_reveal], 0
    mov byte ptr [rip+tb_delay], MSG_SPEED
    mov rdi, rax
    call tb_page_len
    mov word ptr [rip+tb_len], ax
    jmp .Lmf_paint
.Lmf_next:
    movzx eax, byte ptr [rip+msg_i]
    inc eax
    movzx ecx, byte ptr [rip+msg_n]
    cmp eax, ecx
    jae .Lmf_end
    mov byte ptr [rip+msg_i], al
    lea rcx, [rip+msg_q]
    mov rdi, qword ptr [rcx+rax*8]
    mov esi, 0
    call msg_begin
    jmp .Lmf_paint
.Lmf_end:
    mov byte ptr [rip+tb_active], 0
.Lmf_paint:
    call tb_paint
    movzx eax, byte ptr [rip+tb_active]
    pop rbx
    ret

.globl tb_paint
tb_paint:
    push rbx
    mov edi, TXB_X
    mov esi, TXB_Y
    mov edx, TXB_W
    mov ecx, TXB_H
    mov r8d, A_BOX
    call fb_box
    mov edi, TXB_X+1
    mov esi, TXB_Y+1
    mov edx, TXB_W-2
    mov ecx, TXB_H-2
    lea r8, [rip+g_space]
    mov r9d, A_NORM
    call fb_fill
    mov rdi, qword ptr [rip+tb_ptr]
    movzx esi, word ptr [rip+tb_reveal]
    mov edx, TXT_X
    mov ecx, TXT_Y
    mov r8d, TXT_W
    mov r9d, A_NORM
    call tb_render
    movzx eax, word ptr [rip+tb_reveal]
    movzx ecx, word ptr [rip+tb_len]
    cmp eax, ecx
    jb .Ltp_done
    cmp byte ptr [rip+tb_choice], 0
    je .Ltp_arrow
    mov rdi, qword ptr [rip+tb_ptr]
    call tb_page_last_p
    test eax, eax
    jz .Ltp_arrow
    mov edi, TXB_X+TXB_W-12
    mov esi, TXB_Y+2
    mov edx, 10
    mov ecx, 4
    mov r8d, A_BOX
    call fb_box
    mov edi, TXB_X+TXB_W-10
    mov esi, TXB_Y+3
    lea rdx, [rip+str_yes]
    mov ecx, A_NORM
    call fb_puts
    mov edi, TXB_X+TXB_W-10
    mov esi, TXB_Y+4
    lea rdx, [rip+str_no]
    mov ecx, A_NORM
    call fb_puts
    mov esi, TXB_Y+3
    cmp byte ptr [rip+ch_sel], 0
    je 1f
    mov esi, TXB_Y+4
1:  mov edi, TXB_X+TXB_W-12
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    jmp .Ltp_done
.Ltp_arrow:
    movzx eax, word ptr [rip+fcount]
    and eax, 16
    jz .Ltp_done
    mov edi, TXB_X+TXB_W-4
    mov esi, TXB_Y+TXB_H-2
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
.Ltp_done:
    pop rbx
    ret

# ============================================================ UI PRIMITIVES ==
# draw_hpbar(edi=x, esi=y, edx=width, ecx=cur, r8d=max)
.globl draw_hpbar
draw_hpbar:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx                     # cur
    mov ebp, r8d                      # max
    # empty track: dashes, so the filled part stands out even in a text dump
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, 1
    lea r8, [rip+g_h]
    mov r9d, A_DIM
    call fb_fill
    xor ebx, ebx
    test ebp, ebp
    jz .Lhb_done
    # filled width = width * cur / max (rounded up so it never shows empty early)
    mov eax, r14d
    imul eax, r15d
    xor edx, edx
    mov ecx, ebp
    div ecx
    mov ebx, eax
    test r15d, r15d
    jz .Lhb_done
    test ebx, ebx
    jnz 1f
    mov ebx, 1
1:  # colour: pct = cur*100/max
    mov eax, r15d
    imul eax, eax, 100
    xor edx, edx
    div ebp
    mov r9d, A_GREEN
    cmp eax, 20
    ja 2f
    mov r9d, A_RED
    jmp 3f
2:  cmp eax, 50
    ja 3f
    mov r9d, A_HILIGHT
3:  mov edi, r12d
    mov esi, r13d
    mov edx, ebx
    mov ecx, 1
    lea r8, [rip+g_eq]
    call fb_fill
.Lhb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# panel(edi=x, esi=y, edx=w, ecx=h, r8d=attr): framed box w/ cleared interior
.globl panel
panel:
    push rbx
    mov r8d, r8d
    call fb_box
    pop rbx
    ret

# draw_entity(edi=px, esi=py, rdx=top glyph, rcx=bottom glyph, r8d=attr_top, r9d=attr_bot)
# draws a 2x2 glyph sprite: useful for the player and NPCs.
.globl draw_entity
draw_entity:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14, rdx
    mov r15, rcx
    mov ebx, r8d
    mov ebp, r9d
    # top row
    mov edi, r12d
    mov esi, r13d
    mov rdx, r14
    mov ecx, ebx
    call fb_putg
    mov edi, r12d
    inc edi
    mov esi, r13d
    mov rdx, r14
    mov ecx, ebx
    call fb_putg
    # bottom row
    mov edi, r12d
    mov esi, r13d
    inc esi
    mov rdx, r15
    mov ecx, ebp
    call fb_putg
    mov edi, r12d
    inc edi
    mov esi, r13d
    inc esi
    mov rdx, r15
    mov ecx, ebp
    call fb_putg
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# label_u(edi=x, esi=y, edx=value, ecx=width, r8d=attr) -> right aligned
.globl label_u
label_u:
    jmp fb_putu

# vim: sw=4 ts=4
