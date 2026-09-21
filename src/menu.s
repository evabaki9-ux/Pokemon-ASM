# ============================================================================
#  menu.s - pause menu, party screen, bag, pokedex, save
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

.set MB_X, 46
.set MB_Y, 1
.set MB_W, 32
.set MB_H, 11

.section .rodata
str_optmsg:  .asciz "OPTION\fTEXT SPEED: FAST\fBATTLE STYLE:\nSHIFT\fFRAME SKIP: OFF\f(everything is\nhardcoded. this\nis assembly.)"
str_playermsg: .asciz "PLAYER: RED\fBADGES: 0\nMONEY: 3000\fPOKeDEX: %d%%\fStill needs to\nbeat RIVAL."
str_savemsg: .asciz "Your progress\nhas been saved!"
str_savefail: .asciz "Saving failed.\n(disk? permissions?)"
str_noparty: .asciz "You have no\nPOKeMON yet!"
str_ball_no: .asciz "You can't use\nthat right now!"
str_potion_full: .asciz "It won't have\nany effect."
str_mon_fainted:.asciz "\fThis POKeMON has\nfainted."
str_used_potion: .asciz " used a POTION!\f"
str_rec20:   .asciz " recovered\n20 HP!"
str_summary: .asciz "STATS"
str_hp_abbr: .asciz "HP"
str_atk_abbr:.asciz "ATTACK"
str_def_abbr:.asciz "DEFENSE"
str_spd_abbr:.asciz "SPEED"
str_xp_abbr: .asciz "EXP"
str_moves_hdr: .asciz "MOVES"
str_pp_hdr:  .asciz "PP"
str_dex_hdr: .asciz "POKeDEX"
str_dex_seen:.asciz "SEEN"
str_dex_caught:.asciz "CAUGHT"
str_no_data: .asciz "No data yet."
str_menu_hdr: .asciz "MENU"
str_close:   .asciz "X: close"
str_nothing: .asciz "Nothing to do\nhere."

.section .bss
.globl menu_sel, party_sel, bag_sel, dex_sel, sum_sel
menu_sel:  .byte 0
party_sel: .byte 0
bag_sel:   .byte 0
dex_sel:   .byte 0
sum_sel:   .byte 0

.section .text
# ================================================================ MENU ======
.globl menu_frame
menu_frame:
    push rbx
    call ow_draw
    mov edi, MB_X
    mov esi, MB_Y
    mov edx, MB_W
    mov ecx, MB_H
    mov r8d, A_BOX
    call fb_box
    mov edi, MB_X+1
    mov esi, MB_Y+1
    mov edx, MB_W-2
    mov ecx, MB_H-2
    lea r8, [rip+g_space]
    mov r9d, A_NORM
    call fb_fill
    lea rdx, [rip+str_menu_hdr]
    mov edi, MB_X+2
    mov esi, MB_Y+1
    mov ecx, A_HILIGHT
    call fb_puts
    xor ebx, ebx
.Lmn_loop:
    cmp ebx, 7
    jae .Lmn_cursor
    lea rcx, [rip+menu_labels]
    mov rdx, qword ptr [rcx+rbx*8]
    mov edi, MB_X+4
    mov esi, MB_Y+3
    add esi, ebx
    mov ecx, A_NORM
    call fb_puts
    inc ebx
    jmp .Lmn_loop
.Lmn_cursor:
    movzx eax, byte ptr [rip+menu_sel]
    mov esi, MB_Y+3
    add esi, eax
    mov edi, MB_X+2
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    lea rdx, [rip+str_close]
    mov edi, MB_X+2
    mov esi, MB_Y+MB_H-2
    mov ecx, A_DIM
    call fb_puts
    # input
    movzx eax, byte ptr [rip+key]
    cmp eax, K_UP
    je .Lmn_up
    cmp eax, K_DOWN
    je .Lmn_down
    cmp eax, K_START
    je .Lmn_close
    cmp eax, K_B
    je .Lmn_close
    cmp eax, K_A
    je .Lmn_pick
    pop rbx
    ret
