// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Cabinet reader (CabinetReader.h). The format, little-endian throughout:
//
//   CFHEADER  "MSCF", reserved1, cbCabinet, reserved2, coffFiles, reserved3, versionMinor,
//             versionMajor, cFolders, cFiles, flags, setID, iCabinet; when flags has
//             RESERVE_PRESENT: cbCFHeader (u16), cbCFFolder (u8), cbCFData (u8), then
//             cbCFHeader reserved bytes. PREV_CABINET / NEXT_CABINET add strings after that,
//             which this reader skips; a file that continues into the next cabinet is refused.
//   CFFOLDER  coffCabStart, cCFData, typeCompress, cbCFFolder reserved bytes.
//   CFFILE    cbFile, uoffFolderStart, iFolder, date, time, attribs, szName (NUL-terminated).
//   CFDATA    csum, cbData, cbUncomp, cbCFData reserved bytes, cbData bytes.
//
// A folder's files are byte ranges of the concatenation of its blocks' output. An MSZIP block
// is "CK" followed by one raw deflate stream whose output is at most 32 KiB and which may refer
// to the previous 32 KiB of the folder's output: each block is inflated with that output as
// the preset dictionary. The block checksums are not verified: the caller checks what it takes
// out (VCRedist.swift verifies the PE machine, the signature directory and the version).
//
// LZX folders (what the DirectX redistributable and its inner cabinets use) are decoded by the
// section "LZX" below, written from the LZX description in the Cabinet File Format
// specification: 16-bit little-endian words read most significant bit first, canonical Huffman
// trees whose lengths are sent as deltas against the previous block's, the repeated-offset
// queue, 32 KiB frames (one CFDATA each), and the x86 call-address (E8) translation applied to
// each frame as it is written out. A folder is decoded only as far as the file asked for ends,
// frame by frame, so a 100 MB redistributable is not unpacked for a file near its start.

#include "CabinetReader.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

enum {
    CAB_HEADER_BYTES = 36,
    CAB_FOLDER_BYTES = 8,
    CAB_FILE_BYTES = 16,
    CAB_DATA_BYTES = 8,
    CAB_BLOCK_MAX = 32768,
    CAB_NAME_MAX = 255,
    CAB_FOLDER_MAX = 256u << 20,          /* the most a decompressed folder may take: 256 MiB */
    CAB_FILES_MAX = 65535,
    CAB_FLAG_PREV = 1, CAB_FLAG_NEXT = 2, CAB_FLAG_RESERVE = 4,
    CAB_COMPRESS_NONE = 0, CAB_COMPRESS_MSZIP = 1, CAB_COMPRESS_LZX = 3,
    CAB_FOLDER_CONTINUED = 0xFFFD,         /* iFolder values from here up: continued elsewhere */
};

typedef struct {
    uint32_t first;                    /* coffCabStart */
    uint32_t blocks;                   /* cCFData */
    uint32_t type;                     /* typeCompress & 0xF */
    uint8_t *data;                     /* the decompressed folder, once used */
    size_t size;                       /* its length */
    unsigned window_bits;              /* LZX: typeCompress >> 8 */
    size_t decoded;                    /* LZX: bytes of data written so far (size when whole) */
    struct lzx_state *lzx;             /* LZX: the decoder, kept between calls */
} cab_folder;

typedef struct {
    uint32_t size;
    uint32_t offset;
    uint32_t folder;
    char name[CAB_NAME_MAX + 1];
} cab_file;

struct madeira_cab {
    const uint8_t *bytes;
    size_t length;                     /* bytes available */
    size_t cabinet;                    /* cbCabinet */
    unsigned data_reserve;             /* cbCFData */
    unsigned folder_count, file_count;
    cab_folder *folders;
    cab_file *files;
};

struct lzx_state;
static void lzx_free(struct lzx_state *s);
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/* Skips a NUL-terminated string at *pos (bounded); 0 if it runs off the end. */
static int skip_string(const madeira_cab *cab, size_t *pos)
{
    size_t p = *pos;
    while (p < cab->length && cab->bytes[p]) p++;
    if (p >= cab->length) return 0;
    *pos = p + 1;
    return 1;
}

