# ============================================================================
#  battle.s - turn based battles: Gen-3 damage formula, type chart, STAB,
#             crits, stat stages, poison, switching, catching, XP/level-ups.
#
#  The battle is a state machine driven by battle_frame().  Any action that
#  needs player-visible text queues messages and parks in BS_MSG; when the
#  queue drains, main_loop resumes the machine at bt_msg_ret.
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

# ---- states (index into bt_table) -----------------------------------------
.set BS_INIT,     0
.set BS_INTRO1,   1
.set BS_INTRO2,   2
.set BS_MENU,     3
.set BS_MOVES,    4
.set BS_TURNA,    5
.set BS_AFTERA,   6
.set BS_TURNB,    7
.set BS_AFTERB,   8
.set BS_ENDTURN,  9
.set BS_FAINTE,   10
.set BS_XP,       11
.set BS_LEVELUP,  12
.set BS_FAINTA,   13
.set BS_SWAP,     14
.set BS_WIN,      15
.set BS_LOSE,     16
.set BS_RAN,      17
.set BS_BAG,      18
.set BS_ITEM,     19
.set BS_THROW,    20
.set BS_CATCH,    21
.set BS_CATCHED,  22
.set BS_DONE,     23
.set BS_MSG,      24
.set BS_SENTOUT,  25
.set BS_ENDTURN_B,26
.set BS_MENUCHK,  27
.set BS_CHECKNEXT,28
.set BS_XPDONE,   29
.set BS_EVOLVE,   30
.set BS_NSTATES,  32

.set SIDE_AL, 0
.set SIDE_EN, 1

# ============================================================== battle data ==
.section .bss
.align 8
.globl bt_sub, bt_kind, bt_result, en_n, en_idx, bt_ally, en_party
.globl wild_spec, wild_lvl, hp_shown_en, hp_shown_al
bt_sub:        .byte BS_INIT
bt_kind:       .byte 0
bt_result:     .byte 0
en_n:          .byte 0
en_idx:        .byte 0
bt_ally:       .byte 0
wild_spec:     .byte 0
wild_lvl:      .byte 0
hp_shown_en:   .word 0
hp_shown_al:   .word 0

bt_first:      .byte 0
bt_move_al:    .byte 0
bt_slot_al:    .byte 0
bt_move_en:    .byte 0
bt_slot_en:    .byte 0
bt_msg_ret:    .byte 0
bt_after:      .byte 0
bt_menu_sel:   .byte 0
bt_swap_sel:   .byte 0
bt_forced:     .byte 0
bt_levels:     .byte 0
bt_evo_to:     .byte 0          # species+1 that ally is evolving into, 0 = none
bt_xp_gained:  .word 0
bt_anim:       .word 0
bt_intro_t:    .word 0
bt_stage:      .skip 4                # ally atk, ally def, en atk, en def
bt_cur_pow:    .byte 0
bt_cur_eff_id: .byte 0
bt_cur_type:   .byte 0
bt_cur_eff:    .byte 0
bt_cur_slot:   .byte 0
bt_cur_side:   .byte 0
bt_effq:       .word 0
en_party:      .skip (6*M_SZ)

# ---- message string builder (ring of 8 x 96 bytes) ------------------------
sb_idx:        .byte 0
sb_cur:        .quad 0
sb_pos:        .word 0
strbufs:       .skip (8*96)
sb_rev:        .skip 16
sb_tmp:        .skip 16

.section .rodata
str_a_wild:     .asciz "A wild "
str_appeared:   .asciz " appeared!"
str_rival_wants:.asciz "RIVAL wants\nto fight!"
str_sent_out:   .asciz " sent out\n"
str_go:         .asciz "Go! "
str_used:       .asciz " used "
str_bang:       .asciz "!"
str_fainted:    .asciz " fainted!"
str_gained:     .asciz " gained "
str_exp_pts:    .asciz " EXP. Points!"
str_grew:       .asciz " grew to\nLv"
str_crit:       .asciz "A critical\nhit!"
str_super:      .asciz "It's super\neffective!"
str_weak:       .asciz "It's not very\neffective..."
str_noeff:      .asciz "It doesn't\naffect..."
str_atk_fell:   .asciz "'s ATTACK\nfell!"
str_def_fell:   .asciz "'s DEFENSE\nfell!"
str_recovered:  .asciz " recovered\nhealth!"
str_poisoned:   .asciz " was poisoned!"
str_poison_hit: .asciz " is hurt by\npoison!"
str_no_pp:      .asciz " has no PP\nleft!"
str_run_ok:     .asciz "Got away\nsafely!"
str_run_fail:   .asciz "Can't escape!"
str_throw:      .asciz " threw a\nPOKe BALL!"
str_gotcha:     .asciz "Gotcha! "
str_caught:     .asciz " was caught!"
str_free:       .asciz "Oh no! The\nPOKeMON broke\nfree!"
str_won:        .asciz "You won the\nbattle!"
str_trainer_won:.asciz "RIVAL is out\nof POKeMON!\fYou won!"
str_lost:       .asciz "You have no\nPOKeMON left!"
str_what:       .asciz "What will "
str_do:         .asciz " do?"
str_fight:      .asciz "FIGHT"
str_bagb:       .asciz "BAG"
str_pokemonb:   .asciz "POKeMON"
str_runb:       .asciz "RUN"
str_pp:         .asciz "PP"
str_swapped:    .asciz "Come back!\f"
str_sentout2:   .asciz "Go! "
str_no_items:   .asciz "You have none of\nthat item!"
str_hp_full:    .asciz "It won't have\nany effect."
str_used_potion:.asciz "You used a\nPOTION!\f"
str_heal20:     .asciz " recovered\n20 HP!"
str_item_max:   .asciz " no effect."
str_ball_toss:  .asciz "\f"
str_level_lv:   .asciz " (Lv"

.section .text
# ------------------------------------------------------- string builder -----
sb_new:                                  # -> rax = fresh buffer
    movzx eax, byte ptr [rip+sb_idx]
    inc eax
    and eax, 7
    mov byte ptr [rip+sb_idx], al
    shl eax, 7
    shr eax, 1
    lea rcx, [rip+strbufs]
    add rax, rcx
    mov qword ptr [rip+sb_cur], rax
    mov word ptr [rip+sb_pos], 0
    mov byte ptr [rax], 0
    ret

sb_add:                                  # rdi = cstr
    mov r8, qword ptr [rip+sb_cur]
    movzx eax, word ptr [rip+sb_pos]
    add r8, rax
1:  movzx edx, byte ptr [rdi]
    test dl, dl
    jz 2f
    mov byte ptr [r8], dl
    inc r8
    inc eax
    inc rdi
    jmp 1b
2:  mov byte ptr [r8], 0
    mov word ptr [rip+sb_pos], ax
    ret

sb_num:                                  # edi = value
    push rbx
    mov eax, edi
    lea rbx, [rip+sb_rev]
    xor ecx, ecx
1:  xor edx, edx
    mov esi, 10
    div esi
    add edx, '0'
    mov byte ptr [rbx+rcx], dl
    inc ecx
    test eax, eax
    jnz 1b
    lea rdi, [rip+sb_tmp]
    mov r8, rdi
2:  dec ecx
    movzx eax, byte ptr [rbx+rcx]
    mov byte ptr [r8], al
    inc r8
    test ecx, ecx
    jnz 2b
    mov byte ptr [r8], 0
    call sb_add
    pop rbx
    ret

sb_name:                                 # rdi = mon
    push rdi
    call mon_name
    mov rdi, rax
    call sb_add
    pop rdi
    ret

# ------------------------------------------------------------- mon access ---
ally_mon:
    movzx edi, byte ptr [rip+bt_ally]
    jmp party_mon

enemy_mon:
    movzx eax, byte ptr [rip+en_idx]
    imul eax, eax, M_SZ
    lea rcx, [rip+en_party]
    add rax, rcx
    ret

