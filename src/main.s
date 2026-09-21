# ============================================================================
#  main.s - main loop, title screen, PROF. OAK intro, starter selection
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"


.section .bss
.globl pend_evt, pend_arg, ow_dirty
pend_evt:     .byte 0
pend_arg:     .byte 0
ow_dirty:     .byte 0

.section .rodata
str_continue_q: .asciz "CONTINUE\fA saved game\nexists.\fContinue from\nthat journey?"
str_nosave_q:   .asciz "NEW GAME\fNo saved data\nfound.\fBegin a new\nadventure?"
str_choose_p:   .asciz "Choose your first partner!"
str_charm:      .asciz "CHARMANDER"
str_bulb:       .asciz "BULBASAUR"
str_squir:      .asciz "SQUIRTLE"
str_pickhint:   .asciz "Z: choose     Arrows: look"
str_intro_head: .asciz "PROF. OAK's POKeMON LAB"
str_copyright:  .asciz "hand-written x86-64 asm: no libc, no engine, raw syscalls"
str_ready:      .asciz "Your partner is with you. Head north to VIRIDIAN!"

.section .text
.globl main_loop
main_loop:
    call frame_wait
    inc word ptr [rip+fcount]
    call input_poll
    call kq_pop
    mov byte ptr [rip+key], al
    mov byte ptr [rip+key_dlg], al
    cmp byte ptr [rip+tb_active], 0
    je 1f
    mov byte ptr [rip+key], 0            # dialogue owns the input this frame
1:  movzx eax, byte ptr [rip+game_state]
    shl eax, 3
    lea rcx, [rip+state_table]
    mov rax, qword ptr [rcx+rax]
    call rax
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    # dialogue paints over whatever the handler drew
    cmp byte ptr [rip+tb_active], 0
    je .Lml_after
    call msg_frame
.Lml_after:
    cmp byte ptr [rip+key_dlg], K_QUIT
    jne .Lml_flip
    call term_restore
    mov eax, SYS_EXIT
    xor edi, edi
    syscall
.Lml_flip:
    call flip
    jmp main_loop

state_table:
    .quad title_frame, intro_frame, starter_frame, world_frame
    .quad world_frame, menu_frame, party_frame, bag_frame
    .quad dex_frame, battle_frame, quit_frame

.section .bss
rsp_ref: .quad 0
.section .text

quit_frame:
    call term_restore
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

# ================================================================ TITLE =====
title_frame:
    push rbx
    cmp byte ptr [rip+sub], 1
    jne .Lti_draw
    # we asked "continue?" - act on the answer
    cmp byte ptr [rip+tb_active], 0
    jne .Lti_wait
    cmp byte ptr [rip+ch_res], 0
    jne .Lti_load
    mov byte ptr [rip+sub], 0
    call new_game
    pop rbx
    ret
.Lti_load:
    mov byte ptr [rip+sub], 0
    call load_game
    pop rbx
    ret
.Lti_wait:
    pop rbx
    ret
.Lti_draw:
    # the generated sunset, cell by cell (see tools/art2cells.py)
    mov edi, C_BLACK
    call fb_clear
    xor edi, edi
    xor esi, esi
    lea rdx, [rip+art_title]
    movzx ecx, byte ptr [rip+art_title_w]
    movzx r8d, byte ptr [rip+art_title_h]
    call blit_art_hb
    # The wordmark is generated art now (art_logo: POKeMON over FIRE RED).
    # The scene is bright across the middle, so the logo goes in the dark band
    # along the bottom and the smaller labels go in the dark sky at the top.
    mov edi, 16
    mov esi, 15
    call draw_logo
    mov edi, 30
    mov esi, 13
    mov edx, 17
    mov ecx, 1
    lea r8, [rip+g_block]
    mov r9d, (C_BLACK<<4)|C_BLACK
    call fb_fill
    mov edi, 31
    mov esi, 13
    lea rdx, [rip+str_title3]
    mov ecx, (C_BLACK<<4)|C_BYELLOW
    call fb_puts
    # credits
    mov edi, 6
    mov esi, 22
    lea rdx, [rip+str_copyright]
    mov ecx, (C_BLACK<<4)|C_WHITE
    call fb_puts
    # prompt: blink it over its own black plate so it stays legible
    # whatever the art behind it is doing
    mov edi, 33
    mov esi, 0
    mov edx, 15
    mov ecx, 3
    lea r8, [rip+g_block]
    mov r9d, (C_BLACK<<4)|C_BLACK
    call fb_fill
    movzx eax, byte ptr [rip+fcount]
    and eax, 32
    jz 1f
    mov edi, 34
    mov esi, 1
    lea rdx, [rip+str_start]
    mov ecx, (C_BLACK<<4)|C_BWHITE
    call fb_puts
