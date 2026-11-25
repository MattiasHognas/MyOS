/* A C program for Linux, linked statically against musl: the first
 * program MyOS runs that was not written for it. It prints what it was
 * started with and exits with its number of arguments. */
#include <stdio.h>

int main(int argc, char **argv, char **envp) {
    printf("hello from musl: %d args\n", argc);
    for (int i = 0; i < argc; i++) printf("argv[%d]=%s\n", i, argv[i]);
    for (char **e = envp; *e; e++) printf("env %s\n", *e);
    return argc;
}
