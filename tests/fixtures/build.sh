#!/usr/bin/env bash
# Build the fixture programs: MyOS's test programs for Linux, from the
# sources in tests/fixtures/src, with stock toolchains and nothing of MyOS
# in them. The kernel tests run them unmodified.
#
# They are built, not stored: the repository holds the sources only, and
# what the toolchains put into a binary is the business of whoever builds
# it. scripts/build.sh runs this script when it packs a test image.
#
# Usage: tests/fixtures/build.sh [--force]
#
# Each group needs its toolchain; a group whose toolchain is missing is
# left out with a note, and the kernel tests that need it say they were
# skipped. Nothing is rebuilt while the sources, this script and the
# toolchains' versions are as they were (bin/.stamp); --force rebuilds.
#
#   musl-hello-static   C, statically linked against musl (Zig's bundled
#                       musl and clang: `zig cc -target x86_64-linux-musl`)
#   musl-threads-static C with pthreads: mutex, condition variable, barrier,
#                       thread-local storage, join, a timed wait
#   musl-hello-static-pie
#                       the C program as a static PIE: loaded at a random
#                       address, relocated by its own start-up code
#   glibc-hello-dynamic the C program linked dynamically against glibc
#                       (Zig's stand-in for glibc 2.36 at link time; the
#                       real one comes from scripts/fetch-sysroot.sh)
#   c-hello-gcc         the C program built with plain `gcc` (needs gcc)
#   rust-hello-static, rust-hello-static-pie
#                       Rust with its standard library, statically linked
#                       against musl, at a fixed address and as a static
#                       PIE (needs rustc with the x86_64-unknown-linux-musl
#                       target)
#   rust-hello-cargo    the Rust program built with plain `cargo build`
#   go-hello-static     Go: goroutines, a channel, the garbage collector,
#                       built without cgo and stripped
#   go-hello-plain      the same with plain `go build` (needs go)
#   dotnet-hello-static .NET compiled ahead of time (Native AOT) for
#                       linux-musl, statically linked at a fixed address,
#                       with Zig as the linker (zig-link). Not how a .NET
#                       developer builds (docs/todo.md, 9): it shows what
#                       the runtime's core asks of the kernel
#   dotnet-hello-aot    `dotnet publish -r linux-x64 -p:PublishAot=true`:
#                       dynamically linked against glibc
#   dotnet-realapp/     the same of an app (`src/dotnet-realapp`): the generic
#                       host, configuration reload, FileSystemWatcher,
#                       Process.Start, File.Copy, a named Mutex, raw console.
#   dotnet-hello-app/   `dotnet publish -r linux-x64 --self-contained`,
#                       trimmed: a folder with the JIT runtime (needs the
#                       .NET SDK)
set -euo pipefail
cd "$(dirname "$0")"

have() { command -v "$1" >/dev/null 2>&1; }
note() { echo "fixtures: $*" >&2; }

# What the result depends on: sources, this script and its linker
# wrapper, and the versions of the toolchains there are.
versions() {
    for tool in zig gcc rustc cargo go dotnet; do
        if have "$tool"; then printf '%s: %s\n' "$tool" "$("$tool" version 2>/dev/null || "$tool" --version 2>/dev/null | head -1)"; fi
    done
}
stamp="$( (cat build.sh zig-link; find src -type f | sort | xargs cat; versions) | sha256sum | cut -d' ' -f1)"
if [[ "${1:-}" != --force && -f bin/.stamp && "$(cat bin/.stamp)" == "$stamp" ]]; then
    echo "fixtures: tests/fixtures/bin (up to date)"
    exit 0
fi

rm -rf bin
mkdir -p bin
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- C, with Zig: always there, it builds MyOS.
zig cc -target x86_64-linux-musl -static -no-pie -O2 -s -o bin/musl-hello-static src/hello.c
zig cc -target x86_64-linux-musl -static -no-pie -O2 -s -pthread -o bin/musl-threads-static src/threads.c
zig cc -target x86_64-linux-musl -static -fPIE -pie -O2 -s -o bin/musl-hello-static-pie src/hello.c
zig cc -target x86_64-linux-gnu.2.36 -O2 -s -o bin/glibc-hello-dynamic src/hello.c

