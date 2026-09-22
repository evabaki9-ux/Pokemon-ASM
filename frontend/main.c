/*
 * frontend/main.c -- a real window for the assembly game.
 *
 * The game itself is unchanged: this program starts ./pokemon on a pseudo
 * terminal, reads the ANSI stream it writes, and turns it into a graphical
 * frame.  What changes is the resolution and the colour: a terminal cell
 * becomes a 16x16 pixel box, so
 *
 *   * the map is drawn from the generated tile art, 32x32 pixels per tile,
 *   * a battle draws the generated creature pictures at 160x160 on the
 *     generated backdrop instead of half-block characters,
 *   * the title screen is the generated title picture,
 *   * text, boxes and menus keep the game's own layout and its 16 colours,
 *     drawn with a bitmap font packed out of a real monospace face.
 *
 * In other words: in the terminal build the art was a source of colours; here
 * the same pictures are the actual image.
 *
 * Build:  make gui
 * Run:    ./pokemon-gui                              window, 1280x384
 *         ./pokemon-gui --scale 2                    twice the size
 *         ./pokemon-gui --shot f.bmp --scenario battle   headless frame grab
 */
#define _GNU_SOURCE
#include <SDL.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define SCR_W 80
#define SCR_H 24
#define CELL_W 16
#define CELL_H 16
#define SCR_PW (SCR_W * CELL_W)
#define SCR_PH (SCR_H * CELL_H)
#define TILE_PX 32
#define SPECIES_PX 96
#define CREATURE_PX 160
#define MAX_TILES 64
#define MAX_SPECIES 32
#define N_PICTURES 3                     /* title, field, city */

static const char *root = ".";
static const char *game_path = "./pokemon";

static void die(const char *what)
{
    fprintf(stderr, "pokemon-gui: %s\n", what);
    exit(1);
}

/* ---------------------------------------------------------------- assets -- */
static Uint8 palette[16][3];
static Uint8 *font_bits;
static int font_w = 8, font_h = 16;

typedef struct {
    int present;
    Uint32 words[4];
    const Uint8 *px;
} Tile;

typedef struct {
    char name[24];
    const Uint8 *px;
} Species;

static Tile tiles[2][MAX_TILES];
static int tiles_per_set;
static Species species[MAX_SPECIES];
static int n_species;
static const Uint8 *pictures[N_PICTURES];
static Uint8 *assets;

static Uint32 rd32(const Uint8 **p)
{
    Uint32 v = (Uint32)(*p)[0] | ((Uint32)(*p)[1] << 8) |
               ((Uint32)(*p)[2] << 16) | ((Uint32)(*p)[3] << 24);
    *p += 4;
    return v;
}

static void load_assets(const char *path)
{
    FILE *fh = fopen(path, "rb");
    long len;
    const Uint8 *p;
    int i, s, k;

    if (!fh)
        die("cannot open assets -- run: python3 tools/pack_assets.py");
    fseek(fh, 0, SEEK_END);
    len = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    assets = malloc((size_t)len);
    if (!assets || fread(assets, 1, (size_t)len, fh) != (size_t)len)
        die("short read on assets");
    fclose(fh);

    p = assets;
    if (memcmp(p, "PKAR", 4) != 0)
        die("assets is not a packed file");
    p += 4;
    rd32(&p);                                       /* version */
    tiles_per_set = (int)rd32(&p);
    rd32(&p);                                       /* sets */
    n_species = (int)rd32(&p);
    rd32(&p);                                       /* pictures */
    font_w = (int)rd32(&p);
    font_h = (int)rd32(&p);
    rd32(&p);
    rd32(&p);
    rd32(&p);
    rd32(&p);
    if (tiles_per_set > MAX_TILES || n_species > MAX_SPECIES ||
        font_w * font_h <= 0)
        die("assets does not fit this build");

    for (i = 0; i < 16; i++)
        for (k = 0; k < 3; k++)
            palette[i][k] = *p++;
    font_bits = (Uint8 *)p;
    p += 95 * font_w * font_h;

    for (s = 0; s < 2; s++) {
        for (i = 0; i < tiles_per_set; i++) {
            tiles[s][i].present = *p++;
            for (k = 0; k < 4; k++)
                tiles[s][i].words[k] = rd32(&p);
            tiles[s][i].px = p;
            p += TILE_PX * TILE_PX;
        }
    }
    for (i = 0; i < n_species; i++) {
        int n = *p++;
        memcpy(species[i].name, p, n);
        species[i].name[n] = 0;
        p += n;
        species[i].px = p;
        p += SPECIES_PX * SPECIES_PX;
    }
    for (i = 0; i < N_PICTURES; i++) {
        pictures[i] = p;
        p += SCR_PW * SCR_PH;
    }
    if (p > assets + len)
        die("assets ends early");
}