.Lmn_up:
    movzx eax, byte ptr [rip+menu_sel]
    test eax, eax
    jnz 1f
    mov eax, 7
1:  dec eax
    mov byte ptr [rip+menu_sel], al
    pop rbx
    ret
.Lmn_down:
    movzx eax, byte ptr [rip+menu_sel]
    inc eax
    cmp eax, 7
    jb 1f
    xor eax, eax
1:  mov byte ptr [rip+menu_sel], al
    pop rbx
    ret
.Lmn_close:
    mov byte ptr [rip+game_state], ST_OVERWORLD
    pop rbx
    ret
.Lmn_pick:
    movzx eax, byte ptr [rip+menu_sel]
    cmp eax, 0
    je .Lmn_dex
    cmp eax, 1
    je .Lmn_party
    cmp eax, 2
    je .Lmn_bag
    cmp eax, 3
    je .Lmn_player
    cmp eax, 4
    je .Lmn_save
    cmp eax, 5
    je .Lmn_option
    mov byte ptr [rip+game_state], ST_OVERWORLD
    pop rbx
    ret
.Lmn_dex:
    mov byte ptr [rip+dex_sel], 0
    mov byte ptr [rip+game_state], ST_DEX
    pop rbx
    ret
.Lmn_party:
    mov byte ptr [rip+party_sel], 0
    mov byte ptr [rip+sub], 0
    mov byte ptr [rip+game_state], ST_PARTY
    pop rbx
    ret
.Lmn_bag:
    mov byte ptr [rip+bag_sel], 0
    mov byte ptr [rip+game_state], ST_BAG
    pop rbx
    ret
.Lmn_player:
    lea rdi, [rip+str_playermsg]
    mov esi, 0
    call msg_show
    pop rbx
    ret
.Lmn_option:
    lea rdi, [rip+str_optmsg]
    mov esi, 0
    call msg_show
    pop rbx
    ret
.Lmn_save:
    call save_write
    test eax, eax
    jz 1f
    lea rdi, [rip+str_savemsg]
    mov esi, 0
    call msg_show
    pop rbx
    ret
1:  lea rdi, [rip+str_savefail]
    mov esi, 0
    call msg_show
    pop rbx
    ret

.section .rodata
.globl menu_labels
menu_labels: .quad str_pokedex, str_pokemon_m, str_bag_m, str_player_m, str_save_m, str_option_m, str_exit_m
.section .text

# =============================================================== PARTY ======
.globl party_frame
party_frame:
    push rbx
    push r12
    call ow_draw
    cmp byte ptr [rip+sub], 1
    je .Lpf_summary
    mov edi, 2
    mov esi, 1
    mov edx, 46
    mov ecx, 12
    mov r8d, A_BOX
    call fb_box
    lea rdx, [rip+str_menu_pokemon]
    mov edi, 4
    mov esi, 1
    mov ecx, A_HILIGHT
    call fb_puts
    movzx r12d, byte ptr [rip+party_n]
    test r12d, r12d
    jnz 1f
    lea rdx, [rip+str_noparty]
    mov edi, 4
    mov esi, 4
    mov ecx, A_NORM
    call fb_puts
1:  xor ebx, ebx
.Lpf_loop:
    cmp ebx, r12d
    jae .Lpf_cursor
    mov edi, ebx
    call party_mon
    mov rdi, rax
    push rax
    call mon_name
    mov rdx, rax
    mov edi, 6
    mov esi, 3
    add esi, ebx
    mov ecx, A_NORM
    call fb_puts
    pop rbx
    # level
    lea rdx, [rip+str_lv]
    mov edi, 22
    mov esi, 3
    add esi, ebx
    mov ecx, A_NORM
    push rbx
    call fb_puts
    movzx edx, byte ptr [rbx+M_LEVEL]
    mov edi, 24
    mov esi, 3
    add esi, ebx
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    # hp bar
    mov edi, 28
    mov esi, 3
    add esi, ebx
    mov edx, 12
    movzx ecx, word ptr [rbx+M_HP]
    movzx r8d, word ptr [rbx+M_MAXHP]
    call draw_hpbar
    movzx edx, word ptr [rbx+M_HP]
    mov edi, 41
    mov esi, 3
    add esi, ebx
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    pop rbx
    inc ebx
    jmp .Lpf_loop
