# ============================================================================
#  world.s -- overworld: 2x2-char tile renderer, walking, warps, NPCs, items
#
#  The play field is 40 tiles wide by 8 tiles tall (80x16 characters, rows
#  1..16).  Every tile is drawn as a 2x2 block of ASCII characters; the tile
#  background colour paints the block, the characters add the detail.
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

.set DIR_UP,     0
.set DIR_DOWN,   1
.set DIR_LEFT,   2
.set DIR_RIGHT,  3
.set TILE_SZ,    40                # bytes per tile_defs entry
.set ENT_SZ,     16                # bytes per map entity entry
.set SPR_SZ,     40                # bytes per ent_sprite_defs entry
.set TILE_OUT,   23                # index of the "nothing" tile
.set TILE_GRASS, 0
.set ENC_RATE,   14                # percent per step in tall grass
.set MOVE_DELAY, 4                 # frames between steps when a key is held
.set AUTO_T,     5                 # frames a direction keeps repeating

.section .bss
.align 16
.globl tile_buf
tile_buf:   .skip 2048             # working copy of the current map tiles
.globl oc_sel, oc_tile, oc_x, oc_y
oc_sel:     .byte 0
oc_tile:    .byte 0
oc_x:       .byte 0
oc_y:       .byte 0
map_loaded: .byte 0
ow_w:       .byte 0
ow_h:       .byte 0
autodir:    .byte 0
auto_t:     .byte 0

.section .rodata
dir_dx:     .byte 0, 0, -1, 1
dir_dy:     .byte -1, 1, 0, 0

str_ready:  .asciz "PROF. OAK\fTake good care\nof your new\npartner!\fWild POKeMON hide\nin tall grass.\fZ: talk/confirm\nX: cancel\nM: menu"
str_healed: .asciz "NURSE\fYour POKeMON are\nfighting fit!\fWe hope to see\nyou again!"
str_rival_again: .asciz "RIVAL\fI am training\nright here.\fGo get stronger\nfirst!"
str_whiteout:    .asciz "You have no\nPOKeMON that can\nfight!\f...You scurried\nto the POKeMON\nCENTER."
str_found_potion:.asciz "\fYou found a\nPOTION!\fIt went into\nyour BAG."
str_found_ball:  .asciz "\fYou found a\nPOKe BALL!\fIt went into\nyour BAG."
str_w_hp:   .asciz "HP"
str_w_steps:.asciz "STEPS"
str_w_none: .asciz "NO POKeMON YET"

.section .text

# ------------------------------------------------------------------ helpers --
# ow_tile(edi=x, esi=y) -> eax = tile char (0 when outside the map)
.globl ow_tile
ow_tile:
    cmp edi, 0
    jl 9f
    cmp esi, 0
    jl 9f
    movzx eax, byte ptr [rip+ow_w]
    cmp edi, eax
    jae 9f
    movzx eax, byte ptr [rip+ow_h]
    cmp esi, eax
    jae 9f
    movzx ecx, byte ptr [rip+ow_w]
    mov eax, esi
    imul eax, ecx
    add eax, edi
    lea rcx, [rip+tile_buf]
    movzx eax, byte ptr [rcx+rax]
    ret
9:  xor eax, eax
    ret

# ow_walkable_char(edi=char) -> eax = 1 when that tile can be walked on
ow_walkable_char:
    test edi, edi
    jz 9f
    lea rcx, [rip+char_to_tile]
    movzx eax, byte ptr [rcx+rdi]
    imul eax, eax, TILE_SZ
    lea rcx, [rip+tile_defs]
    movzx eax, byte ptr [rcx+rax+36]
    ret
9:  xor eax, eax
    ret

# ow_item_taken(edi=bit index) -> eax
ow_item_taken:
    mov eax, edi
    shr eax, 3
    lea rcx, [rip+map_items]
    movzx edx, byte ptr [rcx+rax]
    mov ecx, edi
    and ecx, 7
    shr edx, cl
    mov eax, edx
    and eax, 1
    ret