1:  movzx eax, byte ptr [rip+key]
    cmp eax, K_START
    je .Lti_go
    cmp eax, K_A
    je .Lti_go
    pop rbx
    ret
.Lti_go:
    mov byte ptr [rip+sub], 1
    cmp byte ptr [rip+has_save], 0
    je 2f
    lea rdi, [rip+str_continue_q]
    jmp 3f
2:  lea rdi, [rip+str_nosave_q]
3:  mov esi, 2
    call msg_show
    pop rbx
    ret

# ================================================================ INTRO =====
intro_frame:
    cmp byte ptr [rip+sub], 0
    jne .Lif_draw
    mov byte ptr [rip+sub], 1
    call msg_clear
    lea rdi, [rip+str_intro1]
    call msg_push
    lea rdi, [rip+str_intro2]
    call msg_push
    lea rdi, [rip+str_intro3]
    call msg_push
    mov esi, 0
    call msg_begin_queue
.Lif_draw:
    mov edi, C_BLACK
    call fb_clear
    mov edi, 0
    mov esi, 0
    mov edx, 80
    mov ecx, 1
    lea r8, [rip+g_space]
    mov r9d, A_MENUBG
    call fb_fill
    lea rdx, [rip+str_intro_head]
    mov edi, 1
    mov esi, 0
    mov ecx, A_MENUBG
    call fb_puts
    # four creatures watching Oak talk: generated art where we have it,
    # the old ASCII sprite for GEODUDE until its art lands
    mov edi, 4
    mov esi, 3
    mov edx, 5                          # ODDISH
    call art_blit_small
    mov edi, 34
    mov esi, 3
    mov edx, 3                          # PIDGEY
    call art_blit_small
    mov edi, 62
    mov esi, 3
    mov edx, 6                          # MEOWTH
    call art_blit_small
    mov edi, 4
    mov esi, 10
    mov edx, 4                          # RATTATA
    call art_blit_small
    mov edi, 34
    mov esi, 10
    mov edx, 8                          # MAGIKARP
    call art_blit_small
    mov edi, 62
    mov esi, 10
    mov edx, 9                          # GEODUDE
    call art_blit_small
    # Oak has finished talking -> on to the lab
    cmp byte ptr [rip+tb_active], 0
    jne 1f
    mov byte ptr [rip+sub], 0
    mov byte ptr [rip+sel], 0
    mov byte ptr [rip+game_state], ST_STARTER
1:  ret

# ============================================================== STARTER =====
starter_frame:
    push rbx
    push r12
    push r13
    cmp byte ptr [rip+sub], 1
    jne .Lsf_pick
    # confirmation step: msg_show handled the box; act on the answer
    cmp byte ptr [rip+tb_active], 0
    jne .Lsf_wait
    cmp byte ptr [rip+ch_res], 0
    jne .Lsf_give
    mov byte ptr [rip+sub], 0
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_give:
    call give_starter
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_wait:
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_pick:
    mov edi, C_BLACK
    call fb_clear
    lea rdx, [rip+str_choose_p]
    mov edi, 29
    mov esi, 1
    mov ecx, A_HILIGHT
    call fb_puts
    xor ebx, ebx