.Lpf_cursor:
    movzx eax, byte ptr [rip+party_sel]
    mov esi, 3
    add esi, eax
    mov edi, 4
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    lea rdx, [rip+str_party_hint]
    mov edi, 4
    mov esi, 12
    mov ecx, A_DIM
    call fb_puts
    movzx eax, byte ptr [rip+key]
    cmp eax, K_UP
    je .Lpf_up
    cmp eax, K_DOWN
    je .Lpf_down
    cmp eax, K_A
    je .Lpf_open
    cmp eax, K_B
    je .Lpf_back
    cmp eax, K_START
    je .Lpf_back
    pop r12
    pop rbx
    ret
.Lpf_up:
    movzx eax, byte ptr [rip+party_sel]
    test eax, eax
    jnz 1f
    mov eax, r12d
1:  dec eax
    mov byte ptr [rip+party_sel], al
    pop r12
    pop rbx
    ret
.Lpf_down:
    movzx eax, byte ptr [rip+party_sel]
    inc eax
    cmp eax, r12d
    jb 1f
    xor eax, eax
1:  mov byte ptr [rip+party_sel], al
    pop r12
    pop rbx
    ret
.Lpf_open:
    cmp r12d, 0
    je 1f
    mov byte ptr [rip+sub], 1
1:  pop r12
    pop rbx
    ret
.Lpf_back:
    mov byte ptr [rip+game_state], ST_OVERWORLD
    pop r12
    pop rbx
    ret
.Lpf_summary:
    movzx edi, byte ptr [rip+party_sel]
    call party_mon
    mov rbx, rax
    mov edi, 46
    mov esi, 1
    mov edx, 32
    mov ecx, 16
    mov r8d, A_BOX
    call fb_box
    mov rdi, rbx
    call mon_name
    mov rdx, rax
    mov edi, 48
    mov esi, 2
    mov ecx, A_HILIGHT
    call fb_puts
    lea rdx, [rip+str_lv]
    mov edi, 48
    mov esi, 3
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rbx+M_LEVEL]
    mov edi, 50
    mov esi, 3
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    # type
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    movzx eax, byte ptr [rax+S_T1]
    mov edi, eax
    call type_name
    mov rdx, rax
    mov edi, 60
    mov esi, 3
    mov ecx, A_NORM
    call fb_puts
    # hp
    lea rdx, [rip+str_hp]
    mov edi, 48
    mov esi, 5
    mov ecx, A_NORM
    call fb_puts
    mov edi, 51
    mov esi, 5
    mov edx, 18
    movzx ecx, word ptr [rbx+M_HP]
    movzx r8d, word ptr [rbx+M_MAXHP]
    call draw_hpbar
    movzx edx, word ptr [rbx+M_HP]
    mov edi, 70
    mov esi, 5
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+g_slash]
    mov edi, 73
    mov esi, 5
    mov ecx, A_NORM
    call fb_puts
    movzx edx, word ptr [rbx+M_MAXHP]
    mov edi, 74
    mov esi, 5
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    # stats
    lea rdx, [rip+str_atk_abbr]
    mov edi, 48
    mov esi, 7
    mov ecx, A_DIM
    call fb_puts
    movzx edx, word ptr [rbx+M_ATK]
    mov edi, 60
    mov esi, 7
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_def_abbr]
    mov edi, 48
    mov esi, 8
    mov ecx, A_DIM
    call fb_puts
    movzx edx, word ptr [rbx+M_DEF]
    mov edi, 60
    mov esi, 8
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_spd_abbr]
    mov edi, 48
    mov esi, 9
    mov ecx, A_DIM
    call fb_puts
    movzx edx, word ptr [rbx+M_SPD]
    mov edi, 60
    mov esi, 9
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_xp_abbr]
    mov edi, 48
    mov esi, 10
    mov ecx, A_DIM
    call fb_puts
    movzx edx, word ptr [rbx+M_XP]
    mov edi, 60
    mov esi, 10
    mov ecx, 5
    mov r8d, A_NORM
    call fb_putu
    # moves
    lea rdx, [rip+str_moves_hdr]
    mov edi, 48
    mov esi, 12
    mov ecx, A_HILIGHT
    call fb_puts
    xor r12d, r12d
