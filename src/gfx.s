# ============================================================================
#  gfx.s - raw terminal, UTF-8 framebuffer renderer, input, RNG
#  All output goes through a 64K buffer flushed with a single write(2).
#  Each screen cell holds one UTF-8 glyph (<=3 bytes + NUL) and one colour
#  attribute byte (bg<<4|fg) -> true 16-colour FireRed-ish look.
# ============================================================================
.intel_syntax noprefix
.include "defs.inc"

# ---------------------------------------------------------------- data ------
.section .bss
.align 16
termios_save: .skip 64
termios_raw:  .skip 64
outlen:       .quad 0
outbuf:       .skip OUTBUF_SIZE
fb_cells:     .skip (SCR_W*SCR_H*CELL_SZ)
fb_attr:      .skip (SCR_W*SCR_H)
rowesc:       .skip (24*8)
attres:       .skip (256*12)
kbuf:         .skip 64
kq:           .skip 64
kq_head:      .quad 0
kq_tail:      .quad 0
decbuf:       .skip 32
.globl g_trace
g_trace:      .byte 0
ts:           .skip 16                    # timespec {0, 20ms set per frame}
has_tty:      .quad 0
.globl g_headless
g_headless:   .quad 0
.globl g_fast
g_fast:       .byte 0
g_script:     .quad 0                     # scripted-input cursor
g_script_end: .quad 0
g_frames:     .quad 0
rng_state:    .quad 0
scratch:      .skip 64

.section .data
dump_fd:      .quad -1
.globl gfx_dump_fd
gfx_dump_fd:  .quad 0

.section .rodata
s_clear:      .asciz "\033[2J\033[H"
s_hidecur:    .asciz "\033[?25l"
s_showcur:    .asciz "\033[?25h"
s_reset:      .asciz "\033[0m"
s_altscr_on:  .asciz "\033[?1049h\033[H\033[2J"
s_altscr_off: .asciz "\033[?1049l"
.globl g_space
g_space:      .asciz " "
g_block:      .asciz " "
# utf8 of the half-block glyphs, 3 bytes each, in index order
hb_glyphs:    .byte 0xE2,0x96,0x80, 0xE2,0x96,0x88, 0xE2,0x96,0x84

# ---------------------------------------------------------------- helpers ---
.section .text

# ------------------------------------------------------------ crash report --
# A SIGSEGV/SIGBUS handler that prints the fault address and the instruction
# pointer, so a bare-metal binary can be debugged without gdb.
.section .bss
.align 16
sigact:  .skip 32

.section .text
.globl segv_init
segv_init:
    lea rax, [rip+segv_handler]
    mov qword ptr [rip+sigact], rax
    mov qword ptr [rip+sigact+8], 0x04000004   # SA_SIGINFO|SA_RESTORER
    lea rax, [rip+sigreturn_tramp]
    mov qword ptr [rip+sigact+16], rax
    mov qword ptr [rip+sigact+24], 0
    mov eax, SYS_RT_SIGACTION
    mov edi, 11                            # SIGSEGV
    lea rsi, [rip+sigact]
    xor edx, edx
    mov r10d, 8
    syscall
    mov eax, SYS_RT_SIGACTION
    mov edi, 7                             # SIGBUS
    lea rsi, [rip+sigact]
    xor edx, edx
    mov r10d, 8
    syscall
    ret

sigreturn_tramp:
    mov eax, 15                            # rt_sigreturn
    syscall

segv_handler:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
    lea rdi, [rip+s_segv]
    call dbg_str
    mov rdi, qword ptr [rbx+16]            # si_addr
    call dbg_hex
    lea rdi, [rip+s_rip]
    call dbg_str
    mov rdi, qword ptr [r12+168]           # uc_mcontext.gregs[REG_RIP]
    call dbg_hex
    mov rdi, qword ptr [r12+160]           # REG_RSP
    mov rbx, rdi
    mov edi, 'R'
    call dbg_mark
    # registers of interest: rax rbx rcx rdx rsi rdi r12
    mov edi, 13
    call dbg_reg
    mov edi, 11
    call dbg_reg
    mov edi, 14
    call dbg_reg
    mov edi, 12
    call dbg_reg
    mov edi, 9
    call dbg_reg
    mov edi, 8
    call dbg_reg
    mov edi, 4
    call dbg_reg
    mov edi, 's'
    call dbg_mark
    xor r13d, r13d
1:  mov rdi, qword ptr [rbx+r13*8]
    call dbg_hex
    inc r13d
    cmp r13d, 16
    jb 1b
    mov edi, 10
    call dbg_mark
    mov eax, SYS_EXIT
    mov edi, 139
    syscall

.section .rodata
s_segv: .asciz "\nSEGV addr="
s_rip:  .asciz "rip="
.section .text


# ob_reset: start a fresh output buffer
.globl ob_reset
ob_reset:
    mov qword ptr [rip+outlen], 0
    ret

# ob_byte(edi=byte)
.globl ob_byte
ob_byte:
    mov rax, qword ptr [rip+outlen]
    lea rcx, [rip+outbuf]
    mov byte ptr [rcx+rax], dil
    inc rax
    mov qword ptr [rip+outlen], rax
    ret

# ob_cstr(rdi=ptr): append NUL-terminated string
.globl ob_cstr
ob_cstr:
    mov rax, qword ptr [rip+outlen]
    lea rcx, [rip+outbuf]
    add rcx, rax
1:  movzx edx, byte ptr [rdi]
    test edx, edx
    jz 2f
    mov byte ptr [rcx], dl
    inc rcx
    inc rax
    inc rdi
    jmp 1b
2:  mov qword ptr [rip+outlen], rax
    ret

# ob_mem(rdi=ptr, rsi=len)
.globl ob_mem
ob_mem:
    mov rax, qword ptr [rip+outlen]
    lea rcx, [rip+outbuf]
    add rcx, rax
    add rax, rsi
    mov qword ptr [rip+outlen], rax