/* ------------------------------------------------------------------ grid -- */
typedef struct {
    Uint8 glyph;                     /* 0 blank, 1 full block, 2 upper, 3 lower */
    Uint8 fg, bg;
} Cell;

static Cell grid[SCR_H][SCR_W];          /* the frame being shown */
static Cell next_grid[SCR_H][SCR_W];     /* the frame being painted */
static int cx, cy, dirty = 1;

static void put_cell(Uint8 g, Uint8 fg, Uint8 bg)
{
    if (cy >= 0 && cy < SCR_H && cx >= 0 && cx < SCR_W) {
        next_grid[cy][cx].glyph = g;
        next_grid[cy][cx].fg = fg;
        next_grid[cy][cx].bg = bg;
        dirty = 1;
    }
    cx++;
}

/* The game repaints the whole screen every frame and only omits cells it
   wants left blank, so a frame boundary -- the cursor jumping back to 1,1 --
   is exactly the moment to swap buffers.  Without this, cells from the
   previous screen (a battle's boxes over the map, say) would stay behind. */
static void frame_boundary(void)
{
    if (memcmp(grid, next_grid, sizeof(grid)) != 0) {
        memcpy(grid, next_grid, sizeof(grid));
        dirty = 1;
    }
    memset(next_grid, 0, sizeof(next_grid));
}

/* ------------------------------------------------------------ ansi parse -- */
enum { ST_GROUND, ST_ESC, ST_CSI };
static int st = ST_GROUND;
static int par[8], npar, got_priv;
static Uint8 cur_fg = 7, cur_bg = 0;
static int utf_left;
static Uint32 utf_code;

static void sgr(void)
{
    int i;
    if (npar == 0 || (npar == 1 && par[0] == 0)) {
        cur_fg = 7;
        cur_bg = 0;
        return;
    }
    for (i = 0; i < npar; i++) {
        int v = par[i];
        if (v >= 30 && v <= 37)
            cur_fg = (Uint8)(v - 30);
        else if (v >= 90 && v <= 97)
            cur_fg = (Uint8)(v - 90 + 8);
        else if (v >= 40 && v <= 47)
            cur_bg = (Uint8)(v - 40);
        else if (v >= 100 && v <= 107)
            cur_bg = (Uint8)(v - 100 + 8);
    }
}

static void ansi_byte(Uint8 b)
{
    if (utf_left) {
        utf_code = (utf_code << 6) | (b & 0x3f);
        if (--utf_left == 0) {
            if (utf_code == 0x2588)
                put_cell(1, cur_fg, cur_bg);
            else if (utf_code == 0x2580)
                put_cell(2, cur_fg, cur_bg);
            else if (utf_code == 0x2584)
                put_cell(3, cur_fg, cur_bg);
            else if (utf_code == 0x2500)
                put_cell('-', cur_fg, cur_bg);
        }
        return;
    }
    switch (st) {
    case ST_ESC:
        if (b == '[') {
            st = ST_CSI;
            npar = 0;
            par[0] = 0;
            got_priv = 0;
        } else {
            st = ST_GROUND;
        }
        return;
    case ST_CSI:
        if (b >= '0' && b <= '9') {
            if (npar == 0)
                npar = 1;
            par[npar - 1] = par[npar - 1] * 10 + (b - '0');
            return;
        }
        if (b == ';') {
            if (npar < 8) {
                par[npar] = 0;
                npar++;
            }
            return;
        }
        if (b == '?')
            got_priv = 1;
        else if ((b == 'H' || b == 'f') && !got_priv) {
            int row = (npar >= 1 && par[0]) ? par[0] : 1;
            int col = (npar >= 2 && par[1]) ? par[1] : 1;
            if (row == 1 && col == 1)
                frame_boundary();
            cy = row - 1;
            cx = col - 1;
        } else if (b == 'm')
            sgr();
        st = ST_GROUND;
        return;
    default:
        break;
    }
    if (b == 0x1b) {
        st = ST_ESC;
        return;
    }
    if (b >= 0x20 && b < 0x7f) {
        put_cell(b, cur_fg, cur_bg);
        return;
    }
    if ((b & 0xe0) == 0xc0) {
        utf_left = 1;
        utf_code = b & 0x1f;
    } else if ((b & 0xf0) == 0xe0) {
        utf_left = 2;
        utf_code = b & 0x0f;
    }
}