2:  cmp r12d, 4
    jae .Lpf_msum_done
    movzx eax, byte ptr [rbx+M_MOVES+r12]
    test eax, eax
    jz .Lpf_msum_done
    cmp r12d, 0
    je 3f
    movzx ecx, byte ptr [rbx+M_MOVES+r12-1]
    test ecx, ecx
    jz .Lpf_msum_done
3:  shl eax, 4
    lea rcx, [rip+move_table]
    mov rdx, qword ptr [rcx+rax+V_NAME]
    push rdx
    mov edi, 48
    mov esi, 13
    add esi, r12d
    mov ecx, A_NORM
    call fb_puts
    pop rdx
    movzx eax, byte ptr [rbx+M_PP+r12]
    mov byte ptr [rip+numbuf], al
    mov edi, 70
    mov esi, 13
    add esi, r12d
    mov ecx, 2
    mov r8d, A_DIM
    movzx edx, byte ptr [rbx+M_PP+r12]
    call fb_putu
    inc r12d
    jmp 2b
.Lpf_msum_done:
    lea rdx, [rip+str_summary_hint]
    mov edi, 4
    mov esi, 14
    mov ecx, A_DIM
    call fb_puts
    movzx eax, byte ptr [rip+key]
    cmp eax, K_B
    je 1f
    cmp eax, K_A
    je 1f
    cmp eax, K_START
    je 1f
    pop r12
    pop rbx
    ret
1:  mov byte ptr [rip+sub], 0
    pop r12
    pop rbx
    ret

.section .rodata
str_party_hint: .asciz "Z: summary     X: back"
str_summary_hint: .asciz "X: back"
str_menu_pokemon: .asciz "POKeMON"
.section .text

# ================================================================= BAG ======
.globl bag_frame
bag_frame:
    push rbx
    call ow_draw
    mov edi, 4
    mov esi, 3
    mov edx, 40
    mov ecx, 8
    mov r8d, A_BOX
    call fb_box
    lea rdx, [rip+str_bag_m]
    mov edi, 6
    mov esi, 3
    mov ecx, A_HILIGHT
    call fb_puts
    lea rdx, [rip+str_potion]
    mov edi, 8
    mov esi, 5
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rip+bag_potion]
    mov edi, 30
    mov esi, 5
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_pokeball_u]
    mov edi, 8
    mov esi, 6
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rip+bag_ball]
    mov edi, 30
    mov esi, 6
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    movzx eax, byte ptr [rip+bag_sel]
    add eax, 5
    mov esi, eax
    mov edi, 6
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    lea rdx, [rip+str_bag_hint]
    mov edi, 6
    mov esi, 9
    mov ecx, A_DIM
    call fb_puts
    movzx eax, byte ptr [rip+key]
    cmp eax, K_B
    je .Lbg_out
    cmp eax, K_START
    je .Lbg_out
    cmp eax, K_UP
    je .Lbg_dir
    cmp eax, K_DOWN
    je .Lbg_dir
    cmp eax, K_A
    je .Lbg_use
    pop rbx
    ret
.Lbg_out:
    mov byte ptr [rip+game_state], ST_MENU
    pop rbx
    ret
.Lbg_dir:
    movzx eax, byte ptr [rip+bag_sel]
    xor eax, 1
    mov byte ptr [rip+bag_sel], al
    pop rbx
    ret