if have gcc; then
    gcc -O2 -o bin/c-hello-gcc src/hello.c
else
    note "no gcc: c-hello-gcc left out"
fi

# --- Rust.
if have rustc && rustc --print target-libdir --target x86_64-unknown-linux-musl >/dev/null 2>&1 &&
    [[ -d "$(rustc --print target-libdir --target x86_64-unknown-linux-musl)" ]]; then
    rustc -O --target x86_64-unknown-linux-musl -C relocation-model=static \
        -C strip=symbols -o bin/rust-hello-static src/hello.rs
    rustc -O --target x86_64-unknown-linux-musl -C strip=symbols \
        -o bin/rust-hello-static-pie src/hello.rs
else
    note "no rustc with the x86_64-unknown-linux-musl target: rust-hello-static(-pie) left out"
fi
if have cargo; then
    mkdir -p "$work/cargo/src"
    printf '[package]\nname = "hello"\nversion = "0.1.0"\nedition = "2021"\n' >"$work/cargo/Cargo.toml"
    cp src/hello.rs "$work/cargo/src/main.rs"
    (cd "$work/cargo" && cargo build -q --release)
    cp "$work/cargo/target/release/hello" bin/rust-hello-cargo
else
    note "no cargo: rust-hello-cargo left out"
fi

# --- Go.
if have go; then
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' \
        -o bin/go-hello-static src/hello.go
    mkdir -p "$work/go"
    printf 'module hello\n\ngo 1.22\n' >"$work/go/go.mod"
    cp src/hello.go "$work/go/"
    (cd "$work/go" && go build -o "$OLDPWD/bin/go-hello-plain" .)
else
    note "no go: go-hello-static and go-hello-plain left out"
fi

# --- .NET.
if have dotnet; then
    project="$work/dotnet"
    publish() { # <output> <dotnet publish arguments...>: the hello-world
        local out="$1"
        shift
        publishFrom src/dotnet-hello hello.csproj "$out" "$@"
    }
    publishFrom() { # <source folder> <project file> <output> <dotnet publish arguments...>
        local src="$1" proj="$2" out="$3"
        shift 3
        rm -rf "$project"
        mkdir -p "$project"
        cp "$src"/* "$project/"
        dotnet publish "$project/$proj" -c Release "$@" -o "$project/out" >/dev/null
        rm -f "$project/out"/*.pdb "$project/out"/*.dbg
        cp -r "$project/out" "$out"
    }
    # Static against musl: Zig as the linker, for want of an installed musl.
    ZIG_LINK_TARGET=x86_64-linux-musl publish "$work/static" -r linux-musl-x64 \
        -p:PublishAot=true -p:StaticExecutable=true -p:PositionIndependentExecutable=false \
        -p:CppCompilerAndLinker="$PWD/zig-link" -p:LinkerFlavor=lld
    cp "$work/static/hello" bin/dotnet-hello-static
    # As its tools build it, linked against a plain glibc instead of this
    # machine's: a distribution built for newer CPUs only (x86-64-v3, -v4)
    # marks every program linked on it as needing such a CPU, which would
    # keep it from QEMU's emulated CPU.
    ZIG_LINK_TARGET=x86_64-linux-gnu.2.36 publish "$work/aot" -r linux-x64 -p:PublishAot=true \
        -p:CppCompilerAndLinker="$PWD/zig-link" -p:LinkerFlavor=lld
    cp "$work/aot/hello" bin/dotnet-hello-aot
    # Self-contained with the JIT runtime, trimmed: 23 MB instead of 80.
    publish bin/dotnet-hello-app -r linux-x64 --self-contained -p:PublishTrimmed=true
    # An app rather than a hello-world: the generic host with configuration
    # that reloads, file watching, a child process, a named mutex (25 MB).
    rm -rf bin/dotnet-realapp
    publishFrom src/dotnet-realapp realapp.csproj bin/dotnet-realapp -r linux-x64 --self-contained -p:PublishTrimmed=true
else
    note "no dotnet: dotnet-hello-static, dotnet-hello-aot and dotnet-hello-app left out"
fi

echo "$stamp" >bin/.stamp
ls -l bin
