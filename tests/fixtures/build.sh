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
#   go-hello-static     Go (no cgo): goroutines, a channel, the garbage
#                       collector
#   rust-hello-static   Rust with its standard library, statically linked
#                       against musl at a fixed address (rustup target
#                       x86_64-unknown-linux-musl)
#   dotnet-hello-static .NET compiled ahead of time (Native AOT) for
#                       linux-musl, statically linked at a fixed address.
#                       Not how a .NET developer builds (docs/todo.md, 9):
#                       it shows what the runtime's core asks of the kernel
#                       before the kernel can load shared libraries. Linked
#                       with Zig (zig-musl-link) for want of an installed musl
set -euo pipefail
cd "$(dirname "$0")"

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s \
    -o bin/musl-hello-static src/hello.c

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s -pthread \
    -o bin/musl-threads-static src/threads.c

rustc -O --target x86_64-unknown-linux-musl -C relocation-model=static \
    -C strip=symbols -o bin/rust-hello-static src/hello.rs

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' \
    -o bin/go-hello-static src/hello.go

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp src/dotnet-hello/hello.csproj src/dotnet-hello/Program.cs "$work"
dotnet publish "$work/hello.csproj" -c Release -r linux-musl-x64 \
    -p:PublishAot=true -p:StaticExecutable=true \
    -p:PositionIndependentExecutable=false \
    -p:CppCompilerAndLinker="$PWD/zig-musl-link" -p:LinkerFlavor=lld \
    -o "$work/out" >/dev/null
cp "$work/out/hello" bin/dotnet-hello-static

ls -l bin
