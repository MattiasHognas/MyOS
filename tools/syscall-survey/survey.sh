#!/usr/bin/env bash
# Which system calls a Linux program really needs, measured the way Loupe
# (ASPLOS 2024) does it, with strace alone:
#
#   1. run the program under strace, nothing injected, and keep its output
#      and exit status;
#   2. list the calls it makes (strace -f);
#   3. for each call, run it again with every use of that call failing with
#      ENOSYS, and again with every use faking success (returning 0);
#   4. a call is needed if the program breaks both ways; it may fail if
#      ENOSYS is fine, and may be faked if returning 0 is. "output differs"
#      means the program ends as before and says something else (fewer
#      CPUs, say): to be judged by what the output is.
#
# Usage: tools/syscall-survey/survey.sh NAME -- COMMAND [ARGS...]
# Prints one Markdown table row per call: | call | uses | ENOSYS | faked |.
# Environment: SURVEY_TIMEOUT (seconds per run, default 20).
set -euo pipefail

name=$1
shift
[[ ${1:-} == -- ]] && shift
timeout_s=${SURVEY_TIMEOUT:-20}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

run() { # run [strace options...] -- writes $work/out, returns the status
    local status=0
    # (In a subshell with its errors thrown away: bash reports a program
    # that a signal ended, which is an outcome here, not news.)
    (timeout "$timeout_s" strace -f -qq -o /dev/null "$@" -- "${cmd[@]}" >"$work/out" 2>&1 </dev/null) 2>/dev/null || status=$?
    return "$status"
}

cmd=("$@")
# The normal run is under strace too, with nothing injected: what the
# program sees then differs from a run without it (`$_`, timing) only as
# every injected run does.
base_status=0
run || base_status=$?
mv "$work/out" "$work/base"

# The calls and how often each is made.
timeout "$timeout_s" strace -f -qq -c -U name,calls -o "$work/count" -- "${cmd[@]}" >/dev/null 2>&1 </dev/null || true
mapfile -t calls < <(awk 'NR>2 && $1 !~ /^-+$/ && $1 != "total" && NF==2 {print $1" "$2}' "$work/count" | sort)

verdict() { # verdict STATUS: how the run compares with the normal one
    if [[ $1 != "$base_status" ]]; then
        if [[ $1 == 124 ]]; then echo "hangs"; else echo "breaks ($1)"; fi
    elif cmp -s "$work/out" "$work/base"; then
        echo ok
    else
        echo "output differs"
    fi
}

echo "<!-- $name: exit status $base_status -->"
for entry in "${calls[@]}"; do
    call=${entry% *}
    uses=${entry#* }
    case $call in exit_group | exit | execve) continue ;; esac # nothing to learn: they end or start it
    s=0; run -e inject="$call":error=ENOSYS || s=$?
    enosys=$(verdict "$s")
    s=0; run -e inject="$call":retval=0 || s=$?
    faked=$(verdict "$s")
    echo "| \`$call\` | $uses | $enosys | $faked |"
done