# ow_item_set(edi=bit index)
ow_item_set:
    mov r8d, edi
    shr r8d, 3
    mov ecx, edi
    and ecx, 7
    mov eax, 1
    shl eax, cl
    lea rcx, [rip+map_items]
    or byte ptr [rcx+r8], al
    ret

# ow_npc_at(edi=x, esi=y) -> rax = entity pointer or 0
.globl ow_npc_at
ow_npc_at:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_NPCS]
    test rbx, rbx
    jz 8f
1:  movzx eax, byte ptr [rbx]
    cmp eax, 0xff
    je 8f
    cmp eax, r12d
    jne 2f
    movzx eax, byte ptr [rbx+1]
    cmp eax, r13d
    jne 2f
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret
2:  add rbx, ENT_SZ
    jmp 1b
8:  xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# ow_load_map: copy the current map's tiles into tile_buf, hide taken items
.globl ow_load_map
ow_load_map:
    push rbx
    push r12
    push r13
    push r14
    push r15
    movzx edi, byte ptr [rip+p_map]
    call map_spawn
    mov rbx, rax
    movzx r12d, byte ptr [rbx+SP_W]
    movzx r13d, byte ptr [rbx+SP_H]
    mov byte ptr [rip+ow_w], r12b
    mov byte ptr [rip+ow_h], r13b
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov r14, rax
    mov rsi, qword ptr [r14+MT_TILES]
    lea rdi, [rip+tile_buf]
    mov ecx, r12d
    imul ecx, r13d
    cld
    xor eax, eax
6:  cmp eax, ecx
    jae 7f
    movzx edx, byte ptr [rsi+rax]
    mov byte ptr [rdi+rax], dl
    inc eax
    jmp 6b
7:
    # items already picked up stay picked up
    mov r15, qword ptr [r14+MT_ITEMS]
    test r15, r15
    jz .Lolm_items_done
    xor ebx, ebx                        # slot index
1:  movzx eax, byte ptr [r15]
    cmp eax, 0xff
    je .Lolm_items_done
    movzx edi, byte ptr [rip+p_map]
    shl edi, 1
    add edi, ebx
    call ow_item_taken
    test eax, eax
    jz 4f
    movzx eax, byte ptr [r15+1]         # y
    imul eax, r12d                      # * width
    movzx ecx, byte ptr [r15]           # x
    add eax, ecx
    lea rcx, [rip+tile_buf]
    mov byte ptr [rcx+rax], '.'
4:  add r15, ENT_SZ
    inc ebx
    jmp 1b
.Lolm_items_done:
    mov byte ptr [rip+map_loaded], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- camera ----
.globl ow_update_camera
ow_update_camera:
    push rbx
    movzx eax, byte ptr [rip+p_x]
    sub eax, VIEW_TW/2
    movzx ecx, byte ptr [rip+ow_w]
    sub ecx, VIEW_TW
    jle 1f
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  mov word ptr [rip+cam_x], ax
    movzx eax, byte ptr [rip+p_y]
    sub eax, VIEW_TH/2
    movzx ecx, byte ptr [rip+ow_h]
    sub ecx, VIEW_TH
    jle 3f
    cmp eax, ecx
    jle 3f
    mov eax, ecx
3:  test eax, eax
    jns 4f
    xor eax, eax
4:  mov word ptr [rip+cam_y], ax
    pop rbx
    ret

# ---------------------------------------------------------------- warps -----
# ow_do_warp(edi=map, esi=spawn x or 0xfe, edx=spawn y or 0xfe)
.globl ow_do_warp
ow_do_warp:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov ebx, edx
    movzx eax, byte ptr [rip+p_map]
    mov byte ptr [rip+back_map], al
    movzx eax, byte ptr [rip+p_x]
    mov byte ptr [rip+back_x], al
    movzx eax, byte ptr [rip+p_y]
    mov byte ptr [rip+back_y], al
    cmp r12d, 0xfe                       # door back outside
    jne 1f
    movzx r12d, byte ptr [rip+back_map]
    movzx r13d, byte ptr [rip+back_x]
    movzx ebx, byte ptr [rip+back_y]
    jmp 2f
1:  cmp r13d, 0xfe
    jne 2f
    movzx r13d, byte ptr [rip+p_x]