side_mon:                                # edi = side -> rax
    test edi, edi
    jnz 1f
    jmp ally_mon
1:  jmp enemy_mon

# stat_with_stage(edi=stat, esi=stage) -> eax
stat_with_stage:
    mov eax, edi
    mov ecx, esi
    add ecx, 2
    cmp ecx, 1
    jge 1f
    mov ecx, 1
1:  imul eax, ecx
    sar eax, 1
    ret

atk_of:                                  # edi = side -> eax
    push rbx
    mov ebx, edi
    call side_mon
    movzx eax, word ptr [rax+M_ATK]
    mov edi, eax
    lea rcx, [rip+bt_stage]
    test ebx, ebx
    jz 1f
    add rcx, 2
1:  movzx esi, byte ptr [rcx]
    call stat_with_stage
    pop rbx
    ret

def_of:                                  # edi = side -> eax
    push rbx
    mov ebx, edi
    call side_mon
    movzx eax, word ptr [rax+M_DEF]
    mov edi, eax
    lea rcx, [rip+bt_stage]
    test ebx, ebx
    jz 1f
    add rcx, 2
1:  movzx esi, byte ptr [rcx+1]
    call stat_with_stage
    pop rbx
    ret

# eff_of(edx=move id, rdi=defender) -> eax = effectiveness in quarters
eff_of:
    push rbx
    push r12
    mov r12, rdi
    mov eax, edx
    shl eax, 4
    lea rcx, [rip+move_table]
    movzx ebx, byte ptr [rcx+rax+V_TYPE]
    imul ebx, ebx, 10
    movzx edi, byte ptr [r12+M_SPECIES]
    call spec_ptr
    movzx ecx, byte ptr [rax+S_T1]
    movzx edx, byte ptr [rax+S_T2]
    lea rax, [rip+type_chart]
    add rax, rbx
    movzx r8d, byte ptr [rax+rcx]
    movzx r9d, byte ptr [rax+rdx]
    mov eax, r8d
    imul eax, r9d
    pop r12
    pop rbx
    ret

# stab_of(edx=move id, rdi=attacker) -> eax = 1/0
stab_of:
    push rbx
    push r12
    mov r12, rdi
    mov eax, edx
    shl eax, 4
    lea rcx, [rip+move_table]
    movzx ebx, byte ptr [rcx+rax+V_TYPE]
    movzx edi, byte ptr [r12+M_SPECIES]
    call spec_ptr
    movzx ecx, byte ptr [rax+S_T1]
    movzx edx, byte ptr [rax+S_T2]
    xor eax, eax
    cmp ebx, ecx
    je 1f
    cmp ebx, edx
    jne 2f
1:  mov eax, 1
2:  pop r12
    pop rbx
    ret

# calc_damage(edi=atk side, esi=def side, edx=move id, ecx=crit) -> eax
calc_damage:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    movzx eax, r14b
    shl eax, 4
    lea rcx, [rip+move_table]
    movzx ebx, byte ptr [rcx+rax+V_POWER]
    test ebx, ebx
    jz .Lcd_zero
    mov edi, r12d
    call side_mon
    mov rbp, rax
    movzx eax, byte ptr [rbp+M_LEVEL]
    lea eax, [rax+rax*4]
    xor edx, edx
    mov ecx, 5
    div ecx
    add eax, 2
    imul eax, ebx
    mov ebx, eax
    mov edi, r12d
    call atk_of
    imul ebx, eax
    mov edi, r13d
    call def_of
    test eax, eax
    jz 1f
    mov ecx, eax
    mov eax, ebx
    xor edx, edx
    div ecx
    mov ebx, eax
1:  mov eax, ebx
    xor edx, edx
    mov ecx, 50
    div ecx
    add eax, 2
    mov ebx, eax
    # effectiveness
    mov edi, r13d
    call side_mon
    mov rdi, rax
    mov edx, r14d
    call eff_of
    mov r14d, eax
    test r14d, r14d
    jz .Lcd_zero
    imul ebx, r14d
    mov eax, ebx
    xor edx, edx
    mov ecx, 16
    div ecx
    mov ebx, eax
    # STAB
    mov edi, r12d
    call side_mon
    mov rdi, rax
    movzx edx, byte ptr [rip+bt_cur_eff_id]
    call stab_of
    test eax, eax
    jz 2f
    imul ebx, 3
    sar ebx, 1
2:  test r15d, r15d
    jz 3f
    shl ebx, 1
3:  mov edi, 16
    call rng_range
    add eax, 85
    imul ebx, eax
    mov eax, ebx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ebx, eax
    test ebx, ebx
    jnz 4f
    mov ebx, 1
4:  mov eax, ebx
    jmp .Lcd_out
.Lcd_zero:
    xor eax, eax
.Lcd_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

apply_damage:                            # edi=mon, esi=dmg
    movzx eax, word ptr [rdi+M_HP]
    sub eax, esi
    jns 1f
    xor eax, eax
1:  mov word ptr [rdi+M_HP], ax
    ret

# ------------------------------------------------------------- messaging ----
# bt_say(rdi=str, esi=next state)
bt_say:
    push rbx
    mov ebx, esi
    push rdi
    call msg_clear
    pop rdi
    call msg_push
    xor esi, esi                        # plain box: no YES/NO prompt
    call msg_begin_queue
    mov byte ptr [rip+bt_sub], BS_MSG
    mov byte ptr [rip+bt_msg_ret], bl
    pop rbx
    ret

# bt_say_queue(esi=next state): show the messages queued so far
bt_say_queue:
    mov byte ptr [rip+bt_sub], BS_MSG
    mov byte ptr [rip+bt_msg_ret], sil
    xor esi, esi                        # plain box: no YES/NO prompt
    jmp msg_begin_queue

# ---------------------------------------------------------------- init ------
bt_common_init:
    push rbx
    mov byte ptr [rip+bt_result], 0
    mov byte ptr [rip+bt_sub], BS_INIT
    mov byte ptr [rip+bt_forced], 0
    mov byte ptr [rip+bt_menu_sel], 0
    mov byte ptr [rip+bt_swap_sel], 0
    mov word ptr [rip+bt_anim], 0
    mov word ptr [rip+bt_intro_t], 0
    mov byte ptr [rip+bt_cur_eff], 4
    mov dword ptr [rip+bt_stage], 0
    call lead_mon
    test rax, rax
    jnz 1f
    xor edi, edi
    call party_mon
1:  mov rbx, rax
    mov rdi, rbx
    call party_index_of
    mov byte ptr [rip+bt_ally], al
    movzx eax, word ptr [rbx+M_HP]
    mov word ptr [rip+hp_shown_al], ax
    call enemy_mon
    movzx eax, word ptr [rax+M_HP]
    mov word ptr [rip+hp_shown_en], ax
    call enemy_mon
    movzx edi, byte ptr [rax+M_SPECIES]
    xor esi, esi
    call dex_set
    mov byte ptr [rip+game_state], ST_BATTLE
    pop rbx
    ret

party_index_of:                          # rdi=mon -> eax
    lea rcx, [rip+party]
    mov rax, rdi
    sub rax, rcx
    xor edx, edx
    mov ecx, M_SZ
    div ecx
    ret

.globl battle_start_wild
battle_start_wild:
    mov byte ptr [rip+bt_kind], 0
    mov byte ptr [rip+en_n], 1
    mov byte ptr [rip+en_idx], 0
    lea rdi, [rip+en_party]
    movzx esi, byte ptr [rip+wild_spec]
    movzx edx, byte ptr [rip+wild_lvl]
    call mon_init
    jmp bt_common_init

.globl battle_start_trainer
battle_start_trainer:
    mov byte ptr [rip+bt_kind], 1
    mov byte ptr [rip+en_n], 2
    mov byte ptr [rip+en_idx], 0
    jmp bt_common_init

