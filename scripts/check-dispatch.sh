#!/usr/bin/env bash
# Check that the normal kernel calls its syscall dispatcher directly.
#
# Only the test kernel may reach the dispatcher through a pointer that can
# be replaced (arch.syscall.setHandler, so tests can watch syscalls). In the
# normal kernel such a pointer would be one more thing a stray write could
# redirect, and an indirect branch on every syscall. The pointer is a
# variable, so it shows in the symbol table: it must be in the test kernel
# (which also proves this check can see it) and not in the normal one.
#
# Usage: scripts/check-dispatch.sh <kernel.elf> <kernel-test.elf>
# Exits 1 on a failure, 2 on a usage error.
set -euo pipefail

objdump="${OBJDUMP:-objdump}"
symbol='arch.x86_64.syscall.handler'

if (($# != 2)); then
    echo "Usage: $0 <kernel.elf> <kernel-test.elf>" >&2
    exit 2
fi

# True if the symbol table of ELF file $1 has the handler pointer.
has_pointer() {
    "$objdump" -t "$1" | awk -v s="$symbol" '$NF == s { found = 1 } END { exit !found }'
}

status=0
if has_pointer "$1"; then
    echo "FAIL [$1]: has a replaceable syscall handler ($symbol)" >&2
    status=1
fi
if ! has_pointer "$2"; then
    echo "FAIL [$2]: no $symbol; the test kernel should have one, so this check may be looking for the wrong name" >&2
    status=1
fi
((status == 0)) && echo "dispatch [$1]: syscalls call the dispatcher directly"
exit "$status"
