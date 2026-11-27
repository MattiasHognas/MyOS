#!/usr/bin/env bash
# Run the benchmark (tools/bench/bench.zig, and the .NET workload of
# tools/bench/dotnet when there is a .NET SDK) in a Linux guest and a MyOS
# guest under the same QEMU and KVM, with the same CPUs and memory, and
# print the two side by side. The same static program runs on both.
#
#   tools/bench/run.sh [--cpus N] [--save]
#
# The Linux guest boots the host's own kernel image (/usr/lib/modules/
# $(uname -r)/vmlinuz, or $BENCH_LINUX_KERNEL) with the benchmark as its
# /init, twice: with its default mitigations and with mitigations=off.
# MyOS runs the benchmark from its test image (scenario "bench"), built
# ReleaseSafe: optimized, with its safety checks on, as it ships.
#
# Results go to zig-out/bench/; with --save also to
# tools/bench/results/<commit>.csv, the record kept per commit.
#
# For numbers that mean something: an idle host, the performance CPU
# governor and no turbo if you can set them; and look at the spread
# (min, max) as well as the median. Under KVM, timer and IPI exits weigh
# on the switching benchmarks for both kernels alike.
set -euo pipefail
cd "$(dirname "$0")/../.."  # the repository root

cpus=4
save=false
while (($#)); do
    case "$1" in
        --cpus) cpus="$2"; shift 2 ;;
        --save) save=true; shift ;;
        *) echo "Usage: $0 [--cpus N] [--save]" >&2; exit 2 ;;
    esac
done
[[ -w /dev/kvm ]] || { echo "bench: needs KVM (/dev/kvm)" >&2; exit 1; }
memory=1G
out=zig-out/bench
mkdir -p "$out"

# --- Build: the programs, MyOS's kernel and its test image.
zig build -Doptimize=ReleaseSafe
zig build test-kernel -Doptimize=ReleaseSafe
# The .NET workload, ahead of time and static (as the fixture
# dotnet-hello-static is built), if there is a .NET SDK.
extra="$out/extra"
rm -rf "$extra"
mkdir -p "$extra/usr/bin"
if command -v dotnet >/dev/null; then
    work="$out/dotnet"
    rm -rf "$work"
    mkdir -p "$work"
    cp tools/bench/dotnet/bench.csproj tools/bench/dotnet/Program.cs "$work/"
    ZIG_LINK_TARGET=x86_64-linux-musl dotnet publish "$work/bench.csproj" -c Release -r linux-musl-x64 \
        -p:PublishAot=true -p:StaticExecutable=true -p:PositionIndependentExecutable=false \
        -p:CppCompilerAndLinker="$PWD/tests/fixtures/zig-link" -p:LinkerFlavor=lld -o "$work/out" >/dev/null
    cp "$work/out/dotnet-bench" "$extra/usr/bin/dotnet-bench"
else
    echo "bench: no dotnet: the .NET workload is left out" >&2
fi
MYOS_INITRD_EXTRA="$extra" bash scripts/build.sh --package-test >/dev/null

# --- Linux: the host's kernel, the benchmark as /init.
kernel="${BENCH_LINUX_KERNEL:-/usr/lib/modules/$(uname -r)/vmlinuz}"
[[ -r "$kernel" ]] || { echo "bench: cannot read a Linux kernel at $kernel (set BENCH_LINUX_KERNEL)" >&2; exit 1; }
cpio_dir="$out/linux-initramfs"
rm -rf "$cpio_dir"
mkdir -p "$cpio_dir"
cp zig-out/bin/bin-bench "$cpio_dir/init"
[[ -f "$extra/usr/bin/dotnet-bench" ]] && cp "$extra/usr/bin/dotnet-bench" "$cpio_dir/dotnet-bench"
(cd "$cpio_dir" && find . | cpio -o -H newc --quiet) >"$out/linux-initramfs.cpio"

qemu_common=(-machine q35 -enable-kvm -cpu host,+invtsc -smp "$cpus" -m "$memory"
    -display none -monitor none -serial stdio -no-reboot)

run_linux() { # $1: extra kernel arguments; $2: the output file
    timeout 600 qemu-system-x86_64 "${qemu_common[@]}" \
        -kernel "$kernel" -initrd "$out/linux-initramfs.cpio" \
        -append "console=ttyS0 rdinit=/init quiet loglevel=0 $1" \
        </dev/null | tr -d '\r' >"$2" || true
}

run_myos() { # $1: the output file
    timeout 600 qemu-system-x86_64 "${qemu_common[@]}" \
        -cdrom zig-out/test/os.iso -boot d \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -fw_cfg name=opt/myos/scenario,string=bench \
        </dev/null | tr -d '\r' >"$1" || true
}

echo "bench: Linux ($(basename "$(dirname "$kernel")")), default mitigations" >&2
run_linux "" "$out/linux.log"
echo "bench: Linux, mitigations=off" >&2
run_linux "mitigations=off" "$out/linux-nomit.log"
echo "bench: MyOS" >&2
run_myos "$out/myos.log"

for f in linux linux-nomit myos; do
    grep -q '^BENCH_DONE' "$out/$f.log" || { echo "bench: the $f run did not finish; see $out/$f.log" >&2; exit 1; }
    grep '^bench,' "$out/$f.log" | grep -v '^bench,kernel' >"$out/$f.csv"
done

# --- Side by side: the median ns per operation, and MyOS against Linux.
commit=$(git rev-parse --short HEAD)
{
    echo "# $(date -u +%Y-%m-%dT%H:%MZ) commit $commit, $cpus CPUs under KVM ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'))"
    echo "name,copies,linux_ns,linux_nomit_ns,myos_ns,myos_vs_linux"
    join -t, -j1 \
        <(awk -F, '{print $2":"$3","$4}' "$out/linux.csv" | sort) \
        <(awk -F, '{print $2":"$3","$4}' "$out/linux-nomit.csv" | sort) |
        join -t, -j1 - <(awk -F, '{print $2":"$3","$4}' "$out/myos.csv" | sort) |
        awk -F, '{ split($1, k, ":"); printf "%s,%s,%s,%s,%s,%.2f\n", k[1], k[2], $2, $3, $4, $4 / $2 }' |
        sort -t, -k1,1 -k2,2n
} >"$out/compare.csv"
column -t -s, <"$out/compare.csv"
if $save; then
    mkdir -p tools/bench/results
    cp "$out/compare.csv" "tools/bench/results/$commit.csv"
    echo "bench: saved tools/bench/results/$commit.csv" >&2
fi