int madeira_cab_open(const void *bytes, size_t length, madeira_cab **out)
{
    const uint8_t *b = bytes;
    *out = NULL;
    if (!b || length < CAB_HEADER_BYTES) return MADEIRA_CAB_BAD_HEADER;
    if (memcmp(b, "MSCF", 4) != 0 || rd32(b + 4) != 0 || rd32(b + 12) != 0 || rd32(b + 20) != 0) return MADEIRA_CAB_BAD_HEADER;
    uint32_t cabinet = rd32(b + 8), files_at = rd32(b + 16);
    unsigned minor = b[24], major = b[25];
    unsigned folders = rd16(b + 26), files = rd16(b + 28), flags = rd16(b + 30);
    if (major != 1 || minor != 3 || folders == 0 || files == 0 || files > CAB_FILES_MAX) return MADEIRA_CAB_BAD_HEADER;
    if (cabinet < CAB_HEADER_BYTES || cabinet > length) return MADEIRA_CAB_TRUNCATED;

    madeira_cab *cab = calloc(1, sizeof *cab);
    if (!cab) return MADEIRA_CAB_NO_MEMORY;
    cab->bytes = b;
    cab->length = cabinet;             /* nothing past cbCabinet belongs to this cabinet */
    cab->cabinet = cabinet;

    size_t pos = CAB_HEADER_BYTES;
    unsigned folder_reserve = 0;
    if (flags & CAB_FLAG_RESERVE) {
        if (pos + 4 > cab->length) { free(cab); return MADEIRA_CAB_TRUNCATED; }
        unsigned header_reserve = rd16(b + pos);
        folder_reserve = b[pos + 2];
        cab->data_reserve = b[pos + 3];
        pos += 4;
        if (pos + header_reserve > cab->length) { free(cab); return MADEIRA_CAB_TRUNCATED; }
        pos += header_reserve;
    }
    if (flags & CAB_FLAG_PREV) { if (!skip_string(cab, &pos) || !skip_string(cab, &pos)) { free(cab); return MADEIRA_CAB_TRUNCATED; } }
    if (flags & CAB_FLAG_NEXT) { if (!skip_string(cab, &pos) || !skip_string(cab, &pos)) { free(cab); return MADEIRA_CAB_TRUNCATED; } }

    cab->folders = calloc(folders, sizeof *cab->folders);
    cab->files = calloc(files, sizeof *cab->files);
    if (!cab->folders || !cab->files) { madeira_cab_close(cab); return MADEIRA_CAB_NO_MEMORY; }
    cab->folder_count = folders;
    cab->file_count = files;

    for (unsigned i = 0; i < folders; i++) {
        if (pos + CAB_FOLDER_BYTES + folder_reserve > cab->length) { madeira_cab_close(cab); return MADEIRA_CAB_TRUNCATED; }
        cab->folders[i].first = rd32(b + pos);
        cab->folders[i].blocks = rd16(b + pos + 4);
        cab->folders[i].type = rd16(b + pos + 6) & 0xF;
        cab->folders[i].window_bits = (rd16(b + pos + 6) >> 8) & 0x1F;
        pos += CAB_FOLDER_BYTES + folder_reserve;
    }

    pos = files_at;
    for (unsigned i = 0; i < files; i++) {
        if (pos + CAB_FILE_BYTES > cab->length) { madeira_cab_close(cab); return MADEIRA_CAB_TRUNCATED; }
        cab_file *f = &cab->files[i];
        f->size = rd32(b + pos);
        f->offset = rd32(b + pos + 4);
        f->folder = rd16(b + pos + 8);
        pos += CAB_FILE_BYTES;
        size_t n = 0;
        while (pos + n < cab->length && b[pos + n] && n < CAB_NAME_MAX) n++;
        if (pos + n >= cab->length || b[pos + n]) { madeira_cab_close(cab); return MADEIRA_CAB_BAD_HEADER; }   /* no NUL within 255 bytes */
        memcpy(f->name, b + pos, n);
        f->name[n] = 0;
        pos += n + 1;
    }
    *out = cab;
    return MADEIRA_CAB_OK;
}

void madeira_cab_close(madeira_cab *cab)
{
    if (!cab) return;
    if (cab->folders) {
        for (unsigned i = 0; i < cab->folder_count; i++) { free(cab->folders[i].data); lzx_free(cab->folders[i].lzx); }
        free(cab->folders);
    }
    free(cab->files);
    free(cab);
}