.Lsf_loop:
    cmp ebx, 3
    jae .Lsf_cursor
    mov eax, ebx
    imul eax, eax, 26
    add eax, 6
    mov edi, eax
    mov esi, 5
    mov edx, 22
    mov ecx, 9
    mov r8d, A_BOX
    call fb_box
    # creature art (12x8 cells -> centred in the 22x9 box: +5, +0)
    mov edi, ebx
    call starter_species_of
    cmp eax, 3                           # only the three starters have art
    jae .Lsf_drawn
    push rax
    mov eax, ebx
    imul eax, eax, 26
    add eax, 5                          # 12 wide in a 22 wide box: centred
    mov edi, eax
    mov esi, 4                          # 8 rows, so the name at y=12 is clear
    pop rdx
    call art_blit_big
.Lsf_drawn:
    # name under the sprite
    mov edi, ebx
    call starter_species_of
    mov edi, eax
    call spec_name
    mov rdx, rax
    mov eax, ebx
    imul eax, eax, 26
    add eax, 12
    mov edi, eax
    mov esi, 12
    mov ecx, A_NORM
    call fb_puts
    inc ebx
    jmp .Lsf_loop
.Lsf_cursor:
    movzx eax, byte ptr [rip+sel]
    imul eax, eax, 26
    add eax, 16
    mov edi, eax
    mov esi, 3
    lea rdx, [rip+g_more]
    mov ecx, A_HILIGHT
    call fb_putg
    lea rdx, [rip+str_pickhint]
    mov edi, 27
    mov esi, 20
    mov ecx, A_DIM
    call fb_puts
    # type names for the selected one
    movzx ebx, byte ptr [rip+sel]
    mov edi, ebx
    call starter_species_of
    mov edi, eax
    call spec_ptr
    movzx r12d, byte ptr [rax+S_T1]
    movzx r13d, byte ptr [rax+S_T2]
    mov edi, r12d
    call type_name
    mov rdx, rax
    mov edi, 6
    mov esi, 15
    mov ecx, A_DIM
    call fb_puts
    cmp r12d, r13d
    je 2f
    mov edi, r13d
    call type_name
    mov rdx, rax
    mov edi, 6
    mov esi, 16
    mov ecx, A_DIM
    call fb_puts
2:
    # input
    movzx eax, byte ptr [rip+key]
    cmp eax, K_LEFT
    je .Lsf_left
    cmp eax, K_RIGHT
    je .Lsf_right
    cmp eax, K_UP
    je .Lsf_left
    cmp eax, K_DOWN
    je .Lsf_right
    cmp eax, K_A
    je .Lsf_take
    cmp eax, K_START
    je .Lsf_take
    cmp eax, K_B
    je .Lsf_right
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_left:
    movzx eax, byte ptr [rip+sel]
    test eax, eax
    jnz 1f
    mov eax, 3
1:  dec eax
    mov byte ptr [rip+sel], al
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_right:
    movzx eax, byte ptr [rip+sel]
    inc eax
    cmp eax, 3
    jb 1f
    xor eax, eax
1:  mov byte ptr [rip+sel], al
    pop r13
    pop r12
    pop rbx
    ret
.Lsf_take:
    mov byte ptr [rip+sub], 1
    movzx eax, byte ptr [rip+sel]
    shl eax, 3
    lea rcx, [rip+starter_texts]
    mov rdi, qword ptr [rcx+rax]
    mov esi, 2
    call msg_show
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
starter_texts: .quad str_starter_a, str_starter_b, str_starter_c
# the three lab POKeMON, in the order they appear on the table
starter_species: .byte 0, 1, 2           # CHARMANDER, BULBASAUR, SQUIRTLE
.section .bss
sel_art: .quad 0
.section .text

# type_name(edi=type) -> rax
.globl type_name
type_name:
    mov eax, edi
    shl rax, 3
    lea rcx, [rip+type_names]
    mov rax, qword ptr [rcx+rax]
    ret


