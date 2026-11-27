/* head [-n count] [file...]: the first lines of each file (10 unless told),
 * or of standard input. A plain C program, built against musl. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int head(FILE *f, long lines) {
    int ch;
    while (lines > 0 && (ch = getc(f)) != EOF) {
        putchar(ch);
        if (ch == '\n') lines--;
    }
    return ferror(f) ? -1 : 0;
}

int main(int argc, char **argv) {
    long lines = 10;
    int first = 1, status = 0;
    if (first < argc && strcmp(argv[first], "-n") == 0 && first + 1 < argc) {
        char *end;
        lines = strtol(argv[first + 1], &end, 10);
        if (*end || lines < 0) {
            fprintf(stderr, "head: invalid number of lines: '%s'\n", argv[first + 1]);
            return 1;
        }
        first += 2;
    }
    if (first == argc) return head(stdin, lines) < 0;
    for (int i = first; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (!f) {
            fprintf(stderr, "head: cannot open '%s' for reading: %s\n", argv[i], strerror(errno));
            status = 1;
            continue;
        }
        if (argc - first > 1) printf("%s==> %s <==\n", i > first ? "\n" : "", argv[i]);
        if (head(f, lines) < 0) status = 1;
        fclose(f);
    }
    return status;
}