/* ------------------------------------------------------------- frame buf -- */
static Uint32 frame[SCR_PW * SCR_PH];

static Uint32 rgb(int idx)
{
    return 0xff000000u | ((Uint32)palette[idx][0] << 16) |
           ((Uint32)palette[idx][1] << 8) | palette[idx][2];
}

static void fill_rect(int x, int y, int w, int h, Uint32 col)
{
    int i, j;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > SCR_PW) w = SCR_PW - x;
    if (y + h > SCR_PH) h = SCR_PH - y;
    for (j = 0; j < h; j++) {
        Uint32 *row = frame + (size_t)(y + j) * SCR_PW + x;
        for (i = 0; i < w; i++)
            row[i] = col;
    }
}

static void blit_indexed(const Uint8 *px, int sw, int sh, int dx, int dy,
                         int dw, int dh)
{
    int x, y;
    for (y = 0; y < dh; y++) {
        int fy = dy + y;
        int sy = (sh == dh) ? y : y * sh / dh;
        if (fy < 0 || fy >= SCR_PH)
            continue;
        for (x = 0; x < dw; x++) {
            int fx = dx + x;
            Uint8 v;
            if (fx < 0 || fx >= SCR_PW)
                continue;
            v = px[sy * sw + ((sw == dw) ? x : x * sw / dw)];
            if (v == 255)
                continue;
            frame[(size_t)fy * SCR_PW + fx] = rgb(v);
        }
    }
}

static void blit_glyph(int code, int dx, int dy, Uint32 col)
{
    const Uint8 *g;
    int x, y;
    if (code < 32 || code > 126)
        return;
    g = font_bits + (code - 32) * font_w * font_h;
    for (y = 0; y < CELL_H; y++) {
        int sy = y * font_h / CELL_H;
        int py = dy + y;
        if (py < 0 || py >= SCR_PH)
            continue;
        for (x = 0; x < CELL_W; x++) {
            int sx = x * font_w / CELL_W;
            int px = dx + x;
            if (px < 0 || px >= SCR_PW)
                continue;
            if (g[sy * font_w + sx] < 110)
                continue;
            frame[(size_t)py * SCR_PW + px] = col;
        }
    }
}

/* --------------------------------------------------------- screen facts -- */
static void row_text(int row, int c0, int c1, char *out, int cap)
{
    int x, n = 0;
    for (x = c0; x < c1 && x < SCR_W; x++) {
        Uint8 g = grid[row][x].glyph;
        if (n < cap - 1)
            out[n++] = (g >= 32 && g < 127) ? (char)g : ' ';
    }
    out[n] = 0;
}

static int screen_has(int r0, int r1, int c0, int c1, const char *needle)
{
    char row[SCR_W + 1];
    int r;
    for (r = r0; r <= r1 && r < SCR_H; r++) {
        row_text(r, c0, c1, row, sizeof(row));
        if (strstr(row, needle))
            return 1;
    }
    return 0;
}

static int species_in(int r0, int r1, int c0, int c1)
{
    char row[SCR_W + 1];
    int r, i;
    for (r = r0; r <= r1 && r < SCR_H; r++) {
        row_text(r, c0, c1, row, sizeof(row));
        for (i = 0; i < n_species; i++)
            if (strstr(row, species[i].name))
                return i;
    }
    return -1;
}

