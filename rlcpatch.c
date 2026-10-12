/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Loren Weith
 *
 * rlcpatch -- boot-ROM image surgery for the RLC-Club dumper/bovine builds.
 * Pure C89 + stdlib (no deps, no interpreter); compiled by the Makefile with
 * cc, so the build keeps working without a Python runtime.
 *
 *   rlcpatch overlay --base BASE|- --out OUT --slotsz N [--size N] ADDR:FILE...
 *       Overlay regions onto a copy of BASE WITHOUT an erase: every resulting
 *       byte must satisfy (old & new) == new (programming only clears bits),
 *       else the patch is refused.  BASE '-' is a blank all-$FF image.  Reports
 *       the live append-only slots before/after and which the stub will boot.
 *
 *   rlcpatch probe[-pc|-iz|-pk] FW
 *       Print the host reset vector read from FW.  CPU16 vector @ $00000:
 *       word0 = reserved:ZK:SK:PK (PK = word0 & $F), word1 = PC, word2 = SP,
 *       word3 = IZ (all big-endian).  'probe' prints "PC IZ PK".
 *
 *   rlcpatch bovine --fw FW --cow COW --base BOVBASE --out OUT
 *       Graft the cow (assembled at BOVBASE) into FW and redirect the reset
 *       vector to it, preserving the host's SP/IZ and saving its entry for the
 *       cow's CHAIN.  Full image -> erase + burn.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IMGSZ 0x80000L          /* 512 KB boot window */

static const char *prog = "rlcpatch";

static void die(const char *msg)
{
    fprintf(stderr, "%s: ERROR: %s\n", prog, msg);
    exit(1);
}

static long parse_num(const char *s)
{
    char *end;
    long v = strtol(s, &end, 0);
    if (end == s || *end != '\0') {
        fprintf(stderr, "%s: ERROR: bad number '%s'\n", prog, s);
        exit(1);
    }
    return v;
}

/* Read a whole file into a malloc'd buffer; *len gets its length. */
static unsigned char *read_file(const char *path, long *len)
{
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    long n;
    if (!f) {
        fprintf(stderr, "%s: ERROR: cannot open %s\n", prog, path);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = (unsigned char *)malloc(n > 0 ? n : 1);
    if (!buf)
        die("out of memory");
    if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n)
        die("short read");
    fclose(f);
    *len = n;
    return buf;
}

static void write_file(const char *path, const unsigned char *buf, long len)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "%s: ERROR: cannot write %s\n", prog, path);
        exit(1);
    }
    if (fwrite(buf, 1, (size_t)len, f) != (size_t)len)
        die("short write");
    fclose(f);
}

/* Find the next CLI value for an option, or die. */
static const char *opt_val(int argc, char **argv, int *i, const char *name)
{
    if (*i + 1 >= argc) {
        fprintf(stderr, "%s: ERROR: %s needs a value\n", prog, name);
        exit(1);
    }
    return argv[++(*i)];
}

static int rdword(const unsigned char *b, long a)
{
    return (b[a] << 8) | b[a + 1];
}

static void wrword(unsigned char *b, long a, int v)
{
    b[a] = (unsigned char)((v >> 8) & 0xFF);
    b[a + 1] = (unsigned char)(v & 0xFF);
}

/* Print the live append-only slots (header byte neither $FF nor $00). */
static void print_slots(const unsigned char *img, long len, long slotsz)
{
    long i, last = -1;
    int any = 0;
    printf("[");
    for (i = 1; i < len / slotsz; i++) {
        int h = img[i * slotsz];
        if (h != 0xFF && h != 0x00) {
            printf("%s%ld", any ? " " : "", i);
            any = 1;
            last = i;
        }
    }
    printf("]");
    if (last >= 0)
        printf(" -> stub boots slot %ld", last);
    else
        printf(" -> stub boots nothing");
}

