# ============================================================================
#  core.s - startup, shared game state, utility + POKeMON stat routines
#  x86-64 Linux, raw syscalls only, no libc. GAS Intel syntax.
#
#  Calling convention for the whole project:
#    rax rcx rdx rsi rdi r8-r11 are scratch; rbx rbp r12-r15 are preserved.
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

# map_table entry layout (see tools/gen_data.py):
#   +0 name  +8 tiles  +16 npcs  +24 signs  +32 items
#   +40 links  +48 warps  +56 spawn{x,y,w,h}     (MT_* live in defs.inc)
.set SP_X, 0
.set SP_Y, 1
.set SP_W, 2
.set SP_H, 3

# =============================================================== save data ==
.section .bss
.globl opt_quick, opt_level, opt_xp
opt_quick: .byte 0
.align 8
.globl save_blk, save_end, party
.globl p_map, p_x, p_y, p_dir, party_n, bag_potion, bag_ball, flags, money
.globl dex_seen, dex_caught, map_items, rival_pick, back_map, back_x, back_y
.globl p_scr_x, p_scr_y
save_blk:
p_map:        .byte 0
p_x:          .byte 0
p_y:          .byte 0
p_dir:        .byte 0
party_n:      .byte 0
bag_potion:   .byte 0
bag_ball:     .byte 0
flags:        .byte 0            # bit0 starter taken, bit1 rival beaten
pad0:         .byte 0
money:        .word 0
dex_seen:     .word 0
dex_caught:   .word 0
map_items:    .skip 8            # bitfield of taken items, per map
rival_pick:   .byte 0
back_map:     .byte 0
back_x:       .byte 0
back_y:       .byte 0
pad1:         .byte 0
party:        .skip (6*M_SZ)
save_end:
# not part of the save: where the player was last blitted, for --gfx frames
p_scr_x:      .byte 0
p_scr_y:      .byte 0

.align 16
# ------------------------------------------------------------- live state ---
.globl game_state, sub, key, fcount, cam_x, cam_y, p_anim, move_cd, steps
.globl sel, sel_b, sel_c, blink, has_save, tmp_ptr, mapw, last_spec, last_lvl, numbuf
game_state:   .byte ST_TITLE
sub:          .byte 0
key:          .byte 0
fcount:       .word 0
cam_x:        .word 0
cam_y:        .word 0
p_anim:       .byte 0
move_cd:      .byte 0
steps:        .word 0
sel:          .byte 0
sel_b:        .byte 0
sel_c:        .byte 0
blink:        .byte 0
has_save:     .byte 0
mapw:         .byte 0
last_spec:    .byte 0
last_lvl:     .byte 0
tmp_ptr:      .quad 0
numbuf:       .skip 16

.section .rodata
.globl str_pokeball_u, str_nomon, str_hint
.globl str_steps, str_controls, g_slash, g_x, g_more, g_ball
str_pokeball_u:.asciz "POKe BALL"
str_nomon:     .asciz "(no POKeMON)"
str_hint:      .asciz "ARROWS walk   Z talk/confirm   X cancel   M menu"
str_steps:     .asciz "STEPS"
str_controls:  .asciz "Z=A  X=B  M=MENU  Q=quit"
str_escape:    .asciz "\fESC = cancel"
g_slash:       .asciz "/"
g_x:           .asciz "x"
g_more:        .asciz ">"
g_ball:        .asciz "o"

.section .text
.globl _start
_start:
    call segv_init
    mov r12, qword ptr [rsp]              # argc
    lea r13, [rsp+8]                      # argv
    mov rbx, 1
.Largloop:
    cmp rbx, r12
    jae .Largdone
    mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_headless]
    call str_eq
    test eax, eax
    jz 1f
    mov edi, 1
    call set_headless
    jmp .Largnext
1:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_gfx]
    call str_eq
    test eax, eax
    jz 1f
    mov qword ptr [rip+g_gfx], 1
    jmp .Largnext
1:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_script]
    call str_eq
    test eax, eax
    jz 2f
    inc rbx
    cmp rbx, r12
    jae .Largnext
    mov rdi, qword ptr [r13+rbx*8]
    call script_arg
    jmp .Largnext
2:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_dump]
    call str_eq
    test eax, eax
    jz 3f
    inc rbx
    cmp rbx, r12
    jae .Largnext
    mov rdi, qword ptr [r13+rbx*8]
    call dump_open
    jmp .Largnext
3:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_seed]
    call str_eq
    test eax, eax
    jz 4f
    inc rbx
    cmp rbx, r12
    jae .Largnext
    mov rdi, qword ptr [r13+rbx*8]
    call atoi
    mov rdi, rax
    call rng_seed
    jmp .Largnext
4:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_fast]
    call str_eq
    test eax, eax
    jz 5f
    mov edi, 1
    call set_fast
    jmp .Largnext
5:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_quick]
    call str_eq
    test eax, eax
    jz 61f
    mov byte ptr [rip+opt_quick], 1
    jmp .Largnext
61: mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_trace]
    call str_eq
    test eax, eax
    jz 6f
    mov edi, 1
    call set_trace
    jmp .Largnext
6:  mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_fixed]
    call str_eq
    test eax, eax
    jz 61f
    mov byte ptr [rip+opt_fixed_rng], 1
    jmp .Largnext
61: mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_level]
    call str_eq
    test eax, eax
    jz 62f
    inc rbx
    cmp rbx, r12
    jae .Largnext
    mov rdi, qword ptr [r13+rbx*8]
    call atoi
    mov byte ptr [rip+opt_level], al
    jmp .Largnext
62: mov rdi, qword ptr [r13+rbx*8]
    lea rsi, [rip+a_xp]
    call str_eq
    test eax, eax
    jz .Largnext
    inc rbx
    cmp rbx, r12
    jae .Largnext
    mov rdi, qword ptr [r13+rbx*8]
    call atoi
    mov word ptr [rip+opt_xp], ax
.Largnext:
    inc rbx
    jmp .Largloop
.Largdone:
    call term_init
    call is_headless
    test rax, rax
    jz .Lseed_rand
    mov rdi, 0x1234567890ABCDEF
    call rng_seed
    jmp .Lseed_done
.Lseed_rand:
    cmp byte ptr [rip+opt_fixed_rng], 0
    jne .Lseed_fixed
    xor edi, edi
    call rng_seed
    jmp .Lseed_done
.Lseed_fixed:
    mov rdi, 0x1234567890ABCDEF
    call rng_seed
.Lseed_done:
    call boot_defaults
    cmp byte ptr [rip+opt_quick], 0
    je 7f
    call new_game                        # straight into the world with a
    call give_starter                    # starter: used by the test scripts
    mov byte ptr [rip+pend_evt], 0
    mov byte ptr [rip+bag_potion], 2     # a small kit so the test scripts can
    mov byte ptr [rip+bag_ball], 5       # exercise the BAG and catching

7:  call save_probe
    jmp main_loop

# script_arg(rdi=cstr): the thing after --script.  It is either the script
# itself ("uaa..q") or the name of a file holding one.
script_arg:
    push rbx
    mov rbx, rdi
    mov eax, SYS_OPEN
    mov rdi, rbx
    xor esi, esi                        # O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .Lsa_literal
    mov rbx, rax                        # fd
    mov eax, SYS_READ
    mov rdi, rbx
    lea rsi, [rip+script_buf]
    mov edx, 65535
    syscall
    push rax
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop rax
    test rax, rax
    jle .Lsa_literal
    lea rdi, [rip+script_buf]
    mov byte ptr [rdi+rax], 0
    xor ecx, ecx                        # strip CR/LF/space
    xor edx, edx
1:  movzx eax, byte ptr [rdi+rdx]
    test al, al
    jz 3f
    cmp al, 10
    je 2f
    cmp al, 13
    je 2f
    cmp al, ' '
    je 2f
    mov byte ptr [rdi+rcx], al
    inc ecx
2:  inc edx
    jmp 1b
3:  mov byte ptr [rdi+rcx], 0
    call input_set_script
    pop rbx
    ret
.Lsa_literal:
    mov rdi, rbx
    call input_set_script
    pop rbx
    ret