# ---------------------------------------------------------------- AI --------
ai_pick:
    push rbx
    push r12
    push r13
    call enemy_mon
    mov rbx, rax
    xor r12d, r12d
    xor r13d, r13d
    xor ecx, ecx
.Lai_loop:
    cmp ecx, 4
    jae .Lai_done
    movzx eax, byte ptr [rbx+M_MOVES+rcx]
    test eax, eax
    jz .Lai_next
    cmp byte ptr [rbx+M_PP+rcx], 0
    je .Lai_next
    push rcx
    mov edx, eax
    shl eax, 4
    lea rdi, [rip+move_table]
    movzx esi, byte ptr [rdi+rax+V_POWER]
    mov edi, SIDE_AL
    push rdx
    call side_mon
    pop rdx
    mov rdi, rax
    call eff_of
    imul esi, eax
    cmp esi, r13d
    jbe 1f
    mov r13d, esi
    pop rcx
    mov r12d, ecx
    push rcx
1:  pop rcx
.Lai_next:
    inc ecx
    jmp .Lai_loop
.Lai_done:
    mov edi, 4
    call rng_range
    test eax, eax
    jnz 2f
    mov edi, 4
    call rng_range
    movzx ecx, byte ptr [rbx+M_MOVES+rax]
    test ecx, ecx
    jz 2f
    cmp byte ptr [rbx+M_PP+rax], 0
    je 2f
    mov r12d, eax
2:  mov eax, r12d
    mov byte ptr [rip+bt_slot_en], al
    movzx eax, byte ptr [rbx+M_MOVES+r12]
    mov byte ptr [rip+bt_move_en], al
    pop r13
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------ turn order ----
compute_order:
    push rbx
    push r12
    movzx eax, byte ptr [rip+bt_move_al]
    shl eax, 4
    lea rcx, [rip+move_table]
    movzx r12d, byte ptr [rcx+rax+V_EFFECT]
    movzx eax, byte ptr [rip+bt_move_en]
    shl eax, 4
    movzx ebx, byte ptr [rcx+rax+V_EFFECT]
    xor eax, eax
    cmp r12d, 5
    jne 1f
    mov eax, 1
1:  xor edx, edx
    cmp ebx, 5
    jne 2f
    mov edx, 1
2:  cmp eax, edx
    jg .Lco_al
    jl .Lco_en
    call ally_mon
    movzx r12d, word ptr [rax+M_SPD]
    call enemy_mon
    movzx ebx, word ptr [rax+M_SPD]
    cmp r12d, ebx
    ja .Lco_al
    jb .Lco_en
    mov edi, 2
    call rng_range
    test eax, eax
    jnz .Lco_en
.Lco_al:
    mov byte ptr [rip+bt_first], SIDE_AL
    pop r12
    pop rbx
    ret
.Lco_en:
    mov byte ptr [rip+bt_first], SIDE_EN
    pop r12
    pop rbx
    ret

# ------------------------------------------------------------- do_attack ----
# do_attack(edi = attacking side). Queues messages, applies effects.
# Caller must have set bt_after.
do_attack:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                        # attacker side
    mov eax, SIDE_EN
    sub eax, r12d
    mov r13d, eax                        # defender side
    mov edi, r12d
    call side_mon
    mov rbx, rax                         # attacker mon
    mov edi, r13d
    call side_mon
    mov r14, rax                         # defender mon
    # chosen move + slot
    test r12d, r12d
    jnz 1f
    movzx eax, byte ptr [rip+bt_move_al]
    movzx ecx, byte ptr [rip+bt_slot_al]
    jmp 2f
1:  movzx eax, byte ptr [rip+bt_move_en]
    movzx ecx, byte ptr [rip+bt_slot_en]
2:  mov byte ptr [rip+bt_cur_eff_id], al
    mov byte ptr [rip+bt_cur_slot], cl
    mov byte ptr [rip+bt_cur_side], r12b
    # move fields
    movzx edx, al
    shl edx, 4
    lea rsi, [rip+move_table]
    movzx r15d, byte ptr [rsi+rdx+V_POWER]
    mov byte ptr [rip+bt_cur_pow], r15b
    movzx eax, byte ptr [rsi+rdx+V_EFFECT]
    mov byte ptr [rip+bt_cur_eff], al
    mov qword ptr [rip+bt_movename], 0
    mov rax, qword ptr [rsi+rdx+V_NAME]
    mov qword ptr [rip+bt_movename], rax
    # PP check
    movzx ecx, byte ptr [rip+bt_cur_slot]
    cmp byte ptr [rbx+M_PP+rcx], 0
    jne 3f
    call sb_new
    push rax
    mov rdi, rbx
    call sb_name
    pop rax
    lea rdi, [rip+str_no_pp]
    call sb_add
    mov rdi, rax
    movzx esi, byte ptr [rip+bt_after]
    call bt_say
    jmp .Lda_out
3:  dec byte ptr [rbx+M_PP+rcx]
    # "<attacker> used <move>!"
    call msg_clear
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    mov rdi, rbx
    call sb_name
    lea rdi, [rip+str_used]
    call sb_add
    mov rdi, qword ptr [rip+bt_movename]
    call sb_add
    lea rdi, [rip+str_bang]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    call msg_push
    cmp byte ptr [rip+bt_cur_pow], 0
    jne .Lda_damage
    # ---------------- status move ----------------
    movzx eax, byte ptr [rip+bt_cur_eff]
    cmp eax, 3
    je .Lda_heal
    cmp eax, 1
    je .Lda_atkdown
    cmp eax, 2
    je .Lda_defdown
    jmp .Lda_wrap
.Lda_heal:
    movzx eax, word ptr [r14+M_MAXHP]
    shr eax, 1
    add ax, word ptr [r14+M_HP]
    cmp ax, word ptr [r14+M_MAXHP]
    jbe 1f
    movzx eax, word ptr [r14+M_MAXHP]
1:  mov word ptr [r14+M_HP], ax
    call sb_new
    push rax
    mov rdi, r14
    call sb_name
    pop rax
    lea rdi, [rip+str_recovered]
    call sb_add
    mov rdi, rax
    call msg_push
    jmp .Lda_faint_chk
.Lda_atkdown:
    lea rcx, [rip+bt_stage]
    test r13d, r13d
    jz 1f
    add rcx, 2
1:  cmp byte ptr [rcx], -6
    jle .Lda_wrap
    dec byte ptr [rcx]
    call sb_new
    push rax
    mov rdi, r14
    call sb_name
    pop rax
    lea rdi, [rip+str_atk_fell]
    call sb_add
    mov rdi, rax
    call msg_push
    jmp .Lda_faint_chk
.Lda_defdown:
    lea rcx, [rip+bt_stage+1]
    test r13d, r13d
    jz 1f
    add rcx, 2
1:  cmp byte ptr [rcx], -6
    jle .Lda_wrap
    dec byte ptr [rcx]
    call sb_new
    push rax
    mov rdi, r14
    call sb_name
    pop rax
    lea rdi, [rip+str_def_fell]
    call sb_add
    mov rdi, rax
    call msg_push
    jmp .Lda_faint_chk
    # ---------------- damaging move ----------------
.Lda_damage:
    mov edi, 16
    call rng_range
    test eax, eax
    jnz 1f
    mov r15d, 1
    jmp 2f
1:  xor r15d, r15d
2:  mov edi, r12d
    mov esi, r13d
    movzx edx, byte ptr [rip+bt_cur_eff_id]
    mov ecx, r15d
    call calc_damage
    mov dword ptr [rip+bt_dmg], eax     # bt_dmg is a .long
    # effectiveness (0 = immune: no damage at all)
    mov edi, r13d
    call side_mon
    mov rdi, rax
    movzx edx, byte ptr [rip+bt_cur_eff_id]
    call eff_of
    mov word ptr [rip+bt_effq], ax
    test eax, eax
    jz 3f
    mov edi, r13d
    call side_mon
    mov rdi, rax
    mov esi, dword ptr [rip+bt_dmg]     # bt_dmg is a .long
    call apply_damage