1:  test rsi, rsi
    jz 2f
    movzx edx, byte ptr [rdi]
    mov byte ptr [rcx], dl
    inc rdi
    inc rcx
    dec rsi
    jmp 1b
2:  ret

# ob_flush: write(1, outbuf, outlen)
.globl ob_flush
ob_flush:
    mov rdx, qword ptr [rip+outlen]
    test rdx, rdx
    jz 1f
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [rip+outbuf]
    syscall
    mov qword ptr [rip+outlen], 0
1:  ret

# utoa(rdi=dest, esi=value) -> writes decimal digits, NUL-terminate
# (internal helper, returns rdi pointing at NUL)
utoa:
    push rbx
    mov eax, esi
    lea rbx, [rip+scratch3]
    mov ecx, 0
1:  xor edx, edx
    mov esi, 10
    div esi
    add edx, '0'
    mov byte ptr [rbx+rcx], dl
    inc ecx
    test eax, eax
    jnz 1b
    # reverse into dest
2:  dec ecx
    movzx eax, byte ptr [rbx+rcx]
    mov byte ptr [rdi], al
    inc rdi
    test ecx, ecx
    jnz 2b
    mov byte ptr [rdi], 0
    pop rbx
    ret

.section .bss
hexbuf:   .skip 32
scratch2: .skip 64
scratch3: .skip 32

.section .text

# ------------------------------------------------------------ terminal ------
.globl term_init
term_init:
    push rbx
    # probe tty
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, TCGETS
    lea rdx, [rip+termios_save]
    syscall
    cmp rax, 0
    jl .Lnotty
    mov qword ptr [rip+has_tty], 1
    # duplicate
    lea rsi, [rip+termios_save]
    lea rdi, [rip+termios_raw]
    mov ecx, 8
    rep movsq
    # raw flags
    lea rdi, [rip+termios_raw]
    and dword ptr [rdi+12], 0xFFFF7F84      # ~(IEXTEN|ECHONL|ECHOK|ECHOE|ECHO|ICANON|ISIG)
    and dword ptr [rdi+0],  0xFFFFFACD      # ~(IXON|ICRNL|ISTRIP|INPCK|BRKINT)
    and dword ptr [rdi+4],  0xFFFFFFFE      # ~OPOST
    mov byte ptr [rdi+22], 0                # c_cc[VTIME] = 0
    mov byte ptr [rdi+23], 0                # c_cc[VMIN]  = 0 (poll)
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, TCSETS
    lea rdx, [rip+termios_raw]
    syscall
    # alternate screen, cursor off
    lea rdi, [rip+s_altscr_on]
    call ob_cstr
    lea rdi, [rip+s_hidecur]
    call ob_cstr
    call ob_flush
    jmp .Ldone
.Lnotty:
    mov qword ptr [rip+has_tty], 0
.Ldone:
    call esc_init
    pop rbx
    ret

.globl term_restore
term_restore:
    cmp qword ptr [rip+has_tty], 0
    je 1f
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, TCSETS
    lea rdx, [rip+termios_save]
    syscall
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [rip+s_showcur]
    mov edx, 6
    syscall
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [rip+s_reset]
    mov edx, 4
    syscall
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [rip+s_altscr_off]
    mov edx, 8
    syscall
1:  ret

esc_init:
    push rbx
    push r12
    xor r12d, r12d                  # row 0..23
1:  lea rbx, [rip+rowesc]
    mov rax, r12
    imul rax, rax, 8
    add rbx, rax
    mov byte ptr [rbx], 0x1b
    mov byte ptr [rbx+1], '['
    lea rdi, [rbx+2]
    lea esi, [r12d+1]
    call utoa
    mov byte ptr [rdi], ';'
    mov byte ptr [rdi+1], '1'
    mov byte ptr [rdi+2], 'H'
    mov byte ptr [rdi+3], 0
    inc r12d
    cmp r12d, 24
    jb 1b
    # colour escapes for all 256 attrs: ESC [ fg ; bg m
    xor r12d, r12d
4:  mov esi, r12d
    and esi, 15                     # fg
    mov ecx, r12d
    shr ecx, 4                      # bg
    cmp esi, 8
    jb 5f
    add esi, 90-8
    jmp 6f
5:  add esi, 30
6:  cmp ecx, 8
    jb 7f
    add ecx, 100-8
    jmp 8f
7:  add ecx, 40
8:  lea rbx, [rip+attres]
    mov rax, r12
    imul rax, rax, 12
    add rbx, rax
    mov byte ptr [rbx], 0x1b
    mov byte ptr [rbx+1], '['
    lea rdi, [rbx+2]
    push rcx
    call utoa                       # fg
    pop rcx
    mov byte ptr [rdi], ';'
    inc rdi
    mov esi, ecx
    call utoa                       # bg
    mov byte ptr [rdi], 'm'
    mov byte ptr [rdi+1], 0
    inc r12d
    cmp r12d, 256
    jb 4b
    pop r12
    pop rbx
    ret

# --------------------------------------------------------------- frame ------
# frame_wait: sleep one frame
.globl frame_wait
frame_wait:
    mov qword ptr [rip+ts+8], 20000000     # 20 ms -> 50 fps
    cmp qword ptr [rip+g_headless], 0
    jne 9f
    cmp byte ptr [rip+g_fast], 0
    je 8f
9:  mov qword ptr [rip+ts+8], 2000000      # 2ms: headless / --fast test runs
8:  mov eax, SYS_NANOSLEEP
    lea rdi, [rip+ts]
    xor esi, esi
    syscall
    inc qword ptr [rip+g_frames]
    ret

# ------------------------------------------------------------- the "GPU" ----
# fb_clear(edi=attr)
.globl fb_clear
fb_clear:
    push rdi
    lea rdi, [rip+fb_cells]
    mov eax, 0x20
    mov ecx, SCR_W*SCR_H
    rep stosd
    pop rdi
    movzx eax, dil
    lea rdi, [rip+fb_attr]
    mov ecx, SCR_W*SCR_H
    rep stosb
    ret

