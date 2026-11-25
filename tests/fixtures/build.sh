#!/usr/bin/env bash
# Build the fixture programs: programs for Linux, built by stock toolchains
# with nothing of MyOS in them, that the kernel tests run unmodified.
#
# The binaries in tests/fixtures/bin are checked in, so that building and
# testing MyOS needs none of these toolchains. Run this script after
# changing a source in tests/fixtures/src, and commit the result.
#
# Usage: tests/fixtures/build.sh
#
#   musl-hello-static   C, statically linked against musl (Zig's bundled
#                       musl and clang: `zig cc -target x86_64-linux-musl`)
#   musl-threads-static C with pthreads: mutex, condition variable, barrier,
#                       thread-local storage, join, a timed wait
#   rust-hello-static   Rust with its standard library, statically linked
#                       against musl at a fixed address (rustup target
#                       x86_64-unknown-linux-musl)
set -euo pipefail
cd "$(dirname "$0")"

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s \
    -o bin/musl-hello-static src/hello.c

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s -pthread \
    -o bin/musl-threads-static src/threads.c

rustc -O --target x86_64-unknown-linux-musl -C relocation-model=static \
    -C strip=symbols -o bin/rust-hello-static src/hello.rs

ls -l bin