3:  test r15d, r15d
    jz 4f
    lea rdi, [rip+str_crit]
    call msg_push
4:  movzx eax, word ptr [rip+bt_effq]
    cmp eax, 16
    jle 5f
    lea rdi, [rip+str_super]
    call msg_push
    jmp .Lda_statuseff
5:  cmp eax, 4
    jge .Lda_statuseff
    test eax, eax
    jz 51f
    lea rdi, [rip+str_weak]
    call msg_push
    jmp .Lda_statuseff
51: lea rdi, [rip+str_noeff]
    call msg_push
.Lda_statuseff:
    # secondary poison effect
    movzx eax, byte ptr [rip+bt_cur_eff]
    cmp eax, 6
    jne .Lda_faint_chk
    cmp byte ptr [r14+M_STATUS], 0
    jne .Lda_faint_chk
    mov byte ptr [r14+M_STATUS], 1
    call sb_new
    push rax
    mov rdi, r14
    call sb_name
    pop rax
    lea rdi, [rip+str_poisoned]
    call sb_add
    mov rdi, rax
    call msg_push
.Lda_faint_chk:
    cmp word ptr [r14+M_HP], 0
    ja .Lda_wrap
    call sb_new
    push rax
    mov rdi, r14
    call sb_name
    pop rax
    lea rdi, [rip+str_fainted]
    call sb_add
    mov rdi, rax
    call msg_push
.Lda_wrap:
    movzx esi, byte ptr [rip+bt_after]
    call bt_say_queue
.Lda_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .bss
bt_movename: .quad 0
bt_msg1:     .quad 0
bt_msg2:     .quad 0
bt_msg3:     .quad 0
bt_dmg:      .long 0
.section .text

# -------------------------------------------------------------- catching ----
isqrt:                                   # edi -> eax
    mov eax, edi
    test eax, eax
    jz 9f
    xor ecx, ecx
    mov edx, 1
    shl edx, 30
1:  cmp edx, eax
    jbe 2f
    shr edx, 2
    jmp 1b
2:  test edx, edx
    jz 3f
    lea esi, [rcx+rdx]
    cmp eax, esi
    jb 4f
    sub eax, esi
    shr ecx, 1
    add ecx, edx
    jmp 5f
4:  shr ecx, 1
5:  shr edx, 2
    jmp 2b
3:  mov eax, ecx
9:  ret

try_catch:                               # eax = 1 caught
    push rbx
    push r12
    call enemy_mon
    mov rbx, rax
    movzx edi, byte ptr [rbx+M_SPECIES]
    call spec_ptr
    movzx r12d, byte ptr [rax+S_CATCH]
    movzx ecx, word ptr [rbx+M_MAXHP]
    mov eax, ecx
    imul eax, eax, 3
    movzx edx, word ptr [rbx+M_HP]
    shl edx, 1
    sub eax, edx
    jns 1f
    xor eax, eax
1:  imul eax, r12d
    mov r8d, eax
    movzx ecx, word ptr [rbx+M_MAXHP]
    imul ecx, ecx, 3
    mov eax, r8d
    xor edx, edx
    div ecx
    cmp eax, 255
    jae .Ltc_yes
    test eax, eax
    jz .Ltc_no
    mov ecx, eax
    mov eax, 16711680
    xor edx, edx
    div ecx
    mov edi, eax
    call isqrt
    mov edi, eax
    call isqrt
    mov ecx, eax
    test ecx, ecx
    jz .Ltc_no
    mov eax, 1048560
    xor edx, edx
    div ecx
    mov r12d, eax
    xor ebx, ebx
2:  cmp ebx, 4
    jae .Ltc_yes
    mov edi, 65536
    call rng_range
    cmp eax, r12d
    jae .Ltc_no
    inc ebx
    jmp 2b
.Ltc_yes:
    mov eax, 1
    pop r12
    pop rbx
    ret
.Ltc_no:
    xor eax, eax
    pop r12
    pop rbx
    ret

# ================================================================ FRAME =====
.globl battle_frame
battle_frame:
    push rbx
    cmp byte ptr [rip+bt_sub], BS_INIT
    jne 1f
    mov byte ptr [rip+bt_sub], BS_INTRO1
1:  cmp byte ptr [rip+bt_sub], BS_MSG
    jne 2f
    cmp byte ptr [rip+tb_active], 0
    jne 2f
    movzx eax, byte ptr [rip+bt_msg_ret]
    mov byte ptr [rip+bt_sub], al
2:  cmp byte ptr [rip+tb_active], 0
    jne .Lbf_draw
    cmp byte ptr [rip+key], K_QUIT
    je .Lbf_draw
    movzx eax, byte ptr [rip+bt_sub]
    cmp eax, BS_NSTATES
    jae .Lbf_draw
    shl eax, 3
    lea rcx, [rip+bt_table]
    mov rax, qword ptr [rcx+rax]
    call rax
.Lbf_draw:
    call bt_anim_hp
    call bt_draw
    cmp word ptr [rip+bt_intro_t], 60
    jae 3f
    inc word ptr [rip+bt_intro_t]
3:  pop rbx
    ret

bt_table:
    .quad bt_st_init,   bt_st_intro1,  bt_st_intro2, bt_st_menu
    .quad bt_st_moves,  bt_st_turna,   bt_st_aftera, bt_st_turnb
    .quad bt_st_afterb, bt_st_endturn, bt_st_fainte, bt_st_xp
    .quad bt_st_levelup,bt_st_fainta,  bt_st_swap,   bt_st_win
    .quad bt_st_lose,   bt_st_ran,     bt_st_bag,    bt_st_item
    .quad bt_st_throw,  bt_st_catch,   bt_st_catched,bt_st_done
    .quad bt_st_msg,    bt_st_sentout, bt_st_endturn_b, bt_st_menuchk
    .quad bt_st_checknext, bt_st_xpdone, bt_st_evolve, bt_st_nop

bt_st_nop:
    ret

bt_st_msg:
    ret

bt_st_init:
    ret

# ---- intro ---------------------------------------------------------------
bt_st_intro1:
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    cmp byte ptr [rip+bt_kind], 0
    jne 1f
    lea rdi, [rip+str_a_wild]
    call sb_add
    call enemy_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_appeared]
    call sb_add
    jmp 2f
1:  lea rdi, [rip+str_rival_wants]
    call sb_add
2:  mov rdi, qword ptr [rip+bt_msg1]
    mov esi, BS_INTRO2
    call bt_say
    ret

bt_st_intro2:
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    cmp byte ptr [rip+bt_kind], 0
    je 1f
    # trainer: "RIVAL sent out <enemy>!"
    lea rdi, [rip+str_rival_name]
    call sb_add
    lea rdi, [rip+str_sent_out]
    call sb_add
    call enemy_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_bang]
    call sb_add
    jmp 2f
1:  lea rdi, [rip+str_go]
    call sb_add
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_bang]
    call sb_add
2:  mov rdi, qword ptr [rip+bt_msg1]
    mov esi, BS_MENU
    call bt_say
    mov byte ptr [rip+bt_menu_sel], 0
    ret

bt_st_sentout:
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    lea rdi, [rip+str_sentout2]
    call sb_add
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_bang]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    mov esi, BS_MENU
    call bt_say
    ret

.section .rodata
str_rival_name: .asciz "RIVAL"
.section .text

# ---- main menu -----------------------------------------------------------
bt_st_menu:
    movzx eax, byte ptr [rip+key]
    cmp eax, K_UP
    je .Lmn_toggle2
    cmp eax, K_DOWN
    je .Lmn_toggle2
    cmp eax, K_LEFT
    je .Lmn_toggle1
    cmp eax, K_RIGHT
    je .Lmn_toggle1
    cmp eax, K_B
    je .Lmn_run
    cmp eax, K_A
    jne .Lmn_ret
    movzx eax, byte ptr [rip+bt_menu_sel]
    cmp eax, 0
    je .Lmn_fight
    cmp eax, 1
    je .Lmn_bag
    cmp eax, 2
    je .Lmn_pkmn