# spec_art(edi=species, esi=x, edx=y)
.globl spec_art
spec_art:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov edi, ebx
    call spec_typecol
    mov ecx, eax
    mov edi, ebx
    call spec_sprite
    mov rdx, rax
    mov edi, r12d
    mov esi, r13d
    call fb_puts
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================== NEW GAME ====
.globl new_game
new_game:
    mov byte ptr [rip+p_map], 0
    mov byte ptr [rip+p_dir], 0
    mov byte ptr [rip+party_n], 0
    mov byte ptr [rip+bag_potion], 0
    mov byte ptr [rip+bag_ball], 0
    mov byte ptr [rip+flags], 0
    mov word ptr [rip+money], 3000
    mov word ptr [rip+dex_seen], 0
    mov word ptr [rip+dex_caught], 0
    mov byte ptr [rip+rival_pick], 0
    mov word ptr [rip+steps], 0
    mov byte ptr [rip+sub], 0
    mov byte ptr [rip+sel], 0
    xor eax, eax
    lea rdi, [rip+map_items]
    mov ecx, 4
1:  mov byte ptr [rdi+rax], 0
    inc rax
    cmp rax, 4
    jb 1b
    mov byte ptr [rip+game_state], ST_INTRO
    ret

# load_game: restore save block and drop the player back into the world
.globl load_game
load_game:
    call save_read
    test eax, eax
    jz 1f
    call world_spawn_from_save
    mov byte ptr [rip+game_state], ST_OVERWORLD
    ret
1:  call new_game
    ret

# give_starter:
    # called after the player confirms a starter
.globl give_starter
give_starter:
    push rbx
    push r12
    movzx ebx, byte ptr [rip+sel]
    mov edi, ebx
    call starter_species_of
    mov r12d, eax                        # chosen species
    lea rdi, [rip+party]
    mov esi, eax
    mov edx, 5
    call mon_init
    mov byte ptr [rip+party_n], 1
    mov edi, r12d
    xor esi, esi
    call dex_set
    mov edi, r12d
    mov esi, 1
    call dex_set
    lea rcx, [rip+rival_cycle]
    movzx eax, byte ptr [rcx+rbx]
    mov byte ptr [rip+rival_pick], al
    lea rdi, [rip+en_party]
    mov esi, eax
    mov edx, 9                           # RIVAL's starter, a few levels ahead
    call mon_init
    lea rdi, [rip+en_party+M_SZ]
    mov esi, 4                           # PIDGEY
    mov edx, 7
    call mon_init
    mov byte ptr [rip+flags], 1          # starter taken
    movzx eax, byte ptr [rip+opt_level]
    test eax, eax
    jz 9f
    mov edi, eax                         # --level N: jump the starter to N
    call mon_set_level
9:  movzx esi, word ptr [rip+opt_xp]      # --xp N: a nudge towards a level-up
    test esi, esi
    jz 8f
    lea rdi, [rip+party]
    call mon_give_xp
8:
    # place the player at the start map spawn
    mov byte ptr [rip+p_map], 0
    xor edi, edi
    call map_spawn
    movzx ecx, byte ptr [rax+SP_X]
    movzx edx, byte ptr [rax+SP_Y]
    mov byte ptr [rip+p_x], cl
    mov byte ptr [rip+p_y], dl
    call ow_update_camera
    mov byte ptr [rip+game_state], ST_OVERWORLD
    mov byte ptr [rip+pend_evt], EV_READY
    pop r12
    pop rbx
    ret


rival_cycle: .byte 2, 0, 1               # fire->water, grass->fire, water->grass

# starter_species_of(edi=slot 0..2) -> eax species id
.globl starter_species_of
starter_species_of:
    mov eax, edi
    lea rcx, [rip+starter_species]
    movzx eax, byte ptr [rcx+rax]
    ret

# vim: sw=4 ts=4
