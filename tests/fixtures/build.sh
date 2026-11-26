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
#   musl-hello-static-pie, rust-hello-static-pie
#                       the C and the Rust program as static PIEs: loaded
#                       at a random address, relocated by their own startup
#                       code
#   glibc-hello-dynamic the C program linked the ordinary way: dynamically,
#                       against glibc (Zig's stand-in for glibc 2.36 at
#                       link time; the real one comes from
#                       scripts/fetch-sysroot.sh when it runs)
#   c-hello-gcc, rust-hello-cargo, go-hello-plain
#                       the C, Rust and Go programs built the ordinary way
#                       on this machine, with no flags: gcc, cargo build,
#                       go build
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
#                       with Zig (zig-link) for want of an installed musl
#   dotnet-hello-app/   .NET as `dotnet publish -r linux-x64
#                       --self-contained` builds it: a folder with the
#                       JIT runtime, less the runtime's native libraries
#                       (scripts/fetch-dotnet-runtime.sh has those)
#   dotnet-hello-aot    .NET as `dotnet publish -r linux-x64
#                       -p:PublishAot=true` builds it: dynamically linked
#                       against glibc, position independent
set -euo pipefail
cd "$(dirname "$0")"

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s \
    -o bin/musl-hello-static src/hello.c

zig cc -target x86_64-linux-musl -static -no-pie -O2 -s -pthread \
    -o bin/musl-threads-static src/threads.c

rustc -O --target x86_64-unknown-linux-musl -C relocation-model=static \
    -C strip=symbols -o bin/rust-hello-static src/hello.rs

# The same two as static position-independent executables, which is what
# both toolchains build unless told otherwise (for Zig's clang: -pie).
zig cc -target x86_64-linux-musl -static -fPIE -pie -O2 -s \
    -o bin/musl-hello-static-pie src/hello.c
rustc -O --target x86_64-unknown-linux-musl -C strip=symbols \
    -o bin/rust-hello-static-pie src/hello.rs

zig cc -target x86_64-linux-gnu.2.36 -O2 -s \
    -o bin/glibc-hello-dynamic src/hello.c

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' \
    -o bin/go-hello-static src/hello.go

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp src/dotnet-hello/hello.csproj src/dotnet-hello/Program.cs "$work"
ZIG_LINK_TARGET=x86_64-linux-musl dotnet publish "$work/hello.csproj" -c Release -r linux-musl-x64 \
    -p:PublishAot=true -p:StaticExecutable=true \
    -p:PositionIndependentExecutable=false \
    -p:CppCompilerAndLinker="$PWD/zig-link" -p:LinkerFlavor=lld \
    -o "$work/out" >/dev/null
cp "$work/out/hello" bin/dotnet-hello-static

# The same program as `dotnet publish -r linux-x64 -p:PublishAot=true`
# builds it: position independent, dynamically linked against glibc. The
# one thing that differs from that command is the linker's C library:
# Zig's stand-in for a plain glibc instead of this machine's own, because
# a distribution built for newer CPUs only (x86-64-v3, -v4) marks every
# program linked on it as needing such a CPU.
rm -rf "$work/out" "$work/bin" "$work/obj"
ZIG_LINK_TARGET=x86_64-linux-gnu.2.36 dotnet publish "$work/hello.csproj" -c Release -r linux-x64 \
    -p:PublishAot=true \
    -p:CppCompilerAndLinker="$PWD/zig-link" -p:LinkerFlavor=lld \
    -o "$work/out" >/dev/null
cp "$work/out/hello" bin/dotnet-hello-aot

# And as `dotnet publish -r linux-x64 --self-contained` leaves it: a folder
# with a host program, the runtime and its JIT compiler as shared
# libraries, and the program as an assembly. Trimmed (-p:PublishTrimmed),
# which leaves out the parts of the class library the program does not
# use: 23 MB instead of 80. Of those, 20 MB are the runtime's native
# libraries, which publishing copies unchanged from Microsoft's runtime
# package; they are not checked in but fetched from that package
# (scripts/fetch-dotnet-runtime.sh) and compared here. If the SDK on this
# machine publishes another runtime version than that script pins, the
# comparison fails: change the version and the checksum there.
rm -rf "$work/out" "$work/bin" "$work/obj"
dotnet publish "$work/hello.csproj" -c Release -r linux-x64 --self-contained \
    -p:PublishTrimmed=true -o "$work/out" >/dev/null
../../scripts/fetch-dotnet-runtime.sh >/dev/null
rm -rf bin/dotnet-hello-app
mkdir bin/dotnet-hello-app
for f in "$work/out"/*; do
    name="$(basename "$f")"
    if [[ -f "../../dotnet-runtime/$name" ]]; then
        cmp "$f" "../../dotnet-runtime/$name" # the same file: not kept twice
    elif [[ "$name" != *.pdb && "$name" != *.dbg ]]; then
        cp "$f" bin/dotnet-hello-app/
    fi
done

# The same three programs built as a developer on this machine builds
# them, with nothing added: `gcc hello.c`, `cargo build --release`,
# `go build`. They are linked against this machine's C library; a
# distribution built for newer CPUs marks them as needing one too.
gcc -O2 -o bin/c-hello-gcc src/hello.c
cargo_dir="$work/cargo"
mkdir -p "$cargo_dir/src"
printf '[package]\nname = "hello"\nversion = "0.1.0"\nedition = "2021"\n' >"$cargo_dir/Cargo.toml"
cp src/hello.rs "$cargo_dir/src/main.rs"
(cd "$cargo_dir" && cargo build -q --release)
cp "$cargo_dir/target/release/hello" bin/rust-hello-cargo
go_dir="$work/go"
mkdir -p "$go_dir"
printf 'module hello\n\ngo 1.22\n' >"$go_dir/go.mod"
cp src/hello.go "$go_dir/"
(cd "$go_dir" && go build -o "$OLDPWD/bin/go-hello-plain" .)

ls -l bin bin/dotnet-hello-app