# fb_putc(edi=x, esi=y, edx=char, ecx=attr)
.globl fb_putc
fb_putc:
    test edi, edi
    js .Lpc_out
    cmp edi, SCR_W
    jge .Lpc_out
    test esi, esi
    js .Lpc_out
    cmp esi, SCR_H
    jge .Lpc_out
    imul eax, esi, SCR_W
    add eax, edi
    mov r8d, eax
    shl eax, 2
    lea r9, [rip+fb_cells]
    add r9, rax
    movzx edx, dl
    mov dword ptr [r9], edx
    lea r9, [rip+fb_attr]
    mov byte ptr [r9+r8], cl
.Lpc_out:
    ret

# fb_putc_bg(edi=x, esi=y, edx=char, ecx=fg)
# Writes one character but keeps whatever background colour the cell already
# has -- that is what makes map sprites look transparent over the terrain.
.globl fb_putc_bg
fb_putc_bg:
    test edi, edi
    js 9f
    cmp edi, SCR_W
    jge 9f
    test esi, esi
    js 9f
    cmp esi, SCR_H
    jge 9f
    imul eax, esi, SCR_W
    add eax, edi
    mov r8d, eax
    shl eax, 2
    lea r9, [rip+fb_cells]
    add r9, rax
    movzx edx, dl
    mov dword ptr [r9], edx
    lea r9, [rip+fb_attr]
    movzx eax, byte ptr [r9+r8]
    and eax, 0xf0
    and ecx, 0x0f
    or eax, ecx
    mov byte ptr [r9+r8], al
9:  ret

# fb_putg(edi=x, esi=y, rdx=glyph ptr, ecx=attr)
.globl fb_putg
fb_putg:
    test edi, edi
    js .Lpg_out
    cmp edi, SCR_W
    jge .Lpg_out
    test esi, esi
    js .Lpg_out
    cmp esi, SCR_H
    jge .Lpg_out
    imul eax, esi, SCR_W
    add eax, edi
    mov r8d, eax
    shl eax, 2
    lea r9, [rip+fb_cells]
    add r9, rax
    mov dword ptr [r9], 0
    movzx r10d, byte ptr [rdx]
    test r10d, r10d
    jz .Lpg_attr
    mov byte ptr [r9], r10b
    movzx r10d, byte ptr [rdx+1]
    test r10d, r10d
    jz .Lpg_attr
    mov byte ptr [r9+1], r10b
    movzx r10d, byte ptr [rdx+2]
    test r10d, r10d
    jz .Lpg_attr
    mov byte ptr [r9+2], r10b
.Lpg_attr:
    lea r9, [rip+fb_attr]
    mov byte ptr [r9+r8], cl
.Lpg_out:
    ret

# fb_putn(edi=x, esi=y, rdx=glyph ptr, ecx=glyph length (1..3), r8d=attr)
# Length explicit: required when copying a glyph out of the middle of a string.
.globl fb_putn
fb_putn:
    test edi, edi
    js 9f
    cmp edi, SCR_W
    jge 9f
    test esi, esi
    js 9f
    cmp esi, SCR_H
    jge 9f
    imul eax, esi, SCR_W
    add eax, edi
    mov r9d, eax
    shl eax, 2
    lea r10, [rip+fb_cells]
    add r10, rax
    mov dword ptr [r10], 0
    cmp ecx, 1
    jb 3f
    movzx eax, byte ptr [rdx]
    mov byte ptr [r10], al
    cmp ecx, 2
    jb 3f
    movzx eax, byte ptr [rdx+1]
    mov byte ptr [r10+1], al
    cmp ecx, 3
    jb 3f
    movzx eax, byte ptr [rdx+2]
    mov byte ptr [r10+2], al
3:  lea r10, [rip+fb_attr]
    mov byte ptr [r10+r9], r8b
9:  ret

# ============================================================ ART BLITTER ===
# blit_art(edi=x, esi=y, rdx=words, ecx=cells_w, r8d=cells_h)
# One dword per cell: glyph | (fg<<16); a zero word leaves the cell alone.
.globl blit_art
blit_art:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                        # x0
    mov r13d, esi                        # y0
    mov r14, rdx                         # words
    mov r15d, ecx                        # width in cells
    mov ebp, r8d                         # height in cells
    test r15d, r15d
    jz .Lbg_art_done
    test ebp, ebp
    jz .Lbg_art_done
    xor ebx, ebx                         # row
.Lbg_art_row:
    cmp ebx, ebp
    jae .Lbg_art_done
    mov eax, r13d
    add eax, ebx
    test eax, eax
    js .Lbg_art_nextrow
    cmp eax, SCR_H
    jge .Lbg_art_done
    imul edi, eax, SCR_W                 # row base cell index
    xor ecx, ecx                         # col
.Lbg_art_col:
    cmp ecx, r15d
    jae .Lbg_art_nextrow
    mov eax, ebx
    imul eax, r15d
    add eax, ecx
    mov edx, dword ptr [r14+rax*4]       # the cell word
    test dl, dl
    jz .Lbg_art_next                     # transparent: keep what is there
    mov esi, r12d
    add esi, ecx
    test esi, esi
    js .Lbg_art_next
    cmp esi, SCR_W
    jge .Lbg_art_next
    add esi, edi
    mov eax, esi
    shl eax, 2
    lea r9, [rip+fb_cells]
    movzx r10d, dl
    mov dword ptr [r9+rax], r10d
    shr edx, 16
    lea r9, [rip+fb_attr]
    mov byte ptr [r9+rsi], dl
.Lbg_art_next:
    inc ecx
    jmp .Lbg_art_col
.Lbg_art_nextrow:
    inc ebx
    jmp .Lbg_art_row