2:  cmp ebx, 0xfe
    jne 3f
    movzx ebx, byte ptr [rip+p_y]
3:  mov byte ptr [rip+p_map], r12b
    mov byte ptr [rip+p_x], r13b
    mov byte ptr [rip+p_y], bl
    call ow_load_map
    call ow_update_camera
    mov byte ptr [rip+ow_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

# ow_check_warp -> eax = 1 when the player was moved to another map
ow_check_warp:
    push rbx
    push r12
    push r13
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_LINKS]
    mov r12, rbx
    movzx r13d, byte ptr [rip+p_y]
    test r13d, r13d
    jnz 1f
    add r12, 0                           # north edge
    jmp .Lcw_edge
1:  movzx eax, byte ptr [rip+ow_h]
    dec eax
    cmp r13d, eax
    jne 2f
    lea r12, [rbx+3]                     # south edge
    jmp .Lcw_edge
2:  movzx r13d, byte ptr [rip+p_x]
    test r13d, r13d
    jnz 3f
    lea r12, [rbx+6]                     # west edge
    jmp .Lcw_edge
3:  movzx eax, byte ptr [rip+ow_w]
    dec eax
    cmp r13d, eax
    jne .Lcw_tiles
    lea r12, [rbx+9]                     # east edge
.Lcw_edge:
    movzx eax, byte ptr [r12]
    cmp eax, 0xff
    je .Lcw_tiles
    movzx edi, byte ptr [r12]
    movzx esi, byte ptr [r12+1]
    movzx edx, byte ptr [r12+2]
    call ow_do_warp
    mov eax, 1
    jmp .Lcw_done
.Lcw_tiles:
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_WARPS]
    test rbx, rbx
    jz .Lcw_no
    movzx r13d, byte ptr [rip+p_x]
.Lcw_scan:
    movzx eax, byte ptr [rbx]
    cmp eax, 0xff
    je .Lcw_no
    cmp eax, r13d
    jne .Lcw_next
    movzx eax, byte ptr [rbx+1]
    movzx ecx, byte ptr [rip+p_y]
    cmp eax, ecx
    jne .Lcw_next
    movzx edi, byte ptr [rbx+2]
    movzx esi, byte ptr [rbx+3]
    movzx edx, byte ptr [rbx+4]
    call ow_do_warp
    mov eax, 1
    jmp .Lcw_done
.Lcw_next:
    add rbx, 5
    jmp .Lcw_scan
.Lcw_no:
    xor eax, eax
.Lcw_done:
    pop r13
    pop r12
    pop rbx
    ret

# enc_table_for(edi=encounter group) -> rax = pointer to that group's row
enc_table_for:
    lea rax, [rip+enc_tables]
    lea rcx, [rip+enc_counts]
    xor esi, esi
1:  cmp esi, edi
    jae 2f
    movzx edx, byte ptr [rcx+rsi]
    add rax, rdx                         # rows are as long as their table
    inc esi
    jmp 1b
2:  ret

# ------------------------------------------------------------- encounters ---
ow_try_encounter:
    push rbx
    push r12
    push r14
    call rng_next
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp edx, ENC_RATE
    jae 9f
    # the group comes in from the tile the player stepped on (edi), so the
    # water holds MAGIKARP and the cave floor holds GEODUDE wherever they are
    mov r14d, edi                        # encounter group
    lea rcx, [rip+enc_counts]
    movzx ecx, byte ptr [rcx+r14]
    test ecx, ecx
    jz 9f
    mov r12d, ecx                        # species count
    mov rdi, r14
    call enc_table_for
    mov rbx, rax
    call rng_next                        # species roll (same draw count as ever)
    xor edx, edx
    div r12d
    movzx ebx, byte ptr [rbx+rdx]
    call rng_next
    xor edx, edx
    lea rcx, [rip+enc_levels]
    movzx r12d, byte ptr [rcx+r14*2]     # low
    movzx ecx, byte ptr [rcx+r14*2+1]    # high
    sub ecx, r12d
    inc ecx
    div ecx
    add edx, r12d
    mov byte ptr [rip+wild_spec], bl
    mov byte ptr [rip+wild_lvl], dl
    call battle_start_wild
