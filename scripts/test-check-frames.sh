#!/usr/bin/env bash
# Test scripts/check-frames.sh against hand-written disassembly.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-frames.sh"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

failures=0
# expect <name> <exit status> <regex the output must match> <disassembly>
expect() {
    local name="$1" want_status="$2" want_re="$3" got status=0
    printf '%s\n' "$4" >"$dir/$name.txt"
    got="$(bash "$script" --disasm "$dir/$name.txt" 2>&1)" || status=$?
    if [[ "$status" != "$want_status" ]]; then
        echo "FAIL: $name: exit status $status, want $want_status; output: $got" >&2
        failures=$((failures + 1))
    elif ! grep -Eq -- "$want_re" <<<"$got"; then
        echo "FAIL: $name: output does not match '$want_re': $got" >&2
        failures=$((failures + 1))
    fi
}

# Small frames pass; the largest one is reported.
expect small 0 'largest in use: 512 bytes \(big\)' \
'ffffffff80000000 <small>:
ffffffff80000000:	push   %rbp
ffffffff80000001:	sub    $0x40,%rsp
ffffffff80000005:	call   ffffffff80000100 <big>
ffffffff8000000a:	ret
ffffffff80000100 <big>:
ffffffff80000100:	sub    $0x200,%rsp
ffffffff80000107:	ret'

# A frame over the soft limit warns but passes.
expect soft 0 '^warning .*: medium has a 3000-byte stack frame \(over 2048\)$' \
'ffffffff80000000 <medium>:
ffffffff80000000:	sub    $0xbb8,%rsp
ffffffff80000007:	ret'

# A called function over the hard limit fails.
expect hard 1 '^FAIL .*: huge has a 4248-byte stack frame \(limit 4088\)' \
'ffffffff80000000 <caller>:
ffffffff80000000:	sub    $0x18,%rsp
ffffffff80000004:	call   ffffffff80000100 <huge>
ffffffff80000009:	ret
ffffffff80000100 <huge>:
ffffffff80000100:	sub    $0x1098,%rsp
ffffffff80000107:	ret'

# 4088 bytes is still allowed, 4096 is not.
expect at_limit 0 'largest in use: 4088 bytes \(edge\)' \
'ffffffff80000000 <caller>:
ffffffff80000000:	sub    $0x18,%rsp
ffffffff80000004:	call   ffffffff80000100 <edge>
ffffffff80000100 <edge>:
ffffffff80000100:	sub    $0xff8,%rsp'
expect page 1 '^FAIL .*: page has a 4096-byte stack frame' \
'ffffffff80000000 <caller>:
ffffffff80000000:	sub    $0x18,%rsp
ffffffff80000004:	call   ffffffff80000100 <page>
ffffffff80000100 <page>:
ffffffff80000100:	sub    $0x1000,%rsp'

# An oversized function nothing refers to is only noted.
expect dead 0 '^note .*: __divei4 has a 16424-byte stack frame but nothing refers to it$' \
'ffffffff80000000 <small>:
ffffffff80000000:	sub    $0x40,%rsp
ffffffff80000004:	ret
ffffffff80000100 <__divei4>:
ffffffff80000100:	sub    $0x4028,%rsp
ffffffff80000107:	call   ffffffff80000100 <__divei4>
ffffffff8000010c:	ret'

# Taking its address (a function pointer) or a tail call counts as a reference;
# a jump into the middle of another function does not hide the size either.
expect address_taken 1 '^FAIL .*: huge has a 8192-byte stack frame' \
'ffffffff80000000 <small>:
ffffffff80000000:	sub    $0x40,%rsp
ffffffff80000004:	lea    0xf5(%rip),%rdi        # ffffffff80000100 <huge>
ffffffff80000100 <huge>:
ffffffff80000100:	sub    $0x2000,%rsp'
expect tail_call 1 '^FAIL .*: huge has a 8192-byte stack frame' \
'ffffffff80000000 <small>:
ffffffff80000000:	sub    $0x40,%rsp
ffffffff80000004:	jmp    ffffffff80000100 <huge>
ffffffff80000100 <huge>:
ffffffff80000100:	sub    $0x2000,%rsp'

# A frame allocated through the stack-probe routine is measured too, and the
# probe routine itself (which moves RSP a page at a time) is not a frame.
expect probed 1 '^FAIL .*: probed has a 8200-byte stack frame' \
'ffffffff80000000 <caller>:
ffffffff80000000:	sub    $0x18,%rsp
ffffffff80000004:	call   ffffffff80000100 <probed>
ffffffff80000100 <probed>:
ffffffff80000100:	push   %rbp
ffffffff80000101:	mov    $0x2008,%eax
ffffffff80000106:	call   ffffffff80000200 <__zig_probe_stack>
ffffffff8000010b:	sub    %rax,%rsp
ffffffff80000200 <__zig_probe_stack>:
ffffffff80000200:	sub    $0x1000,%rsp
ffffffff80000207:	ret'
expect probe_only 0 'largest in use: 24 bytes \(caller\)' \
'ffffffff80000000 <caller>:
ffffffff80000000:	sub    $0x18,%rsp
ffffffff80000004:	mov    $0x10,%eax
ffffffff80000009:	call   ffffffff80000200 <__zig_probe_stack>
ffffffff80000200 <__zig_probe_stack>:
ffffffff80000200:	sub    $0x1000,%rsp'

# Input without any frame is an error, not a silent pass.
expect empty 2 'no stack frames found' 'not a disassembly'

# The limits can be changed from the environment.
printf '%s\n' 'ffffffff80000000 <f>:' 'ffffffff80000000:	sub    $0x200,%rsp' \
    'ffffffff80000004:	call   ffffffff80000000 <g>' 'ffffffff80000010 <g>:' \
    'ffffffff80000010:	sub    $0x200,%rsp' 'ffffffff80000014:	call   ffffffff80000000 <f>' >"$dir/env.txt"
if MYOS_FRAME_HARD_LIMIT=256 bash "$script" --disasm "$dir/env.txt" >/dev/null 2>&1; then
    echo "FAIL: MYOS_FRAME_HARD_LIMIT=256 did not fail a 512-byte frame" >&2
    failures=$((failures + 1))
fi

# No arguments is a usage error.
status=0
bash "$script" >/dev/null 2>&1 || status=$?
if [[ "$status" != 2 ]]; then
    echo "FAIL: no arguments: exit status $status, want 2" >&2
    failures=$((failures + 1))
fi

if ((failures)); then exit 1; fi
echo "check-frames tests passed"
