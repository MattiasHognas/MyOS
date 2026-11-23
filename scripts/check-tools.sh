#!/usr/bin/env bash
# Compare the tools on PATH with the versions MyOS is built and tested with
# (tools.versions).
#
# Usage: check-tools.sh [tool...]      tools: zig limine qemu xorriso kcov
#        (default: zig limine qemu xorriso)
#
# A tool that is missing or has another version is reported. What happens
# then depends on where this runs:
#   - in CI (the CI variable is set), or with MYOS_STRICT_TOOLS=1: exit 1;
#   - otherwise: a warning, and exit 0. A development machine's packages
#     move on by themselves; the warning says what differs so that a strange
#     test result can be traced to it.
# MYOS_STRICT_TOOLS=0 turns the failure off even in CI.
#
# To get the exact versions: scripts/install-<tool>.sh <directory>.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools.versions
source "$root/tools.versions"

strict=0
[[ -n "${CI:-}" ]] && strict=1
[[ -n "${MYOS_STRICT_TOOLS:-}" ]] && strict="$MYOS_STRICT_TOOLS"

# The first version number in a tool's version output: digits and dots,
# with xorriso's patch level (".pl02") if there is one.
first_version() {
    grep -oE '[0-9]+(\.[0-9]+)*(\.pl[0-9]+)?' | head -n 1
}

# Print the version of the tool named $1 as found on PATH, or nothing.
found_version() {
    case "$1" in
        zig) zig version 2>/dev/null | first_version ;;
        limine) limine --version 2>/dev/null | head -n 1 | first_version ;;
        qemu) qemu-system-x86_64 --version 2>/dev/null | head -n 1 | first_version ;;
        xorriso) xorriso --version 2>&1 | head -n 1 | first_version ;;
        kcov) kcov --version 2>/dev/null | head -n 1 | first_version ;;
    esac
}

wanted_version() {
    case "$1" in
        zig) echo "$ZIG_VERSION" ;;
        limine) echo "$LIMINE_VERSION" ;;
        qemu) echo "$QEMU_VERSION" ;;
        xorriso) echo "$XORRISO_VERSION" ;;
        kcov) echo "$KCOV_VERSION" ;;
        *)
            echo "check-tools.sh: unknown tool '$1' (zig limine qemu xorriso kcov)" >&2
            exit 2
            ;;
    esac
}

tools=("$@")
((${#tools[@]})) || tools=(zig limine qemu xorriso)

problems=()
for tool in "${tools[@]}"; do
    want="$(wanted_version "$tool")"
    got="$(found_version "$tool" || true)"
    if [[ -z "$got" ]]; then
        problems+=("$tool: not found (want $want)")
    elif [[ "$got" != "$want" ]]; then
        problems+=("$tool: found $got, want $want")
    fi
done

((${#problems[@]})) || exit 0

if [[ "$strict" == 1 ]]; then
    echo "error: tool versions differ from tools.versions:" >&2
else
    echo "warning: tool versions differ from tools.versions (CI uses exactly those):" >&2
fi
printf '  %s\n' "${problems[@]}" >&2
echo "  install the pinned version with scripts/install-<tool>.sh <directory>, or update tools.versions" >&2
[[ "$strict" == 1 ]] && exit 1
exit 0