9:  pop r14
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------------ step ----
# ow_try_move(edi=direction)
.globl ow_try_move
ow_try_move:
    push rbx
    push r12
    push r13
    movzx ebx, dil
    mov byte ptr [rip+p_dir], bl
    lea rcx, [rip+dir_dx]
    movsx r12d, byte ptr [rcx+rbx]
    movzx eax, byte ptr [rip+p_x]
    add r12d, eax                        # target x
    lea rcx, [rip+dir_dy]
    movsx r13d, byte ptr [rcx+rbx]
    movzx eax, byte ptr [rip+p_y]
    add r13d, eax                        # target y
    test r12d, r12d
    js .Ltm_block
    test r13d, r13d
    js .Ltm_block
    mov edi, r12d
    mov esi, r13d
    call ow_tile
    test eax, eax
    jz .Ltm_block
    mov edi, eax
    call ow_walkable_char
    test eax, eax
    jz .Ltm_block
    mov edi, r12d
    mov esi, r13d
    call ow_npc_at
    test rax, rax
    jnz .Ltm_block
    mov byte ptr [rip+p_x], r12b
    mov byte ptr [rip+p_y], r13b
    inc byte ptr [rip+steps]
    call ow_update_camera
    call ow_check_warp
    test eax, eax
    jnz .Ltm_done
    movzx edi, byte ptr [rip+p_x]       # what did we step on?
    movzx esi, byte ptr [rip+p_y]
    call ow_tile
    lea rcx, [rip+char_to_tile]
    movzx eax, byte ptr [rcx+rax]
    imul eax, eax, TILE_SZ
    lea rcx, [rip+tile_defs]
    movzx edi, byte ptr [rcx+rax+37]    # encounter group for this tile
    test edi, edi
    jz .Ltm_done
    call ow_try_encounter
.Ltm_done:
    jmp .Ltm_out
.Ltm_block:
.Ltm_out:
    pop r13
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------------ input ---
# ow_key_dir(edi=key) -> eax = direction or -1
ow_key_dir:
    mov eax, edi
    cmp eax, K_UP
    jne 1f
    xor eax, eax
    ret
1:  cmp eax, K_DOWN
    jne 2f
    mov eax, DIR_DOWN
    ret
2:  cmp eax, K_LEFT
    jne 3f
    mov eax, DIR_LEFT
    ret
3:  cmp eax, K_RIGHT
    jne 4f
    mov eax, DIR_RIGHT
    ret
4:  mov eax, -1
    ret

.globl ow_input
ow_input:
    push rbx
    movzx eax, byte ptr [rip+key]
    cmp eax, K_START
    jne .Loi_no_menu
    mov byte ptr [rip+menu_sel], 0
    mov byte ptr [rip+game_state], ST_MENU
    jmp .Loi_done
.Loi_no_menu:
    cmp eax, K_A
    jne 1f
    call ow_interact
    jmp .Loi_done
1:  mov edi, eax
    call ow_key_dir
    cmp eax, 0
    jl 2f
    mov bl, al
    cmp bl, byte ptr [rip+autodir]
    je 3f
    mov byte ptr [rip+autodir], bl
    mov byte ptr [rip+move_cd], 0
3:  mov byte ptr [rip+auto_t], AUTO_T
    jmp 4f
2:  movzx eax, byte ptr [rip+key]
    test eax, eax
    jz 4f
    mov byte ptr [rip+auto_t], 0
4:  cmp byte ptr [rip+move_cd], 0
    je 5f
    dec byte ptr [rip+move_cd]
    jmp .Loi_done
5:  cmp byte ptr [rip+auto_t], 0
    je .Loi_done
    dec byte ptr [rip+auto_t]
    movzx edi, byte ptr [rip+autodir]
    call ow_try_move
    mov byte ptr [rip+move_cd], MOVE_DELAY
    cmp byte ptr [rip+g_headless], 0
    je 6f
    mov byte ptr [rip+move_cd], 0        # scripted input: one step per key