# mon_set_level(edi=level): jump the starter to that level (test aid)
.globl mon_set_level
mon_set_level:
    push rbx
    mov ebx, edi
    mov eax, ebx
    imul eax, eax
    imul eax, ebx                        # level^3 = the XP required
    mov esi, eax
    lea rdi, [rip+party]
    call mon_give_xp
    pop rbx
    ret

# first-boot defaults for fields that live in .bss
boot_defaults:
    mov word ptr [rip+money], 3000
    mov byte ptr [rip+p_scr_x], 0xff
    mov byte ptr [rip+p_scr_y], 0xff
    ret

a_headless: .asciz "--headless"
a_gfx:      .asciz "--gfx"

a_fast:     .asciz "--fast"
a_quick:    .asciz "--quickstart"
a_trace:    .asciz "--trace"
a_script:   .asciz "--script"
a_dump:     .asciz "--dump"
a_seed:     .asciz "--seed"
a_fixed:    .asciz "--fixed-rng"
a_level:    .asciz "--level"
a_xp:       .asciz "--xp"

.section .bss
opt_fixed_rng: .byte 0
opt_level:     .byte 0          # --level N: level up the starter (test aid)
opt_xp:        .word 0          # --xp N: give the starter EXP (test aid)
.align 8
script_buf:    .skip 65536
.section .text

# ------------------------------------------------------------- tiny utils ---
.globl str_eq
str_eq:
1:  movzx eax, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp al, dl
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

.globl atoi
atoi:
    xor eax, eax
1:  movzx edx, byte ptr [rdi]
    cmp dl, '0'
    jb 2f
    cmp dl, '9'
    ja 2f
    imul rax, rax, 10
    sub edx, '0'
    add rax, rdx
    inc rdi
    jmp 1b
2:  ret

.globl str_len
str_len:
    xor eax, eax
1:  cmp byte ptr [rdi+rax], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

# map_entry(edi=map) -> rax
.globl map_entry
map_entry:
    mov eax, edi
    imul rax, rax, MT_SIZE              # entries are 9 pointers
    lea rcx, [rip+map_table]
    add rax, rcx
    ret

# map_spawn(edi=map) -> rax
.globl map_spawn
map_spawn:
    call map_entry
    mov rax, qword ptr [rax+MT_SPAWN]
    ret

# map_tiles(edi=map) -> rax
.globl map_tiles
map_tiles:
    movzx eax, byte ptr [rip+p_map]
    cmp eax, edi
    jne 1f
    lea rax, [rip+tile_buf]             # the live copy (items may be gone)
    ret
1:  call map_entry
    mov rax, qword ptr [rax+MT_TILES]
    ret

# tile_at(edi=map, esi=x, edx=y) -> eax = tile char (0 if OOB)
.globl tile_at
tile_at:
    push rbx
    push r12
    mov r12d, edx
    mov ebx, esi
    call map_spawn
    mov r8, rax
    test ebx, ebx
    js 9f
    test r12d, r12d
    js 9f
    movzx eax, byte ptr [r8+SP_W]
    cmp ebx, eax
    jae 9f
    movzx eax, byte ptr [r8+SP_H]
    cmp r12d, eax
    jae 9f
    mov eax, r12d
    movzx ecx, byte ptr [r8+SP_W]
    imul eax, ecx
    add eax, ebx
    push rax
    movzx edi, byte ptr [rip+p_map]
    call map_tiles
    pop rcx
    movzx eax, byte ptr [rax+rcx]
    pop r12
    pop rbx
    ret
9:  xor eax, eax
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------- mon helpers --
.globl spec_ptr
spec_ptr:                                # edi=species -> rax
    mov eax, edi
    imul rax, rax, S_SZ
    lea rcx, [rip+species_table]
    add rax, rcx
    ret

.globl spec_field
spec_field:                              # edi=species, esi=offset -> eax
    push rsi
    call spec_ptr
    pop rsi
    movzx eax, byte ptr [rax+rsi]
    ret

.globl spec_name
spec_name:                               # edi=species -> rax
    call spec_ptr
    mov rax, qword ptr [rax+S_NAME]
    ret

.globl spec_sprite
spec_sprite:                             # edi=species -> rax
    call spec_ptr
    mov rax, qword ptr [rax+S_SPRITE]
    ret