.Lmn_run:
    cmp byte ptr [rip+bt_kind], 0
    jne .Lmn_noescape
    mov edi, 100
    call rng_range
    push rax
    call ally_mon
    movzx ecx, word ptr [rax+M_SPD]
    call enemy_mon
    movzx eax, word ptr [rax+M_SPD]
    mov r8d, eax
    mov eax, ecx
    imul eax, eax, 50
    xor edx, edx
    test r8d, r8d
    jz 1f
    div r8d
    add eax, 30
1:  mov ecx, eax
    pop rax
    cmp eax, ecx
    ja .Lmn_noescape
    lea rdi, [rip+str_run_ok]
    mov esi, BS_RAN
    call bt_say
    ret
.Lmn_noescape:
    # failed escape: the enemy gets a turn
    call ai_pick
    mov byte ptr [rip+bt_first], SIDE_AL
    lea rdi, [rip+str_run_fail]
    mov esi, BS_TURNB
    call bt_say
    ret
.Lmn_ret:
    ret
.Lmn_toggle2:
    movzx eax, byte ptr [rip+bt_menu_sel]
    xor eax, 2
    mov byte ptr [rip+bt_menu_sel], al
    ret
.Lmn_toggle1:
    movzx eax, byte ptr [rip+bt_menu_sel]
    xor eax, 1
    mov byte ptr [rip+bt_menu_sel], al
    ret
.Lmn_fight:
    mov byte ptr [rip+bt_sub], BS_MOVES
    mov byte ptr [rip+sel], 0
    ret
.Lmn_bag:
    mov byte ptr [rip+sel], 0
    mov byte ptr [rip+bt_sub], BS_BAG
    ret
.Lmn_pkmn:
    mov byte ptr [rip+bt_swap_sel], 0
    mov byte ptr [rip+bt_forced], 0
    mov byte ptr [rip+bt_sub], BS_SWAP
    ret

# ---- move list -----------------------------------------------------------
bt_st_moves:
    movzx eax, byte ptr [rip+key]
    cmp eax, K_B
    je .Lmv_back
    cmp eax, K_UP
    je .Lmv_v
    cmp eax, K_DOWN
    je .Lmv_v
    cmp eax, K_LEFT
    je .Lmv_h
    cmp eax, K_RIGHT
    je .Lmv_h
    cmp eax, K_A
    je .Lmv_ok
    ret
.Lmv_back:
    mov byte ptr [rip+bt_sub], BS_MENU
    ret
.Lmv_v:
    movzx eax, byte ptr [rip+sel]
    xor eax, 1
    mov byte ptr [rip+sel], al
    ret
.Lmv_h:
    movzx eax, byte ptr [rip+sel]
    xor eax, 2
    mov byte ptr [rip+sel], al
    ret
.Lmv_ok:
    call ally_mon
    movzx ecx, byte ptr [rip+sel]
    movzx eax, byte ptr [rax+M_MOVES+rcx]
    test eax, eax
    jz .Lmv_back
    mov byte ptr [rip+bt_move_al], al
    mov byte ptr [rip+bt_slot_al], cl
    call ai_pick
    call compute_order
    call ally_mon
    movzx ecx, byte ptr [rip+sel]
    cmp byte ptr [rax+M_PP+rcx], 0
    jne 1f
    movzx eax, byte ptr [rip+bt_move_al]
    mov esi, BS_MENU
    call bt_say
    ret
1:  mov byte ptr [rip+bt_sub], BS_TURNA
    ret

# ---- turn ----------------------------------------------------------------
bt_st_turna:
    mov byte ptr [rip+bt_after], BS_AFTERA
    movzx edi, byte ptr [rip+bt_first]
    call do_attack
    ret

bt_st_aftera:
    call check_faints
    test eax, eax
    jnz 1f
    mov byte ptr [rip+bt_sub], BS_TURNB
1:  ret

bt_st_turnb:
    mov byte ptr [rip+bt_after], BS_AFTERB
    movzx eax, byte ptr [rip+bt_first]
    xor eax, 1
    mov edi, eax
    call do_attack
    ret

bt_st_afterb:
    call check_faints
    test eax, eax
    jnz 1f
    mov byte ptr [rip+bt_sub], BS_ENDTURN
1:  ret

# check_faints -> eax=1 if a faint state was selected
check_faints:
    call enemy_mon
    cmp word ptr [rax+M_HP], 0
    je .Lcf_en
    call ally_mon
    cmp word ptr [rax+M_HP], 0
    je .Lcf_al
    xor eax, eax
    ret
.Lcf_en:
    mov byte ptr [rip+bt_sub], BS_FAINTE
    mov eax, 1
    ret
.Lcf_al:
    mov byte ptr [rip+bt_sub], BS_FAINTA
    mov eax, 1
    ret

bt_st_endturn:
    call enemy_mon
    cmp byte ptr [rax+M_STATUS], 0
    je 1f
    mov rdi, rax
    mov esi, 2
    call apply_damage
    call sb_new
    push rax
    call enemy_mon
    mov rdi, rax
    call sb_name
    pop rax
    lea rdi, [rip+str_poison_hit]
    call sb_add
    mov rdi, rax
    mov esi, BS_ENDTURN_B
    call bt_say
    ret
1:  mov byte ptr [rip+bt_sub], BS_ENDTURN_B
    ret

bt_st_endturn_b:
    call ally_mon
    cmp byte ptr [rax+M_STATUS], 0
    je 1f
    mov rdi, rax
    mov esi, 2
    call apply_damage
    call sb_new
    push rax
    call ally_mon
    mov rdi, rax
    call sb_name
    pop rax
    lea rdi, [rip+str_poison_hit]
    call sb_add
    mov rdi, rax
    mov esi, BS_MENUCHK
    call bt_say
    ret
1:  mov byte ptr [rip+bt_sub], BS_MENUCHK
    ret

bt_st_menuchk:
    call check_faints
    test eax, eax
    jnz 1f
    mov byte ptr [rip+bt_sub], BS_MENU
1:  ret

# ---- enemy fainted: XP ---------------------------------------------------
bt_st_fainte:
    call enemy_mon
    movzx edi, byte ptr [rax+M_SPECIES]
    call spec_ptr
    movzx r8d, byte ptr [rax+S_YIELD]     # keep the yield across the call
    call enemy_mon
    movzx ecx, byte ptr [rax+M_LEVEL]
    mov eax, r8d
    imul eax, ecx
    xor edx, edx
    mov ecx, 7
    div ecx
    test eax, eax
    jnz 1f
    mov eax, 1
1:  mov word ptr [rip+bt_xp_gained], ax
    call msg_clear
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_gained]
    call sb_add
    movzx edi, word ptr [rip+bt_xp_gained]
    call sb_num
    lea rdi, [rip+str_exp_pts]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    call msg_push
    call ally_mon
    mov rdi, rax
    movzx esi, word ptr [rip+bt_xp_gained]
    call mon_give_xp
    mov byte ptr [rip+bt_levels], al
    mov esi, BS_XP
    call bt_say_queue
    ret

bt_st_xp:
    cmp byte ptr [rip+bt_levels], 0
    je 1f
    mov byte ptr [rip+bt_sub], BS_LEVELUP
    ret
1:  mov byte ptr [rip+bt_sub], BS_CHECKNEXT
    ret