size_t madeira_cab_length(const madeira_cab *cab) { return cab ? cab->cabinet : 0; }
unsigned madeira_cab_file_count(const madeira_cab *cab) { return cab ? cab->file_count : 0; }
const char *madeira_cab_file_name(const madeira_cab *cab, unsigned index)
{
    return cab && index < cab->file_count ? cab->files[index].name : NULL;
}
uint32_t madeira_cab_file_size(const madeira_cab *cab, unsigned index)
{
    return cab && index < cab->file_count ? cab->files[index].size : 0;
}


/* ------------------------------------------------------------------------------------------ */
/* LZX */

enum { LZX_MAIN_MAX = 256 + 8 * 51, LZX_LEN_SYMS = 249, LZX_FRAME = 32768, LZX_MAXLEN = 16 };

typedef struct {                       /* canonical Huffman code, lengths up to 16 */
    uint16_t count[LZX_MAXLEN + 1];
    uint16_t first[LZX_MAXLEN + 1];    /* the first code of each length */
    uint16_t base[LZX_MAXLEN + 1];     /* index in `sorted` of each length's first symbol */
    uint16_t sorted[LZX_MAIN_MAX];
    unsigned maxlen;
} lzx_tree;

typedef struct lzx_state {
    unsigned window_bits, slots;
    uint8_t *window;                   /* ring of 1 << window_bits bytes: the raw output */
    size_t wpos, produced;             /* write position in the ring, bytes ever produced */
    uint32_t r0, r1, r2;
    int header_read, intel_started;
    uint32_t intel_filesize;
    int64_t intel_curpos;
    unsigned block_type;               /* 0 none yet, 1 verbatim, 2 aligned, 3 uncompressed */
    uint32_t block_remaining;
    int block_odd;                     /* an uncompressed block of odd size: a pad byte follows */
    uint8_t main_len[LZX_MAIN_MAX], len_len[LZX_LEN_SYMS];
    lzx_tree main_tree, len_tree, aligned_tree;
    uint32_t next_block;               /* the next CFDATA of the folder */
    size_t next_pos;                   /* and where it starts */
    uint32_t frame;                    /* frames written so far */
    /* the bit reader over the current CFDATA */
    const uint8_t *ip, *iend;
    uint64_t bitbuf;
    unsigned bitsleft;
} lzx_state;

static void lzx_free(lzx_state *s)
{
    if (!s) return;
    free(s->window);
    free(s);
}

static void lzx_load(lzx_state *s)     /* one more 16-bit word (zeros past the end of the block) */
{
    unsigned w = 0;
    if (s->ip + 1 < s->iend) w = (unsigned)(s->ip[0] | (s->ip[1] << 8));
    else if (s->ip < s->iend) w = s->ip[0];
    s->ip += 2;
    s->bitbuf |= (uint64_t)w << (48 - s->bitsleft);
    s->bitsleft += 16;
}
static uint32_t lzx_bits(lzx_state *s, unsigned n)   /* n in 0..17 */
{
    if (!n) return 0;
    while (s->bitsleft < n) lzx_load(s);
    uint32_t v = (uint32_t)(s->bitbuf >> (64 - n));
    s->bitbuf <<= n;
    s->bitsleft -= n;
    return v;
}

/* Builds the canonical code of lens[0..n); 0 if the lengths over-subscribe it. */
static int lzx_build(lzx_tree *t, const uint8_t *lens, unsigned n)
{
    memset(t, 0, sizeof *t);
    for (unsigned i = 0; i < n; i++) t->count[lens[i]]++;
    t->count[0] = 0;
    int left = 1;
    for (unsigned l = 1; l <= LZX_MAXLEN; l++) {
        left = (left << 1) - t->count[l];
        if (left < 0) return 0;
        if (t->count[l]) t->maxlen = l;
    }
    unsigned code = 0, index = 0;
    for (unsigned l = 1; l <= LZX_MAXLEN; l++) {
        code = (code + t->count[l - 1]) << 1;
        t->first[l] = (uint16_t)code;
        t->base[l] = (uint16_t)index;
        index += t->count[l];
    }
    uint16_t next[LZX_MAXLEN + 1];
    memcpy(next, t->base, sizeof next);
    for (unsigned i = 0; i < n; i++) if (lens[i]) t->sorted[next[lens[i]]++] = (uint16_t)i;
    return 1;
}