6:  mov byte ptr [rip+auto_t], 0
.Loi_done:
    pop rbx
    ret

# ------------------------------------------------------------ interaction ---
.globl ow_interact
ow_interact:
    push rbx
    push r12
    push r13
    xor ebx, ebx
    movzx eax, byte ptr [rip+p_dir]
    mov ebx, eax
    lea rcx, [rip+dir_dx]
    movsx r12d, byte ptr [rcx+rbx]
    movzx eax, byte ptr [rip+p_x]
    add r12d, eax
    lea rcx, [rip+dir_dy]
    movsx r13d, byte ptr [rcx+rbx]
    movzx eax, byte ptr [rip+p_y]
    add r13d, eax
    test r12d, r12d
    js .Lit_done
    test r13d, r13d
    js .Lit_done
    mov edi, r12d
    mov esi, r13d
    call ow_npc_at
    test rax, rax
    jz .Lit_tile
    mov rbx, rax
    mov rdi, qword ptr [rbx+8]
    movzx eax, byte ptr [rbx+2]
    cmp eax, 1
    jne 1f
    mov byte ptr [rip+pend_evt], EV_NURSE
    jmp 3f
1:  cmp eax, 2
    jne 2f
    mov byte ptr [rip+pend_evt], EV_RIVAL
    jmp 3f
2:  mov byte ptr [rip+pend_evt], EV_NONE
3:  xor esi, esi
    call msg_show
    jmp .Lit_done
.Lit_tile:
    mov edi, r12d
    mov esi, r13d
    call ow_tile
    mov byte ptr [rip+oc_tile], al
    mov byte ptr [rip+oc_x], r12b
    mov byte ptr [rip+oc_y], r13b
    cmp al, '$'
    je .Lit_sign
    cmp al, '*'
    je .Lit_item
    jmp .Lit_done
.Lit_sign:
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_SIGNS]
    test rbx, rbx
    jz .Lit_done
1:  movzx eax, byte ptr [rbx]
    cmp eax, 0xff
    je .Lit_done
    cmp eax, r12d
    jne 2f
    movzx eax, byte ptr [rbx+1]
    cmp eax, r13d
    je 3f
2:  add rbx, ENT_SZ
    jmp 1b
3:  mov rdi, qword ptr [rbx+8]
    xor esi, esi
    call msg_show
    jmp .Lit_done
.Lit_item:
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_ITEMS]
    test rbx, rbx
    jz .Lit_done
    xor r12d, r12d                       # slot index
1:  movzx eax, byte ptr [rbx]
    cmp eax, 0xff
    je .Lit_done
    movzx ecx, byte ptr [rip+oc_x]
    cmp eax, ecx
    jne 2f
    movzx eax, byte ptr [rbx+1]
    movzx ecx, byte ptr [rip+oc_y]
    cmp eax, ecx
    je 3f
2:  add rbx, ENT_SZ
    inc r12d
    jmp 1b
3:  movzx eax, byte ptr [rbx+2]          # item id
    cmp eax, 0
    jne 4f
    inc byte ptr [rip+bag_potion]
    lea rdi, [rip+str_found_potion]
    jmp 5f
4:  inc byte ptr [rip+bag_ball]
    lea rdi, [rip+str_found_ball]
5:  push rdi
    movzx edi, byte ptr [rip+p_map]
    shl edi, 1
    add edi, r12d
    call ow_item_set
    pop rdi
    xor esi, esi
    call msg_show
    # the tile becomes plain floor
    movzx eax, byte ptr [rip+oc_y]
    movzx ecx, byte ptr [rip+ow_w]
    imul eax, ecx
    movzx ecx, byte ptr [rip+oc_x]
    add eax, ecx
    lea rcx, [rip+tile_buf]
    mov byte ptr [rcx+rax], '.'
.Lit_done:
    pop r13
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- pending ---
# ow_pending: events that fire once their dialogue has finished
.globl ow_pending
ow_pending:
    push rbx
    cmp byte ptr [rip+tb_active], 0
    jne .Lop_done
    movzx eax, byte ptr [rip+pend_evt]
    test eax, eax
    jz .Lop_done
    mov byte ptr [rip+pend_evt], EV_NONE
    cmp eax, EV_READY
    jne 1f
    lea rdi, [rip+str_ready]
    xor esi, esi
    call msg_show
    jmp .Lop_done
