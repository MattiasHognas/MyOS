#!/usr/bin/env bash
# Write tests/fixtures/THIRD_PARTY_NOTICES.txt: the copyright notices and
# licences of the code that the toolchains copy into the fixture binaries
# (C libraries, language runtimes, the .NET runtime), taken from the
# toolchains installed on this machine. build.sh runs it after building the
# fixtures; the file is checked in with them, and scripts/build.sh puts it
# into every image that carries them.
set -euo pipefail
cd "$(dirname "$0")"

out=THIRD_PARTY_NOTICES.txt
dotnet_version=10.0.13
nuget="$HOME/.nuget/packages"
rust_doc="$(rustc --print sysroot)/share/doc/rust"
zig_lib="$(zig env | sed -n 's/.*\.lib_dir = "\(.*\)",/\1/p')"

section() { # <title> <file...>
    printf '\n\n%s\n%s\n\n' "$1" "$(printf '=%.0s' $(seq 1 ${#1}))"
    shift
    for f in "$@"; do cat "$f"; printf '\n'; done
}

# HTML to text, enough for the Rust project's notice files.
html_text() {
    python3 -I -c 'import html, re, sys
t = sys.stdin.read()
t = re.sub(r"(?is)<(script|style).*?</\1>", "", t)
t = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</h[1-6]>|</tr>|</pre>", "\n", t)
t = re.sub(r"<[^>]+>", "", t)
t = html.unescape(t)
print(re.sub(r"\n{3,}", "\n\n", t).strip())' <"$1"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
html_text "$rust_doc/COPYRIGHT-library.html" >"$work/rust-library.txt"

{
cat <<'HEAD'
Third-party notices for the programs in tests/fixtures/bin
==========================================================

The programs in tests/fixtures/bin are MyOS's test programs (sources in
tests/fixtures/src), built with other projects' toolchains. Those
toolchains copy parts of their own libraries into what they build, and
those parts come with the copyright notices and licences below. What MyOS
itself wrote is under MyOS's licence.

Which program contains what:

  musl-hello-static, musl-hello-static-pie, musl-threads-static
      musl libc (MIT), and Zig's compiler-rt (MIT, the Zig licence).
  rust-hello-static, rust-hello-static-pie
      musl libc (MIT); the Rust standard library (MIT or Apache-2.0, with
      the notices of the crates it is made of).
  rust-hello-cargo
      the Rust standard library, as above; glibc's and GCC's start-up
      code (see the last section).
  go-hello-static, go-hello-plain
      the Go runtime and standard library (BSD-3-Clause).
  dotnet-hello-static, dotnet-hello-aot, dotnet-hello-app/*
      the .NET runtime and libraries (MIT, with the third-party notices
      Microsoft ships with them); dotnet-hello-static also musl libc
      (MIT) and Zig's compiler-rt (MIT).
  c-hello-gcc, glibc-hello-dynamic
      glibc's and GCC's start-up code (see the last section).
HEAD
section "musl libc" "$zig_lib/libc/musl/COPYRIGHT"
section "Zig (compiler-rt)" /usr/share/licenses/zig/LICENSE
# The standard library's notices only (COPYRIGHT-library); the toolchain's
# own, much longer, cover the compiler, which is not in the programs.
section "The Rust standard library" "$work/rust-library.txt" "$rust_doc/licenses/MIT.txt" "$rust_doc/licenses/Apache-2.0.txt"
section "Go" /usr/share/licenses/go/LICENSE
section ".NET runtime and libraries" "$nuget/microsoft.netcore.app.runtime.linux-x64/$dotnet_version/LICENSE.TXT" "$nuget/microsoft.netcore.app.runtime.linux-x64/$dotnet_version/THIRD-PARTY-NOTICES.TXT"
cat <<'TAIL'


Start-up code from glibc and GCC
================================

A program linked against glibc by gcc or by a linker gcc drives contains
glibc's start-up objects (crt1.o, crti.o, crtn.o, part of
libc_nonshared.a) and GCC's (crtbegin.o, crtend.o, parts of libgcc). Both
come with permission to link them into any program and to distribute that
program without restriction from them: glibc's under the exception in the
files themselves ("In addition to the permissions in the GNU Lesser
General Public License, the Free Software Foundation gives you unlimited
permission to link the compiled version of this file with other programs,
and to distribute those programs without any restriction coming from the
use of this file"), GCC's under the GCC Runtime Library Exception 3.1. They
are named here for completeness; the libraries themselves (libc.so.6 and
the rest) are not in these programs and come from the system they run on.
TAIL
} >"$out"
echo "notices: tests/fixtures/$out ($(wc -c <"$out") bytes)"