/* One symbol, or -1 when the bits match no code. */
static int lzx_sym(lzx_state *s, const lzx_tree *t)
{
    if (!t->maxlen) return -1;
    while (s->bitsleft < LZX_MAXLEN) lzx_load(s);
    uint32_t peek = (uint32_t)(s->bitbuf >> 48);
    for (unsigned l = 1; l <= t->maxlen; l++) {
        uint32_t code = peek >> (16 - l);
        uint32_t d = code - t->first[l];
        if (code >= t->first[l] && d < t->count[l]) {
            s->bitbuf <<= l;
            s->bitsleft -= l;
            return t->sorted[t->base[l] + d];
        }
    }
    return -1;
}

/* The lengths of lens[first..last) as the block header sends them: a 20-symbol code of 4-bit
 * lengths, then deltas against the previous block's lengths (mod 17) with run codes. */
static int lzx_read_lengths(lzx_state *s, uint8_t *lens, unsigned first, unsigned last)
{
    uint8_t pre[20];
    lzx_tree tree;
    for (unsigned i = 0; i < 20; i++) pre[i] = (uint8_t)lzx_bits(s, 4);
    if (!lzx_build(&tree, pre, 20)) return 0;
    for (unsigned i = first; i < last;) {
        int z = lzx_sym(s, &tree);
        if (z < 0) return 0;
        if (z == 17 || z == 18) {
            unsigned run = z == 17 ? 4 + lzx_bits(s, 4) : 20 + lzx_bits(s, 5);
            if (i + run > last) return 0;
            while (run--) lens[i++] = 0;
        } else if (z == 19) {
            unsigned run = 4 + lzx_bits(s, 1);
            int d = lzx_sym(s, &tree);
            if (d < 0 || i + run > last) return 0;
            uint8_t v = (uint8_t)((lens[i] + 17 - d) % 17);
            while (run--) lens[i++] = v;
        } else {
            lens[i] = (uint8_t)((lens[i] + 17 - z) % 17);
            i++;
        }
    }
    return 1;
}

static int lzx_block_header(lzx_state *s)
{
    if (!s->header_read) {
        s->header_read = 1;
        if (lzx_bits(s, 1)) {
            uint32_t hi = lzx_bits(s, 16), lo = lzx_bits(s, 16);
            s->intel_filesize = (hi << 16) | lo;
        }
    }
    unsigned type = lzx_bits(s, 3);
    uint32_t hi = lzx_bits(s, 16), lo = lzx_bits(s, 8);
    uint32_t size = (hi << 8) | lo;
    if (type < 1 || type > 3 || size == 0) return 0;
    s->block_type = type;
    s->block_remaining = size;
    s->block_odd = 0;
    if (type == 3) {
        /* Pad to a 16-bit boundary (1 to 16 bits), then three little-endian offsets, then the bytes. */
        while (s->bitsleft < 16) lzx_load(s);
        unsigned pad = s->bitsleft % 16;
        if (!pad) pad = 16;
        s->bitbuf <<= pad;
        s->bitsleft -= pad;
        s->ip -= s->bitsleft / 8;          /* the whole words still in the buffer go back */
        s->bitbuf = 0;
        s->bitsleft = 0;
        if (s->ip + 12 > s->iend) return 0;
        s->r0 = rd32(s->ip); s->r1 = rd32(s->ip + 4); s->r2 = rd32(s->ip + 8);
        s->ip += 12;
        s->block_odd = size & 1;
        return 1;
    }
    if (type == 2) {
        uint8_t al[8];
        for (unsigned i = 0; i < 8; i++) al[i] = (uint8_t)lzx_bits(s, 3);
        if (!lzx_build(&s->aligned_tree, al, 8)) return 0;
    }
    unsigned main_syms = 256 + 8 * s->slots;
    if (!lzx_read_lengths(s, s->main_len, 0, 256)) return 0;
    if (!lzx_read_lengths(s, s->main_len, 256, main_syms)) return 0;
    if (!lzx_read_lengths(s, s->len_len, 0, LZX_LEN_SYMS)) return 0;
    if (!lzx_build(&s->main_tree, s->main_len, main_syms)) return 0;
    if (!lzx_build(&s->len_tree, s->len_len, LZX_LEN_SYMS)) return 0;
    if (s->main_len[0xE8]) s->intel_started = 1;
    return 1;
}

static unsigned lzx_footer_bits(unsigned slot) { return slot < 4 ? 0 : slot < 36 ? slot / 2 - 1 : 17; }
static uint32_t lzx_slot_base(unsigned slot)
{
    uint32_t base = 0;
    for (unsigned i = 0; i < slot; i++) base += 1u << lzx_footer_bits(i);
    return base;
}