bt_st_levelup:
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_grew]
    call sb_add
    call ally_mon
    movzx edi, byte ptr [rax+M_LEVEL]
    call sb_num
    lea rdi, [rip+str_bang]
    call sb_add
    # a level-up can be the moment a POKeMON evolves.  The message pointer has
    # to be re-loaded after these calls: ally_mon leaves the mon in rdi.
    call ally_mon
    mov rdi, rax
    call mon_evo_ready
    lea ecx, [rax+1]                     # 1-based, so 0 means "none"
    mov byte ptr [rip+bt_evo_to], cl
    mov rdi, qword ptr [rip+bt_msg1]
    cmp eax, 0
    jl 1f
    mov esi, BS_EVOLVE
    call bt_say
    ret
1:  mov esi, BS_XPDONE
    call bt_say
    ret

# "What? X is evolving!" then "Congratulations! Your X evolved into Y!"
# The old name is read straight off the species table: str_sp_* strings are
# static, so the pointer stays valid after the species changes.
bt_st_evolve:
    call ally_mon
    mov rdi, rax
    movzx edi, byte ptr [rdi+M_SPECIES]
    call spec_ptr
    mov rax, qword ptr [rax+S_NAME]
    mov qword ptr [rip+bt_msg2], rax     # the name it is wearing right now
    call sb_new
    mov qword ptr [rip+bt_msg3], rax
    lea rdi, [rip+str_what_evo]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg2]
    call sb_add
    lea rdi, [rip+str_is_evolving]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg3]
    call msg_push
    call ally_mon                        # and now it happens
    mov rdi, rax
    movzx esi, byte ptr [rip+bt_evo_to]
    dec esi                              # back to a real species id
    call mon_evolve
    call sb_new
    mov qword ptr [rip+bt_msg3], rax
    lea rdi, [rip+str_congrats]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg2]
    call sb_add
    lea rdi, [rip+str_evolved_into]
    call sb_add
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_bang]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg3]
    call msg_push
    mov esi, BS_XPDONE
    call bt_say_queue
    ret

bt_st_xpdone:
    mov byte ptr [rip+bt_sub], BS_CHECKNEXT
    ret

bt_st_checknext:
    cmp byte ptr [rip+bt_kind], 0
    je .Lcn_win
    movzx eax, byte ptr [rip+en_idx]
    inc eax
    movzx ecx, byte ptr [rip+en_n]
    cmp eax, ecx
    jae .Lcn_win
    mov byte ptr [rip+en_idx], al
    call enemy_mon
    movzx eax, word ptr [rax+M_HP]
    mov word ptr [rip+hp_shown_en], ax
    call enemy_mon
    movzx edi, byte ptr [rax+M_SPECIES]
    xor esi, esi
    call dex_set
    # "RIVAL sent out <name>!"
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    lea rdi, [rip+str_rival_name]
    call sb_add
    lea rdi, [rip+str_sent_out]
    call sb_add
    call enemy_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_bang]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    mov esi, BS_MENU
    call bt_say
    ret
.Lcn_win:
    mov byte ptr [rip+bt_sub], BS_WIN
    ret

# ---- ally fainted --------------------------------------------------------
bt_st_fainta:
    call alive_count
    test eax, eax
    jz .Lfa_lose
    mov byte ptr [rip+bt_forced], 1
    mov byte ptr [rip+bt_sub], BS_SWAP
    ret
.Lfa_lose:
    mov byte ptr [rip+bt_sub], BS_LOSE
    ret

# ---- switching -----------------------------------------------------------
bt_st_swap:
    movzx eax, byte ptr [rip+key]
    cmp eax, K_UP
    je .Lsw_up
    cmp eax, K_DOWN
    je .Lsw_dn
    cmp eax, K_A
    je .Lsw_ok
    cmp byte ptr [rip+bt_forced], 0
    jne 1f
    cmp eax, K_B
    je 1f
    ret
1:  mov byte ptr [rip+bt_sub], BS_MENU
    ret
.Lsw_up:
    movzx eax, byte ptr [rip+bt_swap_sel]
    test eax, eax
    jnz 1f
    movzx eax, byte ptr [rip+party_n]
1:  dec eax
    mov byte ptr [rip+bt_swap_sel], al
    ret
.Lsw_dn:
    movzx eax, byte ptr [rip+bt_swap_sel]
    inc eax
    movzx ecx, byte ptr [rip+party_n]
    cmp eax, ecx
    jb 1f
    xor eax, eax
1:  mov byte ptr [rip+bt_swap_sel], al
    ret
.Lsw_ok:
    movzx edi, byte ptr [rip+bt_swap_sel]
    call party_mon
    cmp word ptr [rax+M_HP], 0
    jle 1f
    movzx ecx, byte ptr [rip+bt_swap_sel]
    mov byte ptr [rip+bt_ally], cl
    movzx eax, word ptr [rax+M_HP]
    mov word ptr [rip+hp_shown_al], ax
    mov byte ptr [rip+bt_forced], 0
    mov byte ptr [rip+bt_sub], BS_SENTOUT
    ret
1:  ret

# ---- bag -----------------------------------------------------------------
bt_st_bag:
    movzx eax, byte ptr [rip+key]
    cmp eax, K_UP
    je .Lbg_tog
    cmp eax, K_DOWN
    je .Lbg_tog
    cmp eax, K_B
    je .Lbg_out
    cmp eax, K_A
    je .Lbg_pick
    ret
.Lbg_tog:
    movzx eax, byte ptr [rip+sel]
    xor eax, 1
    mov byte ptr [rip+sel], al
    ret
.Lbg_out:
    mov byte ptr [rip+bt_sub], BS_MENU
    ret
.Lbg_pick:
    cmp byte ptr [rip+sel], 0
    jne .Lbg_ball
    cmp byte ptr [rip+bag_potion], 0
    jne 1f
    lea rdi, [rip+str_no_items]
    mov esi, BS_MENU
    call bt_say
    ret
1:  call ally_mon
    mov rbx, rax
    movzx eax, word ptr [rbx+M_HP]
    cmp ax, word ptr [rbx+M_MAXHP]
    jb 2f
    lea rdi, [rip+str_hp_full]
    mov esi, BS_MENU
    call bt_say
    ret
2:  dec byte ptr [rip+bag_potion]
    add eax, 20
    cmp ax, word ptr [rbx+M_MAXHP]
    jbe 3f
    movzx eax, word ptr [rbx+M_MAXHP]
3:  mov word ptr [rbx+M_HP], ax
    call msg_clear
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    lea rdi, [rip+str_used_potion]
    call sb_add
    call ally_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_heal20]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    call msg_push
    call ai_pick
    mov byte ptr [rip+bt_first], SIDE_AL
    mov esi, BS_TURNB
    call bt_say_queue
    ret
.Lbg_ball:
    cmp byte ptr [rip+bag_ball], 0
    jne 1f
    lea rdi, [rip+str_no_items]
    mov esi, BS_MENU
    call bt_say
    ret
1:  dec byte ptr [rip+bag_ball]
    mov word ptr [rip+bt_anim], 0
    mov byte ptr [rip+bt_sub], BS_THROW
    ret

bt_st_item:
    ret

# ---- ball throw ----------------------------------------------------------
bt_st_throw:
    inc word ptr [rip+bt_anim]
    cmp word ptr [rip+bt_anim], 28
    jb 1f
    lea rdi, [rip+str_throw]
    mov esi, BS_CATCH
    call bt_say
1:  ret

bt_st_catch:
    call try_catch
    test eax, eax
    jz .Lct_no
    call msg_clear
    call sb_new
    mov qword ptr [rip+bt_msg1], rax
    lea rdi, [rip+str_gotcha]
    call sb_add
    call enemy_mon
    mov rdi, rax
    call sb_name
    lea rdi, [rip+str_caught]
    call sb_add
    mov rdi, qword ptr [rip+bt_msg1]
    call msg_push
    call enemy_mon
    movzx edi, byte ptr [rax+M_SPECIES]
    mov esi, 1
    call dex_set
    mov esi, BS_CATCHED
    call bt_say_queue
    ret