.globl spec_typecol
spec_typecol:                            # edi=species -> eax
    call spec_ptr
    movzx eax, byte ptr [rax+S_CR]
    ret

.globl mon_name
mon_name:                                # rdi=mon -> rax
    movzx edi, byte ptr [rdi+M_SPECIES]
    jmp spec_name

.globl mon_sprite
mon_sprite:
    movzx edi, byte ptr [rdi+M_SPECIES]
    jmp spec_sprite

.globl mon_typecol
mon_typecol:
    movzx edi, byte ptr [rdi+M_SPECIES]
    jmp spec_typecol

.globl stat_calc
stat_calc:                               # edi=base, esi=level -> eax (non-HP)
    lea eax, [rdi*2+8]
    imul eax, esi
    xor edx, edx
    mov ecx, 100
    div ecx
    add eax, 5
    ret

.globl mon_recalc
mon_recalc:                              # rdi=mon
    push rbx
    push r12
    mov rbx, rdi
    movzx r12d, byte ptr [rbx+M_LEVEL]
    movzx edi, byte ptr [rbx+M_SPECIES]
    mov esi, S_HP
    call spec_field
    mov edi, eax
    mov esi, r12d
    call stat_calc
    add eax, r12d
    add eax, 5
    mov word ptr [rbx+M_MAXHP], ax
    movzx edi, byte ptr [rbx+M_SPECIES]
    mov esi, S_ATK
    call spec_field
    mov edi, eax
    mov esi, r12d
    call stat_calc
    mov word ptr [rbx+M_ATK], ax
    movzx edi, byte ptr [rbx+M_SPECIES]
    mov esi, S_DEF
    call spec_field
    mov edi, eax
    mov esi, r12d
    call stat_calc
    mov word ptr [rbx+M_DEF], ax
    movzx edi, byte ptr [rbx+M_SPECIES]
    mov esi, S_SPD
    call spec_field
    mov edi, eax
    mov esi, r12d
    call stat_calc
    mov word ptr [rbx+M_SPD], ax
    pop r12
    pop rbx
    ret

.globl lev_move_count
lev_move_count:                          # esi=level -> eax
    mov eax, esi
    sub eax, 5
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 3
    div ecx
    inc eax
    cmp eax, 4
    jbe 2f
    mov eax, 4
2:  ret

.globl mon_init
mon_init:                                # rdi=mon, esi=species, edx=level
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov byte ptr [rbx+M_SPECIES], r12b
    mov byte ptr [rbx+M_LEVEL], r13b
    mov byte ptr [rbx+M_STATUS], 0
    mov rdi, rbx
    call mon_recalc
    movzx eax, word ptr [rbx+M_MAXHP]
    mov word ptr [rbx+M_HP], ax
    mov eax, r13d
    imul eax, r13d
    imul eax, r13d
    cmp eax, XP_CAP
    jbe 1f
    mov eax, XP_CAP
1:  mov word ptr [rbx+M_XP], ax
    mov esi, r13d
    call lev_move_count
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    lea rsi, [rax+S_MOVES]
    xor ecx, ecx
2:  movzx edx, byte ptr [rsi+rcx]
    mov byte ptr [rbx+M_MOVES+rcx], dl
    shl edx, 4
    lea rdi, [rip+move_table]
    movzx eax, byte ptr [rdi+rdx+V_PP]
    mov byte ptr [rbx+M_PP+rcx], al
    inc ecx
    cmp ecx, 4
    jb 2b
    pop r13
    pop r12
    pop rbx
    ret

.globl mon_sync_moves
mon_sync_moves:                          # rdi=mon
    push rbx
    push r12
    mov rbx, rdi
    movzx esi, byte ptr [rbx+M_LEVEL]
    call lev_move_count
    mov r12d, eax
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    lea rsi, [rax+S_MOVES]
    xor ecx, ecx
1:  cmp ecx, r12d
    jae 3f
    movzx edx, byte ptr [rsi+rcx]
    cmp dl, byte ptr [rbx+M_MOVES+rcx]
    je 2f
    mov byte ptr [rbx+M_MOVES+rcx], dl
    shl edx, 4
    lea rdi, [rip+move_table]
    movzx eax, byte ptr [rdi+rdx+V_PP]
    mov byte ptr [rbx+M_PP+rcx], al