/* Decodes one frame of `frame_size` bytes from the CFDATA at s->ip..iend into the ring. */
static int lzx_frame(lzx_state *s, unsigned frame_size)
{
    const size_t mask = ((size_t)1 << s->window_bits) - 1;
    unsigned done = 0;
    s->bitbuf = 0;
    s->bitsleft = 0;
    while (done < frame_size) {
        if (s->block_remaining == 0) {
            if (!lzx_block_header(s)) return 0;
        }
        unsigned run = s->block_remaining < frame_size - done ? s->block_remaining : frame_size - done;
        if (s->block_type == 3) {
            if (s->ip + run > s->iend) return 0;
            for (unsigned i = 0; i < run; i++) s->window[(s->wpos + i) & mask] = s->ip[i];
            s->ip += run;
            s->wpos = (s->wpos + run) & mask;
            s->produced += run;
            done += run;
            s->block_remaining -= run;
            if (s->block_remaining == 0 && s->block_odd) s->ip += 1;
            continue;
        }
        s->block_remaining -= run;
        done += run;
        while (run > 0) {
            int sym = lzx_sym(s, &s->main_tree);
            if (sym < 0) return 0;
            if (sym < 256) {
                s->window[s->wpos] = (uint8_t)sym;
                s->wpos = (s->wpos + 1) & mask;
                s->produced++;
                run--;
                continue;
            }
            sym -= 256;
            unsigned length = (unsigned)(sym & 7) + 2, slot = (unsigned)sym >> 3;
            if ((sym & 7) == 7) {
                int l = lzx_sym(s, &s->len_tree);
                if (l < 0) return 0;
                length += (unsigned)l;
            }
            uint32_t offset;
            if (slot == 0) offset = s->r0;
            else if (slot == 1) { offset = s->r1; s->r1 = s->r0; s->r0 = offset; }
            else if (slot == 2) { offset = s->r2; s->r2 = s->r0; s->r0 = offset; }
            else {
                unsigned footer = lzx_footer_bits(slot);
                uint32_t extra;
                if (s->block_type == 2 && footer >= 3) {
                    extra = lzx_bits(s, footer - 3) << 3;
                    int a = lzx_sym(s, &s->aligned_tree);
                    if (a < 0) return 0;
                    extra += (uint32_t)a;
                } else extra = lzx_bits(s, footer);
                offset = lzx_slot_base(slot) - 2 + extra;
                s->r2 = s->r1; s->r1 = s->r0; s->r0 = offset;
            }
            if (length > run || offset == 0 || offset > mask || offset > s->produced) return 0;
            for (unsigned i = 0; i < length; i++) {
                s->window[s->wpos] = s->window[(s->wpos - offset) & mask];
                s->wpos = (s->wpos + 1) & mask;
            }
            s->produced += length;
            run -= length;
        }
    }
    return 1;
}