/* Is this blank cell the inside of a box?  Something must be drawn to its
   left *and* right in the same row, and above *and* below in the same column;
   otherwise it is open ground and the picture behind should show through. */
static int enclosed(int x, int y)
{
    int i, hit;
    hit = 0;
    for (i = x - 1; i >= 0 && x - i < 60; i--)
        if (grid[y][i].glyph) { hit |= 1; break; }
    for (i = x + 1; i < SCR_W && i - x < 60; i++)
        if (grid[y][i].glyph) { hit |= 2; break; }
    if (hit != 3)
        return 0;
    hit = 0;
    for (i = y - 1; i >= 0 && y - i < 24; i--)
        if (grid[i][x].glyph) { hit |= 1; break; }
    for (i = y + 1; i < SCR_H && i - y < 24; i++)
        if (grid[i][x].glyph) { hit |= 2; break; }
    return hit == 3;
}

static int count_blocks(void)
{
    int x, y, n = 0;
    for (y = 0; y < SCR_H; y++)
        for (x = 0; x < SCR_W; x++)
            if (grid[y][x].glyph >= 1 && grid[y][x].glyph <= 3)
                n++;
    return n;
}

/* ------------------------------------------------------------ tile match -- */
static const int terrain_first[] = { 0, 1, 2, 3, 4, 5, 12, 14, 15, 27, 31 };
#define N_TERRAIN ((int)(sizeof(terrain_first) / sizeof(terrain_first[0])))

static int cell_matches(const Cell *c, Uint32 w)
{
    return c->glyph == (w & 0xff) && c->fg == ((w >> 16) & 0xff) &&
           c->bg == ((w >> 24) & 0xff);
}

/* which tile is this 2x2 block of cells?  -1 when it is not a tile */
static int block_tile(int vx, int vy, int setno, int *score_out)
{
    const Cell *c[4];
    int i, k, t, best = -1, best_score = 0;

    c[0] = &grid[1 + vy * 2][vx * 2];
    c[1] = &grid[1 + vy * 2][vx * 2 + 1];
    c[2] = &grid[2 + vy * 2][vx * 2];
    c[3] = &grid[2 + vy * 2][vx * 2 + 1];

    for (t = 0; t < tiles_per_set; t++) {
        int score = 0;
        if (!tiles[setno][t].present)
            continue;
        for (i = 0; i < 4; i++)
            if (cell_matches(c[i], tiles[setno][t].words[i]))
                score++;
        if (score > best_score) {
            best_score = score;
            best = t;
        }
    }
    if (best_score >= 3) {                       /* exact, or a sprite on it */
        *score_out = best_score;
        return best;
    }
    for (k = 0; k < N_TERRAIN; k++) {            /* wholly covered: the ground */
        int t2 = terrain_first[k], score = 0;
        if (t2 >= tiles_per_set || !tiles[setno][t2].present)
            continue;
        for (i = 0; i < 4; i++)
            if (c[i]->bg == ((tiles[setno][t2].words[i] >> 24) & 0xff))
                score++;
        if (score == 4) {
            *score_out = 2;
            return t2;
        }
    }
    return -1;
}

/* ------------------------------------------------------------- rendering -- */
/* what the renderer decided for each cell: 0 = draw it as text, 1 = a tile
   covers it exactly, 2 = a tile is behind it and the cell is a sprite on top */
static Uint8 covered[SCR_H][SCR_W];
static Uint32 cover_word[SCR_H][SCR_W];

static int screen_picture(void)
{
    if (species_in(0, 4, 1, 35) >= 0 && screen_has(0, 4, 1, 35, "Lv"))
        return 1;                                 /* wild battle: the field */
    if (screen_has(0, 11, 0, 79, "wants to fight"))
        return 2;                                 /* trainer battle: the city */
    if (count_blocks() > 1200)
        return 0;                                 /* the title screen */
    return -1;
}