2:  inc ecx
    jmp 1b
3:  pop r12
    pop rbx
    ret

.globl mon_heal
mon_heal:                                # rdi=mon
    push rbx
    mov rbx, rdi
    movzx eax, word ptr [rbx+M_MAXHP]
    mov word ptr [rbx+M_HP], ax
    mov byte ptr [rbx+M_STATUS], 0
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    lea rsi, [rax+S_MOVES]
    xor ecx, ecx
1:  movzx edx, byte ptr [rsi+rcx]
    shl edx, 4
    lea rdi, [rip+move_table]
    movzx eax, byte ptr [rdi+rdx+V_PP]
    mov byte ptr [rbx+M_PP+rcx], al
    inc ecx
    cmp ecx, 4
    jb 1b
    pop rbx
    ret

.globl party_mon
party_mon:                               # edi=index -> rax
    mov eax, edi
    imul eax, eax, M_SZ
    lea rcx, [rip+party]
    add rax, rcx
    ret

.globl party_heal_all
party_heal_all:
    push rbx
    xor ebx, ebx
1:  movzx eax, byte ptr [rip+party_n]
    cmp ebx, eax
    jae 2f
    mov edi, ebx
    call party_mon
    mov rdi, rax
    call mon_heal
    inc ebx
    jmp 1b
2:  pop rbx
    ret

.globl lead_mon
lead_mon:                                # rax = first healthy mon or 0
    xor ecx, ecx
1:  movzx eax, byte ptr [rip+party_n]
    cmp ecx, eax
    jae 3f
    push rcx
    mov edi, ecx
    call party_mon
    pop rcx
    cmp word ptr [rax+M_HP], 0
    ja 2f
    inc ecx
    jmp 1b
3:  xor eax, eax
2:  ret

.globl alive_count
alive_count:
    push rbx
    xor ebx, ebx
    xor r12d, r12d
1:  movzx eax, byte ptr [rip+party_n]
    cmp ebx, eax
    jae 2f
    mov edi, ebx
    call party_mon
    cmp word ptr [rax+M_HP], 0
    je 3f
    inc r12d
3:  inc ebx
    jmp 1b
2:  mov eax, r12d
    pop rbx
    ret

# mon_give_xp(rdi=mon, esi=xp) -> eax = levels gained
.globl mon_give_xp
mon_give_xp:
    push rbx
    push r12
    mov rbx, rdi
    movzx eax, word ptr [rbx+M_XP]
    add eax, esi
    cmp eax, XP_CAP
    jbe 1f
    mov eax, XP_CAP
1:  mov word ptr [rbx+M_XP], ax
    xor r12d, r12d
2:  movzx ecx, byte ptr [rbx+M_LEVEL]
    cmp ecx, 100
    jae 5f
    lea eax, [rcx+1]
    imul eax, eax
    lea edx, [rcx+1]
    imul eax, edx
    movzx edx, word ptr [rbx+M_XP]
    cmp edx, eax
    jb 5f
    inc ecx
    mov byte ptr [rbx+M_LEVEL], cl
    inc r12d
    jmp 2b
5:  test r12d, r12d
    jz 6f
    mov rdi, rbx
    call mon_recalc
    movzx eax, word ptr [rbx+M_MAXHP]
    mov word ptr [rbx+M_HP], ax
    mov rdi, rbx
    call mon_sync_moves
6:  mov eax, r12d
    pop r12
    pop rbx
    ret

# mon_evo_ready(rdi=mon) -> eax = species it should evolve into, or -1
.globl mon_evo_ready
mon_evo_ready:
    push rbx
    mov rbx, rdi
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    movzx ecx, byte ptr [rax+S_EVO]
    cmp ecx, 0xFF                       # 0xFF = this species does not evolve
    je 1f
    movzx edx, byte ptr [rbx+M_LEVEL]
    movzx eax, byte ptr [rax+S_EVO_LV]
    cmp edx, eax
    jb 1f
    mov eax, ecx
    pop rbx
    ret
1:  mov eax, -1
    pop rbx
    ret