static int cmd_overlay(int argc, char **argv)
{
    const char *base = NULL, *out = NULL;
    long slotsz = 0, size = IMGSZ;
    unsigned char *img;
    long changed = 0, nbad = 0;
    long badaddr[16];
    int badold[16], badnew[16];
    int i;

    for (i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--base") == 0) base = opt_val(argc, argv, &i, "--base");
        else if (strcmp(argv[i], "--out") == 0) out = opt_val(argc, argv, &i, "--out");
        else if (strcmp(argv[i], "--slotsz") == 0) slotsz = parse_num(opt_val(argc, argv, &i, "--slotsz"));
        else if (strcmp(argv[i], "--size") == 0) size = parse_num(opt_val(argc, argv, &i, "--size"));
        else break;      /* remaining args are ADDR:FILE regions */
    }
    if (!base || !out || slotsz <= 0) {
        fprintf(stderr, "usage: %s overlay --base BASE|- --out OUT --slotsz N "
                "[--size N] ADDR:FILE...\n", prog);
        return 1;
    }

    if (strcmp(base, "-") == 0) {
        img = (unsigned char *)malloc(size);
        if (!img) die("out of memory");
        memset(img, 0xFF, (size_t)size);
    } else {
        long blen;
        img = read_file(base, &blen);
        if (blen != size) {
            fprintf(stderr, "%s: ERROR: %s is %ld bytes, expected %ld\n",
                    prog, base, blen, size);
            return 1;
        }
    }

    printf("live slots before: ");
    print_slots(img, size, slotsz);
    printf("\n");

    for (; i < argc; i++) {
        char *spec = argv[i];
        char *colon = strchr(spec, ':');
        long addr, dlen, k;
        unsigned char *data;
        char tmp[64];
        if (!colon) {
            fprintf(stderr, "%s: ERROR: region '%s' is not ADDR:FILE\n", prog, spec);
            return 1;
        }
        if (colon - spec >= (long)sizeof(tmp)) die("region address too long");
        memcpy(tmp, spec, colon - spec);
        tmp[colon - spec] = '\0';
        addr = parse_num(tmp);
        data = read_file(colon + 1, &dlen);
        if (addr < 0 || addr + dlen > size) {
            fprintf(stderr, "%s: ERROR: %s (%ld bytes @ %#lx) overruns the "
                    "%#lx-byte ROM\n", prog, colon + 1, dlen, addr, size);
            return 1;
        }
        for (k = 0; k < dlen; k++) {
            int old = img[addr + k], nw = data[k];
            if ((old & nw) != nw) {
                if (nbad < 16) {
                    badaddr[nbad] = addr + k;
                    badold[nbad] = old;
                    badnew[nbad] = nw;
                }
                nbad++;
            } else if (old != nw) {
                img[addr + k] = (unsigned char)nw;
                changed++;
            }
        }
        free(data);
    }

    if (nbad) {
        long show = nbad < 16 ? nbad : 16;
        fprintf(stderr, "REFUSED: %ld byte(s) would need a 0->1 bit change "
                "(erase required):\n", nbad);
        for (i = 0; i < (int)show; i++)
            fprintf(stderr, "  %#07lx: chip %02x -> wanted %02x\n",
                    badaddr[i], badold[i], badnew[i]);
        if (nbad > 16)
            fprintf(stderr, "  ... and %ld more\n", nbad - 16);
        return 1;
    }

    write_file(out, img, size);
    printf("%s: %ld byte(s) newly programmed vs base\n", out, changed);
    printf("live slots after:  ");
    print_slots(img, size, slotsz);
    printf("\n");
    free(img);
    return 0;
}

static int cmd_probe(const char *fw, int which /*0 all,1 pc,2 iz,3 pk*/)
{
    long len;
    unsigned char *b = read_file(fw, &len);
    int pc, iz, pk;
    if (len < 8) die("host image shorter than a reset vector");
    pc = rdword(b, 2);
    iz = rdword(b, 6);
    pk = rdword(b, 0) & 0xF;
    if (which == 1) printf("0x%04X\n", pc);
    else if (which == 2) printf("0x%04X\n", iz);
    else if (which == 3) printf("0x%X\n", pk);
    else printf("0x%04X 0x%04X 0x%X\n", pc, iz, pk);
    free(b);
    return 0;
}

