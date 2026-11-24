#!/usr/bin/env bash
# Run os.iso (built by scripts/build.sh) in QEMU with serial output on the terminal.
#
# Usage: scripts/run-qemu.sh [--gdb] [--bios] [--no-kvm] [--smp N] [-- extra QEMU args]
#   --gdb     start paused and wait for GDB on localhost:1234 (see docs/debugging.md)
#   --bios    boot with legacy BIOS instead of UEFI (OVMF)
#   --no-kvm  use software emulation even if KVM is available
#   --smp N   give the machine N CPUs (default 1)
set -euo pipefail
cd "$(dirname "$0")/.."  # run from the repository root

gdb=0
bios=0
kvm=1
smp=1
extra=()
while (($#)); do
    case "$1" in
        --gdb) gdb=1 ;;
        --bios) bios=1 ;;
        --no-kvm) kvm=0 ;;
        --smp) smp="${2:?--smp needs a number of CPUs}"; shift ;;
        --) shift; extra=("$@"); break ;;
        *) echo "unknown option: $1 (see the header of $0)" >&2; exit 2 ;;
    esac
    shift
done

[[ -f os.iso ]] || { echo "os.iso not found; run scripts/build.sh first" >&2; exit 1; }
[[ -f disk.img ]] || { echo "disk.img not found; run scripts/build.sh first" >&2; exit 1; }

args=(
    -M q35 -m 2G -smp "$smp" -cdrom os.iso
    -serial stdio -no-reboot -no-shutdown
    -drive file=disk.img,if=none,id=nvm,format=raw
    -device nvme,serial=myos0001,drive=nvm
)

if ((!bios)); then
    ovmf=""
    for f in /usr/share/edk2/x64/OVMF.4m.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { ovmf="$f"; break; }
    done
    [[ -n "$ovmf" ]] || { echo "OVMF firmware not found; install edk2-ovmf or use --bios" >&2; exit 1; }
    args+=(-bios "$ovmf")
fi

if ((kvm)) && [[ -w /dev/kvm ]]; then
    args+=(-enable-kvm -cpu host)
else
    args+=(-cpu max)
fi

if ((gdb)); then
    # -s: GDB server on tcp::1234, -S: don't start the CPU until GDB continues.
    args+=(-s -S)
    echo "QEMU is waiting for GDB: gdb -x scripts/kernel.gdb (see docs/debugging.md)" >&2
fi

exec qemu-system-x86_64 "${args[@]}" "${extra[@]}"