static void render(void)
{
    int x, y, vx, vy, pic = screen_picture();
    int art_mode = (pic == 0 || pic == 1 || pic == 2);
    int battle = (pic == 1 || pic == 2);


    memset(frame, 0, sizeof(frame));
    memset(covered, 0, sizeof(covered));

    if (pic >= 0)
        blit_indexed(pictures[pic], SCR_PW, SCR_PH, 0, 0, SCR_PW, SCR_PH);

    /* ---- the map, in generated tile art ---- */
    if (!art_mode) {
        for (vy = 0; vy < 8; vy++) {
            for (vx = 0; vx < SCR_W / 2; vx++) {
                int s0 = 0, s1 = 0, score = 0;
                int t0 = block_tile(vx, vy, 0, &s0);
                int t1 = block_tile(vx, vy, 1, &s1);
                int setno, t;
                if (t0 >= 0 && s0 >= s1) {
                    setno = 0;
                    t = t0;
                } else if (t1 >= 0) {
                    setno = 1;
                    t = t1;
                } else {
                    continue;
                }
                score = (setno == 0) ? s0 : s1;
                blit_indexed(tiles[setno][t].px, TILE_PX, TILE_PX,
                             vx * 2 * CELL_W, (1 + vy * 2) * CELL_H,
                             TILE_PX, TILE_PX);
                for (y = 0; y < 2; y++) {
                    for (x = 0; x < 2; x++) {
                        int gy = 1 + vy * 2 + y, gx = vx * 2 + x;
                        covered[gy][gx] = (score == 4) ? 1 : 2;
                        cover_word[gy][gx] =
                            tiles[setno][t].words[y * 2 + x];
                    }
                }
            }
        }
    }

    /* ---- creatures, under the interface but over the backdrop ---- */
    if (battle) {
        int en = species_in(0, 4, 1, 35);
        int al = species_in(8, 15, 36, 79);
        if (getenv("POKEGUI_DEBUG")) {
            int n = 0, i2;
            for (i2 = 0; i2 < SPECIES_PX * SPECIES_PX; i2++)
                if (species[al >= 0 ? al : 0].px[i2] != 255)
                    n++;
            fprintf(stderr, "battle: pic=%d enemy=%d ally=%d solid=%d first=%d,%d,%d\n",
                    pic, en, al, n, species[0].px[0], species[0].px[1],
                    species[0].px[96 * 40 + 48]);
        }
        if (en >= 0)
            blit_indexed(species[en].px, SPECIES_PX, SPECIES_PX,
                         52 * CELL_W, 4 * CELL_H, CREATURE_PX, CREATURE_PX);
        if (al >= 0)
            blit_indexed(species[al].px, SPECIES_PX, SPECIES_PX,
                         6 * CELL_W, 5 * CELL_H, CREATURE_PX, CREATURE_PX);
    }

    /* ---- everything the game draws in characters ---- */
    for (y = 0; y < SCR_H; y++) {
        for (x = 0; x < SCR_W; x++) {
            const Cell *c = &grid[y][x];
            int px = x * CELL_W, py = y * CELL_H;
            Uint32 col;

            if (covered[y][x]) {
                if (covered[y][x] == 1 && cell_matches(c, cover_word[y][x]))
                    continue;                    /* the tile art says it all */
                if (c->glyph >= 32 && c->glyph < 127) {
                    col = (c->fg == 0) ? 0xffc8c8c8u : rgb(c->fg);
                    blit_glyph(c->glyph, px, py, col);
                }
                continue;
            }

            if (c->glyph == 0) {                 /* blank: its background */
                /* Over a picture (title, battle) a blank cell must not paint
                   the whole screen black -- but the *inside of a box* is blank
                   cells too, and that has to be filled.  A box interior always
                   has frame characters nearby, so that is the test. */
                if (art_mode && c->bg == 0 && !enclosed(x, y))
                    continue;
                fill_rect(px, py, CELL_W, CELL_H, rgb(c->bg));
                continue;
            }
            if (c->glyph <= 3) {                 /* the game's half-block art */
                /* On the title screen the whole screen is one picture and the
                   wordmark is drawn over it as blocks: keep the wordmark, drop
                   the rest (the packed picture is better than the blocks).  In
                   a battle the blocks are the small creature sprites, which the
                   front-end replaces with the full-size pictures. */
                if (pic == 0) {
                    if (x < 16 || x > 63 || y < 15 || y > 22)
                        continue;
                } else if (art_mode) {
                    continue;
                }
                fill_rect(px, py, CELL_W, CELL_H, rgb(c->bg));
                if (c->glyph == 1)
                    fill_rect(px, py, CELL_W, CELL_H, rgb(c->fg));
                else if (c->glyph == 2)
                    fill_rect(px, py, CELL_W, CELL_H / 2, rgb(c->fg));
                else
                    fill_rect(px, py + CELL_H / 2, CELL_W, CELL_H / 2,
                              rgb(c->fg));
                continue;
            }
            fill_rect(px, py, CELL_W, CELL_H, rgb(c->bg));
            col = (c->fg == 0 && c->bg == 0) ? 0xffc8c8c8u : rgb(c->fg);
            blit_glyph(c->glyph, px, py, col);
        }
    }
}