.Lbg_use:
    cmp byte ptr [rip+bag_sel], 0
    jne .Lbg_ball
    cmp byte ptr [rip+bag_potion], 0
    jne 1f
    lea rdi, [rip+str_bagempty]
    mov esi, 0
    call msg_show
    pop rbx
    ret
1:  call lead_mon
    test rax, rax
    jz 9f
    mov rbx, rax
    movzx eax, word ptr [rbx+M_HP]
    cmp ax, word ptr [rbx+M_MAXHP]
    jae 2f
    dec byte ptr [rip+bag_potion]
    add ax, 20
    cmp ax, word ptr [rbx+M_MAXHP]
    jbe 3f
    movzx eax, word ptr [rbx+M_MAXHP]
3:  mov word ptr [rbx+M_HP], ax
    mov rdi, rbx
    call mon_name
    mov rdx, rax
    mov edi, 0
    mov esi, 0
    mov ecx, 0
    # message: "<name> used a POTION!"
    call msg_clear
    mov rdi, rbx
    call mon_name
    lea rdi, [rip+msg_q]
    lea rdx, [rip+str_used_potion]
    # build with names is tedious; use a fixed message
    lea rdi, [rip+str_potion_used2]
    mov esi, 0
    call msg_show
    pop rbx
    ret
2:  lea rdi, [rip+str_potion_full]
    mov esi, 0
    call msg_show
    pop rbx
    ret
9:  lea rdi, [rip+str_noparty]
    mov esi, 0
    call msg_show
    pop rbx
    ret
.Lbg_ball:
    lea rdi, [rip+str_ball_no]
    mov esi, 0
    call msg_show
    pop rbx
    ret

.section .rodata
str_bag_hint: .asciz "Z: use     X: back"
str_potion_used2: .asciz "You used a\nPOTION!\fYour POKeMON\nrecovered 20 HP!"
.section .text

# =============================================================== DEX =======
.globl dex_frame
dex_frame:
    push rbx
    push r12
    call ow_draw
    mov edi, 2
    mov esi, 1
    mov edx, 44
    mov ecx, 16
    mov r8d, A_BOX
    call fb_box
    lea rdx, [rip+str_dex_hdr]
    mov edi, 4
    mov esi, 1
    mov ecx, A_HILIGHT
    call fb_puts
    lea rdx, [rip+str_dex_seen]
    mov edi, 26
    mov esi, 1
    mov ecx, A_DIM
    call fb_puts
    lea rdx, [rip+str_dex_caught]
    mov edi, 33
    mov esi, 1
    mov ecx, A_DIM
    call fb_puts
    xor ebx, ebx
.Ldx_loop:
    movzx eax, byte ptr [rip+n_species]
    cmp ebx, eax
    jae .Ldx_input
    # seen / caught
    mov edi, ebx
    xor esi, esi
    call dex_get
    mov r12d, eax
    mov edi, ebx
    mov esi, 1
    call dex_get
    # name
    mov edi, ebx
    call spec_name
    mov rdx, rax
    cmp r12d, 0
    jne 1f
    lea rdx, [rip+str_dashname]
1:  mov edi, 5
    mov esi, 3
    add esi, ebx
    mov ecx, A_NORM
    call fb_puts
    # seen mark
    cmp r12d, 0
    je 2f
    lea rdx, [rip+g_ball]
    mov edi, 28
    mov esi, 3
    add esi, ebx
    mov ecx, A_RED
    call fb_putg
2:  # caught mark
    test eax, eax
    lea rdx, [rip+g_ball]
    mov edi, 36
    mov esi, 3
    add esi, ebx
    mov ecx, A_HILIGHT
    call fb_putg
    inc ebx
    jmp .Ldx_loop
.Ldx_input:
    movzx eax, byte ptr [rip+key]
    cmp eax, K_B
    je 1f
    cmp eax, K_START
    je 1f
    pop r12
    pop rbx
    ret
1:  mov byte ptr [rip+game_state], ST_MENU
    pop r12
    pop rbx
    ret

.section .rodata
str_dashname: .asciz "-----"
.section .text

# vim: sw=4 ts=4
