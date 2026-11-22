#!/usr/bin/env bash
# Check that no function in a kernel ELF has a stack frame that could step
# over a kernel stack's guard page.
#
# A kernel stack has one unmapped 4 KiB guard page below it (src/kernel/
# kstack.zig). A function whose frame is smaller than a page cannot move the
# stack pointer past the guard without touching it, so an overflow always
# faults. A larger frame could land in the stack below. Zig has no
# alloca or variable-length arrays, so the fixed frame sizes in the function
# prologues are the whole story.
#
# Usage: scripts/check-frames.sh <elf>...
#        scripts/check-frames.sh --disasm <file>...   (objdump -d output; for tests)
#
# For every function the frame size is the largest `sub $N,%rsp`, or the size
# passed to the stack-probe routine. The script
#   - fails if a frame is larger than MYOS_FRAME_HARD_LIMIT (default 4088: a
#     page minus the return address the next call pushes) and anything in the
#     disassembly refers to the function,
#   - notes such a function if nothing refers to it (dead library code that
#     the linker kept, e.g. compiler-rt's big-integer division),
#   - warns if a frame is larger than MYOS_FRAME_SOFT_LIMIT (default 2048).
#
# Limits: a reference from a data table (a function pointer in .rodata) is
# not seen, and hand-written assembly that moves RSP by a computed amount is
# not understood. Exits 1 on a failure, 2 on a usage error.
set -euo pipefail

hard="${MYOS_FRAME_HARD_LIMIT:-4088}"
soft="${MYOS_FRAME_SOFT_LIMIT:-2048}"
objdump="${OBJDUMP:-objdump}"

from_disasm=false
if [[ "${1:-}" == --disasm ]]; then
    from_disasm=true
    shift
fi
if (($# == 0)); then
    echo "Usage: $0 [--disasm] <file>..." >&2
    exit 2
fi

# Print "F <hex size> <function>" for each frame allocation and
# "R <function>" for each function something refers to.
scan() {
    awk '
        /^[0-9a-f]+ <[^>]+>:$/ {
            fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn)
            imm = ""
            next
        }
        fn == "" { next }
        {
            # References: call/jmp targets and address-of comments, "<name>" without an offset.
            line = $0
            while (match(line, /<[^>+]+>/)) {
                ref = substr(line, RSTART + 1, RLENGTH - 2)
                if (ref != fn && !(ref in seen)) { seen[ref] = 1; print "R", ref }
                line = substr(line, RSTART + RLENGTH)
            }
        }
        /sub +\$0x[0-9a-f]+,%rsp/ {
            match($0, /\$0x[0-9a-f]+/)
            print "F", substr($0, RSTART + 1, RLENGTH - 1), fn
        }
        # Probed frames: the size goes to the probe routine in eax/rax.
        /mov[a-z]* +\$0x[0-9a-f]+,%[er]ax/ {
            match($0, /\$0x[0-9a-f]+/)
            imm = substr($0, RSTART + 1, RLENGTH - 1)
            next
        }
        /call.*<(__zig_probe_stack|__chkstk|___chkstk_ms)>/ {
            if (imm != "") print "F", imm, fn
        }
        { imm = "" }
    '
}

status=0
for file in "$@"; do
    if [[ ! -r "$file" ]]; then
        echo "$0: cannot read $file" >&2
        exit 2
    fi
    if $from_disasm; then
        records="$(scan <"$file")"
    else
        records="$("$objdump" -d --no-show-raw-insn "$file" | scan)"
    fi

    declare -A frame=() referenced=()
    functions=0
    while read -r kind a b; do
        case "$kind" in
            R) referenced["$a"]=1 ;;
            F)
                # The probe routine itself moves RSP a page at a time; that is not a frame.
                [[ "$b" == __zig_probe_stack || "$b" == __chkstk || "$b" == ___chkstk_ms ]] && continue
                size=$((a))
                if ((size > ${frame["$b"]:-0})); then frame["$b"]=$size; fi
                ;;
        esac
    done <<<"$records"

    largest=0
    largest_fn="(none)"
    for fn in "${!frame[@]}"; do
        size=${frame["$fn"]}
        functions=$((functions + 1))
        if ((size > hard)); then
            if [[ -n "${referenced["$fn"]:-}" ]]; then
                echo "FAIL [$file]: $fn has a $size-byte stack frame (limit $hard): it can step over a stack guard page" >&2
                status=1
            else
                echo "note [$file]: $fn has a $size-byte stack frame but nothing refers to it"
            fi
            continue
        fi
        if ((size > soft)); then
            echo "warning [$file]: $fn has a $size-byte stack frame (over $soft)"
        fi
        if ((size > largest)); then
            largest=$size
            largest_fn=$fn
        fi
    done
    if ((functions == 0)); then
        echo "$0: no stack frames found in $file (not a disassembly objdump understands?)" >&2
        exit 2
    fi
    echo "frames [$file]: $functions functions with a frame, largest in use: $largest bytes ($largest_fn)"
    unset frame referenced
done
exit $status