/* --------------------------------------------------------------- bmp out -- */
static void save_bmp(const char *path)
{
    int w = SCR_PW, h = SCR_PH, x, y;
    int row_pad = (4 - (w * 3) % 4) % 4;
    int size = 54 + (w * 3 + row_pad) * h;
    Uint8 hdr[54];
    FILE *fh = fopen(path, "wb");

    if (!fh)
        die("cannot write the shot");
    memset(hdr, 0, sizeof(hdr));
    hdr[0] = 'B'; hdr[1] = 'M';
    hdr[2] = size & 0xff; hdr[3] = (size >> 8) & 0xff;
    hdr[4] = (size >> 16) & 0xff; hdr[5] = (size >> 24) & 0xff;
    hdr[10] = 54;
    hdr[14] = 40;
    hdr[18] = w & 0xff; hdr[19] = (w >> 8) & 0xff;
    hdr[22] = h & 0xff; hdr[23] = (h >> 8) & 0xff;
    hdr[26] = 1;
    hdr[28] = 24;
    fwrite(hdr, 1, 54, fh);
    for (y = h - 1; y >= 0; y--) {
        for (x = 0; x < w; x++) {
            Uint32 v = frame[(size_t)y * w + x];
            Uint8 bgr[3];
            bgr[0] = v & 0xff;
            bgr[1] = (v >> 8) & 0xff;
            bgr[2] = (v >> 16) & 0xff;
            fwrite(bgr, 1, 3, fh);
        }
        for (x = 0; x < row_pad; x++)
            fputc(0, fh);
    }
    fclose(fh);
    printf("wrote %s (%dx%d)\n", path, w, h);
}

/* ------------------------------------------------------------- the game --- */
static pid_t child;
static int master_fd = -1, child_alive = 1;

static void spawn_game(int quickstart)
{
    struct winsize ws;
    pid_t pid;

    /* a checkout out of an archive or a snapshot can have 0644 on the game */
    if (access(game_path, X_OK) != 0)
        chmod(game_path, 0755);
    pid = forkpty(&master_fd, NULL, NULL, NULL);
    if (pid < 0)
        die("forkpty failed");
    if (pid == 0) {
        if (chdir(root) != 0)
            _exit(1);
        if (quickstart) {
            char *av[4];
            av[0] = (char *)game_path;
            av[1] = (char *)"--fast";
            av[2] = (char *)"--quickstart";
            av[3] = NULL;
            execv(game_path, av);
        } else {
            char *av[3];
            av[0] = (char *)game_path;
            av[1] = (char *)"--fast";
            av[2] = NULL;
            execv(game_path, av);
        }
        _exit(127);
    }
    child = pid;
    ws.ws_row = SCR_H;
    ws.ws_col = SCR_W;
    ws.ws_xpixel = ws.ws_ypixel = 0;
    ioctl(master_fd, TIOCSWINSZ, &ws);
    fcntl(master_fd, F_SETFL, O_NONBLOCK);
}

static void pump_game(void)
{
    Uint8 buf[1 << 16];
    for (;;) {
        ssize_t n = read(master_fd, buf, sizeof(buf));
        ssize_t i;
        if (n > 0) {
            for (i = 0; i < n; i++)
                ansi_byte(buf[i]);
            dirty = 1;
            continue;
        }
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK))
            child_alive = 0;
        break;
    }
}