1:  cmp eax, EV_NURSE
    jne 2f
    call party_heal_all
    lea rdi, [rip+str_healed]
    xor esi, esi
    call msg_show
    jmp .Lop_done
2:  cmp eax, EV_RIVAL
    jne 3f
    test byte ptr [rip+flags], 2          # bit 1: RIVAL already beaten?
    jz 4f
    lea rdi, [rip+str_rival_again]
    xor esi, esi
    call msg_show
    jmp .Lop_done
4:  call battle_start_trainer
    jmp .Lop_done
3:  cmp eax, EV_WHITEOUT
    jne .Lop_done
    call party_heal_all
    mov byte ptr [rip+p_map], 3
    mov byte ptr [rip+p_x], 5
    mov byte ptr [rip+p_y], 7
    call ow_load_map
    call ow_update_camera
    lea rdi, [rip+str_whiteout]
    xor esi, esi
    call msg_show
.Lop_done:
    pop rbx
    ret

# ------------------------------------------------------------------ draw ----
# draw_cells(edi=x, esi=y, rdx=tile/sprite entry)
draw_cells:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdx
    mov r12d, edi
    mov r13d, esi
    xor r14d, r14d
.Ldc_loop:
    cmp r14d, 4
    jae .Ldc_done
    mov edi, r12d
    mov eax, r14d
    and eax, 1
    add edi, eax
    mov esi, r13d
    mov eax, r14d
    shr eax, 1
    add esi, eax
    mov rdx, qword ptr [rbx+r14*8]
    movzx ecx, byte ptr [rbx+32+r14]
    call fb_putg
    inc r14d
    jmp .Ldc_loop
.Ldc_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# draw_sprite(edi=x, esi=y, edx=sprite id) -- keeps the terrain background
draw_sprite:
    push rbx
    push r12
    push r13
    push r14
    imul rdx, rdx, SPR_SZ
    lea rbx, [rip+ent_sprite_defs]
    add rbx, rdx
    mov r12d, edi
    mov r13d, esi
    xor r14d, r14d
.Lds_loop:
    cmp r14d, 4
    jae .Lds_done
    mov edi, r12d
    mov eax, r14d
    and eax, 1
    add edi, eax
    mov esi, r13d
    mov eax, r14d
    shr eax, 1
    add esi, eax
    mov rdx, qword ptr [rbx+r14*8]
    movzx edx, byte ptr [rdx]
    movzx ecx, byte ptr [rbx+32+r14]
    call fb_putc_bg
    inc r14d
    jmp .Lds_loop
.Lds_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ow_draw_ents: NPCs of the current map, then the player
ow_draw_ents:
    push rbx
    push r12
    push r13
    push r14
    push r15
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rbx, qword ptr [rax+MT_NPCS]
    test rbx, rbx
    jz .Lde_player
    movsx r14d, word ptr [rip+cam_x]
    movsx r15d, word ptr [rip+cam_y]
.Lde_loop:
    movzx eax, byte ptr [rbx]
    cmp eax, 0xff
    je .Lde_player
    sub eax, r14d                        # tile x on screen
    js .Lde_next
    cmp eax, VIEW_TW
    jae .Lde_next
    mov r12d, eax
    movzx eax, byte ptr [rbx+1]
    sub eax, r15d
    js .Lde_next
    cmp eax, VIEW_TH
    jae .Lde_next
    mov r13d, eax
    shl r12d, 1
    shl r13d, 1
    add r13d, VIEW_PY
    movzx edx, byte ptr [rbx+3]
    mov edi, r12d
    mov esi, r13d
    call draw_sprite
.Lde_next:
    add rbx, ENT_SZ
    jmp .Lde_loop