.Lbg_art_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# art_blit_big(edi=x, esi=y, edx=species)   -- 12x8 cells (starter picker)
.globl art_blit_big
art_blit_big:
    push rbx
    movzx eax, byte ptr [rip+art_n_species]
    cmp edx, eax
    jae .Lbg_big_none
    imul edx, edx, 8                     # 8-byte pointers
    lea rax, [rip+art_big_tbl]
    mov rdx, qword ptr [rax+rdx]
    movzx ecx, byte ptr [rip+art_big_w]
    movzx r8d, byte ptr [rip+art_big_h]
    call blit_art_hb
.Lbg_big_none:
    pop rbx
    ret

# art_blit_small(edi=x, esi=y, edx=species) -- 12x5 cells (battle)
.globl art_blit_small
art_blit_small:
    push rbx
    movzx eax, byte ptr [rip+art_n_species]
    cmp edx, eax
    jae .Lbg_sml_none
    imul edx, edx, 8
    lea rax, [rip+art_sml_tbl]
    mov rdx, qword ptr [rax+rdx]
    movzx ecx, byte ptr [rip+art_sml_w]
    movzx r8d, byte ptr [rip+art_sml_h]
    call blit_art_hb
.Lbg_sml_none:
    pop rbx
    ret

# ------------------------------------------------------------- half block ---
# A cell is two square pixels stacked: the foreground colour fills the top
# half of the cell and the *background* colour the bottom half.  That doubles
# the vertical resolution and makes the pixels square, which is what turns the
# art from text into a picture.  One word per cell:
#     idx | (fg<<16) | (bg<<24)      0 = transparent, 1 = top half, 2 = full
.globl blit_art_hb
blit_art_hb:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                        # x0
    mov r13d, esi                        # y0
    mov r14, rdx                         # words
    mov r15d, ecx                        # width in cells
    mov ebp, r8d                         # height in cells
    test r15d, r15d
    jz .Lhb_done
    test ebp, ebp
    jz .Lhb_done
    xor ebx, ebx                         # row
.Lhb_row:
    cmp ebx, ebp
    jae .Lhb_done
    mov eax, r13d
    add eax, ebx
    test eax, eax
    js .Lhb_nextrow
    cmp eax, SCR_H
    jge .Lhb_done
    imul edi, eax, SCR_W
    xor ecx, ecx                         # col
.Lhb_col:
    cmp ecx, r15d
    jae .Lhb_nextrow
    mov eax, ebx
    imul eax, r15d
    add eax, ecx
    mov edx, dword ptr [r14+rax*4]       # the cell word
    test dl, dl
    jz .Lhb_next                         # transparent: leave the cell alone
    mov esi, r12d
    add esi, ecx
    test esi, esi
    js .Lhb_next
    cmp esi, SCR_W
    jge .Lhb_next
    add esi, edi
    mov eax, esi
    shl eax, 2
    lea r9, [rip+fb_cells]
    add r9, rax
    movzx r10d, dl                       # glyph index
    dec r10d                             # the table is 0-based
    imul r10d, r10d, 3
    lea r11, [rip+hb_glyphs]
    add r11, r10
    mov eax, dword ptr [r11]             # utf8 for the block, 3 bytes
    and eax, 0x00FFFFFF                  # a cell is 3 glyph bytes + a NUL
    mov dword ptr [r9], eax
    shr edx, 16
    mov eax, edx
    and eax, 0x0F                        # fg = the top pixel
    shr edx, 8
    and edx, 0x0F                        # bg = the bottom pixel
    shl edx, 4
    or eax, edx                          # attr = (bg<<4)|fg
    lea r9, [rip+fb_attr]
    mov byte ptr [r9+rsi], al
.Lhb_next:
    inc ecx
    jmp .Lhb_col
.Lhb_nextrow:
    inc ebx
    jmp .Lhb_row
.Lhb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# art_blit_tile(edi=tile, esi=x, edx=y) -- one 2x2-cell map tile
.globl art_blit_tile
art_blit_tile:
    push rbx
    cmp edi, 0
    jl .Lbg_tile_none
    cmp edi, 15
    jae .Lbg_tile_none
    mov r11d, edx                       # keep y: rdx becomes the art pointer
    # the map names its own tileset (outdoors / indoors), so the tile index
    # has to be offset into that set
    movzx eax, byte ptr [rip+p_map]
    lea rcx, [rip+map_tilesets]
    movzx eax, byte ptr [rcx+rax]
    movzx ecx, byte ptr [rip+art_tiles_per_set]
    imul eax, ecx                       # NOT imul eax,eax,ecx: that form
    add edi, eax                        # does not exist and GAS encodes it
                                        # as an EVEX insn that SIGILLs
    shl edi, 4                          # 4 words per tile
    lea rax, [rip+art_tiles]
    lea rdx, [rax+rdi]
    mov edi, esi                        # x
    mov esi, r11d                       # y
    mov ecx, 2
    mov r8d, 2
    call blit_art
.Lbg_tile_none:
    pop rbx
    ret

# draw_logo(edi=x, esi=y) -- the generated title wordmark
.globl draw_logo
draw_logo:
    push rbx
    mov r11d, edi
    mov ebx, esi
    mov edi, r11d
    mov esi, ebx
    lea rdx, [rip+art_logo]
    mov ecx, 48
    mov r8d, 8
    call blit_art_hb
    pop rbx
    ret

# fb_setattr(edi=x, esi=y, ecx=attr)
.globl fb_setattr
fb_setattr:
    imul eax, esi, SCR_W
    add eax, edi
    lea r9, [rip+fb_attr]
    mov byte ptr [r9+rax], cl
    ret

# fb_puts(edi=x, esi=y, rdx=str, ecx=attr)  - handles \n, utf8 aware
.globl fb_puts
fb_puts:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14, rdx
    mov r15d, ecx
    mov ebp, edi
.Lps_loop:
    movzx eax, byte ptr [r14]
    test eax, eax
    jz .Lps_done
    cmp al, 0x0a
    jne .Lps_glyph
    inc r13d
    mov r12d, ebp
    inc r14
    jmp .Lps_loop
.Lps_glyph:
    mov ecx, 1
    cmp al, 0xc0
    jb .Lps_have
    mov ecx, 2
    cmp al, 0xe0
    jb .Lps_have
    mov ecx, 3