static int cmd_bovine(int argc, char **argv)
{
    const char *fw = NULL, *cow = NULL, *out = NULL;
    long base = -1;
    unsigned char *img, *cowbuf;
    long flen, clen, end, i;
    int ai, w0, pc, sp, iz, bank;

    for (ai = 0; ai < argc; ai++) {
        if (strcmp(argv[ai], "--fw") == 0) fw = opt_val(argc, argv, &ai, "--fw");
        else if (strcmp(argv[ai], "--cow") == 0) cow = opt_val(argc, argv, &ai, "--cow");
        else if (strcmp(argv[ai], "--out") == 0) out = opt_val(argc, argv, &ai, "--out");
        else if (strcmp(argv[ai], "--base") == 0) base = parse_num(opt_val(argc, argv, &ai, "--base"));
        else { fprintf(stderr, "%s: ERROR: unknown arg '%s'\n", prog, argv[ai]); return 1; }
    }
    if (!fw || !cow || !out || base < 0) {
        fprintf(stderr, "usage: %s bovine --fw FW --cow COW --base BOVBASE "
                "--out OUT\n", prog);
        return 1;
    }

    img = read_file(fw, &flen);
    cowbuf = read_file(cow, &clen);
    end = base + clen;

    if (flen != IMGSZ) {
        fprintf(stderr, "%s: ERROR: host image is %ld bytes, expected %ld\n",
                prog, flen, IMGSZ);
        return 1;
    }
    w0 = rdword(img, 0);
    pc = rdword(img, 2);
    sp = rdword(img, 4);
    iz = rdword(img, 6);
    if ((w0 & 0xF) != 0)
        die("host entry is not in bank 0 (vector word0 PK != 0); CHAIN assumes a bank-0 host");
    if (base & 1)
        die("BOVBASE is not word-aligned");
    if (end > IMGSZ)
        die("cow runs past the 512 KB image");
    if ((base >> 16) != ((end - 1) >> 16))
        die("cow straddles a 64 KB bank boundary (PC does not carry into PK)");
    for (i = base; i < end; i++) {
        if (img[i] != 0xFF) {
            fprintf(stderr, "%s: ERROR: byte under the cow at %#07lx is %02x, "
                    "not $FF (would clobber host content)\n", prog, i, img[i]);
            return 1;
        }
    }

    bank = (int)(base >> 16);
    memcpy(img + base, cowbuf, (size_t)clen);
    wrword(img, 0, bank);              /* word0: PK = cow bank, ZK=SK=0 */
    wrword(img, 2, (int)(base & 0xFFFF)); /* word1: PC = cow entry (BOVBASE) */
    wrword(img, 4, sp);                /* word2: SP = host's original */
    wrword(img, 6, iz);                /* word3: IZ = host's original */

    write_file(out, img, IMGSZ);
    printf("bovine: grafted %ld bytes at $%05lX (bank %d), entry $%05lX\n",
           clen, base, bank, base);
    printf("  host original vector: PC=$%04X SP=$%04X IZ=$%04X (word0=$%04X)\n",
           pc, sp, iz, w0);
    printf("  new reset vector: word0=$%04X PC=$%04X SP=$%04X IZ=$%04X\n",
           bank, (int)(base & 0xFFFF), sp, iz);
    printf("  cow chains to host at PC=$%04X (built with HOSTPC=0x%04X "
           "HOSTIZ=0x%04X)\n", pc, pc, iz);
    printf("wrote %s (%ld bytes) -- full image: ERASE + burn\n", out, IMGSZ);
    free(img);
    free(cowbuf);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s {overlay|probe|probe-pc|probe-iz|probe-pk|"
                "bovine} ...\n", prog);
        return 1;
    }
    if (strcmp(argv[1], "overlay") == 0)
        return cmd_overlay(argc - 2, argv + 2);
    if (strcmp(argv[1], "probe") == 0 && argc == 3)
        return cmd_probe(argv[2], 0);
    if (strcmp(argv[1], "probe-pc") == 0 && argc == 3)
        return cmd_probe(argv[2], 1);
    if (strcmp(argv[1], "probe-iz") == 0 && argc == 3)
        return cmd_probe(argv[2], 2);
    if (strcmp(argv[1], "probe-pk") == 0 && argc == 3)
        return cmd_probe(argv[2], 3);
    if (strcmp(argv[1], "bovine") == 0)
        return cmd_bovine(argc - 2, argv + 2);
    fprintf(stderr, "%s: ERROR: unknown subcommand '%s'\n", prog, argv[1]);
    return 1;
}