.Lde_player:
    movsx eax, word ptr [rip+cam_x]
    movzx ecx, byte ptr [rip+p_x]
    sub ecx, eax
    js .Lde_done
    cmp ecx, VIEW_TW
    jae .Lde_done
    shl ecx, 1
    movsx eax, word ptr [rip+cam_y]
    movzx edx, byte ptr [rip+p_y]
    sub edx, eax
    js .Lde_done
    cmp edx, VIEW_TH
    jae .Lde_done
    shl edx, 1
    add edx, VIEW_PY
    mov edi, ecx
    mov esi, edx
    xor edx, edx                         # sprite 0 = the player
    call draw_sprite
.Lde_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# draw_topbar: row 0 -- map name + controls
.globl draw_topbar
draw_topbar:
    push rbx
    mov edi, 0
    mov esi, 0
    mov edx, SCR_W
    mov ecx, 1
    lea r8, [rip+g_space]
    mov r9d, A_TITLEB
    call fb_fill
    movzx edi, byte ptr [rip+p_map]
    call map_entry
    mov rdx, qword ptr [rax]
    mov edi, 1
    xor esi, esi
    mov ecx, A_TITLEB
    call fb_puts
    lea rdx, [rip+str_ctrl]
    mov edi, 46
    xor esi, esi
    mov ecx, A_TITLEB
    call fb_puts
    pop rbx
    ret

# draw_panel: the bottom status panel (rows 17..23), FireRed style:
# a white box with the lead POKeMON, its HP bar, the bag and the party.
.globl draw_panel
draw_panel:
    push rbx
    push r12
    push r13
    mov edi, 0
    mov esi, 17
    mov edx, SCR_W
    mov ecx, 7
    lea r8, [rip+g_space]
    mov r9d, A_MENUBG
    call fb_fill
    call lead_mon
    test rax, rax
    jz .Ldp_bag
    mov rbx, rax
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_name
    mov rdx, rax
    mov edi, 2
    mov esi, 18
    mov ecx, A_MENUBG
    call fb_puts
    lea rdx, [rip+str_lv_s]
    mov edi, 14
    mov esi, 18
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 17
    mov esi, 18
    movzx edx, byte ptr [rbx+M_LEVEL]
    mov ecx, 3
    mov r8d, A_MENUBG
    call fb_putu
    lea rdx, [rip+str_w_hp]
    mov edi, 22
    mov esi, 18
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 25
    mov esi, 18
    movzx edx, word ptr [rbx+M_HP]
    mov ecx, 3
    mov r8d, A_MENUBG
    call fb_putu
    lea rdx, [rip+g_slash_u]
    mov edi, 28
    mov esi, 18
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 29
    mov esi, 18
    movzx edx, word ptr [rbx+M_MAXHP]
    mov ecx, 3
    mov r8d, A_MENUBG
    call fb_putu
    mov edi, 34
    mov esi, 18
    mov edx, 10
    movzx ecx, word ptr [rbx+M_HP]
    movzx r8d, word ptr [rbx+M_MAXHP]
    call draw_hpbar
    movzx eax, byte ptr [rbx+M_STATUS]
    test eax, eax
    jz .Ldp_bag
    lea rdx, [rip+str_psn_u]
    mov edi, 46
    mov esi, 18
    mov ecx, A_RED
    call fb_puts
.Ldp_bag:
    lea rdx, [rip+str_potion_s]
    mov edi, 2
    mov esi, 20
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 11
    mov esi, 20
    movzx edx, byte ptr [rip+bag_potion]
    mov ecx, 3
    mov r8d, A_MENUBG
    call fb_putu
    lea rdx, [rip+str_ball_s]
    mov edi, 16
    mov esi, 20
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 28
    mov esi, 20
    movzx edx, byte ptr [rip+bag_ball]
    mov ecx, 3
    mov r8d, A_MENUBG
    call fb_putu
    lea rdx, [rip+str_w_steps]
    mov edi, 34
    mov esi, 20
    mov ecx, A_MENUBG
    call fb_puts
    mov edi, 41
    mov esi, 20
    movzx edx, word ptr [rip+steps]
    mov ecx, 6
    mov r8d, A_MENUBG
    call fb_putu
    # ---- party row (row 22): 14 columns per slot ----
    xor r12d, r12d