.Lps_have:
    mov ebx, ecx
    mov edi, r12d
    mov esi, r13d
    mov rdx, r14
    mov ecx, ebx
    mov r8d, r15d
    call fb_putn
    add r14, rbx
    inc r12d
    jmp .Lps_loop
.Lps_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# fb_putu(edi=x, esi=y, edx=value, ecx=minwidth, r8d=attr) - right aligned
.globl fb_putu
fb_putu:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov ebx, r8d
    mov r14d, ecx
    mov esi, edx
    lea rdi, [rip+scratch2]
    call utoa
    # glyph length of scratch2
    lea rsi, [rip+scratch2]
    xor edx, edx
1:  cmp byte ptr [rsi+rdx], 0
    je 2f
    inc edx
    jmp 1b
2:  mov ecx, r14d
    sub ecx, edx
    jle 3f
4:  mov edi, r12d
    mov esi, r13d
    mov edx, ' '
    push rcx
    mov ecx, ebx
    call fb_putc
    pop rcx
    inc r12d
    dec ecx
    jnz 4b
3:  mov edi, r12d
    mov esi, r13d
    lea rdx, [rip+scratch2]
    mov ecx, ebx
    call fb_puts
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# glyph_count(rdi=str) -> rax  (number of glyphs, \n counts 1)
.globl glyph_count
glyph_count:
    xor eax, eax
1:  movzx edx, byte ptr [rdi]
    test edx, edx
    jz 2f
    inc rax
    cmp dl, 0xc0
    jb 3f
    cmp dl, 0xe0
    jb 4f
    add rdi, 3
    jmp 1b
4:  add rdi, 2
    jmp 1b
3:  inc rdi
    jmp 1b
2:  ret

# fb_fill(edi=x, esi=y, edx=w, ecx=h, r8=glyph ptr, r9d=attr)
.globl fb_fill
fb_fill:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov ebx, edx
    mov ebp, ecx
    mov r14, r8
    mov r15d, r9d
.Lfl_row:
    test ebp, ebp
    jz .Lfl_done
    mov r10d, r12d
    mov r11d, ebx
.Lfl_col:
    test r11d, r11d
    jz .Lfl_next
    mov edi, r10d
    mov esi, r13d
    mov rdx, r14
    mov ecx, r15d
    push r10
    push r11
    call fb_putg
    pop r11
    pop r10
    inc r10d
    dec r11d
    jmp .Lfl_col
.Lfl_next:
    inc r13d
    dec ebp
    jmp .Lfl_row
.Lfl_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# fb_box(edi=x, esi=y, edx=w, ecx=h, r8d=attr)
.globl fb_box
fb_box:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    # top: corner + hline + corner
    mov edi, r12d
    mov esi, r13d
    lea rdx, [rip+g_tl]
    mov ecx, ebx
    call fb_putg
    lea r8, [rip+g_h]
    mov edi, r12d
    inc edi
    mov esi, r13d
    mov edx, r14d
    sub edx, 2
    mov ecx, 1
    mov r9d, ebx
    call fb_fill
    mov edi, r12d
    add edi, r14d
    dec edi
    mov esi, r13d
    lea rdx, [rip+g_tr]
    mov ecx, ebx
    call fb_putg
    # interior: fill it with the box's own background so a box is opaque --
    # without this a battle status box shows the artwork through the panel
    cmp r15d, 2
    jle .Lbx_nofill
    cmp r14d, 2
    jle .Lbx_nofill
    mov edi, r12d
    inc edi
    mov esi, r13d
    inc esi
    mov edx, r14d
    sub edx, 2
    mov ecx, r15d
    sub ecx, 2
    lea r8, [rip+g_block]
    mov r9d, ebx
    call fb_fill
.Lbx_nofill:
    # sides
    mov r10d, 1
.Lbx_side:
    cmp r10d, r15d
    jge .Lbx_bot
    lea r11d, [r13d+r10d]
    mov edi, r12d
    mov esi, r11d
    lea rdx, [rip+g_v]
    mov ecx, ebx
    push r10
    push r11
    call fb_putg
    pop r11
    pop r10
    mov edi, r12d
    add edi, r14d
    dec edi
    mov esi, r11d
    lea rdx, [rip+g_v]
    mov ecx, ebx
    push r10
    push r11
    call fb_putg
    pop r11
    pop r10
    inc r10d
    jmp .Lbx_side
.Lbx_bot:
    lea r11d, [r13d+r15d-1]
    mov edi, r12d
    mov esi, r11d
    lea rdx, [rip+g_bl]
    mov ecx, ebx
    push r11
    call fb_putg
    pop r11
    lea r8, [rip+g_h]
    mov edi, r12d
    inc edi
    mov esi, r11d
    mov edx, r14d
    sub edx, 2
    mov ecx, 1
    mov r9d, ebx
    call fb_fill
    lea r11d, [r13d+r15d-1]              # fb_fill does not preserve r11
    mov edi, r12d
    add edi, r14d
    dec edi
    mov esi, r11d
    lea rdx, [rip+g_br]
    mov ecx, ebx
    call fb_putg
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
.globl g_space, g_block, g_h, g_v, g_arrow, g_dot
.globl g_tl, g_tr, g_bl, g_br
g_tl: .asciz "+"
g_tr: .asciz "+"
g_bl: .asciz "+"
g_br: .asciz "+"
g_h:  .asciz "-"
.globl g_eq
g_eq: .asciz "="
g_v:  .asciz "|"
g_arrow: .asciz ">"
g_dot:   .asciz "\xc2\xb7"

.section .text

# ---------------------------------------------------------------- flip ------
# flip: paint fb -> terminal (single write)
.globl flip
flip:
    cmp qword ptr [rip+g_headless], 0
    jne .Lflip_ret
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    lea r15, [rip+outbuf]
    xor ebp, ebp                     # write index
    lea rdi, [rip+s_hidecur]
    call .Lemit_cstr
    xor r12d, r12d                   # row