/* Decodes frames of the folder until `upto` bytes (or all of it) are in folder->data. */
static int lzx_decode(madeira_cab *cab, cab_folder *folder, size_t upto)
{
    lzx_state *s = folder->lzx;
    if (!s) {
        if (folder->window_bits < 15 || folder->window_bits > 21) return MADEIRA_CAB_UNSUPPORTED;
        s = calloc(1, sizeof *s);
        if (!s) return MADEIRA_CAB_NO_MEMORY;
        s->window_bits = folder->window_bits;
        s->slots = folder->window_bits == 21 ? 50 : folder->window_bits == 20 ? 42 : folder->window_bits == 19 ? 38
                 : folder->window_bits == 18 ? 36 : folder->window_bits == 17 ? 34 : folder->window_bits == 16 ? 32 : 30;
        s->window = calloc(1, (size_t)1 << s->window_bits);
        if (!s->window) { free(s); return MADEIRA_CAB_NO_MEMORY; }
        s->r0 = s->r1 = s->r2 = 1;
        s->next_pos = folder->first;
        folder->lzx = s;
    }
    while (folder->decoded < upto && folder->decoded < folder->size) {
        if (s->next_block >= folder->blocks) return MADEIRA_CAB_BAD_DATA;
        size_t pos = s->next_pos;
        if (pos + CAB_DATA_BYTES + cab->data_reserve > cab->length) return MADEIRA_CAB_TRUNCATED;
        unsigned packed = rd16(cab->bytes + pos + 4), unpacked = rd16(cab->bytes + pos + 6);
        const uint8_t *payload = cab->bytes + pos + CAB_DATA_BYTES + cab->data_reserve;
        if (pos + CAB_DATA_BYTES + cab->data_reserve + packed > cab->length) return MADEIRA_CAB_TRUNCATED;
        if (unpacked == 0 || unpacked > LZX_FRAME || folder->decoded + unpacked > folder->size) return MADEIRA_CAB_BAD_DATA;
        s->next_pos = pos + CAB_DATA_BYTES + cab->data_reserve + packed;
        s->next_block++;
        s->ip = payload;
        s->iend = payload + packed;
        size_t from = s->wpos;
        if (!lzx_frame(s, unpacked)) return MADEIRA_CAB_BAD_DATA;
        const size_t mask = ((size_t)1 << s->window_bits) - 1;
        uint8_t *dst = folder->data + folder->decoded;
        for (unsigned i = 0; i < unpacked; i++) dst[i] = s->window[(from + i) & mask];
        if (s->intel_started && s->intel_filesize && s->frame < 32768 && unpacked > 10) {
            int64_t cur = s->intel_curpos;
            const int64_t filesize = s->intel_filesize;
            uint8_t *p = dst, *end = dst + unpacked - 10;
            while (p < end) {
                if (*p++ != 0xE8) { cur++; continue; }
                int32_t abs_off = (int32_t)rd32(p);
                if (abs_off >= -cur && abs_off < filesize) {
                    int32_t rel = abs_off >= 0 ? (int32_t)(abs_off - cur) : (int32_t)(abs_off + filesize);
                    p[0] = (uint8_t)rel; p[1] = (uint8_t)(rel >> 8); p[2] = (uint8_t)(rel >> 16); p[3] = (uint8_t)(rel >> 24);
                }
                p += 4;
                cur += 5;
            }
        }
        s->intel_curpos += unpacked;
        s->frame++;
        folder->decoded += unpacked;
    }
    return MADEIRA_CAB_OK;
}

/* Decompresses a folder's blocks into folder->data. */
static int unpack_folder(madeira_cab *cab, cab_folder *folder, size_t upto)
{
    if (folder->type == CAB_COMPRESS_LZX) {
        if (!folder->data) {
            /* The output size from the block headers; the buffer is filled as far as asked. */
            size_t p = folder->first, total = 0;
            for (uint32_t i = 0; i < folder->blocks; i++) {
                if (p + CAB_DATA_BYTES + cab->data_reserve > cab->length) return MADEIRA_CAB_TRUNCATED;
                unsigned packed = rd16(cab->bytes + p + 4), unpacked = rd16(cab->bytes + p + 6);
                p += CAB_DATA_BYTES + cab->data_reserve + packed;
                if (p > cab->length) return MADEIRA_CAB_TRUNCATED;
                total += unpacked;
                if (total > CAB_FOLDER_MAX) return MADEIRA_CAB_TOO_LARGE;
            }
            folder->data = malloc(total ? total : 1);
            if (!folder->data) return MADEIRA_CAB_NO_MEMORY;
            folder->size = total;
            folder->decoded = 0;
        }
        return lzx_decode(cab, folder, upto);
    }
    if (folder->data) return MADEIRA_CAB_OK;
    if (folder->type != CAB_COMPRESS_NONE && folder->type != CAB_COMPRESS_MSZIP) return MADEIRA_CAB_UNSUPPORTED;

    /* First pass: the output size from the block headers. */
    size_t pos = folder->first, total = 0;
    for (uint32_t i = 0; i < folder->blocks; i++) {
        if (pos + CAB_DATA_BYTES + cab->data_reserve > cab->length) return MADEIRA_CAB_TRUNCATED;
        unsigned packed = rd16(cab->bytes + pos + 4), unpacked = rd16(cab->bytes + pos + 6);
        if (unpacked > CAB_BLOCK_MAX) return MADEIRA_CAB_BAD_DATA;
        pos += CAB_DATA_BYTES + cab->data_reserve;
        if (pos + packed > cab->length) return MADEIRA_CAB_TRUNCATED;
        pos += packed;
        total += unpacked;
        if (total > CAB_FOLDER_MAX) return MADEIRA_CAB_TOO_LARGE;
    }
    uint8_t *out = malloc(total ? total : 1);
    if (!out) return MADEIRA_CAB_NO_MEMORY;

    z_stream z;
    memset(&z, 0, sizeof z);
    int z_ready = 0, result = MADEIRA_CAB_OK;
    size_t done = 0;
    pos = folder->first;
    for (uint32_t i = 0; i < folder->blocks && result == MADEIRA_CAB_OK; i++) {
        const uint8_t *block = cab->bytes + pos;
        unsigned packed = rd16(block + 4), unpacked = rd16(block + 6);
        const uint8_t *payload = block + CAB_DATA_BYTES + cab->data_reserve;
        pos += CAB_DATA_BYTES + cab->data_reserve + packed;
        if (folder->type == CAB_COMPRESS_NONE) {
            if (packed != unpacked) { result = MADEIRA_CAB_BAD_DATA; break; }
            memcpy(out + done, payload, unpacked);
            done += unpacked;
            continue;
        }
        /* MSZIP: "CK", then a raw deflate stream. */
        if (packed < 2 || payload[0] != 'C' || payload[1] != 'K') { result = MADEIRA_CAB_BAD_DATA; break; }
        if (!z_ready) {
            if (inflateInit2(&z, -MAX_WBITS) != Z_OK) { result = MADEIRA_CAB_NO_MEMORY; break; }
            z_ready = 1;
        } else if (inflateReset(&z) != Z_OK) { result = MADEIRA_CAB_BAD_DATA; break; }
        if (done > 0) {
            size_t history = done < CAB_BLOCK_MAX ? done : CAB_BLOCK_MAX;
            if (inflateSetDictionary(&z, out + done - history, (uInt)history) != Z_OK) { result = MADEIRA_CAB_BAD_DATA; break; }
        }
        z.next_in = (Bytef *)(payload + 2);
        z.avail_in = packed - 2;
        z.next_out = out + done;
        z.avail_out = unpacked;
        int zr = inflate(&z, Z_FINISH);
        if ((zr != Z_STREAM_END && zr != Z_OK && zr != Z_BUF_ERROR) || z.avail_out != 0) { result = MADEIRA_CAB_BAD_DATA; break; }
        done += unpacked;
    }
    if (z_ready) inflateEnd(&z);
    if (result != MADEIRA_CAB_OK || done != total) { free(out); return result != MADEIRA_CAB_OK ? result : MADEIRA_CAB_BAD_DATA; }
    folder->data = out;
    folder->size = total;
    return MADEIRA_CAB_OK;
}