static void send_key(const char *s)
{
    if (master_fd >= 0 && child_alive && s && *s)
        (void)!write(master_fd, s, strlen(s));
}

static const char *key_bytes(SDL_Keycode k)
{
    switch (k) {
    case SDLK_UP: return "\033[A";
    case SDLK_DOWN: return "\033[B";
    case SDLK_RIGHT: return "\033[C";
    case SDLK_LEFT: return "\033[D";
    case SDLK_RETURN: case SDLK_KP_ENTER: return "\r";
    case SDLK_SPACE: return " ";
    case SDLK_z: return "z";
    case SDLK_x: return "x";
    case SDLK_m: return "m";
    case SDLK_q: return "q";
    case SDLK_w: return "w";
    case SDLK_a: return "a";
    case SDLK_s: return "s";
    case SDLK_d: return "d";
    default: return NULL;
    }
}

/* A script character from tests/play.py -> the keystroke the game listens for.
   The scenario alphabet is not the keyboard: 'a' is the A button, which is Z. */
static const char *script_key(char c)
{
    switch (c) {
    case 'u': return "\033[A";
    case 'd': return "\033[B";
    case 'l': return "\033[D";
    case 'r': return "\033[C";
    case 'a': return "z";
    case 'b': return "x";
    case 's': return "\r";
    case 'q': return "q";
    case '.': return NULL;                    /* a wait tick */
    case 'D': return NULL;                    /* dump: nothing to press */
    default: return NULL;
    }
}