.Lflip_row:
    # row escape
    lea rax, [rip+rowesc]
    mov ecx, r12d
    shl rcx, 3
    add rax, rcx
    mov rdi, rax
    call .Lemit_cstr
    xor r13d, r13d                   # col
    mov r14d, -1                     # cur attr
.Lflip_col:
    mov eax, r12d
    imul eax, eax, SCR_W
    add eax, r13d
    lea rcx, [rip+fb_attr]
    movzx ebx, byte ptr [rcx+rax]
    cmp ebx, r14d
    je .Lflip_noc
    mov r14d, ebx
    lea rax, [rip+attres]
    mov ecx, ebx
    imul rcx, rcx, 12
    add rax, rcx
    mov rdi, rax
    call .Lemit_cstr
.Lflip_noc:
    mov eax, r12d
    imul eax, eax, SCR_W
    add eax, r13d
    shl eax, 2
    lea rcx, [rip+fb_cells]
    add rcx, rax
    mov eax, dword ptr [rcx]
    test al, al
    jz .Lflip_skip
    mov byte ptr [r15+rbp], al
    inc rbp
    shr eax, 8
    test al, al
    jz .Lflip_skip
    mov byte ptr [r15+rbp], al
    inc rbp
    shr eax, 8
    test al, al
    jz .Lflip_skip
    mov byte ptr [r15+rbp], al
    inc rbp
.Lflip_skip:
    inc r13d
    cmp r13d, SCR_W
    jb .Lflip_col
    inc r12d
    cmp r12d, SCR_H
    jb .Lflip_row
    lea rdi, [rip+s_reset]
    call .Lemit_cstr
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [rip+outbuf]
    mov rdx, rbp
    syscall
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Lflip_ret:
    ret
# local: emit NUL string at rdi into [r15+rbp]
.Lemit_cstr:
    movzx eax, byte ptr [rdi]
    test eax, eax
    jz 1f
    mov byte ptr [r15+rbp], al
    inc rbp
    inc rdi
    jmp .Lemit_cstr
1:  ret

# --------------------------------------------------------------- input ------
# set_fast(edi): 2ms frames even on a real terminal (test runs)
.globl set_fast
set_fast:
    mov byte ptr [rip+g_fast], dil
    ret

# map_byte(edi=byte) -> eax=key code
.globl map_byte
map_byte:
    xor eax, eax
    cmp edi, 'w'
    je .Lu
    cmp edi, 'W'
    je .Lu
    cmp edi, 'k'
    je .Lu
    cmp edi, 's'
    je .Ld
    cmp edi, 'S'
    je .Ld
    cmp edi, 'j'
    je .Ld
    cmp edi, 'a'
    je .Ll
    cmp edi, 'A'
    je .Ll
    cmp edi, 'h'
    je .Ll
    cmp edi, 'd'
    je .Lr
    cmp edi, 'D'
    je .Lr
    cmp edi, 'l'
    je .Lr
    cmp edi, 'z'
    je .La
    cmp edi, 'Z'
    je .La
    cmp edi, ' '
    je .La
    cmp edi, 13
    je .Lst
    cmp edi, 10
    je .Lst
    cmp edi, 'm'
    je .Lst
    cmp edi, 'M'
    je .Lst
    cmp edi, 'x'
    je .Lb
    cmp edi, 'X'
    je .Lb
    cmp edi, 'b'
    je .Lb
    cmp edi, 127
    je .Lb
    cmp edi, 8
    je .Lb
    cmp edi, 'q'
    je .Lq
    cmp edi, 'Q'
    je .Lq
    cmp edi, 3            # ctrl-C
    je .Lq
    ret
.Lu: mov eax, K_UP
    ret
.Ld: mov eax, K_DOWN
    ret
.Ll: mov eax, K_LEFT
    ret
.Lr: mov eax, K_RIGHT
    ret
.La: mov eax, K_A
    ret
.Lb: mov eax, K_B
    ret
.Lst: mov eax, K_START
    ret
.Lq: mov eax, K_QUIT
    ret

# kq_push(edi=key)
.globl kq_push
kq_push:
    test edi, edi
    jz 1f
    mov rax, qword ptr [rip+kq_tail]
    lea rcx, [rip+kq]
    mov byte ptr [rcx+rax], dil
    inc rax
    and rax, 63
    mov qword ptr [rip+kq_tail], rax
1:  ret

# kq_pop() -> eax=key or 0
.globl kq_pop
kq_pop:
    mov rax, qword ptr [rip+kq_head]
    mov rcx, qword ptr [rip+kq_tail]
    cmp rax, rcx
    je 1f
    lea rdx, [rip+kq]
    movzx eax, byte ptr [rdx+rax]
    mov rcx, qword ptr [rip+kq_head]
    inc rcx
    and rcx, 63
    mov qword ptr [rip+kq_head], rcx
    ret
1:  xor eax, eax
    ret

# input_poll: pull available bytes (keyboard or script) and queue keys
.globl input_poll
input_poll:
    # scripted input?
    mov rax, qword ptr [rip+g_script]
    test rax, rax
    jz .Lip_kbd
    mov rcx, qword ptr [rip+g_script_end]
    cmp rax, rcx
    jb 0f
    mov edi, K_QUIT                     # script exhausted: end the run
    call kq_push
    jmp .Lip_done
0:
    movzx edi, byte ptr [rax]
    inc rax
    mov qword ptr [rip+g_script], rax
    # script chars: udlr = moves, a/b/s = buttons, '.'=wait, D=dump, q=quit
    cmp edi, 'u'
    je .Lsu
    cmp edi, 'd'
    je .Lsd
    cmp edi, 'l'
    je .Lsl
    cmp edi, 'r'
    je .Lsr
    cmp edi, 'a'
    je .Lsa
    cmp edi, 'b'
    je .Lsb
    cmp edi, 's'
    je .Lss
    cmp edi, 'q'
    je .Lsq
    cmp edi, '.'
    je .Lip_done
    cmp edi, 'D'
    je .Lip_dump
    jmp .Lip_done