int madeira_cab_extract(madeira_cab *cab, unsigned index, void *out, size_t capacity)
{
    if (!cab || index >= cab->file_count || !out) return MADEIRA_CAB_BAD_INDEX;
    cab_file *file = &cab->files[index];
    if (file->folder >= CAB_FOLDER_CONTINUED) return MADEIRA_CAB_CONTINUED;
    if (file->folder >= cab->folder_count) return MADEIRA_CAB_BAD_HEADER;
    if (capacity < file->size) return MADEIRA_CAB_BAD_INDEX;
    cab_folder *folder = &cab->folders[file->folder];
    int rc = unpack_folder(cab, folder, (size_t)file->offset + file->size);
    if (rc != MADEIRA_CAB_OK) return rc;
    if ((size_t)file->offset + file->size > folder->size) return MADEIRA_CAB_BAD_DATA;
    if (folder->type == CAB_COMPRESS_LZX && (size_t)file->offset + file->size > folder->decoded) return MADEIRA_CAB_BAD_DATA;
    memcpy(out, folder->data + file->offset, file->size);
    return MADEIRA_CAB_OK;
}

const char *madeira_cab_strerror(int code)
{
    switch (code) {
    case MADEIRA_CAB_OK: return "ok";
    case MADEIRA_CAB_BAD_HEADER: return "not a cabinet this reader understands";
    case MADEIRA_CAB_TRUNCATED: return "the cabinet is cut short";
    case MADEIRA_CAB_UNSUPPORTED: return "a folder uses a compression this reader does not have";
    case MADEIRA_CAB_BAD_DATA: return "a data block does not unpack";
    case MADEIRA_CAB_NO_MEMORY: return "out of memory";
    case MADEIRA_CAB_BAD_INDEX: return "no such file, or the buffer is too small";
    case MADEIRA_CAB_CONTINUED: return "the file continues in another cabinet";
    case MADEIRA_CAB_TOO_LARGE: return "a folder is too large to unpack in memory";
    default: return "unknown error";
    }
}