.Lct_no:
    # broke free -> the enemy attacks
    call ai_pick
    mov byte ptr [rip+bt_first], SIDE_AL
    lea rdi, [rip+str_free]
    mov esi, BS_TURNB
    call bt_say
    mov word ptr [rip+bt_anim], 0
    ret

bt_st_catched:
    mov byte ptr [rip+bt_result], 4
    movzx eax, byte ptr [rip+party_n]
    cmp eax, 6
    jae 1f
    mov edi, eax
    call party_mon
    mov rdi, rax
    call enemy_mon
    mov rsi, rax
    mov ecx, M_SZ
2:  movzx eax, byte ptr [rsi]
    mov byte ptr [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz 2b
    inc byte ptr [rip+party_n]
1:  mov byte ptr [rip+bt_sub], BS_WIN
    ret

# ---- end states ----------------------------------------------------------
bt_st_win:
    mov byte ptr [rip+bt_result], 1
    cmp byte ptr [rip+bt_kind], 0
    jne 1f
    lea rdi, [rip+str_won]
    mov esi, BS_DONE
    call bt_say
    ret
1:  lea rdi, [rip+str_trainer_won]
    mov esi, BS_DONE
    call bt_say
    ret

bt_st_lose:
    mov byte ptr [rip+bt_result], 2
    lea rdi, [rip+str_lost]
    mov esi, BS_DONE
    call bt_say
    ret

bt_st_ran:
    mov byte ptr [rip+bt_result], 3
    mov byte ptr [rip+bt_sub], BS_DONE
    ret

bt_st_done:
    movzx eax, byte ptr [rip+bt_result]
    cmp eax, 1
    jne 1f
    cmp byte ptr [rip+bt_kind], 0
    je 1f
    mov byte ptr [rip+flags], 3
1:  cmp eax, 2
    jne 2f
    mov byte ptr [rip+pend_evt], EV_WHITEOUT
2:  mov byte ptr [rip+game_state], ST_OVERWORLD
    ret

# ------------------------------------------------------------- HP animate ---
bt_anim_hp:
    call enemy_mon
    movzx ecx, word ptr [rax+M_HP]
    movzx edx, word ptr [rip+hp_shown_en]
    call lerp_hp
    mov word ptr [rip+hp_shown_en], ax
    call ally_mon
    movzx ecx, word ptr [rax+M_HP]
    movzx edx, word ptr [rip+hp_shown_al]
    call lerp_hp
    mov word ptr [rip+hp_shown_al], ax
    ret

lerp_hp:                                 # edx=shown, ecx=target -> eax
    mov eax, edx
    cmp eax, ecx
    jl .Lup
    jg .Ldown
    ret
.Lup:
    inc eax
    cmp eax, ecx
    jle 9f
    mov eax, ecx
9:  ret
.Ldown:
    mov esi, eax
    sub esi, ecx
    sar esi, 3
    inc esi
    sub eax, esi
    cmp eax, ecx
    jge 9b
    mov eax, ecx
    ret

# ================================================================ DRAW ======
# draw_mon_sprite(rdi=mon, esi=x, edx=y)
draw_mon_sprite:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov rdi, rbx
    call mon_typecol
    push rax
    mov rdi, rbx
    call mon_sprite
    mov rdx, rax
    pop rcx
    mov edi, r12d
    mov esi, r13d
    call fb_puts
    pop r13
    pop r12
    pop rbx
    ret

# slide offset for the intro animation: returns eax
intro_slide:
    movzx eax, word ptr [rip+bt_intro_t]
    cmp eax, 20
    jb 1f
    xor eax, eax
    ret
1:  mov ecx, 20
    sub ecx, eax
    imul eax, ecx, 3
    ret

.globl bt_draw
bt_draw:
    push rbx
    push r12
    mov edi, C_BLACK
    call fb_clear
    # ------------------------------------------------------------ backdrop --
    # a grass field for a wild encounter, the town street for the rival fight
    movzx eax, byte ptr [rip+bt_kind]
    cmp eax, 2
    jb .Lbd_bg_ok
    xor eax, eax
.Lbd_bg_ok:
    lea rdx, [rip+art_bg_tbl]
    mov rdx, [rdx+rax*8]
    xor edi, edi
    xor esi, esi
    movzx ecx, byte ptr [rip+art_bg_w]
    movzx r8d, byte ptr [rip+art_bg_h]
    call blit_art
    # ---------------------------------------------------------- enemy info --
    mov edi, 1
    mov esi, 0
    mov edx, 34
    mov ecx, 4
    mov r8d, A_BOX
    call fb_box
    call enemy_mon
    mov rbx, rax
    mov rdi, rbx
    call mon_name
    mov rdx, rax
    mov edi, 3
    mov esi, 1
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_lv]
    mov edi, 22
    mov esi, 1
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rbx+M_LEVEL]
    mov edi, 24
    mov esi, 1
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    mov edi, 3
    mov esi, 2
    mov edx, 20
    movzx ecx, word ptr [rip+hp_shown_en]
    movzx r8d, word ptr [rbx+M_MAXHP]
    call draw_hpbar
    # ------------------------------------------------------- enemy sprite --
    # a fainted POKeMON leaves the field; the big art flies in from the right
    cmp word ptr [rip+hp_shown_en], 0
    je .Lbd_no_enemy
    call intro_slide
    mov ecx, eax
    mov edi, 52
    add edi, ecx                         # starts off-screen right, lands here
    mov esi, 4
    movzx edx, byte ptr [rbx+M_SPECIES]
    cmp edx, art_n_species
    jb .Lbd_en_art
    mov rdi, rbx                         # species with no art yet: ASCII
    mov esi, 52
    mov edx, 4
    call draw_mon_sprite
    jmp .Lbd_en_done
.Lbd_en_art:
    call art_blit_big
.Lbd_en_done:
.Lbd_no_enemy:
    # ------------------------------------------------------- ally sprite ---
    call ally_mon
    mov r12, rax
    cmp word ptr [rip+hp_shown_al], 0
    je .Lbd_no_ally
    call intro_slide
    mov ecx, eax
    mov edx, 12
    sub edx, ecx                         # slides in from the left
    movzx eax, byte ptr [r12+M_SPECIES]
    cmp eax, art_n_species
    jae .Lbd_al_txt
    mov edi, edx                         # x
    mov esi, 10                          # y
    mov edx, eax                         # species
    call art_blit_small
    jmp .Lbd_al_done
.Lbd_al_txt:
    mov rdi, r12                         # no art yet: the ASCII sprite
    mov esi, edx
    mov edx, 9
    call draw_mon_sprite
.Lbd_al_done:
.Lbd_no_ally:
    # --------------------------------------------------------- ally info --
    mov edi, 40
    mov esi, 11
    mov edx, 38
    mov ecx, 6
    mov r8d, A_BOX
    call fb_box
    mov rdi, r12
    call mon_name
    mov rdx, rax
    mov edi, 42
    mov esi, 12
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_lv]
    mov edi, 62
    mov esi, 12
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [r12+M_LEVEL]
    mov edi, 64
    mov esi, 12
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_hp]
    mov edi, 42
    mov esi, 14
    mov ecx, A_NORM
    call fb_puts
    mov edi, 45
    mov esi, 14
    mov edx, 18
    movzx ecx, word ptr [rip+hp_shown_al]
    movzx r8d, word ptr [r12+M_MAXHP]
    call draw_hpbar
    movzx edx, word ptr [rip+hp_shown_al]
    mov edi, 66
    mov esi, 15
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+g_slash]
    mov edi, 69
    mov esi, 15
    mov ecx, A_NORM
    call fb_puts
    movzx edx, word ptr [r12+M_MAXHP]
    mov edi, 70
    mov esi, 15
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    # ------------------------------------------------------------ panel ---
    mov edi, 0
    mov esi, 17
    mov edx, 80
    mov ecx, 7
    mov r8d, A_BOX
    call fb_box
    movzx eax, byte ptr [rip+bt_sub]
    cmp eax, BS_MENU
    je .Lbd_menu
    cmp eax, BS_MOVES
    je .Lbd_moves
    cmp eax, BS_BAG
    je .Lbd_bag
    cmp eax, BS_SWAP
    je .Lbd_swap
    jmp .Lbd_ball