.Lsu: mov edi, K_UP
    jmp .Lip_push
.Lsd: mov edi, K_DOWN
    jmp .Lip_push
.Lsl: mov edi, K_LEFT
    jmp .Lip_push
.Lsr: mov edi, K_RIGHT
    jmp .Lip_push
.Lsa: mov edi, K_A
    jmp .Lip_push
.Lsb: mov edi, K_B
    jmp .Lip_push
.Lss: mov edi, K_START
    jmp .Lip_push
.Lsq: mov edi, K_QUIT
.Lip_push:
    call kq_push
    jmp .Lip_done
.Lip_dump:
    call dump_screen
    jmp .Lip_done
.Lip_kbd:
    mov eax, SYS_READ
    xor edi, edi
    lea rsi, [rip+kbuf]
    mov edx, 48
    syscall
    cmp rax, 0
    jle .Lip_done
    mov r15, rax                       # count (r15 is callee-saved by us? we must save)
    push r15
    xor r13d, r13d
.Lip_loop:
    mov r15, qword ptr [rsp]
    cmp r13, r15
    jae .Lip_fin
    lea rcx, [rip+kbuf]
    movzx edi, byte ptr [rcx+r13]
    cmp edi, 0x1b
    jne .Lip_single
    # possible escape sequence
    lea rax, [r13+2]
    cmp rax, r15
    jae .Lip_esc_b
    movzx edx, byte ptr [rcx+r13+1]
    cmp dl, '['
    jne .Lip_osc
    movzx edx, byte ptr [rcx+r13+2]
    add r13, 3
    cmp dl, 'A'
    je .Lip_eu
    cmp dl, 'B'
    je .Lip_ed
    cmp dl, 'C'
    je .Lip_er
    cmp dl, 'D'
    je .Lip_el
    jmp .Lip_loop
.Lip_eu: mov edi, K_UP
    jmp .Lip_epush
.Lip_ed: mov edi, K_DOWN
    jmp .Lip_epush
.Lip_er: mov edi, K_RIGHT
    jmp .Lip_epush
.Lip_el: mov edi, K_LEFT
    jmp .Lip_epush
.Lip_esc_b:
    inc r13
    mov edi, K_B
    jmp .Lip_epush
.Lip_osc:                              # ESC O A..D
    lea rax, [r13+2]
    cmp rax, r15
    jae .Lip_esc_b
    movzx edx, byte ptr [rcx+r13+1]
    cmp dl, 'O'
    jne .Lip_esc_b
    movzx edx, byte ptr [rcx+r13+2]
    add r13, 3
    cmp dl, 'A'
    je .Lip_eu
    cmp dl, 'B'
    je .Lip_ed
    cmp dl, 'C'
    je .Lip_er
    cmp dl, 'D'
    je .Lip_el
    jmp .Lip_loop
.Lip_epush:
    call kq_push
    jmp .Lip_loop
.Lip_single:
    inc r13
    call map_byte
    mov edi, eax                       # map_byte returns the key code in eax
    call kq_push
    jmp .Lip_loop
.Lip_fin:
    pop r15
.Lip_done:
    ret

# input_set_script(rdi=str): enable scripted (headless) input
.globl input_set_script
input_set_script:
    mov qword ptr [rip+g_script], rdi
    # find end
    mov rax, rdi
1:  cmp byte ptr [rax], 0
    je 2f
    inc rax
    jmp 1b
2:  mov qword ptr [rip+g_script_end], rax
    ret

# rng_next() -> eax
.globl rng_next
rng_next:
    mov rax, qword ptr [rip+rng_state]
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    mov qword ptr [rip+rng_state], rax
    shr rax, 33
    ret

# rng_range(edi=n) -> eax in [0,n)
.globl rng_range
rng_range:
    mov r8d, edi
    test r8d, r8d
    jz 1f
    call rng_next
    xor edx, edx
    div r8d
    mov eax, edx
    ret
1:  xor eax, eax
    ret

# rng_seed(rdi=seed)  (0 => use getrandom/rdtsc)
.globl rng_seed
rng_seed:
    test rdi, rdi
    jz 1f
    mov qword ptr [rip+rng_state], rdi
    jmp 2f
1:  mov eax, SYS_GETRANDOM
    lea rdi, [rip+rng_state]
    mov esi, 8
    xor edx, edx
    syscall
    cmp rax, 8
    je 3f
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov qword ptr [rip+rng_state], rax
3:  mov rax, qword ptr [rip+rng_state]
    test rax, rax
    jnz 2f
    mov rax, 0x2545F4914F6CDD1D
    mov qword ptr [rip+rng_state], rax
2:  ret

# dbg_mark(edi = byte): write one trace byte to stderr (crash bisection)
.globl dbg_mark
dbg_mark:
    cmp byte ptr [rip+g_trace], 0
    jne 1f
    ret
1:  push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov byte ptr [rip+scratch], dil
    mov eax, SYS_WRITE
    mov edi, 2
    lea rsi, [rip+scratch]
    mov edx, 1
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

# dbg_str(rdi = cstr): write a trace string to stderr
.globl dbg_str
dbg_str:
    cmp byte ptr [rip+g_trace], 0
    jne 1f
    ret
1:  mov rsi, rdi
    xor edx, edx
1:  cmp byte ptr [rsi+rdx], 0
    je 2f
    inc edx
    jmp 1b
2:  mov eax, SYS_WRITE
    mov edi, 2
    syscall
    ret

# dbg_hex(rdi = value): print 16 hex digits + space to stderr
.globl dbg_hex
dbg_hex:
    cmp byte ptr [rip+g_trace], 0
    jne 1f
    ret
1:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rax, rdi
    lea rsi, [rip+hexbuf]
    mov ecx, 16
1:  rol rax, 4
    mov edx, eax
    and edx, 15
    cmp edx, 10
    jb 2f
    add edx, 'a'-10-'0'