.Ldp_party:
    cmp r12d, 5
    jae .Ldp_done
    movzx edi, byte ptr [rip+party_n]
    cmp r12d, edi
    jae .Ldp_done
    mov edi, r12d
    call party_mon
    test rax, rax
    jz .Ldp_done
    mov rbx, rax
    mov r13d, r12d
    imul r13d, r13d, 15
    test r12d, r12d
    jne 1f
    mov edi, r13d
    mov esi, 22
    lea rdx, [rip+str_arrow_u]
    mov ecx, A_MENUBG
    call fb_puts
1:  movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_name
    mov rdx, rax
    lea edi, [r13d+2]
    mov esi, 22
    mov ecx, A_MENUBG
    call fb_puts
    lea edi, [r13d+13]
    mov esi, 22
    movzx eax, word ptr [rbx+M_HP]
    test eax, eax
    jz 2f
    lea rdx, [rip+str_ok_u]
    jmp 3f
2:  lea rdx, [rip+str_ko_u]
3:  mov ecx, A_MENUBG
    call fb_puts
    inc r12d
    jmp .Ldp_party
.Ldp_done:
    pop r13
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------------ frame ---
.globl world_spawn_from_save
world_spawn_from_save:
    call ow_load_map
    call ow_update_camera
    mov byte ptr [rip+ow_dirty], 1
    ret

.globl world_frame
world_frame:
    push rbx
    cmp byte ptr [rip+map_loaded], 0
    jne .Lwf_loaded
    call ow_load_map
.Lwf_loaded:
    call ow_input
    call ow_pending
    call ow_update_camera
    call ow_draw
    pop rbx
    ret

.globl ow_draw
ow_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov edi, A_NORM
    call fb_clear
    call draw_topbar
    movsx r14d, word ptr [rip+cam_x]
    movsx r15d, word ptr [rip+cam_y]
    xor r13d, r13d
.Lod_row:
    cmp r13d, VIEW_TH
    jae .Lod_ents
    xor r12d, r12d
.Lod_col:
    cmp r12d, VIEW_TW
    jae .Lod_nextrow
    mov edi, r14d
    add edi, r12d
    mov esi, r15d
    add esi, r13d
    call ow_tile
    test eax, eax
    jnz 1f
    mov eax, TILE_OUT
    jmp 2f
1:  lea rcx, [rip+char_to_tile]
    movzx eax, byte ptr [rcx+rax]
2:  cmp eax, 24
    jb 3f
    push rdi
    push rsi
    push rdx
    push rax
    lea rdi, [rip+str_bad]
    call dbg_str
    mov rdi, rax
    call dbg_hex
    pop rax
    pop rdx
    pop rsi
    pop rdi
3:  mov r9d, eax                        # tile index
    imul eax, eax, TILE_SZ
    lea r10, [rip+tile_defs]
    add r10, rax                        # r10 = the tile's glyph record
    mov edi, r12d
    shl edi, 1                          # a tile is 2 cells across
    mov esi, r13d
    shl esi, 1
    add esi, VIEW_PY
    cmp r9d, TILE_OUT
    je .Lod_fallback                    # outside the map: the dotted field
    mov edx, esi                        # art_blit_tile(tile, x, y)
    mov esi, edi
    mov edi, r9d
    call art_blit_tile
    jmp .Lod_tiled
.Lod_fallback:
    mov rdx, r10
    call draw_cells
.Lod_tiled:
    inc r12d
    jmp .Lod_col
.Lod_nextrow:
    inc r13d
    jmp .Lod_row
.Lod_ents:
    call ow_draw_ents
    call draw_panel
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
str_ctrl:     .asciz "ARROWS/WASD: MOVE   Z: A   X: B   M: MENU   Q: QUIT"
str_lv_s:     .asciz "Lv"
str_potion_s: .asciz "POTION x"
str_ball_s:   .asciz "POKe BALL x"
g_slash_u:    .asciz "/"
str_arrow_u:  .asciz ">"
str_ok_u:     .asciz "OK"
str_ko_u:     .asciz "KO"
str_psn_u:     .asciz "PSN"
str_bad:      .asciz "bad tile id "