# mon_evolve(rdi=mon, esi=new species)
# Keeps the level, the XP, the moves and the damage taken; only the species
# changes, so the stats and the sprite follow from it.
.globl mon_evolve
mon_evolve:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    movzx eax, word ptr [rbx+M_HP]
    movzx ecx, word ptr [rbx+M_MAXHP]
    push rax                            # keep the HP fraction across the change
    push rcx
    mov byte ptr [rbx+M_SPECIES], r12b
    mov rdi, rbx
    call mon_recalc
    pop rcx
    pop rax
    test ecx, ecx
    jz 1f
    imul rax, rax, 100
    xor edx, edx
    div rcx                             # eax = old HP as a percentage
    movzx ecx, word ptr [rbx+M_MAXHP]
    imul eax, eax, 1
    imul eax, ecx
    mov ecx, 100
    xor edx, edx
    div ecx
    cmp eax, 1
    jae 2f
    mov eax, 1                          # never evolve into 0 HP
2:  mov word ptr [rbx+M_HP], ax
1:  mov rdi, rbx
    call mon_sync_moves
    mov edi, r12d                       # a new species is a new dex entry
    mov esi, 1
    call dex_set
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------- dex helpers --
.globl dex_set
dex_set:                                 # edi=species, esi=0 seen / 1 caught
    mov eax, edi
    mov ecx, edi
    shr ecx, 4
    and eax, 15
    mov r9d, ecx
    mov ecx, eax
    lea rdx, [rip+dex_seen]
    test esi, esi
    jz 1f
    lea rdx, [rip+dex_caught]
1:  movzx r8d, word ptr [rdx]
    mov eax, 1
    shl eax, cl
    or r8d, eax
    mov word ptr [rdx], r8w
    mov eax, r9d
    ret

.globl dex_get
dex_get:                                 # edi=species, esi=0/1 -> eax
    mov eax, edi
    mov ecx, edi
    shr ecx, 4
    and eax, 15
    mov r9d, ecx
    mov ecx, eax
    lea rdx, [rip+dex_seen]
    test esi, esi
    jz 1f
    lea rdx, [rip+dex_caught]
1:  movzx r8d, word ptr [rdx]
    shr r8d, cl
    mov eax, r8d
    and eax, 1
    ret

# --------------------------------------------------------------- save/load --
.globl save_probe
save_probe:
    mov eax, SYS_OPEN
    lea rdi, [rip+savename]
    xor esi, esi                     # O_RDONLY
    xor edx, edx
    syscall
    cmp rax, 0
    jl 1f
    mov byte ptr [rip+has_save], 1
    mov rdi, rax
    mov eax, SYS_CLOSE
    syscall
    ret
1:  mov byte ptr [rip+has_save], 0
    ret

.globl save_write
save_write:
    push rbx
    mov eax, SYS_OPEN
    lea rdi, [rip+savename]
    mov esi, 0x241                   # O_WRONLY|O_CREAT|O_TRUNC
    mov edx, 0x1a4                   # 0644
    syscall
    cmp rax, 0
    jl .Lsw_fail
    mov rbx, rax
    mov eax, SYS_WRITE
    mov rdi, rbx
    lea rsi, [rip+save_blk]
    mov rdx, save_end - save_blk
    syscall
    cmp rax, save_end - save_blk
    jne .Lsw_fail
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    mov byte ptr [rip+has_save], 1
    mov eax, 1
    pop rbx
    ret
.Lsw_fail:
    xor eax, eax
    pop rbx
    ret

.globl save_read
save_read:
    push rbx
    mov eax, SYS_OPEN
    lea rdi, [rip+savename]
    xor esi, esi
    xor edx, edx
    syscall
    cmp rax, 0
    jl .Lsr_fail
    mov rbx, rax
    mov eax, SYS_READ
    mov rdi, rbx
    lea rsi, [rip+save_blk]
    mov rdx, save_end - save_blk
    syscall
    mov r12, rax
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    cmp r12, save_end - save_blk
    jne .Lsr_fail
    mov eax, 1
    pop rbx
    ret
.Lsr_fail:
    xor eax, eax
    pop rbx
    ret

.section .rodata
.globl savename
savename: .asciz "pokemon.sav"

# vim: sw=4 ts=4