2:  add edx, '0'
    mov byte ptr [rsi], dl
    inc rsi
    dec ecx
    jnz 1b
    mov byte ptr [rsi], ' '
    mov eax, SYS_WRITE
    mov edi, 2
    lea rsi, [rip+hexbuf]
    mov edx, 17
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

# ------------------------------------------------------------- dump mode ----
# dump_open(rdi=path)
.globl dump_open
dump_open:
    mov eax, SYS_OPEN
    mov esi, 0x241              # O_WRONLY|O_CREAT|O_TRUNC
    mov edx, 0x1a4              # 0644
    syscall
    mov qword ptr [rip+dump_fd], rax
    ret

# dump_screen: append current screen as plain text (debug/verification)
.globl dump_screen
dump_screen:
    mov rdi, qword ptr [rip+dump_fd]
    cmp rdi, -1
    je 9f
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [rip+s_dmphdr]
    call dump_str
    # --- state header: "# m=.. x=.. y=.. d=.. s=.. hp=.. mx=.. lv=.. $" ---
    lea rdi, [rip+s_hd1]
    call dump_str
    movzx edi, byte ptr [rip+p_map]
    call dump_u
    lea rdi, [rip+s_hd2]
    call dump_str
    movzx edi, byte ptr [rip+p_x]
    call dump_u
    lea rdi, [rip+s_hd3]
    call dump_str
    movzx edi, byte ptr [rip+p_y]
    call dump_u
    lea rdi, [rip+s_hd4]
    call dump_str
    movzx edi, byte ptr [rip+p_dir]
    call dump_u
    lea rdi, [rip+s_hd5]
    call dump_str
    movzx edi, byte ptr [rip+game_state]
    call dump_u
    lea rdi, [rip+s_hd6]
    call dump_str
    movzx edi, byte ptr [rip+party_n]
    call dump_u
    lea rdi, [rip+s_hd7]
    call dump_str
    call lead_hp_info
    mov r14d, ecx                       # syscalls clobber rcx and rdx
    mov r15d, edx
    mov edi, eax
    call dump_u
    lea rdi, [rip+s_hd8]
    call dump_str
    mov edi, r14d
    call dump_u
    lea rdi, [rip+s_hd9]
    call dump_str
    mov edi, r15d
    call dump_u
    mov edi, 10
    call dump_byte
    xor r12d, r12d
1:  xor r13d, r13d
2:  mov eax, r12d
    imul eax, eax, SCR_W
    add eax, r13d
    shl eax, 2
    lea rcx, [rip+fb_cells]
    add rcx, rax
    mov r14d, dword ptr [rcx]
    movzx edi, r14b
    test edi, edi
    jz 3f
    call dump_byte
    shr r14d, 8
    movzx edi, r14b
    test edi, edi
    jz 4f
    call dump_byte
    shr r14d, 8
    movzx edi, r14b
    test edi, edi
    jz 4f
    call dump_byte
    jmp 4f
3:  mov edi, ' '
    call dump_byte
4:  inc r13d
    cmp r13d, SCR_W
    jb 2b
    mov edi, 10
    call dump_byte
    inc r12d
    cmp r12d, SCR_H
    jb 1b
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
9:  ret

.section .rodata
s_dmphdr: .asciz "\n===== FRAME =====\n"
s_hd1: .asciz "# m="
s_hd2: .asciz " x="
s_hd3: .asciz " y="
s_hd4: .asciz " d="
s_hd5: .asciz " s="
s_hd6: .asciz " n="
s_hd7: .asciz " hp="
s_hd8: .asciz "/"
s_hd9: .asciz " lv="
.section .text

# lead_hp_info: eax=hp ecx=maxhp edx=level of the lead mon (0 when the party
# is empty) for the dump header
lead_hp_info:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    movzx r8d, byte ptr [rip+party_n]
    test r8d, r8d
    jz 1f
    movzx eax, word ptr [rip+party+M_HP]
    movzx ecx, word ptr [rip+party+M_MAXHP]
    movzx edx, byte ptr [rip+party+M_LEVEL]
1:  ret

dump_str:                     # rdi=str, uses dump_fd
    mov rsi, rdi
    xor edx, edx
1:  cmp byte ptr [rsi+rdx], 0
    je 2f
    inc edx
    jmp 1b
2:  mov eax, SYS_WRITE
    mov rdi, qword ptr [rip+dump_fd]
    syscall
    ret

dbg_reg:                      # edi = greg index into the faulting ucontext
    push rdi
    lea rax, [rdi*8]
    add rax, 40
    mov rdi, qword ptr [rax+r12]
    call dbg_hex
    pop rdi
    ret

dump_u:                       # edi=value, decimal, appends nothing
    push rbx
    push r12
    push r13
    mov eax, edi
    lea rbx, [rip+decbuf+16]
    mov byte ptr [rbx], 0
    mov r12d, 10
1:  xor edx, edx
    div r12d
    add edx, '0'
    dec rbx
    mov byte ptr [rbx], dl
    test eax, eax
    jnz 1b
    mov rdi, rbx
    call dump_str
    pop r13
    pop r12
    pop rbx
    ret

dump_byte:                    # edi=byte
    mov byte ptr [rip+scratch], dil
    mov eax, SYS_WRITE
    mov rdi, qword ptr [rip+dump_fd]
    lea rsi, [rip+scratch]
    mov edx, 1
    syscall
    ret

.globl frame_count
frame_count:
    mov rax, qword ptr [rip+g_frames]
    ret

.globl is_headless
is_headless:
    mov rax, qword ptr [rip+g_headless]
    ret

.globl set_headless
set_headless:
    mov qword ptr [rip+g_headless], rdi
    ret

.globl has_tty_p
has_tty_p:
    mov rax, qword ptr [rip+has_tty]
    ret

# set_trace(edi): enable/disable the TRACE/dbg output
.globl set_trace
set_trace:
    mov byte ptr [rip+g_trace], dil
    ret

# vim: sw=4 ts=4
