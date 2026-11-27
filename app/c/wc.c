/* wc [-l] [-w] [-c] [file...]: lines, words and bytes of each file (or of
 * standard input), and their total for more than one. A plain C program,
 * built against musl with an ordinary Linux toolchain. */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int show_l, show_w, show_c;

static void print(long l, long w, long c, const char *name) {
    if (show_l) printf("%7ld", l);
    if (show_w) printf(" %7ld", w);
    if (show_c) printf(" %7ld", c);
    if (name) printf(" %s", name);
    printf("\n");
}

static int count(int fd, long *l, long *w, long *c) {
    char buf[4096];
    int in_word = 0;
    ssize_t n;
    *l = *w = *c = 0;
    while ((n = read(fd, buf, sizeof buf)) > 0) {
        for (ssize_t i = 0; i < n; i++) {
            unsigned char ch = (unsigned char)buf[i];
            (*c)++;
            if (ch == '\n') (*l)++;
            if (isspace(ch)) {
                in_word = 0;
            } else if (!in_word) {
                in_word = 1;
                (*w)++;
            }
        }
    }
    return n < 0 ? -1 : 0;
}

int main(int argc, char **argv) {
    int first = 1, status = 0, files = 0;
    long tl = 0, tw = 0, tc = 0;
    for (; first < argc && argv[first][0] == '-' && argv[first][1]; first++) {
        for (const char *p = argv[first] + 1; *p; p++) {
            if (*p == 'l') show_l = 1;
            else if (*p == 'w') show_w = 1;
            else if (*p == 'c') show_c = 1;
            else {
                fprintf(stderr, "wc: invalid option -- '%c'\n", *p);
                return 1;
            }
        }
    }
    if (!show_l && !show_w && !show_c) show_l = show_w = show_c = 1;
    if (first == argc) {
        long l, w, c;
        if (count(0, &l, &w, &c) < 0) {
            perror("wc");
            return 1;
        }
        print(l, w, c, NULL);
        return 0;
    }
    for (int i = first; i < argc; i++) {
        int fd = open(argv[i], O_RDONLY);
        long l, w, c;
        if (fd < 0) {
            fprintf(stderr, "wc: %s: %s\n", argv[i], strerror(errno));
            status = 1;
            continue;
        }
        if (count(fd, &l, &w, &c) < 0) {
            fprintf(stderr, "wc: %s: %s\n", argv[i], strerror(errno));
            status = 1;
        } else {
            print(l, w, c, argv[i]);
            tl += l, tw += w, tc += c, files++;
        }
        close(fd);
    }
    if (files > 1) print(tl, tw, tc, "total");
    return status;
}