.Lbd_menu:
    lea rdx, [rip+str_what]
    mov edi, 2
    mov esi, 18
    mov ecx, A_NORM
    call fb_puts
    call ally_mon
    mov rdi, rax
    call mon_name
    mov rdx, rax
    mov edi, 2
    mov esi, 19
    mov ecx, A_HILIGHT
    call fb_puts
    lea rdx, [rip+str_do]
    mov edi, 2
    mov esi, 20
    mov ecx, A_NORM
    call fb_puts
    # options 2x2
    lea rdx, [rip+str_fight]
    mov edi, 42
    mov esi, 18
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_pokemonb]
    mov edi, 58
    mov esi, 18
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_bagb]
    mov edi, 42
    mov esi, 20
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_runb]
    mov edi, 58
    mov esi, 20
    mov ecx, A_NORM
    call fb_puts
    movzx eax, byte ptr [rip+bt_menu_sel]
    mov edi, 40
    mov esi, 18
    test eax, 2
    jz 1f
    mov esi, 20
1:  test eax, 1
    jz 2f
    mov edi, 56
2:  lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    jmp .Lbd_ball
.Lbd_moves:
    call bd_draw_moves
    jmp .Lbd_ball
.Lbd_bag:
    call bd_draw_bag
    jmp .Lbd_ball
.Lbd_swap:
    call bd_draw_swap
.Lbd_ball:
    # ball toss animation
    cmp byte ptr [rip+bt_sub], BS_THROW
    jne .Lbd_done
    movzx eax, word ptr [rip+bt_anim]
    cmp eax, 28
    ja .Lbd_done
    imul ecx, eax, 44
    xor edx, edx
    mov esi, 28
    div esi
    add eax, 16
    mov r12d, eax                        # px
    movzx eax, word ptr [rip+bt_anim]
    mov ecx, 28
    sub ecx, eax
    imul eax, ecx
    xor edx, edx
    mov ecx, 49
    div ecx
    mov ecx, 11
    sub ecx, eax
    mov r13d, ecx                        # py
    mov edi, r12d
    mov esi, r13d
    lea rdx, [rip+g_ball]
    mov ecx, A_HILIGHT
    call fb_putg
.Lbd_done:
    pop r12
    pop rbx
    ret

# ---- bottom panel: moves --------------------------------------------------
bd_draw_moves:
    push rbx
    push r12
    call ally_mon
    mov rbx, rax
    xor r12d, r12d
.Ldm_loop:
    cmp r12d, 4
    jae .Ldm_pp
    movzx eax, byte ptr [rbx+M_MOVES+r12]
    test eax, eax
    jz .Ldm_pp
    shl eax, 4
    lea rcx, [rip+move_table]
    mov rdx, qword ptr [rcx+rax+V_NAME]
    mov edi, 4
    mov esi, 18
    test r12d, 1
    jz 1f
    mov esi, 19
1:  mov eax, r12d
2:  shr eax, 1
    jz 3f
    add edi, 36
    xor eax, eax
    jmp 3f
3:  push rdx
    mov ecx, A_NORM
    call fb_puts
    pop rdx
    inc r12d
    jmp .Ldm_loop
.Ldm_pp:
    # cursor
    movzx eax, byte ptr [rip+sel]
    mov edi, 2
    mov esi, 18
    test eax, 1
    jz 1f
    mov esi, 19
1:  test eax, 2
    jz 2f
    add edi, 36
2:  lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    # PP of the selected move
    movzx ecx, byte ptr [rip+sel]
    movzx eax, byte ptr [rbx+M_MOVES+rcx]
    test eax, eax
    jz .Ldm_out
    lea rdx, [rip+str_pp]
    push rcx
    mov edi, 62
    mov esi, 21
    mov ecx, A_NORM
    call fb_puts
    pop rcx
    movzx edx, byte ptr [rbx+M_PP+rcx]
    mov edi, 65
    mov esi, 21
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    # max PP from the move table
    movzx eax, byte ptr [rbx+M_MOVES+rcx]
    shl eax, 4
    lea rdx, [rip+move_table]
    movzx edx, byte ptr [rdx+rax+V_PP]
    mov edi, 67
    mov esi, 21
    lea rdx, [rip+g_slash]
    mov ecx, A_NORM
    call fb_puts
    movzx eax, byte ptr [rbx+M_MOVES+rcx]
    shl eax, 4
    lea rdx, [rip+move_table]
    movzx edx, byte ptr [rdx+rax+V_PP]
    mov edi, 68
    mov esi, 21
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
.Ldm_out:
    pop r12
    pop rbx
    ret

# ---- bottom panel: bag ----------------------------------------------------
bd_draw_bag:
    push rbx
    lea rdx, [rip+str_potion]
    mov edi, 4
    mov esi, 18
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rip+bag_potion]
    mov edi, 30
    mov esi, 18
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+str_pokeball_u]
    mov edi, 4
    mov esi, 19
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rip+bag_ball]
    mov edi, 30
    mov esi, 19
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    movzx eax, byte ptr [rip+sel]
    mov edi, 2
    mov esi, 18
    test eax, eax
    jz 1f
    mov esi, 19
1:  lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    lea rdx, [rip+str_bag_pick]
    mov edi, 45
    mov esi, 21
    mov ecx, A_DIM
    call fb_puts
    pop rbx
    ret

# ---- bottom panel: party switch ------------------------------------------
bd_draw_swap:
    push rbx
    push r12
    xor r12d, r12d
1:  movzx eax, byte ptr [rip+party_n]
    cmp r12d, eax
    jae .Lds_cursor
    mov edi, r12d
    call party_mon
    mov rbx, rax
    mov rdi, rbx
    call mon_name
    mov rdx, rax
    mov edi, 4
    mov esi, 18
    add esi, r12d
    mov ecx, A_NORM
    call fb_puts
    lea rdx, [rip+str_lv]
    mov edi, 16
    mov esi, 18
    add esi, r12d
    mov ecx, A_NORM
    call fb_puts
    movzx edx, byte ptr [rbx+M_LEVEL]
    mov edi, 18
    mov esi, 18
    add esi, r12d
    mov ecx, 2
    mov r8d, A_NORM
    call fb_putu
    mov edi, 22
    mov esi, 18
    add esi, r12d
    mov edx, 10
    movzx ecx, word ptr [rbx+M_HP]
    movzx r8d, word ptr [rbx+M_MAXHP]
    call draw_hpbar
    movzx edx, word ptr [rbx+M_HP]
    mov edi, 35
    mov esi, 18
    add esi, r12d
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    lea rdx, [rip+g_slash]
    mov edi, 38
    mov esi, 18
    add esi, r12d
    mov ecx, A_NORM
    call fb_puts
    movzx edx, word ptr [rbx+M_MAXHP]
    mov edi, 39
    mov esi, 18
    add esi, r12d
    mov ecx, 3
    mov r8d, A_NORM
    call fb_putu
    inc r12d
    jmp 1b
.Lds_cursor:
    movzx eax, byte ptr [rip+bt_swap_sel]
    mov esi, 18
    add esi, eax
    mov edi, 2
    lea rdx, [rip+g_arrow]
    mov ecx, A_HILIGHT
    call fb_putg
    cmp byte ptr [rip+bt_forced], 0
    jne .Lds_out
    lea rdx, [rip+str_bag_pick]
    mov edi, 50
    mov esi, 21
    mov ecx, A_DIM
    call fb_puts
.Lds_out:
    pop r12
    pop rbx
    ret

.section .rodata
str_bag_pick: .asciz "Z: use     X: back"
.section .text

# vim: sw=4 ts=4