static void nap_ms(long ms)
{
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

int main(int argc, char **argv)
{
    const char *shot = NULL, *scenario = NULL, *keys = NULL;
    int scale = 1, quickstart = 1, headless = 0, i;
    char asset_path[512];

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--game") && i + 1 < argc)
            game_path = argv[++i];
        else if (!strcmp(argv[i], "--shot") && i + 1 < argc) {
            shot = argv[++i];
            headless = 1;
        } else if (!strcmp(argv[i], "--scenario") && i + 1 < argc)
            scenario = argv[++i];
        else if (!strcmp(argv[i], "--keys") && i + 1 < argc)
            keys = argv[++i];
        else if (!strcmp(argv[i], "--scale") && i + 1 < argc)
            scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-quickstart"))
            quickstart = 0;
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: pokemon-gui [--scale N] [--game PATH] [--keys KEYS]\n"
                   "                   [--scenario NAME] [--shot FILE.bmp]\n");
            return 0;
        }
    }
    {
        const char *slash = strrchr(game_path, '/');
        if (slash && slash != game_path) {
            static char buf[512];
            size_t n = (size_t)(slash - game_path);
            memcpy(buf, game_path, n);
            buf[n] = 0;
            root = buf;
        }
    }
    snprintf(asset_path, sizeof(asset_path), "%s/frontend/assets.bin", root);
    if (headless)
        setenv("SDL_VIDEODRIVER", "dummy", 0);
    load_assets(asset_path);

    if (getenv("POKEGUI_TESTCREATURE")) {
        int i2;
        for (i2 = 0; i2 < SCR_PW * SCR_PH; i2++)
            frame[i2] = 0xff3070a0u;                  /* a solid blue field */
        for (i2 = 0; i2 < n_species && i2 < 8; i2++) {
            int dx = (i2 % 4) * 320 + 20, dy = (i2 / 4) * 190 + 10;
            blit_indexed(species[i2].px, SPECIES_PX, SPECIES_PX, dx, dy,
                         CREATURE_PX, CREATURE_PX);
        }
        save_bmp("creature_test.bmp");
        return 0;
    }
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        die(SDL_GetError());
    {
        SDL_Window *win;
        SDL_Renderer *ren;
        SDL_Texture *tex;
        int w = SCR_PW * (scale < 1 ? 1 : scale);
        int h = SCR_PH * (scale < 1 ? 1 : scale);

        win = SDL_CreateWindow("POKeMON FIRE RED - ASM EDITION",
                               SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                               w, h, SDL_WINDOW_SHOWN);
        if (!win)
            die(SDL_GetError());
        ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
        if (!ren)
            ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
        if (!ren)
            die(SDL_GetError());
        SDL_RenderSetLogicalSize(ren, SCR_PW, SCR_PH);
        tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
                                SDL_TEXTUREACCESS_STREAMING, SCR_PW, SCR_PH);
        if (!tex)
            die(SDL_GetError());

        spawn_game(quickstart);

        if (headless) {
            char script[4096];
            size_t k = 0, slen = 0;
            long t = 0;
            script[0] = 0;
            if (scenario) {
                char cmd[512];
                FILE *fh;
                snprintf(cmd, sizeof(cmd), "python3 tests/play.py %s 2>/dev/null",
                         scenario);
                fh = popen(cmd, "r");
                if (fh) {
                    char raw[4096];
                    size_t got = fread(raw, 1, sizeof(raw) - 1, fh), m;
                    raw[got] = 0;
                    for (m = 0; m < got; m++) {
                        char c = raw[m];
                        if (c == '\n' || c == '\r' || c == ' ' || c == '\t')
                            continue;
                        if (k < sizeof(script) - 1)
                            script[k++] = c;
                    }
                    script[k] = 0;
                    pclose(fh);
                }
            } else if (keys) {
                size_t m;
                for (m = 0; keys[m] && k < sizeof(script) - 1; m++) {
                    if (keys[m] == '\n' || keys[m] == '\r' || keys[m] == ' ')
                        continue;
                    script[k++] = keys[m];
                }
                script[k] = 0;
            }
            slen = strlen(script);
            k = 0;                        /* it was the fill index until here */
            if (getenv("POKEGUI_DEBUG"))
                fprintf(stderr, "script: %d keys, first 40: %.40s\n", (int)slen,
                        script);
            /* settle, then type the script, then settle again */
            while (t < 40000) {
                pump_game();
                if (k < slen) {
                    send_key(script_key(script[k]));
                    k++;
                }
                nap_ms(30);
                t += 30;
                if (k >= slen && t > (slen ? 2500 : 6000))
                    break;
                if (!child_alive)
                    break;
            }
            if (getenv("POKEGUI_DEBUG"))
                fprintf(stderr, "loop end: sent %d/%d keys, t=%ld, alive=%d\n",
                        (int)k, (int)slen, t, child_alive);
            render();
            if (getenv("POKEGUI_DEBUG")) {
                int r, c2;
                for (r = 12; r < 24; r++) {
                    fprintf(stderr, "%2d |", r);
                    for (c2 = 0; c2 < SCR_W; c2++) {
                        Uint8 g = grid[r][c2].glyph;
                        fputc((g >= 32 && g < 127) ? g : (g ? '#' : ' '), stderr);
                    }
                    fprintf(stderr, "|\n");
                }
            }
            save_bmp(shot);
        } else {
            int running = 1;
            while (running) {
                SDL_Event e;
                while (SDL_PollEvent(&e)) {
                    if (e.type == SDL_QUIT)
                        running = 0;
                    else if (e.type == SDL_KEYDOWN) {
                        if (e.key.keysym.sym == SDLK_ESCAPE)
                            running = 0;
                        else
                            send_key(key_bytes(e.key.keysym.sym));
                    }
                }
                pump_game();
                if (dirty) {
                    render();
                    SDL_UpdateTexture(tex, NULL, frame, SCR_PW * 4);
                    SDL_RenderClear(ren);
                    SDL_RenderCopy(ren, tex, NULL, NULL);
                    SDL_RenderPresent(ren);
                    dirty = 0;
                }
                nap_ms(16);
                if (!child_alive) {
                    /* leave the last frame up for a moment, then quit */
                    SDL_Delay(600);
                    running = 0;
                }
            }
        }
        if (child_alive) {
            kill(child, SIGTERM);
            nap_ms(60);
            kill(child, SIGKILL);
        }
        {
            int status = 0;
            waitpid(child, &status, 0);
            if (!child_alive && WIFEXITED(status) && WEXITSTATUS(status) != 0)
                fprintf(stderr, "pokemon-gui: the game exited with status %d "
                                "-- is %s built and executable?\n",
                        WEXITSTATUS(status), game_path);
        }
    }
    SDL_Quit();
    return 0;
}
